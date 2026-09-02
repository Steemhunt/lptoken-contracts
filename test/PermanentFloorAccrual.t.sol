// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import { ILaunchFeeSource } from "../src/interfaces/ILaunchFeeSource.sol";
import { ILpTokenFactory } from "../src/interfaces/ILpTokenFactory.sol";
import { LaunchLiquidityVault } from "../src/LaunchLiquidityVault.sol";
import { LpTokenVault } from "../src/LpTokenVault.sol";
import { TokenLaunchpad } from "../src/TokenLaunchpad.sol";
import { LpTokenTestBase } from "./utils/LpTokenTestBase.sol";

/// @notice Pins the quantitative claims the docs make about the permanent floor, so the
/// prose and the contracts cannot drift apart. See "Permanent floor on the platform
/// launch" in docs/architecture.md.
contract PermanentFloorAccrualTest is LpTokenTestBase {
    using StateLibrary for IPoolManager;

    TokenLaunchpad internal launchpad;
    LaunchLiquidityVault internal launchVault;
    address internal token;
    LpTokenVault internal vault;
    PoolKey internal key;
    address internal trader = makeAddr("trader");

    function setUp() public override {
        super.setUp();
        launchpad = _deployLaunchpad(manager, factory, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE);
        launchVault = launchpad.liquidityVault();
        vm.prank(owner);
        factory.bindLaunchpad(address(launchpad));

        TokenLaunchpad.TokenMetadata memory metadata = TokenLaunchpad.TokenMetadata({
            name: "Floor Cat",
            symbol: "FCAT",
            imageUrl: "ipfs://floor",
            websiteUrl: "https://example.com",
            twitterHandle: "floor_cat",
            telegramHandle: "floor_cat_chat"
        });
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        address vaultAddress;
        (token, vaultAddress,) = launchpad.createToken{ value: 1 ether }(
            metadata,
            keccak256("floor"),
            0,
            0,
            LAUNCH_START_TICK,
            LAUNCH_INITIAL_LP_QUOTE,
            block.timestamp
        );
        vault = LpTokenVault(payable(vaultAddress));
        key = launchpad.poolKey(token);
    }

    function _buy(address who, uint256 ethIn) private {
        vm.deal(who, who.balance + ethIn);
        vm.prank(who);
        swapRouter.swap{ value: ethIn }(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
    }

    function _sell(address who, uint256 amountIn) private {
        if (amountIn == 0) return;
        vm.startPrank(who);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
        vm.stopPrank();
    }

    /// Value a pair in counter terms at the current price. price is target per counter,
    /// so the target leg converts by dividing.
    function _valueInCounter(uint256 targetAmount, uint256 counterAmount)
        private
        view
        returns (uint256)
    {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        uint256 half = FullMath.mulDiv(targetAmount, 1 << 96, sqrtPriceX96);
        return counterAmount + FullMath.mulDiv(half, 1 << 96, sqrtPriceX96);
    }

    /// The NAV allocation the launch source is about to hand over, isolated from the
    /// vault's own position which also moves with price.
    function _pendingNav() private view returns (uint256 navTarget, uint256 navCounter) {
        (, ILaunchFeeSource.FeeAmounts memory nav,) = launchVault.pendingFees(token);
        return (nav.target, nav.counter);
    }

    /// The docs quote 0.20% of buy volume: the 20% NAV share of the 1% counter-leg fee.
    function testCounterLegAccruesTwentyBasisPointsOfBuyVolume() public {
        launchVault.distributeFees(token);

        uint256 buyVolume = 200 ether;
        _buy(trader, buyVolume);

        (, uint256 navCounter) = _pendingNav();
        emit log_named_uint("counter NAV accrued (wei)", navCounter);
        emit log_named_uint("as bps of buy volume", (navCounter * 10_000) / buyVolume);
        assertApproxEqRel(
            navCounter, (buyVolume * 20) / 10_000, 0.01e18, "not ~0.20% of buy volume"
        );
    }

    /// And 0.60% of sell volume: the 60% NAV share of the 1% target-leg fee.
    function testTargetLegAccruesSixtyBasisPointsOfSellVolume() public {
        _buy(trader, 200 ether);
        launchVault.distributeFees(token);

        uint256 sellVolume = IERC20(token).balanceOf(trader);
        _sell(trader, sellVolume);

        (uint256 navTarget,) = _pendingNav();
        emit log_named_uint("target NAV accrued", navTarget);
        emit log_named_uint("as bps of sell volume", (navTarget * 10_000) / sellVolume);
        assertApproxEqRel(
            navTarget, (sellVolume * 60) / 10_000, 0.01e18, "not ~0.60% of sell volume"
        );
    }

    /// Compound pairs what it can into the position and stops when one leg runs out. The
    /// remaining leg has no redeemable claim against it and is therefore out of
    /// circulation. Which leg is left over depends on the buy/sell mix and the price
    /// level, so this asserts the shape rather than a fixed side.
    function testCompoundPairsOneLegAndLeavesTheOtherOutOfCirculation() public {
        for (uint256 i; i < 4; ++i) {
            _buy(trader, 50 ether);
            _sell(trader, IERC20(token).balanceOf(trader) / 2);
        }
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
    }

    /// A minter arriving after a large balance has accrued pays fair value: the permanent
    /// claim is unchanged in either direction, and the minter loses only the share fee.
    function testLateMinterNeitherCapturesNorSubsidizesTheFloor() public {
        for (uint256 i; i < 6; ++i) {
            _buy(trader, 20 ether);
            _sell(trader, IERC20(token).balanceOf(trader) / 2);
        }
        launchVault.distributeFees(token);

        // Buy the minter's bag first so the price move is outside the comparison.
        address late = makeAddr("late-minter");
        _buy(late, 30 ether);
        uint256 bag = IERC20(token).balanceOf(late);
        vm.deal(late, 30 ether);

        uint256 deadShares = vault.balanceOf(vault.DEAD_SHARE_RECEIVER());
        (uint256 deadTarget0, uint256 deadCounter0) = vault.claimForShares(deadShares);
        uint256 deadValueBefore = _valueInCounter(deadTarget0, deadCounter0);

        vm.startPrank(late);
        IERC20(token).approve(address(vault), type(uint256).max);
        (uint256 shares, uint256 targetUsed, uint256 counterUsed) =
            vault.mintPair{ value: 30 ether }(bag, 30 ether, 1, late, block.timestamp + 1);
        vm.stopPrank();

        (uint256 deadTarget1, uint256 deadCounter1) = vault.claimForShares(deadShares);
        assertEq(
            _valueInCounter(deadTarget1, deadCounter1), deadValueBefore, "the permanent claim moved"
        );

        (uint256 mintedTarget, uint256 mintedCounter) = vault.claimForShares(shares);
        uint256 paid = _valueInCounter(targetUsed, counterUsed);
        uint256 got = _valueInCounter(mintedTarget, mintedCounter);
        emit log_named_uint("minter got / paid (bps)", (got * 10_000) / paid);
        // Only the 30 bps share fee separates the two.
        assertApproxEqRel(got, (paid * 9_970) / 10_000, 0.001e18, "minter did not pay fair value");
    }

    /// A second curated pool for a platform token must not borrow the launch pool's
    /// permanent liquidity or receive its launch-fee NAV.
    function testSecondCuratedVaultForLaunchpadTokenIsIsolatedFromLaunchFees() public {
        _buy(owner, 1 ether);
        launchVault.distributeFees(token);

        PoolKey memory curatedKey = _erc20Key(token, address(usdg));
        manager.initialize(curatedKey, TickMath.getSqrtPriceAtTick(0));
        usdg.mint(owner, 1e30);

        vm.startPrank(owner);
        IERC20(token).approve(address(liquidityRouter), type(uint256).max);
        usdg.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(
            curatedKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(curatedKey.tickSpacing),
                tickUpper: TickMath.maxUsableTick(curatedKey.tickSpacing),
                liquidityDelta: 1e12,
                salt: bytes32(0)
            }),
            bytes("")
        );
        vm.stopPrank();

        uint256 targetAmount = 1e18;
        uint256 counterAmount = 1e18;
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(token, curatedKey, targetAmount, counterAmount, 0, 0);
        address predicted = factory.predictVault(token, curatedKey);
        vm.startPrank(owner);
        IERC20(token).approve(predicted, type(uint256).max);
        usdg.approve(predicted, type(uint256).max);
        (address curatedAddress,,) = factory.launch(params);
        vm.stopPrank();

        LpTokenVault curated = LpTokenVault(payable(curatedAddress));
        assertEq(curated.launchFeeSource(), address(0), "curated vault has a launch-fee source");
        assertEq(launchVault.activeLiquidity(token, curatedAddress), 0);
        assertLe(curated.compoundBase(), curated.positionLiquidity());
        (uint256 pendingTarget, uint256 pendingCounter) = curated.pendingLaunchFees();
        assertEq(pendingTarget, 0);
        assertEq(pendingCounter, 0);

        uint256 launchVaultTargetBefore = IERC20(token).balanceOf(address(vault));
        uint256 launchVaultCounterBefore = address(vault).balance;
        uint256 curatedTargetBefore = IERC20(token).balanceOf(curatedAddress);
        uint256 curatedCounterBefore = curatedAddress.balance;

        _buy(trader, 1 ether);
        launchVault.distributeFees(token);

        assertTrue(
            IERC20(token).balanceOf(address(vault)) > launchVaultTargetBefore
                || address(vault).balance > launchVaultCounterBefore,
            "launch vault received no NAV"
        );
        assertEq(IERC20(token).balanceOf(curatedAddress), curatedTargetBefore);
        assertEq(curatedAddress.balance, curatedCounterBefore);
    }
}
