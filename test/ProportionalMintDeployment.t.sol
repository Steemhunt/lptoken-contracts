// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import { LpTokenVault } from "../src/LpTokenVault.sol";
import { TokenLaunchpad } from "../src/TokenLaunchpad.sol";
import { LaunchPoolConfig } from "../src/libraries/LaunchPoolConfig.sol";
import { LpTokenTestBase } from "./utils/LpTokenTestBase.sol";

/// @notice A public mint reproduces the vault's current position and idle balances in the
/// same proportion as the newly issued gross shares. It can therefore scale compound
/// throughput without converting assets that already belonged to existing holders.
contract ProportionalMintDeploymentTest is LpTokenTestBase {
    using StateLibrary for IPoolManager;

    PoolKey internal poolKey;
    LpTokenVault internal vault;
    address internal atk = makeAddr("jit-attacker");

    function setUp() public override {
        super.setUp();
        poolKey = _erc20Key(address(cashcat), address(usdg));
        _initLivePool(poolKey, 0);
        vault = _launch(address(cashcat), poolKey, 1_000e18, 1_000e18);
    }

    function _mintAs(address who, uint256 maxTarget, uint256 maxCounter)
        private
        returns (uint256 shares)
    {
        _fundAndApprove(cashcat, who, address(vault), maxTarget);
        _fundAndApprove(usdg, who, address(vault), maxCounter);
        vm.prank(who);
        (shares,,) = vault.mintPair(maxTarget, maxCounter, 0, who, block.timestamp);
    }

    function _donateIdle(uint256 targetAmount, uint256 counterAmount) private {
        cashcat.mint(address(vault), targetAmount);
        usdg.mint(address(vault), counterAmount);
    }

    function _swapFunded(address who, bool zeroForOne, uint256 amountIn) private {
        vm.startPrank(who);
        cashcat.approve(address(swapRouter), type(uint256).max);
        usdg.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
        vm.stopPrank();
    }

    function _swapToPrice(address who, bool zeroForOne, uint160 sqrtPriceX96) private {
        vm.startPrank(who);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(40_000e18),
                sqrtPriceLimitX96: sqrtPriceX96
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
        vm.stopPrank();
    }

    function testMintScalesPositionAndIdleAssetsPerShare() public {
        _donateIdle(5_000e18, 5_000e18);
        uint256 supplyBefore = vault.totalSupply();
        uint128 liquidityBefore = vault.positionLiquidity();
        (uint256 idleTargetBefore, uint256 idleCounterBefore) = vault.idleBalances();

        assertGt(_mintAs(bob, 1_000e18, 1_000e18), 0);

        uint256 supplyAfter = vault.totalSupply();
        uint128 liquidityAfter = vault.positionLiquidity();
        (uint256 idleTargetAfter, uint256 idleCounterAfter) = vault.idleBalances();

        assertGt(liquidityAfter, liquidityBefore, "mint did not scale the position");
        assertGe(
            uint256(liquidityAfter) * supplyBefore,
            uint256(liquidityBefore) * supplyAfter,
            "mint diluted position liquidity per share"
        );
        assertGe(
            idleTargetAfter * supplyBefore,
            idleTargetBefore * supplyAfter,
            "mint diluted idle target per share"
        );
        assertGe(
            idleCounterAfter * supplyBefore,
            idleCounterBefore * supplyAfter,
            "mint diluted idle counter per share"
        );
    }

    function testLargeMintScalesCapWithoutInflatingExistingHolderAllowance() public {
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 supplyBefore = vault.totalSupply();
        uint128 capBefore = vault.compoundLiquidityCap();

        assertGt(_mintAs(bob, 40_000e18, 40_000e18), 0);

        uint256 supplyAfter = vault.totalSupply();
        uint128 capAfter = vault.compoundLiquidityCap();
        assertGt(capAfter, uint256(capBefore) * 30, "large mint did not scale throughput");
        assertApproxEqAbs(
            FullMath.mulDiv(capAfter, aliceShares, supplyAfter),
            FullMath.mulDiv(capBefore, aliceShares, supplyBefore),
            1,
            "large mint inflated an existing holder's compound allowance"
        );
    }

    /// A small bootstrap must not permanently anchor compound throughput. After a large
    /// proportional mint, a 2.5% matched backlog should clear in a handful of intervals.
    function testLargeMintLetsCompoundCatchUpWithMatchedBacklog() public {
        uint128 capBefore = vault.compoundLiquidityCap();
        assertGt(_mintAs(bob, 40_000e18, 40_000e18), 0);
        uint128 capAfterMint = vault.compoundLiquidityCap();
        assertGt(capAfterMint, uint256(capBefore) * 30, "cap remained bootstrap-anchored");

        _donateIdle(1_000e18, 1_000e18);
        vm.warp(vault.compoundAvailableAt());
        (,, uint128 initialBacklog, uint128 firstCap,,) = vault.previewCompound();
        assertGt(initialBacklog, firstCap, "fixture needs more than one compound call");

        uint256 calls;
        while (calls < 24) {
            (,, uint128 available,, uint128 executable, uint64 availableAt) =
                vault.previewCompound();
            if (available == 0) break;
            vm.warp(availableAt);
            vault.compound(executable, block.timestamp);
            ++calls;
        }

        (,, uint128 remaining,,,) = vault.previewCompound();
        assertEq(remaining, 0, "matched backlog did not catch up within 24 intervals");
        assertLe(calls, 18, "matched backlog took too many intervals to clear");
    }

    /// A mint/redeem round trip may add and remove the caller's proportional position, but
    /// it cannot dilute existing claims or consume the compound cooldown.
    function testMintRedeemRoundTripDoesNotBypassCompoundPolicy() public {
        _donateIdle(10_000e18, 10_000e18);
        uint128 liquidityBefore = vault.positionLiquidity();
        uint256 supplyBefore = vault.totalSupply();
        uint256 aliceShares = vault.balanceOf(alice);
        (uint256 aliceTargetBefore, uint256 aliceCounterBefore) = vault.claimForShares(aliceShares);
        uint64 availableAt = vault.compoundAvailableAt();

        uint256 shares = _mintAs(atk, 22_000e18, 22_000e18);
        vm.prank(atk);
        vault.redeem(shares, 0, 0, atk, block.timestamp);

        assertGe(
            FullMath.mulDiv(vault.positionLiquidity(), aliceShares, vault.totalSupply()),
            FullMath.mulDiv(liquidityBefore, aliceShares, supplyBefore),
            "round trip diluted the holder's position claim"
        );
        (uint256 aliceTargetAfter, uint256 aliceCounterAfter) = vault.claimForShares(aliceShares);
        assertGe(aliceTargetAfter, aliceTargetBefore, "round trip diluted target claim");
        assertGe(aliceCounterAfter, aliceCounterBefore, "round trip diluted counter claim");
        assertEq(vault.compoundAvailableAt(), availableAt, "round trip consumed the cooldown");
    }

    /// JIT manipulation around the round trip must not transfer value away from holders,
    /// in either direction.
    function testJitRoundTripDoesNotHarmHoldersEitherDirection() public {
        _checkJitDirection(true);
        _checkJitDirection(false);
    }

    function _checkJitDirection(bool pushDown) private {
        uint256 snap = vm.snapshotState();
        _donateIdle(10_000e18, 10_000e18);
        uint256 aliceShares = vault.balanceOf(alice);
        (uint160 referenceSqrtPrice,,,) = manager.getSlot0(poolKey.toId());
        (uint256 initialTarget, uint256 initialCounter) = vault.claimForShares(aliceShares);

        uint256 seed = 40_000e18;
        cashcat.mint(atk, seed);
        usdg.mint(atk, seed);
        vm.startPrank(atk);
        cashcat.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        uint256 attackerValueBefore = cashcat.balanceOf(atk) + usdg.balanceOf(atk);

        // Attack: manipulate, mint, unmanipulate, redeem.
        _swapFunded(atk, pushDown, 2_000e18);
        vm.prank(atk);
        (uint256 shares,,) = vault.mintPair(20_000e18, 20_000e18, 0, atk, block.timestamp);
        _swapToPrice(atk, !pushDown, referenceSqrtPrice);
        vm.prank(atk);
        vault.redeem(shares, 0, 0, atk, block.timestamp);
        (uint256 attackTarget, uint256 attackCounter) = vault.claimForShares(aliceShares);

        (uint160 finalSqrtPrice,,,) = manager.getSlot0(poolKey.toId());
        assertEq(finalSqrtPrice, referenceSqrtPrice, "round trip did not restore the price");
        assertGe(attackTarget, initialTarget, "JIT round trip drained holder target");
        assertGe(attackCounter, initialCounter, "JIT round trip drained holder counter");
        assertLe(
            cashcat.balanceOf(atk) + usdg.balanceOf(atk),
            attackerValueBefore,
            "JIT round trip was profitable"
        );
        vm.revertToState(snap);
    }

    /// The cap must stay under the empirically measured break-even, which is the LP fee
    /// applied to the pool's active liquidity (see CompoundCapBreakEven).
    function testCapStaysBelowMeasuredBreakEven() public {
        _donateIdle(50_000e18, 50_000e18);
        uint256 active = manager.getLiquidity(poolKey.toId());
        assertGt(active, 0);
        assertLe(
            uint256(vault.compoundLiquidityCap()) * 1e6,
            active * uint256(poolKey.fee),
            "cap exceeds fee * active liquidity"
        );
    }

    /// The base is protocol-owned liquidity, so a third party adding liquidity to the same
    /// pool cannot raise it.
    function testThirdPartyLiquidityCannotInflateTheBase() public {
        _donateIdle(50_000e18, 50_000e18);
        uint128 baseBefore = vault.compoundBase();
        _addFullRangeLiquidity(poolKey, makeAddr("outsider"), 5e21);
        assertEq(vault.compoundBase(), baseBefore, "outside liquidity moved the base");
    }

    /// A large proportional mint raises the live compound base, and the next compound can
    /// deploy at the enlarged cap. This must not give a JIT attacker a cheaper manipulation
    /// than one run directly against the pool: the minter holds its own pro-rata share of
    /// any mispriced deployment, so an existing holder's exposure to a manipulated compound
    /// is the same as under the honest cap, while the round-trip share fees make the attempt
    /// a clear loss. The baseline adds the same liquidity straight to the pool around an
    /// honest-cap compound, so fee dilution is identical and only the cap differs.
    function testJitMintCannotRaiseHolderExposureToAManipulatedCompound() public {
        _checkJitMintCompound(true);
        _checkJitMintCompound(false);
    }

    function _checkJitMintCompound(bool pushDown) private {
        uint256 snap = vm.snapshotState();
        _donateIdle(10_000e18, 10_000e18);
        uint256 seed = 220_000e18;
        cashcat.mint(atk, seed);
        usdg.mint(atk, seed);
        vm.startPrank(atk);
        cashcat.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        uint256 startClaim = _claim(alice);
        uint128 honestCap = vault.compoundLiquidityCap();

        // Attack: mint 10x the vault so the base follows, then manipulate and compound.
        uint256 attackSnap = vm.snapshotState();
        uint128 liquidityBefore = vault.positionLiquidity();
        vm.prank(atk);
        (uint256 shares,,) = vault.mintPair(110_000e18, 110_000e18, 0, atk, block.timestamp);
        int256 jitLiquidity = int256(uint256(vault.positionLiquidity() - liquidityBefore));
        assertGt(vault.compoundLiquidityCap(), 10 * honestCap, "base did not follow the mint");
        vm.warp(vault.compoundAvailableAt());
        _swapFunded(atk, pushDown, 2_000e18);
        uint128 deployed = vault.compound(0, block.timestamp);
        assertGt(deployed, 10 * honestCap, "manipulated compound did not use the raised cap");
        _swapFunded(atk, !pushDown, 2_000e18);
        vm.prank(atk);
        vault.redeem(shares, 0, 0, atk, block.timestamp);
        _restoreLaunchPrice();
        uint256 attackClaim = _claim(alice);
        uint256 attackWealth = _wealth(atk);
        vm.revertToState(attackSnap);

        // Baseline: the same liquidity straight in the pool around an honest-cap compound.
        _addFullRangeLiquidity(poolKey, atk, jitLiquidity);
        vm.warp(vault.compoundAvailableAt());
        _swapFunded(atk, pushDown, 2_000e18);
        assertLe(vault.compound(0, block.timestamp), uint256(honestCap) * 1_005 / 1_000);
        _swapFunded(atk, !pushDown, 2_000e18);
        _addFullRangeLiquidity(poolKey, atk, -jitLiquidity);
        _restoreLaunchPrice();
        uint256 baselineClaim = _claim(alice);

        assertGe(attackClaim, startClaim, "JIT-mint compound drained holder principal");
        // Both runs mark within 1e-6 of each other; the residue is fee flow along the
        // slightly different unwind path, not principal.
        assertApproxEqRel(
            attackClaim, baselineClaim, 1e12, "raised cap exposed the holder beyond the honest cap"
        );
        assertLt(attackWealth, 2 * seed - 1_000e18, "JIT-mint compound was not a clear loss");
        emit log_named_uint("holder claim, honest cap + pool JIT", baselineClaim);
        emit log_named_uint("holder claim, raised cap via vault JIT", attackClaim);
        vm.revertToState(snap);
    }

    /// Third-party arbitrage back to the launch tick, so holder claims from different
    /// scenarios are marked at one price instead of at whatever tick a scenario ended on.
    function _restoreLaunchPrice() private {
        (, int24 tick,,) = manager.getSlot0(poolKey.toId());
        if (tick == 0) return;
        address arb = makeAddr("jit-mint-arb");
        cashcat.mint(arb, 1e30);
        usdg.mint(arb, 1e30);
        vm.startPrank(arb);
        cashcat.approve(address(swapRouter), type(uint256).max);
        usdg.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: tick > 0,
                amountSpecified: -int256(1e30),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(0)
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
        vm.stopPrank();
    }

    function _claim(address who) private view returns (uint256) {
        (uint256 targetClaim, uint256 counterClaim) = vault.claimForShares(vault.balanceOf(who));
        return targetClaim + counterClaim;
    }

    function _wealth(address who) private view returns (uint256) {
        return cashcat.balanceOf(who) + usdg.balanceOf(who);
    }
}

