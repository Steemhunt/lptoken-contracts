// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { FixedPoint96 } from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import { LaunchLiquidityVault } from "../src/LaunchLiquidityVault.sol";
import { LpTokenVault } from "../src/LpTokenVault.sol";
import { TokenLaunchpad } from "../src/TokenLaunchpad.sol";
import { LpTokenTestBase } from "./utils/LpTokenTestBase.sol";

/// @notice The compound cap's break-even (`CompoundCapBreakEven.t.sol`) assumes the
/// manipulator loses the LP fee on both swap legs. The launch token's creator does not lose
/// all of it: the launch position returns 40% of its target fees and 40% of its counter
/// fees to the creator, the vault's own fees and the 60% / 20% of launch fees that reach it
/// as NAV accrue to lpTOKEN holders pro rata, and the creator may hold a large lpTOKEN
/// position and park its own JIT liquidity in range. These tests put all of that in one
/// pair of hands and check that a round trip around a capped compound still loses, in both
/// directions, across consecutive intervals. The treasury's 40% of counter fees is outside
/// this model: the treasury is the protocol's own, and an attacker holding it is not a
/// threat this cap is asked to price.
///
/// The vault is seeded with idle balances worth a million times its position — far more
/// than fees could ever accumulate — so every compound in the attack is bound by the cap
/// alone, not by what happens to be idle; every compound asserts that it was. Each scenario
/// is also run without the compound: the difference is what the manipulated compound let
/// the attacker extract, and the attack is only a real test of the cap where that is
/// positive. A rational attacker stops the moment it is ahead, so the loss is asserted after
/// every interval, not only at the end.
///
/// The attacker's JIT liquidity is sized against the protocol base at the manipulated price,
/// not at the launch tick: the launch position's range ends at the start tick, so it is
/// inactive there and counts for nothing in the base, while a move into its range activates
/// liquidity a thousand times the bootstrap vault's. The JIT is therefore sized from the
/// vault position plus the launch position's nominal liquidity, and every interval asserts
/// it still dominates the base once the price has moved.
///
/// The attacker's wealth is marked in the counter currency at the launch price, which every
/// round trip is asserted to restore exactly: native balance, token balance, the gross claim
/// of its lpTOKEN on the vault, and every creator payout, flushed before each mark.
contract CompoundCapInsiderAttackTest is LpTokenTestBase {
    using StateLibrary for IPoolManager;

    /// r = sqrt(p'/p) = 1.0001^(tick/2): 1.1x, 2x, 10x, 100x, 1000x, 10000x.
    int24[6] internal DEVIATIONS =
        [int24(1_906), int24(13_862), int24(46_052), int24(92_103), int24(138_155), int24(184_207)];

    /// What the attacker controls and how the attack runs. The attacker is always the
    /// creator, and keeps the creator's 40% of the launch position's fees on each side.
    struct Insider {
        /// The attacker's lpTOKEN, as a multiple of the launch's dead-receiver supply:
        /// 4 is 80% of all shares, 20 is about 95%.
        uint256 shareMultiple;
        /// The attacker parks its own full-range liquidity in the pool for the round trip,
        /// this many times the worst-case protocol base — vault position plus the launch
        /// position's nominal liquidity — so most swap fees are paid to itself. Zero for none.
        uint256 jitMultiple;
        /// How many consecutive compound intervals are attacked.
        uint256 intervals;
        /// Alternate the manipulation's direction from one interval to the next.
        bool alternate;
    }

    TokenLaunchpad internal launchpad;
    LaunchLiquidityVault internal launchVault;
    address internal token;
    LpTokenVault internal vault;
    PoolKey internal key;
    address internal attacker = makeAddr("insider");
    uint160 internal launchSqrtPrice;
    /// The launch position's nominal liquidity: inactive at the launch tick, live below it.
    uint128 internal launchLiquidity;
    bytes32 internal constant JIT_SALT = keccak256("insider-jit");

    function setUp() public override {
        super.setUp();
        launchpad = _deployLaunchpad(manager, factory, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE);
        launchVault = launchpad.liquidityVault();
        vm.prank(owner);
        factory.bindLaunchpad(address(launchpad));

        TokenLaunchpad.TokenMetadata memory metadata = TokenLaunchpad.TokenMetadata({
            name: "Insider Cat",
            symbol: "ICAT",
            imageUrl: "ipfs://insider",
            websiteUrl: "https://example.com",
            twitterHandle: "insider_cat",
            telegramHandle: "insider_cat_chat"
        });
        // The attacker is the creator, and buys nothing at launch.
        vm.deal(attacker, LAUNCH_INITIAL_LP_QUOTE);
        vm.prank(attacker);
        address vaultAddress;
        (token, vaultAddress,) = launchpad.createToken{ value: LAUNCH_INITIAL_LP_QUOTE }(
            metadata,
            keccak256("insider"),
            0,
            0,
            LAUNCH_START_TICK,
            LAUNCH_INITIAL_LP_QUOTE,
            block.timestamp
        );
        vault = LpTokenVault(payable(vaultAddress));
        key = launchpad.poolKey(token);
        launchSqrtPrice = TickMath.getSqrtPriceAtTick(LAUNCH_START_TICK);
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertEq(tick, LAUNCH_START_TICK, "launch should leave the pool at the launch tick");
        (,, launchLiquidity,) = launchVault.positions(token);
        assertGt(
            launchLiquidity, vault.positionLiquidity() * 1000, "launch liquidity is not dominant"
        );
        assertEq(
            launchVault.activeLiquidity(token, address(vault)),
            0,
            "launch range is inactive at its start tick"
        );

        // Endowed far beyond anything the pool can absorb, even with JIT liquidity a hundred
        // times the launch position's in range, so every move is limited by its price target,
        // never by a balance.
        vm.deal(attacker, 1e40);
        deal(token, attacker, 1e40);
        vm.startPrank(attacker);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        IERC20(token).approve(address(liquidityRouter), type(uint256).max);
        IERC20(token).approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    // --- Attacker wealth, marked at the launch price -----------------------------------

    /// Tokens valued in the counter currency at the launch price. The counter is currency0,
    /// so one token is worth 1 / price counter.
    function _tokensInCounter(uint256 amount) private view returns (uint256) {
        uint256 step = FullMath.mulDiv(amount, FixedPoint96.Q96, launchSqrtPrice);
        return FullMath.mulDiv(step, FixedPoint96.Q96, launchSqrtPrice);
    }

    /// Everything the attacker holds, after every payout owed to it has been flushed.
    function _wealth() private returns (uint256) {
        launchVault.distributeFees(token);
        (uint256 targetClaim, uint256 counterClaim) =
            vault.claimForShares(vault.balanceOf(attacker));
        uint256 tokens = IERC20(token).balanceOf(attacker) + targetClaim;
        uint256 counter = attacker.balance + counterClaim;
        return counter + _tokensInCounter(tokens);
    }

    // --- Moves ----------------------------------------------------------------------------

    /// Moves the pool to `targetTick` under a price limit, so the swap costs exactly the move
    /// and stops there. Selling the counter (currency0) lowers the tick; selling the token
    /// raises it.
    function _moveTo(int24 targetTick) private {
        uint160 targetSqrtPrice = TickMath.getSqrtPriceAtTick(targetTick);
        (uint160 current,,,) = manager.getSlot0(key.toId());
        if (current != targetSqrtPrice) {
            bool zeroForOne = targetSqrtPrice < current;
            vm.prank(attacker);
            swapRouter.swap{ value: zeroForOne ? 1e34 : 0 }(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(1e34),
                    sqrtPriceLimitX96: targetSqrtPrice
                }),
                PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
                bytes("")
            );
        }
        (uint160 reached,,,) = manager.getSlot0(key.toId());
        assertEq(reached, targetSqrtPrice, "the pool did not reach the target price");
    }

    /// The attacker's own full-range liquidity, added for a round trip and removed after it.
    function _jit(int256 liquidityDelta) private {
        vm.prank(attacker);
        liquidityRouter.modifyLiquidity{ value: liquidityDelta > 0 ? 1e34 : 0 }(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: liquidityDelta,
                salt: JIT_SALT
            }),
            bytes("")
        );
    }

    /// Mints the attacker `multiple` times the vault's current share supply, proportionally.
    function _acquireShares(uint256 multiple) private {
        (uint256 targetAssets, uint256 counterAssets) = vault.totalAssets();
        uint256 maxTarget = (targetAssets * multiple * 101) / 100;
        uint256 maxCounter = (counterAssets * multiple * 101) / 100;
        vm.prank(attacker);
        vault.mintPair{ value: maxCounter }(
            maxTarget, maxCounter, 1, attacker, vm.getBlockTimestamp()
        );
    }

    /// Idle balances worth a million times the vault's position — far more than fees could
    /// ever accumulate — so each compound reaches its cap even where the launch position's
    /// liquidity swells the base; the question is whether the cap alone holds. Native goes
    /// in directly, since the vault only accepts it from the PoolManager and the launch fee
    /// source.
    function _seedIdle() private {
        (uint256 targetAssets, uint256 counterAssets) = vault.totalAssets();
        deal(
            token,
            address(vault),
            IERC20(token).balanceOf(address(vault)) + targetAssets * 1_000_000
        );
        vm.deal(address(vault), address(vault).balance + counterAssets * 1_000_000);
    }

    // --- The attack -----------------------------------------------------------------------

    struct Outcome {
        /// Net wealth change after each interval, in order; positive means the attack paid.
        int256[] prefixPnl;
        /// Liquidity the compounds deployed at the manipulated price, summed for the log.
        uint256 compounded;
        /// How many compounds executed.
        uint256 compounds;
    }

    /// Runs the attack at `deviation` ticks from the launch tick (negative is down), with or
    /// without calling `compound` at the manipulated price. Without it, the round trips are
    /// the control: what the insider loses to fees it does not get back, and nothing else.
    /// Wealth is marked after every interval, since an attacker that is ahead stops there.
    function _attack(Insider memory insider, int24 deviation, bool withCompound)
        private
        returns (Outcome memory outcome)
    {
        if (insider.shareMultiple != 0) _acquireShares(insider.shareMultiple);
        _seedIdle();
        uint256 before = _wealth();
        outcome.prefixPnl = new int256[](insider.intervals);

        for (uint256 i; i < insider.intervals; ++i) {
            uint64 availableAt = vault.compoundAvailableAt();
            if (availableAt > vm.getBlockTimestamp()) vm.warp(availableAt);
            int24 step = insider.alternate && i % 2 == 1 ? -deviation : deviation;

            // Sized against the base the move is about to activate, not the one at the
            // launch tick, where the launch position counts for nothing.
            int256 jitLiquidity;
            if (insider.jitMultiple != 0) {
                jitLiquidity = int256(
                    (uint256(vault.positionLiquidity()) + uint256(launchLiquidity))
                        * insider.jitMultiple
                );
                _jit(jitLiquidity);
            }
            _moveTo(LAUNCH_START_TICK + step);
            if (insider.jitMultiple != 0) {
                assertGe(
                    uint256(jitLiquidity),
                    uint256(vault.compoundBase()) * insider.jitMultiple,
                    "JIT is not dominant at the manipulated price"
                );
            }
            if (withCompound) {
                uint128 cap = vault.compoundLiquidityCap();
                uint128 added = vault.compound(1, vm.getBlockTimestamp());
                assertGe(uint256(added) * 100, uint256(cap) * 99, "this compound was not cap-bound");
                outcome.compounded += added;
                outcome.compounds += 1;
            }
            _moveTo(LAUNCH_START_TICK);
            (uint160 restored,,,) = manager.getSlot0(key.toId());
            assertEq(restored, launchSqrtPrice, "round trip did not restore the launch price");
            if (insider.jitMultiple != 0) _jit(-jitLiquidity);

            outcome.prefixPnl[i] = int256(_wealth()) - int256(before);
        }
    }

    /// Every deviation, in both directions, each from a clean launch. Asserts that every
    /// compound was bound by its cap, that after every interval the manipulated compound had
    /// let the attacker extract something relative to the control — so the cap is what is
    /// being tested — and that after every interval the attack had still not paid, so
    /// stopping early would not have rescued it.
    function _assertAlwaysLoses(Insider memory insider, string memory label) private {
        for (uint256 i; i < DEVIATIONS.length; ++i) {
            for (uint256 direction; direction < 2; ++direction) {
                int24 deviation = direction == 0 ? DEVIATIONS[i] : -DEVIATIONS[i];

                uint256 snap = vm.snapshotState();
                Outcome memory control = _attack(insider, deviation, false);
                vm.revertToState(snap);

                snap = vm.snapshotState();
                Outcome memory attack = _attack(insider, deviation, true);
                vm.revertToState(snap);

                uint256 last = insider.intervals - 1;
                emit log_named_string("scenario", label);
                emit log_named_int("  deviation (ticks)", deviation);
                emit log_named_uint("  liquidity compounded", attack.compounded);
                emit log_named_int(
                    "  control pnl, no compound (wei of counter)", control.prefixPnl[last]
                );
                emit log_named_int("  attack pnl (wei of counter)", attack.prefixPnl[last]);
                emit log_named_int(
                    "  extracted by the mispriced compound",
                    attack.prefixPnl[last] - control.prefixPnl[last]
                );

                assertEq(attack.compounds, insider.intervals, "a compound did not execute");
                for (uint256 k; k < insider.intervals; ++k) {
                    assertGt(
                        attack.prefixPnl[k] - control.prefixPnl[k],
                        0,
                        "the manipulated compound extracted nothing by this interval"
                    );
                    assertLt(
                        attack.prefixPnl[k], 0, "the insider attack was ahead after an interval"
                    );
                }
            }
        }
    }

    // --- Scenarios ------------------------------------------------------------------------

    /// The creator alone: 40% of the launch position's fees on each side come back. Three
    /// intervals, with the loss asserted after each, so the single-interval attack is the
    /// first of them.
    function testCreatorLosesAcrossIntervals() public {
        _assertAlwaysLoses(
            Insider({ shareMultiple: 0, jitMultiple: 0, intervals: 3, alternate: false }), "creator"
        );
    }

    /// The creator with its own liquidity at ten times the worst-case protocol base and no
    /// lpTOKEN: it recovers the creator's fees and its JIT's fees, and bears none of the
    /// vault's mispricing loss — the JIT combination with the least offsetting it.
    function testCreatorWithDominantJitButNoSharesLoses() public {
        _assertAlwaysLoses(
            Insider({ shareMultiple: 0, jitMultiple: 10, intervals: 1, alternate: false }),
            "creator+JIT x10, no lpTOKEN, one interval"
        );
        _assertAlwaysLoses(
            Insider({ shareMultiple: 0, jitMultiple: 10, intervals: 3, alternate: false }),
            "creator+JIT x10, no lpTOKEN"
        );
    }

    /// Toward the limit where the attacker's liquidity is nearly all of the pool.
    function testCreatorWithOverwhelmingJitButNoSharesLoses() public {
        _assertAlwaysLoses(
            Insider({ shareMultiple: 0, jitMultiple: 100, intervals: 1, alternate: false }),
            "creator+JIT x100, no lpTOKEN, one interval"
        );
    }

    /// A creator holding 80% of the lpTOKEN: the vault's own fees and the launch NAV mostly
    /// come back — but so does most of the mispricing loss the attack inflicts on the vault.
    function testCreatorAndLargeHolderLose() public {
        _assertAlwaysLoses(
            Insider({ shareMultiple: 4, jitMultiple: 0, intervals: 3, alternate: false }),
            "creator+80% holder"
        );
    }

    /// Near-total ownership: 95% of the shares.
    function testCreatorAndNearTotalHolderLose() public {
        _assertAlwaysLoses(
            Insider({ shareMultiple: 20, jitMultiple: 0, intervals: 3, alternate: false }),
            "creator+95% holder"
        );
    }

    /// The holder and the JIT together.
    function testCreatorLargeHolderWithDominantJitLoses() public {
        _assertAlwaysLoses(
            Insider({ shareMultiple: 4, jitMultiple: 10, intervals: 3, alternate: false }),
            "creator+80% holder+JIT x10"
        );
    }

    /// Everything at once, alternating the direction each interval for an hour of intervals.
    function testCreatorAlternatingDirectionsAcrossSixIntervalsLoses() public {
        _assertAlwaysLoses(
            Insider({ shareMultiple: 4, jitMultiple: 10, intervals: 6, alternate: true }),
            "creator+80% holder+JIT x10, alternating x6"
        );
    }
}
