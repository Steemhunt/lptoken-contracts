// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { FixedPoint96 } from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolModifyLiquidityTest } from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import { LaunchLiquidityVault } from "../src/LaunchLiquidityVault.sol";
import { LpTokenFactory } from "../src/LpTokenFactory.sol";
import { LpTokenVault } from "../src/LpTokenVault.sol";
import { TokenLaunchpad } from "../src/TokenLaunchpad.sol";
import { LaunchpadTestDeployer } from "./utils/LaunchpadTestDeployer.sol";

/// @dev A treasury that cannot take a native payout and can still run the rotation.
contract RejectingTreasury {
    LpTokenFactory internal immutable factory;

    constructor(LpTokenFactory factory_) {
        factory = factory_;
    }

    receive() external payable {
        revert("no native");
    }

    function accept() external {
        factory.acceptTreasury();
    }

    function propose(address successor) external {
        factory.proposeTreasury(successor);
    }
}

/// @notice Compound regressions replayed against the live Robinhood PoolManager: the
/// shapes of the incidents the compound cap, cooldown, and launch-fee plumbing were hardened
/// against, each run on a fresh platform launch on the fork so nothing here touches an
/// existing market. Skipped unless `FORK_RPC_URL` is set, as the dry run is.
///
/// (a) and (b) mirror `testLargeMintLetsCompoundCatchUpWithMatchedBacklog` and
/// `testCompoundPairsOneLegAndLeavesTheOtherOutOfCirculation`: a matched backlog clears
/// within a bounded number of intervals, and what cannot be paired stays idle and
/// redeemable rather than being deployed one-sided. (c) leaves the vault range and comes
/// back, (d) prices the dust-compound cooldown grief the NatSpec admits, (e) fails a
/// treasury payout and retries it, and (f) checks the cap's economic premise on the real
/// pool: a compound at a manipulated price never lets the manipulator extract more than the
/// mispricing loss the cap formula bounds. (g) is the single most dangerous case of
/// `CompoundCapInsiderAttack.t.sol` on live bytecode: the creator, holding no lpTOKEN, with
/// its own liquidity at ten times the protocol base, taking one deep trip into the launch
/// position's range and compounding at the bottom.
contract LpTokenForkCompoundRegressionTest is Test, LaunchpadTestDeployer {
    using StateLibrary for IPoolManager;

    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    bytes32 internal constant POOL_MANAGER_CODEHASH =
        0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626;
    int24 internal constant START_TICK = 198_000;
    uint256 internal constant BOOTSTRAP_QUOTE = 0.001 ether;

    /// r = sqrt(p'/p) = 1.0001^(tick/2): 1.1x, 2x, 10x, 100x, 1000x, 10000x.
    int24[6] internal DEVIATIONS =
        [int24(1_906), int24(13_862), int24(46_052), int24(92_103), int24(138_155), int24(184_207)];

    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;
    LpTokenFactory internal factory;
    TokenLaunchpad internal launchpad;
    LaunchLiquidityVault internal launchVault;
    address internal token;
    LpTokenVault internal vault;
    PoolKey internal key;
    uint160 internal launchSqrtPrice;
    /// The launch position's nominal liquidity: inactive at the launch tick, live below it.
    uint128 internal launchLiquidity;
    bytes32 internal constant JIT_SALT = keccak256("fork creator jit");

    address internal owner = makeAddr("fork owner");
    address internal treasury = makeAddr("fork treasury");
    address internal creator = makeAddr("fork creator");
    /// Moves the price under a limit; endowed far past what the pool can absorb.
    address internal trader = makeAddr("fork trader");
    /// Trades organic volume: buys with the counter and sells back half of what it bought.
    address internal maker = makeAddr("fork volume maker");

    receive() external payable { }

    function setUp() public {
        string memory rpcUrl = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;
        uint256 forkBlock = vm.envOr("FORK_BLOCK_NUMBER", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpcUrl);
        else vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, 4663);
        assertEq(POOL_MANAGER.codehash, POOL_MANAGER_CODEHASH);

        manager = IPoolManager(POOL_MANAGER);
        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        factory = new LpTokenFactory(manager, treasury, owner);
        launchpad = _deployLaunchpad(manager, factory, START_TICK, BOOTSTRAP_QUOTE);
        launchVault = launchpad.liquidityVault();
        vm.prank(owner);
        factory.bindLaunchpad(address(launchpad));

        vm.deal(creator, BOOTSTRAP_QUOTE);
        vm.prank(creator);
        address vaultAddress;
        (token, vaultAddress,) = launchpad.createToken{ value: BOOTSTRAP_QUOTE }(
            TokenLaunchpad.TokenMetadata({
                name: "Fork Compound",
                symbol: "FCOMP",
                imageUrl: "ipfs://fork-compound",
                websiteUrl: "https://example.com",
                twitterHandle: "fork_compound",
                telegramHandle: "fork_compound_chat"
            }),
            keccak256("fork compound regression"),
            0,
            0,
            START_TICK,
            BOOTSTRAP_QUOTE,
            block.timestamp
        );
        vault = LpTokenVault(payable(vaultAddress));
        key = launchpad.poolKey(token);
        launchSqrtPrice = TickMath.getSqrtPriceAtTick(START_TICK);
        (,, launchLiquidity,) = launchVault.positions(token);

        // Both the price mover and the creator are endowed far beyond anything the pool can
        // absorb, so every move is limited by its price target, never by a balance.
        for (uint256 i; i < 2; ++i) {
            address who = i == 0 ? trader : creator;
            vm.deal(who, 1e40);
            deal(token, who, 1e40);
            vm.startPrank(who);
            IERC20(token).approve(address(swapRouter), type(uint256).max);
            IERC20(token).approve(address(liquidityRouter), type(uint256).max);
            IERC20(token).approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    modifier onlyForked() {
        if (address(manager) == address(0)) {
            vm.skip(true);
        }
        _;
    }

    // --- Moves ----------------------------------------------------------------------------

    function _buy(address who, uint256 counterIn) private {
        vm.deal(who, who.balance + counterIn);
        vm.prank(who);
        swapRouter.swap{ value: counterIn }(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(counterIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
    }

    function _sell(address who, uint256 tokenIn) private {
        if (tokenIn == 0) return;
        vm.startPrank(who);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(tokenIn),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
        vm.stopPrank();
    }

    /// Moves the pool to `targetTick` under a price limit, so the swap costs exactly the move
    /// and stops there, and asserts it arrived. Selling the counter (currency0) lowers the
    /// tick; selling the token raises it.
    function _moveTo(int24 targetTick) private {
        _moveTo(trader, targetTick);
    }

    function _moveTo(address mover, int24 targetTick) private {
        uint160 targetSqrtPrice = TickMath.getSqrtPriceAtTick(targetTick);
        (uint160 current,,,) = manager.getSlot0(key.toId());
        if (current != targetSqrtPrice) {
            bool zeroForOne = targetSqrtPrice < current;
            vm.prank(mover);
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

    /// The creator's own full-range liquidity, added for a round trip and removed after it.
    function _creatorJit(int256 liquidityDelta) private {
        vm.prank(creator);
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

    /// Round trips of organic volume through the launch pool, the way fees and launch NAV
    /// accrue: a buy, then a sale of half of what the maker holds, so the price wanders and
    /// comes back rather than being pinned.
    function _volume(uint256 rounds, uint256 counterPerRound) private {
        for (uint256 i; i < rounds; ++i) {
            _buy(maker, counterPerRound);
            _sell(maker, IERC20(token).balanceOf(maker) / 2);
        }
    }

    /// Compounds at every interval until nothing pairable is left or `maxIntervals` pass.
    function _compoundUntilDry(uint256 maxIntervals)
        private
        returns (uint256 calls, uint128 remaining)
    {
        while (calls < maxIntervals) {
            (,, uint128 available,, uint128 executable, uint64 availableAt) =
                vault.previewCompound();
            if (available == 0) break;
            if (availableAt > vm.getBlockTimestamp()) vm.warp(availableAt);
            vault.compound(executable, vm.getBlockTimestamp());
            ++calls;
        }
        (,, remaining,,,) = vault.previewCompound();
    }

    function _tokensInCounter(uint256 amount, uint160 sqrtPrice) private pure returns (uint256) {
        uint256 step = FullMath.mulDiv(amount, FixedPoint96.Q96, sqrtPrice);
        return FullMath.mulDiv(step, FixedPoint96.Q96, sqrtPrice);
    }

    // --- (a) Catch-up after a large launch NAV inflow -------------------------------------

    /// Volume through the launch position sends 60% of its target fees and 20% of its counter
    /// fees to the vault as NAV. A backlog larger than one cap clears within a bounded number
    /// of intervals, so the small bootstrap does not anchor the vault's throughput.
    function testForkCompoundCatchesUpAfterLargeLaunchNavInflow() public onlyForked {
        _volume(8, 5 ether);
        launchVault.distributeFees(token);
        uint128 liquidityBefore = vault.positionLiquidity();

        vm.warp(vault.compoundAvailableAt());
        (,, uint128 backlog, uint128 firstCap,,) = vault.previewCompound();
        assertGt(backlog, firstCap, "fixture needs more than one compound call");

        (uint256 calls, uint128 remaining) = _compoundUntilDry(24);
        emit log_named_uint("intervals to clear the matched backlog", calls);
        assertEq(remaining, 0, "matched backlog did not catch up within 24 intervals");
        assertLe(calls, 18, "matched backlog took too many intervals to clear");
        assertGt(vault.positionLiquidity(), liquidityBefore, "nothing was deployed");
    }

    // --- (b) One-sided idle stays out of circulation --------------------------------------

    /// Compound pairs what it can and stops when one leg runs out; the other leg stays idle,
    /// redeemable, and never deployed one-sided. Which leg is left depends on the buy/sell
    /// mix, so this asserts the shape rather than a side.
    function testForkCompoundLeavesOneSidedIdleOutOfCirculation() public onlyForked {
        _volume(4, 5 ether);
        uint128 liquidityBefore = vault.positionLiquidity();

        vm.warp(vault.compoundAvailableAt());
        for (uint256 i; i < 8; ++i) {
            vm.warp(vm.getBlockTimestamp() + 10 minutes);
            try vault.compound(1, vm.getBlockTimestamp()) { } catch { }
        }

        (uint256 idleTarget, uint256 idleCounter) = vault.idleBalances();
        emit log_named_uint("idle target left", idleTarget);
        emit log_named_uint("idle counter left", idleCounter);
        assertGt(vault.positionLiquidity(), liquidityBefore, "nothing was deployed as depth");
        (,, uint128 available,,,) = vault.previewCompound();
        assertEq(available, 0, "a pairable remainder was left undeployed");
        assertGt(idleTarget + idleCounter, 0, "no surplus was left out of circulation");
        assertTrue(idleTarget == 0 || idleCounter == 0, "both legs left idle while pairable");
    }

    // --- (c) Out of range and back ----------------------------------------------------------

    /// With the price above the vault's range, no protocol liquidity is live, the cap is zero,
    /// and compound refuses rather than deploying at a price the vault is not in. Once the
    /// price returns the base, the cap, and compound all resume.
    function testForkCompoundResumesAfterTickLeavesAndReturnsToRange() public onlyForked {
        _volume(4, 5 ether);
        launchVault.distributeFees(token);
        vm.warp(vault.compoundAvailableAt());

        int24 outside = vault.tickUpper() + key.tickSpacing;
        _moveTo(outside);
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertGe(tick, vault.tickUpper(), "price did not leave the vault range");
        assertEq(vault.compoundBase(), 0, "base counted liquidity that is not live");
        assertEq(vault.compoundLiquidityCap(), 0, "cap is not zero out of range");
        vm.expectRevert(
            abi.encodeWithSelector(LpTokenVault.InsufficientLiquidityAdded.selector, 0, 1)
        );
        vault.compound(1, vm.getBlockTimestamp());

        _moveTo(START_TICK);
        assertGt(vault.compoundBase(), 0, "base did not return with the price");
        assertGt(vault.compoundLiquidityCap(), 0, "cap did not return with the price");
        uint128 added = vault.compound(1, vm.getBlockTimestamp());
        assertGt(added, 0, "compound did not resume in range");
    }

    // --- (d) The dust-compound cooldown grief -------------------------------------------

    /// A dust-sized compound starts the cooldown, which the NatSpec admits. What it cannot
    /// do is chain, or cost more than one interval: the next call waits exactly the interval
    /// and then deploys everything the cap and the backlog allow.
    function testForkDustCompoundOnlyDelaysOneInterval() public onlyForked {
        _volume(1, 0.0005 ether);
        launchVault.distributeFees(token);
        vm.warp(vault.compoundAvailableAt());
        uint128 dust = vault.compound(1, vm.getBlockTimestamp());
        uint64 dustAt = uint64(vm.getBlockTimestamp());
        assertGt(dust, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                LpTokenVault.CompoundCooldown.selector, dustAt + vault.COMPOUND_INTERVAL()
            )
        );
        vault.compound(1, vm.getBlockTimestamp());

        _volume(8, 5 ether);
        launchVault.distributeFees(token);
        (,, uint128 backlog, uint128 cap, uint128 executableNow, uint64 availableAt) =
            vault.previewCompound();
        assertGt(backlog, dust * 100, "fixture needs a real backlog behind the dust");
        assertEq(executableNow, 0, "cooldown did not hold");
        assertEq(availableAt, dustAt + vault.COMPOUND_INTERVAL(), "grief exceeded one interval");

        vm.warp(availableAt);
        (,,,, uint128 executable,) = vault.previewCompound();
        assertEq(executable, backlog < cap ? backlog : cap, "post-grief allowance was reduced");
        uint128 added = vault.compound(executable, vm.getBlockTimestamp());
        assertEq(added, executable, "post-grief compound deployed less than allowed");
    }

    // --- (e) Treasury payout fails, accrues, retries ----------------------------------------

    /// A treasury that cannot take its native payout does not block distribution or
    /// compound: the creator and NAV legs settle, the treasury's share accrues as a claim,
    /// and a later distribution pays it to whoever holds the treasury then.
    function testForkTreasuryPayoutFailureAccruesAndRetries() public onlyForked {
        RejectingTreasury rejecting = new RejectingTreasury(factory);
        vm.prank(treasury);
        factory.proposeTreasury(address(rejecting));
        rejecting.accept();
        assertEq(factory.treasury(), address(rejecting));

        _volume(4, 5 ether);
        (, LaunchLiquidityVault.FeeAmounts memory navBefore,) = launchVault.pendingFees(token);
        assertGt(navBefore.counter, 0, "fixture accrued no counter fees");
        uint256 creatorBefore = creator.balance;
        uint256 vaultBefore = address(vault).balance;

        launchVault.distributeFees(token);
        (
            LaunchLiquidityVault.FeeAmounts memory creatorPending,
            LaunchLiquidityVault.FeeAmounts memory navPending,
            LaunchLiquidityVault.FeeAmounts memory protocolPending
        ) = launchVault.pendingFees(token);
        assertEq(creatorPending.counter, 0, "creator payout did not settle");
        assertGt(creator.balance, creatorBefore, "creator was not paid");
        assertEq(navPending.counter, 0, "NAV did not settle");
        assertGt(address(vault).balance, vaultBefore, "vault received no NAV");
        uint256 accrued = protocolPending.counter;
        assertGt(accrued, 0, "rejected treasury payout did not accrue");
        assertEq(address(rejecting).balance, 0);

        // Compound runs the same distribution and must not be blocked by the treasury either.
        vm.warp(vault.compoundAvailableAt());
        assertGt(vault.compound(1, vm.getBlockTimestamp()), 0, "compound was blocked");

        address successor = makeAddr("fork successor treasury");
        rejecting.propose(successor);
        vm.prank(successor);
        factory.acceptTreasury();
        launchVault.distributeFees(token);
        (,, protocolPending) = launchVault.pendingFees(token);
        assertEq(protocolPending.counter, 0, "accrued treasury claim was not retried");
        assertGe(successor.balance, accrued, "successor did not receive the accrued claim");
    }

    // --- (f) The cap formula on the real pool ---------------------------------------------

    struct Trip {
        int256 pnl;
        uint128 added;
        uint128 cap;
        uint128 base;
    }

    /// The trader's wealth in the counter currency at the launch price.
    function _traderWealth() private view returns (uint256) {
        return trader.balance + _tokensInCounter(IERC20(token).balanceOf(trader), launchSqrtPrice);
    }

    /// One round trip to `deviation` ticks and back, compounding at the far end if asked.
    function _trip(int24 deviation, bool withCompound) private returns (Trip memory trip) {
        uint256 before = _traderWealth();
        uint64 availableAt = vault.compoundAvailableAt();
        if (availableAt > vm.getBlockTimestamp()) vm.warp(availableAt);
        _moveTo(START_TICK + deviation);
        if (withCompound) {
            trip.base = vault.compoundBase();
            trip.cap = vault.compoundLiquidityCap();
            trip.added = vault.compound(1, vm.getBlockTimestamp());
        }
        _moveTo(START_TICK);
        (uint160 restored,,,) = manager.getSlot0(key.toId());
        assertEq(restored, launchSqrtPrice, "round trip did not restore the launch price");
        trip.pnl = int256(_traderWealth()) - int256(before);
    }

    /// The mispricing loss of liquidity `added` deployed at `sqrtThere` once the price is back
    /// at `sqrtHere`, in the counter currency: `L * (sqrt(p) - sqrt(p'))^2 / (p * sqrt(p'))`,
    /// the wide-range form, which bounds any narrower range from above.
    function _mispricingBound(uint128 added, uint160 sqrtHere, uint160 sqrtThere)
        private
        pure
        returns (uint256)
    {
        uint256 diff = sqrtHere > sqrtThere ? sqrtHere - sqrtThere : sqrtThere - sqrtHere;
        uint256 step = FullMath.mulDiv(added, diff, sqrtHere);
        step = FullMath.mulDiv(step, diff, sqrtHere);
        return FullMath.mulDiv(step, FixedPoint96.Q96, sqrtThere);
    }

    /// With idle seeded far past any cap, a compound at a manipulated price deploys exactly
    /// the cap; the cap is the formula over the live base; and what the manipulator extracts
    /// relative to the same round trip without the compound never exceeds the mispricing
    /// loss that liquidity can suffer — while the round trip itself still loses.
    function testForkManipulatedCompoundIsBoundedByTheCapFormula() public onlyForked {
        (uint256 targetAssets, uint256 counterAssets) = vault.totalAssets();
        deal(token, address(vault), IERC20(token).balanceOf(address(vault)) + targetAssets * 1e6);
        vm.deal(address(vault), address(vault).balance + counterAssets * 1e6);
        uint24 fee = key.fee;

        for (uint256 i; i < DEVIATIONS.length; ++i) {
            for (uint256 direction; direction < 2; ++direction) {
                int24 deviation = direction == 0 ? DEVIATIONS[i] : -DEVIATIONS[i];
                uint160 sqrtThere = TickMath.getSqrtPriceAtTick(START_TICK + deviation);

                uint256 snap = vm.snapshotState();
                Trip memory control = _trip(deviation, false);
                vm.revertToState(snap);
                snap = vm.snapshotState();
                Trip memory attack = _trip(deviation, true);
                vm.revertToState(snap);

                uint256 formula = FullMath.mulDiv(
                    attack.base,
                    uint256(fee) * vault.COMPOUND_SAFETY_BPS(),
                    uint256(LPFeeLibrary.MAX_LP_FEE - fee) * 10_000
                );
                int256 extracted = attack.pnl - control.pnl;
                uint256 bound = _mispricingBound(attack.added, launchSqrtPrice, sqrtThere);
                emit log_named_int("deviation (ticks)", deviation);
                emit log_named_uint("  liquidity compounded", attack.added);
                emit log_named_int("  extracted by the mispriced compound", extracted);
                emit log_named_uint("  mispricing bound", bound);

                assertLe(attack.cap, formula, "cap exceeded the formula");
                assertGe(attack.cap * 100, formula * 99, "cap fell short of the formula");
                assertGe(attack.added * 100, attack.cap * 99, "compound was not bound by its cap");
                assertLe(extracted, int256((bound * 101) / 100), "extraction exceeded the bound");
                assertLt(attack.pnl, 0, "the manipulation paid");
            }
        }
    }

    // --- (g) The creator's worst single trip, on the live pool ------------------------------

    /// The creator's wealth in the counter currency at the launch price, with every creator
    /// payout flushed first. No lpTOKEN is held, so nothing of the vault's loss comes back.
    function _creatorWealth() private returns (uint256) {
        launchVault.distributeFees(token);
        return creator.balance + _tokensInCounter(IERC20(token).balanceOf(creator), launchSqrtPrice);
    }

    /// One trip by the creator to `deviation` ticks and back, with its own liquidity at
    /// `jitMultiple` times the worst-case protocol base in range, compounding at the far end
    /// if asked.
    function _creatorTrip(int24 deviation, uint256 jitMultiple, bool withCompound)
        private
        returns (int256 pnl, uint128 added)
    {
        uint256 before = _creatorWealth();
        uint64 availableAt = vault.compoundAvailableAt();
        if (availableAt > vm.getBlockTimestamp()) vm.warp(availableAt);
        int256 jit =
            int256((uint256(vault.positionLiquidity()) + uint256(launchLiquidity)) * jitMultiple);
        _creatorJit(jit);
        _moveTo(creator, START_TICK + deviation);
        assertGe(
            uint256(jit),
            uint256(vault.compoundBase()) * jitMultiple,
            "JIT is not dominant at the manipulated price"
        );
        if (withCompound) {
            uint128 cap = vault.compoundLiquidityCap();
            added = vault.compound(1, vm.getBlockTimestamp());
            assertGe(uint256(added) * 100, uint256(cap) * 99, "this compound was not cap-bound");
        }
        _moveTo(creator, START_TICK);
        (uint160 restored,,,) = manager.getSlot0(key.toId());
        assertEq(restored, launchSqrtPrice, "round trip did not restore the launch price");
        _creatorJit(-jit);
        pnl = int256(_creatorWealth()) - int256(before);
    }

    /// The most dangerous case of the insider attack, on live bytecode: the creator, holding
    /// no lpTOKEN, with its own liquidity at ten times the protocol base, moves the sqrt-price
    /// 100x and then 10,000x into the launch position's range — where the launch liquidity
    /// both swells the cap and returns 40% of its fees — compounds at the bottom, comes back,
    /// collects its payouts, and has still lost, though it extracted something.
    function testForkCreatorWithDominantJitLosesOneDeepTripIntoLaunchRange() public onlyForked {
        (uint256 targetAssets, uint256 counterAssets) = vault.totalAssets();
        deal(token, address(vault), IERC20(token).balanceOf(address(vault)) + targetAssets * 1e6);
        vm.deal(address(vault), address(vault).balance + counterAssets * 1e6);

        int24[2] memory deep = [int24(-92_103), int24(-184_207)];
        for (uint256 i; i < deep.length; ++i) {
            uint256 snap = vm.snapshotState();
            (int256 control,) = _creatorTrip(deep[i], 10, false);
            vm.revertToState(snap);
            snap = vm.snapshotState();
            (int256 attack, uint128 added) = _creatorTrip(deep[i], 10, true);
            vm.revertToState(snap);

            emit log_named_int("deviation (ticks)", deep[i]);
            emit log_named_uint("  liquidity compounded", added);
            emit log_named_int("  control pnl, no compound (wei of counter)", control);
            emit log_named_int("  creator pnl (wei of counter)", attack);
            emit log_named_int("  extracted by the mispriced compound", attack - control);
            assertGt(added, 0, "the compound deployed nothing");
            assertGt(attack - control, 0, "the manipulated compound extracted nothing");
            assertLt(attack, 0, "the creator's trip paid");
        }
    }
}
