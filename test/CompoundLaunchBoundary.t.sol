// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import { LaunchLiquidityVault } from "../src/LaunchLiquidityVault.sol";
import { LpTokenVault } from "../src/LpTokenVault.sol";
import { TokenLaunchpad } from "../src/TokenLaunchpad.sol";
import { LpTokenTestBase } from "./utils/LpTokenTestBase.sol";

/// @notice The compound base is read at one tick while the round-trip fee that bounds it is
/// paid along the whole path. Those two agree everywhere inside the launch range, because the
/// launch position backs every tick below the start tick. They would diverge only at or above
/// the start tick, where the launch position is inactive: a caller sitting there could dip one
/// tick-spacing inside, collect a base built on liquidity their path never traded through, and
/// unwind. These tests pin the boundary behaviour and show that position is unreachable.
contract CompoundLaunchBoundaryTest is LpTokenTestBase {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    uint256 private constant Q96 = 1 << 96;

    TokenLaunchpad internal launchpad;
    LaunchLiquidityVault internal launchVault;
    LpTokenVault internal vault;
    address internal token;
    PoolKey internal key;

    address internal trader = makeAddr("boundary trader");
    address internal atk = makeAddr("boundary attacker");

    function setUp() public override {
        super.setUp();
        launchpad = _deployLaunchpad(manager, factory, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE);
        launchVault = launchpad.liquidityVault();
        vm.prank(owner);
        factory.bindLaunchpad(address(launchpad));

        uint256 value = launchpad.initialLpQuote();
        vm.deal(alice, value);
        vm.prank(alice);
        (address t, address v,) = launchpad.createToken{ value: value }(
            TokenLaunchpad.TokenMetadata("Boundary Cat", "BCAT", "", "", "", ""),
            keccak256("compound boundary"),
            0,
            TickMath.MIN_SQRT_PRICE + 1,
            LAUNCH_START_TICK,
            LAUNCH_INITIAL_LP_QUOTE,
            block.timestamp
        );
        token = t;
        vault = LpTokenVault(payable(v));
        key = launchpad.poolKey(t);
    }

    /// @dev At the start tick the launch range is closed on an exclusive upper bound, so the
    /// launch position backs nothing and must not enter the base. One tick-spacing lower it
    /// backs every trade and does enter. Pinning both sides keeps the discontinuity a
    /// deliberate property rather than an accident of the range comparison.
    function testLaunchPositionLeavesTheBaseAtTheStartTick() public {
        assertEq(_tick(), launchpad.startTick());

        (,, uint128 nominal,) = launchVault.positions(token);
        assertGt(nominal, 0);
        assertEq(launchVault.activeLiquidity(token, address(vault)), 0);

        uint128 vaultLiquidity = vault.positionLiquidity();
        assertEq(vault.compoundBase(), vaultLiquidity, "launch position counted at the boundary");
        uint128 capAtBoundary = vault.compoundLiquidityCap();

        // Cross one tick-spacing into the launch range.
        _buy(trader, 0.01 ether);
        assertLt(_tick(), launchpad.startTick());

        assertEq(launchVault.activeLiquidity(token, address(vault)), nominal);
        assertEq(
            vault.compoundBase(),
            vault.positionLiquidity() + nominal,
            "launch position missing from the base inside its range"
        );
        assertGt(vault.compoundLiquidityCap(), capAtBoundary);
    }

    /// @dev The divergence is only reachable from at or above the start tick. Every token in
    /// existence outside the pool was bought through it, and both fee legs leave the pool
    /// permanently on the creator and treasury shares, so a completed round trip always ends
    /// below where it started. Compounding does not close the gap either: the vault's own
    /// full-range liquidity deepens every tick below the boundary as it grows. The exit tick
    /// therefore moves away from the start tick, never toward it.
    function testRoundTripsCannotReachTheStartTick() public {
        int24 startTick = launchpad.startTick();
        int24 firstExitTick;
        int24 lastExitTick;

        for (uint256 round; round < 8; ++round) {
            _buy(trader, 30 ether);
            // A partial exit first, so the target fee leg accrues and compound can pair.
            _sell(trader, IERC20(token).balanceOf(trader) / 3);
            _compoundEverything();
            _sell(trader, IERC20(token).balanceOf(trader));
            _compoundEverything();

            lastExitTick = _tick();
            assertLt(lastExitTick, startTick, "a completed round trip reached the start tick");
            assertEq(launchVault.activeLiquidity(token, address(vault)), _nominalLaunchLiquidity());
            if (round == 0) firstExitTick = lastExitTick;
        }

        assertEq(IERC20(token).balanceOf(trader), 0);
        assertLt(lastExitTick, firstExitTick, "exit tick drifted toward the start tick");
    }

    /// @dev End to end on the launch path, from the closest state trading can reach to the
    /// boundary — where the base is largest relative to the vault's own position. Deploying at
    /// a manipulated spot price does move value to the manipulator, and this measures how
    /// much; the property is that it never reaches what the round trip costs them. The cap's
    /// own margin against the fee-derived break-even is pinned separately in
    /// `CompoundCapBreakEven`, which drives the cap rather than the vault's idle balance.
    function testBoundaryManipulationNeverRepaysItself() public {
        _buy(trader, 30 ether);
        _sell(trader, IERC20(token).balanceOf(trader) / 3);
        _compoundEverything();
        _sell(trader, IERC20(token).balanceOf(trader));
        launchVault.distributeFees(token);
        assertLt(launchpad.startTick() - _tick(), 400, "setup did not land near the boundary");

        _checkManipulationDirection(true);
        _checkManipulationDirection(false);
    }

    function _checkManipulationDirection(bool pushDown) private {
        uint256 outer = vm.snapshotState();
        // Fund once, up front. Every later leg spends this balance, so the closing value is a
        // real profit and loss rather than an artefact of topping the attacker up mid-flow.
        vm.deal(atk, 1_000 ether);
        _buy(atk, 5 ether);
        vm.warp(vault.compoundAvailableAt());

        (uint160 referenceSqrtPrice,,,) = manager.getSlot0(key.toId());
        uint256 navBefore = _navAt(referenceSqrtPrice);
        uint256 baselineSnap = vm.snapshotState();

        // Baseline: the identical round trip, without touching the vault.
        uint256 attackerBefore = _attackerValueAt(referenceSqrtPrice);
        _manipulate(pushDown);
        _unwindTo(pushDown, referenceSqrtPrice);
        uint256 baseline = _navAt(referenceSqrtPrice);
        int256 baselineAttackerPnl =
            int256(_attackerValueAt(referenceSqrtPrice)) - int256(attackerBefore);
        vm.revertToState(baselineSnap);

        // Attack: the same round trip with a compound executed at the manipulated price.
        _manipulate(pushDown);
        uint128 deployed;
        try vault.compound(0, block.timestamp) returns (uint128 added) {
            deployed = added;
        } catch { }
        _unwindTo(pushDown, referenceSqrtPrice);
        uint256 attacked = _navAt(referenceSqrtPrice);
        int256 attackAttackerPnl =
            int256(_attackerValueAt(referenceSqrtPrice)) - int256(attackerBefore);

        assertGt(deployed, 0, "compound did not execute at the manipulated price");
        emit log_named_uint("pushDown", pushDown ? 1 : 0);
        emit log_named_uint("  liquidity deployed at the manipulated price", deployed);
        emit log_named_decimal_uint("  holder NAV before the manipulation", navBefore, 18);
        emit log_named_decimal_uint("  holder NAV, no compound", baseline, 18);
        emit log_named_decimal_uint("  holder NAV, compounded", attacked, 18);
        emit log_named_decimal_int("  manipulator PnL, no compound", baselineAttackerPnl, 18);
        emit log_named_decimal_int("  manipulator PnL, compounded", attackAttackerPnl, 18);

        // Deploying at a manipulated spot price always moves something to the manipulator;
        // the cap exists to keep that transfer below what the round trip costs them, not to
        // make it zero. What the manipulator recovers is exactly what holders give up against
        // the no-compound branch — but that branch is itself well above where holders started,
        // because the manipulation paid them fees on both legs. Holders end ahead either way,
        // so the recovery reduces their gain rather than costing them anything.
        assertGt(attacked, navBefore, "compound left holders below their pre-manipulation NAV");
        int256 extracted = attackAttackerPnl - baselineAttackerPnl;
        assertGt(extracted, 0);
        // Whatever the manipulator recovers comes out of holders, to within the rounding of
        // the two liquidity conversions the comparison runs through.
        assertApproxEqAbs(
            uint256(extracted), baseline - attacked, 2, "extraction is not a holder transfer"
        );

        // The property the cap actually asserts: manipulating to exploit compound never
        // repays its own fee cost, so the whole round trip stays a loss.
        assertLt(attackAttackerPnl, int256(0), "manipulating to exploit compound was profitable");
        assertLt(
            uint256(extracted),
            uint256(-baselineAttackerPnl),
            "compound extraction reached the round-trip fee cost"
        );
        vm.revertToState(outer);
    }

    function _manipulate(bool pushDown) private {
        if (pushDown) {
            _buy(atk, 3 ether);
        } else {
            _sell(atk, IERC20(token).balanceOf(atk));
        }
    }

    /// @dev Both branches must finish at the same price or their NAV is not comparable, and
    /// compound changes pool depth enough that a fixed-size unwind would not. Swapping into
    /// an exact price limit pins the endpoint instead.
    function _unwindTo(bool pushDown, uint160 referenceSqrtPrice) private {
        (uint160 current,,,) = manager.getSlot0(key.toId());
        if (current == referenceSqrtPrice) return;
        bool zeroForOne = current > referenceSqrtPrice;
        uint256 amountIn = zeroForOne ? 400 ether : IERC20(token).balanceOf(atk);
        if (!zeroForOne && amountIn == 0) return;

        vm.startPrank(atk);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap{ value: zeroForOne ? amountIn : 0 }(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amountIn.toInt256(),
                sqrtPriceLimitX96: referenceSqrtPrice
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
        vm.stopPrank();
        (uint160 settled,,,) = manager.getSlot0(key.toId());
        assertEq(settled, referenceSqrtPrice, "unwind did not reach the reference price");
        pushDown;
    }

    /// @dev Holder NAV expressed in the counter leg at a fixed reference price, so the two
    /// branches are compared on the same numeraire and the same pool price.
    function _navAt(uint160 sqrtPriceX96) private view returns (uint256) {
        (uint256 targetAssets, uint256 counterAssets) = vault.totalAssets();
        return _valueAt(sqrtPriceX96, targetAssets, counterAssets);
    }

    /// @dev The manipulator's own book on the same numeraire. Extraction, not holder drift,
    /// is what the fee-derived cap has to bound.
    function _attackerValueAt(uint160 sqrtPriceX96) private view returns (uint256) {
        return _valueAt(sqrtPriceX96, IERC20(token).balanceOf(atk), atk.balance);
    }

    function _valueAt(uint160 sqrtPriceX96, uint256 targetAmount, uint256 counterAmount)
        private
        pure
        returns (uint256)
    {
        uint256 half = FullMath.mulDiv(targetAmount, Q96, sqrtPriceX96);
        return counterAmount + FullMath.mulDiv(half, Q96, sqrtPriceX96);
    }

    function _nominalLaunchLiquidity() private view returns (uint128 liquidity) {
        (,, liquidity,) = launchVault.positions(token);
    }

    function _compoundEverything() private {
        launchVault.distributeFees(token);
        for (uint256 i; i < 30; ++i) {
            vm.warp(vault.compoundAvailableAt());
            try vault.compound(0, block.timestamp) returns (uint128) { }
            catch {
                break;
            }
        }
    }

    function _tick() private view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(key.toId());
    }

    function _buy(address who, uint256 ethIn) private {
        if (who.balance < ethIn) vm.deal(who, ethIn);
        vm.prank(who);
        swapRouter.swap{ value: ethIn }(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -ethIn.toInt256(),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
    }

    function _sell(address who, uint256 amount) private {
        if (amount == 0) return;
        vm.prank(who);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        vm.prank(who);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -amount.toInt256(),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
    }
}