/// @notice On the platform launch path the base also counts the permanent launch
/// position, which shares the PoolKey and can never be withdrawn.
contract CompoundBaseOnLaunchPathTest is LpTokenTestBase {
    using StateLibrary for IPoolManager;

    TokenLaunchpad internal launchpad;

    function setUp() public override {
        super.setUp();
        launchpad = _deployLaunchpad(manager, factory, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE);
        vm.prank(owner);
        factory.bindLaunchpad(address(launchpad));
    }

    function _launch(bytes32 salt, uint256 value)
        private
        returns (address token, LpTokenVault vault)
    {
        TokenLaunchpad.TokenMetadata memory metadata = TokenLaunchpad.TokenMetadata({
            name: "Base Cat",
            symbol: "BCAT",
            imageUrl: "ipfs://base",
            websiteUrl: "https://example.com",
            twitterHandle: "base_cat",
            telegramHandle: "base_cat_chat"
        });
        vm.deal(alice, alice.balance + value);
        vm.prank(alice);
        address vaultAddress;
        (token, vaultAddress,) = launchpad.createToken{ value: value }(
            metadata, salt, 0, 0, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE, block.timestamp
        );
        vault = LpTokenVault(payable(vaultAddress));
    }

    /// At or above the start tick the permanent launch range has ended, so its nominal
    /// liquidity backs nothing. An outsider must not be able to add temporary liquidity of
    /// their own and thereby unlock a cap sized on it.
    function testOutsiderCannotUnlockAnInactiveLaunchPosition() public {
        // Exactly the bootstrap quote: no creator buy, so the pool sits at the start tick
        // and the launch range is already closed.
        (address token, LpTokenVault vault) = _launch(keccak256("inactive"), 0.001 ether);
        PoolKey memory key = launchpad.poolKey(token);
        (, int24 startTick) = LaunchPoolConfig.launchTicks(launchpad.startTick());
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertEq(tick, startTick, "expected the pool to sit at the start tick");

        (,, uint128 nominal,) = launchpad.liquidityVault().positions(token);
        assertGt(nominal, 0, "launch position should still report nominal liquidity");
        assertEq(
            launchpad.liquidityVault().activeLiquidity(token, address(vault)),
            0,
            "an out-of-range launch position must report no active liquidity"
        );

        uint128 baseBefore = vault.compoundBase();
        uint128 capBefore = vault.compoundLiquidityCap();
        assertEq(baseBefore, vault.positionLiquidity(), "base should be the vault position only");

        // A range starting at the current tick is active and single-sided, so this needs
        // only the counter currency and no token inventory at all.
        address outsider = makeAddr("outsider");
        vm.deal(outsider, 5_000 ether);
        vm.prank(outsider);
        liquidityRouter.modifyLiquidity{ value: 4_000 ether }(
            key,
            ModifyLiquidityParams({
                tickLower: startTick,
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: int256(uint256(nominal)),
                salt: keccak256("outsider")
            }),
            bytes("")
        );

        assertGt(manager.getLiquidity(key.toId()), nominal, "outsider liquidity did not land");
        assertEq(vault.compoundBase(), baseBefore, "outsider liquidity moved the base");
        assertEq(vault.compoundLiquidityCap(), capBefore, "outsider liquidity moved the cap");
    }

    /// The launch position only counts while the price is inside its range.
    function testLaunchPositionCountsOnlyWhileInRange() public {
        (address token, LpTokenVault vault) = _launch(keccak256("range"), 0.001 ether);
        assertEq(vault.compoundBase(), vault.positionLiquidity(), "counted while out of range");

        // Any buy moves the tick below the start tick and opens the launch range.
        PoolKey memory key = launchpad.poolKey(token);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        swapRouter.swap{ value: 1 ether }(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(1 ether),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );

        (,, uint128 nominal,) = launchpad.liquidityVault().positions(token);
        assertEq(vault.compoundBase(), vault.positionLiquidity() + nominal, "not counted in range");
    }

    function testLaunchPositionRaisesTheCompoundBase() public {
        TokenLaunchpad.TokenMetadata memory metadata = TokenLaunchpad.TokenMetadata({
            name: "Base Cat",
            symbol: "BCAT",
            imageUrl: "ipfs://base",
            websiteUrl: "https://example.com",
            twitterHandle: "base_cat",
            telegramHandle: "base_cat_chat"
        });
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (address token, address vaultAddress,) = launchpad.createToken{ value: 0.01 ether }(
            metadata,
            keccak256("base"),
            0,
            0,
            LAUNCH_START_TICK,
            LAUNCH_INITIAL_LP_QUOTE,
            block.timestamp
        );
        LpTokenVault vault = LpTokenVault(payable(vaultAddress));

        uint128 bootstrapLiquidity = vault.positionLiquidity();
        (,, uint128 launchLiquidity,) = launchpad.liquidityVault().positions(token);
        assertGt(launchLiquidity, bootstrapLiquidity * 1_000, "launch position should dominate");

        // The base counts both protocol positions, so the cap scales with the liquidity
        // that actually makes manipulation expensive rather than with the tiny bootstrap.
        assertEq(vault.compoundBase(), bootstrapLiquidity + launchLiquidity);
        emit log_named_uint("bootstrap position liquidity", bootstrapLiquidity);
        emit log_named_uint("launch position liquidity", launchLiquidity);
        emit log_named_uint("compound cap", vault.compoundLiquidityCap());
        emit log_named_uint("bootstrap-only cap", (uint256(bootstrapLiquidity) * 505) / 100_000);
        assertGt(
            vault.compoundLiquidityCap() / 1_000,
            (uint256(bootstrapLiquidity) * 505) / 100_000,
            "cap did not scale past the bootstrap-anchored value"
        );

        // Still bounded by the measured break-even against real active liquidity.
        uint256 active = manager.getLiquidity(launchpad.poolKey(token).toId());
        assertLe(
            uint256(vault.compoundLiquidityCap()) * 1e6,
            active * uint256(launchpad.poolKey(token).fee)
        );
    }
}
