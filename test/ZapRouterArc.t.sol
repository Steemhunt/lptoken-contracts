// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

import { LpTokenVault } from "../src/LpTokenVault.sol";
import { ILpTokenVault } from "../src/interfaces/ILpTokenVault.sol";
import { ZapRouterArc } from "../src/periphery/ZapRouterArc.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockArcUSDC } from "./mocks/MockArcUSDC.sol";
import { LpTokenTestBase } from "./utils/LpTokenTestBase.sol";

contract ZapRouterArcTest is LpTokenTestBase {
    address private constant USDC = 0x3600000000000000000000000000000000000000;
    uint256 private constant SCALE = 1e12;
    uint256 private constant DUST = 3 ether + 999_999_999_999;

    MockArcUSDC private arc;
    ZapRouterArc private router;
    PoolKey private stableKey;
    PoolKey private nativeKey;
    LpTokenVault private stableVault;
    LpTokenVault private nativeVault;

    function setUp() public override {
        super.setUp();
        vm.etch(USDC, address(new MockArcUSDC()).code);
        arc = MockArcUSDC(USDC);
        router = new ZapRouterArc(factory);
        stableKey = _erc20Key(address(usdg), USDC);
        nativeKey = _nativeKey(address(cashcat));
        _initBoundedPool(stableKey, 1e12);
        _initBoundedPool(nativeKey, 1e24);
        stableVault = _launch(address(usdg), stableKey, 1_000e6, 1_000e6);
        nativeVault = _launch(address(cashcat), nativeKey, 1_000 ether, 1_000 ether);
        vm.deal(address(router), DUST);
    }

    function testArcIdentityUsesOneUsdcInterface() public view {
        assertEq(router.version(), "2.0-arc");
        assertEq(router.USDC(), USDC);
        assertEq(router.canonicalStable(), USDC);
        assertEq(address(router.wrappedNative()), USDC);
        assertEq(arc.decimals(), 6);
        assertEq(arc.balanceOf(address(router)), DUST / SCALE);
    }

    function testConstructorRejectsUnexpectedUsdcDecimals() public {
        vm.mockCall(USDC, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        vm.expectRevert(ZapRouterArc.InvalidAddress.selector);
        new ZapRouterArc(factory);
    }

    function testNativeToUsdcEmptyRouteRefundsOnlyInputRemainderToPayer() public {
        uint256 remainder = 321_987;
        vm.deal(bob, 100 ether + remainder);
        uint256 receiverBefore = alice.balance;
        vm.prank(bob);
        (uint256 shares,, uint256 counterUsed) = _routed(
            stableVault, address(0), 100 ether + remainder, new PoolKey[](0), 100e6, 50e6, alice
        );
        assertGt(shares, 0);
        assertGt(counterUsed, 50e6);
        assertLe(counterUsed, 100e6);
        assertEq(bob.balance % SCALE, remainder);
        assertEq(alice.balance, receiverBefore);
        _assertClean(stableVault);
    }

    function testUsdcToNativeEmptyRouteScalesCounterUnits() public {
        _approveArc(bob, 100e6);
        vm.prank(bob);
        (uint256 shares,, uint256 counterUsed) =
            _routed(nativeVault, USDC, 100e6, new PoolKey[](0), 100 ether, 50 ether, bob);
        assertGt(shares, 0);
        assertGt(counterUsed, 50 ether);
        assertLe(counterUsed, 100 ether);
        assertEq(nativeVault.balanceOf(bob), shares);
        _assertClean(nativeVault);
    }

    function testNativeToUsdcConversionAtFirstHopKeepsSwapUnits() public {
        MockERC20 target = new MockERC20("Route Target", "RT", 6);
        PoolKey memory vaultKey = _erc20Key(address(target), address(usdg));
        _initBoundedPool(vaultKey, 1e12);
        LpTokenVault vault = _launch(address(target), vaultKey, 1_000e6, 1_000e6);
        vm.deal(bob, 100 ether + 19);
        vm.prank(bob);
        (uint256 shares,, uint256 counterUsed) =
            _routed(vault, address(0), 100 ether + 19, _single(stableKey), 90e6, 45e6, bob);
        assertGt(shares, 0);
        assertGt(counterUsed, 45e6);
        assertLt(counterUsed, 100e6);
        assertEq(bob.balance % SCALE, 19);
        assertEq(target.balanceOf(address(router)), 0);
        _assertClean(vault);
    }

    function testUsdcToNativeConversionAtFirstHopKeepsSwapUnits() public {
        PoolKey memory vaultKey = _erc20Key(address(weth), address(cashcat));
        _initBoundedPool(vaultKey, 1e24);
        LpTokenVault vault = _launch(address(weth), vaultKey, 1_000 ether, 1_000 ether);
        _approveArc(bob, 100e6);
        vm.prank(bob);
        (uint256 shares,, uint256 counterUsed) =
            _routed(vault, USDC, 100e6, _single(nativeKey), 90 ether, 45 ether, bob);
        assertGt(shares, 0);
        assertGt(counterUsed, 45 ether);
        assertLt(counterUsed, 100 ether);
        _assertClean(vault);
    }

    function testFinalNativeToUsdcBoundaryRefundsSwapOutputDust() public {
        PoolKey[] memory route = new PoolKey[](2);
        route[0] = nativeKey;
        route[1] = nativeKey;
        _approveArc(bob, 100e6);
        vm.prank(bob);
        (uint256 shares,, uint256 counterUsed) =
            _routed(stableVault, USDC, 100e6, route, 90e6, 45e6, bob);
        assertGt(shares, 0);
        assertGt(counterUsed, 45e6);
        assertLt(counterUsed, 100e6);
        assertGt(bob.balance % SCALE, 0);
        _assertClean(stableVault);
    }

    function testFinalUsdcToNativeBoundaryScalesActualSwapOutput() public {
        PoolKey[] memory route = new PoolKey[](2);
        route[0] = stableKey;
        route[1] = stableKey;
        vm.deal(bob, 100 ether);
        vm.prank(bob);
        (uint256 shares,, uint256 counterUsed) =
            _routed(nativeVault, address(0), 100 ether, route, 90 ether, 45 ether, bob);
        assertGt(shares, 0);
        assertGt(counterUsed, 45 ether);
        assertLt(counterUsed, 100 ether);
        _assertClean(nativeVault);
    }

    function testDirectZapsAndRedemptionsPreserveUsdcDust() public {
        _directRoundtrip(false, false, false);
        _directRoundtrip(false, true, true);
    }

    function testDirectZapsAndRedemptionsPreserveNativeDust() public {
        _directRoundtrip(true, false, false);
        _directRoundtrip(true, true, true);
    }

    function testPairMintAndDirectRedeemUseNativeAndErc20Units() public {
        _pairMintAndRedeem(false);
        _pairMintAndRedeem(true);
    }

    function testSubMicroUsdcInputCannotConsumeExistingRouterDust() public {
        vm.deal(bob, SCALE - 1);
        vm.prank(bob);
        vm.expectRevert(ZapRouterArc.InvalidAmount.selector);
        _routed(stableVault, address(0), SCALE - 1, new PoolKey[](0), 0, 0, bob);
        assertEq(bob.balance, SCALE - 1);
        _assertClean(stableVault);
    }

    function testRoutedSlippageRevertsNativeConversionAndRefundAtomically() public {
        uint256 amount = 100 ether + 17;
        vm.deal(bob, amount);
        vm.prank(bob);
        vm.expectPartialRevert(ZapRouterArc.InsufficientCounterOutput.selector);
        _routed(stableVault, address(0), amount, new PoolKey[](0), 100e6 + 1, 50e6, bob);
        assertEq(bob.balance, amount);
        _assertClean(stableVault);
    }

    function testSwapSlippageRestoresSharedBalancesAndAllowance() public {
        _approveArc(bob, 100e6);
        uint256 managerBefore = address(manager).balance;
        uint256 payerBefore = bob.balance;
        vm.prank(bob);
        vm.expectPartialRevert(ZapRouterArc.InsufficientSwapOutput.selector);
        router.zapIn(_asVault(stableVault), 100e6, 50e6, 100e6, 1, bob, block.timestamp);
        assertEq(bob.balance, payerBefore);
        assertEq(address(manager).balance, managerBefore);
        assertEq(arc.allowance(bob, address(router)), 100e6);
        _assertClean(stableVault);
    }

    function testSameAssetNativeUsdcRoutePoolIsRejectedBeforeTransfer() public {
        PoolKey[] memory route = _single(_nativeKey(USDC));
        vm.expectRevert(ZapRouterArc.AliasedPoolCurrencies.selector);
        _routed(stableVault, address(0), 100 ether, route, 1, 1, bob);
        _assertClean(stableVault);
    }

    function testSameAssetNativeUsdcVaultIsRejectedBeforeTransfer() public {
        vm.mockCall(
            address(nativeVault),
            abi.encodeCall(ILpTokenVault.poolKey, ()),
            abi.encode(_nativeKey(USDC))
        );
        vm.mockCall(
            address(nativeVault), abi.encodeCall(ILpTokenVault.target, ()), abi.encode(USDC)
        );
        vm.expectRevert(ZapRouterArc.AliasedPoolCurrencies.selector);
        router.zapIn(_asVault(nativeVault), 100 ether, 50 ether, 1, 1, bob, block.timestamp);
        _assertClean(nativeVault);
    }

    function testAliasConversionIsNotAllowedBetweenPoolHops() public {
        PoolKey memory middle = _erc20Key(address(cashcat), USDC);
        manager.initialize(middle, TickMath.getSqrtPriceAtTick(0));
        PoolKey[] memory route = new PoolKey[](3);
        route[0] = nativeKey;
        route[1] = middle;
        route[2] = nativeKey;
        vm.expectRevert(
            abi.encodeWithSelector(ZapRouterArc.RouteCurrencyMismatch.selector, 2, USDC)
        );
        _routed(nativeVault, address(0), 100 ether, route, 1, 1, bob);
    }

    function testCallbackAndNativeReceiveRemainRestricted() public {
        vm.expectRevert(ZapRouterArc.OnlyPoolManager.selector);
        router.unlockCallback(bytes(""));
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        (bool accepted,) = address(router).call{ value: 1 ether }("");
        assertFalse(accepted);
        _assertClean(nativeVault);
    }

    function _directRoundtrip(bool nativeCounter, bool targetInput, bool targetOutput) private {
        LpTokenVault vault = nativeCounter ? nativeVault : stableVault;
        MockERC20 target = nativeCounter ? cashcat : usdg;
        uint256 amount = nativeCounter ? 100 ether : 100e6;
        uint256 shares;
        if (targetInput) {
            _fundAndApprove(target, bob, address(router), amount);
            vm.prank(bob);
            (shares,,) =
                router.zapInTarget(_asVault(vault), amount, amount / 2, 1, 1, bob, block.timestamp);
        } else {
            if (nativeCounter) vm.deal(bob, bob.balance + amount);
            else _approveArc(bob, amount);
            vm.prank(bob);
            (shares,,) = router.zapIn{ value: nativeCounter ? amount : 0 }(
                _asVault(vault), amount, amount / 2, 1, 1, bob, block.timestamp
            );
        }
        assertGt(shares, 0);
        _assertClean(vault);
        vm.prank(bob);
        vault.approve(address(router), shares);
        uint256 beforeOut = targetOutput ? target.balanceOf(bob) : bob.balance;
        vm.prank(bob);
        uint256 output = targetOutput
            ? router.zapOutTarget(_asVault(vault), shares, 1, bob, block.timestamp)
            : router.zapOut(_asVault(vault), shares, 1, bob, block.timestamp);
        assertGt(output, 0);
        if (targetOutput) assertEq(target.balanceOf(bob) - beforeOut, output);
        else assertEq(bob.balance - beforeOut, nativeCounter ? output : output * SCALE);
        assertEq(vault.balanceOf(bob), 0);
        _assertClean(vault);
    }

    function _pairMintAndRedeem(bool nativeCounter) private {
        LpTokenVault vault = nativeCounter ? nativeVault : stableVault;
        MockERC20 target = nativeCounter ? cashcat : usdg;
        uint256 amount = nativeCounter ? 100 ether : 100e6;
        _fundAndApprove(target, bob, address(router), amount);
        if (nativeCounter) vm.deal(bob, bob.balance + amount);
        else _approveArc(bob, amount);
        ZapRouterArc.PermitSignature memory noPermit;
        vm.prank(bob);
        (uint256 shares, uint256 targetUsed, uint256 counterUsed) = router.mintPairWithPermit{
            value: nativeCounter ? amount : 0
        }(
            _asVault(vault), amount, amount, 1, bob, block.timestamp, noPermit, noPermit
        );
        assertGt(shares, 0);
        assertGt(targetUsed, 0);
        assertGt(counterUsed, 0);
        _assertClean(vault);
        uint256 nativeBefore = bob.balance;
        uint256 targetBefore = target.balanceOf(bob);
        vm.prank(bob);
        (uint256 targetOut, uint256 counterOut) = vault.redeem(shares, 1, 1, bob, block.timestamp);
        assertEq(target.balanceOf(bob) - targetBefore, targetOut);
        assertEq(bob.balance - nativeBefore, nativeCounter ? counterOut : counterOut * SCALE);
        _assertClean(vault);
    }

    function _routed(
        LpTokenVault vault,
        address input,
        uint256 amount,
        PoolKey[] memory route,
        uint256 minimumCounter,
        uint256 swapAmount,
        address receiver
    ) private returns (uint256 shares, uint256 targetUsed, uint256 counterUsed) {
        return router.zapInRouted{ value: input == address(0) ? amount : 0 }(
            _asVault(vault),
            Currency.wrap(input),
            amount,
            route,
            minimumCounter,
            swapAmount,
            1,
            1,
            receiver,
            block.timestamp
        );
    }

    function _approveArc(address payer, uint256 amount) private {
        arc.mint(payer, amount);
        vm.prank(payer);
        arc.approve(address(router), amount);
    }

    /// @dev Avoid the generic fixture's 1e30 raw-token funding for six-decimal USDC.
    function _initBoundedPool(PoolKey memory key, int256 liquidity) private {
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        uint256 amount = uint256(liquidity) * 2;
        uint256 value;
        if (key.currency0.isAddressZero()) {
            value = amount;
            vm.deal(address(this), address(this).balance + amount);
        } else {
            _fundAndApprove(
                MockERC20(Currency.unwrap(key.currency0)),
                address(this),
                address(liquidityRouter),
                amount
            );
        }
        _fundAndApprove(
            MockERC20(Currency.unwrap(key.currency1)),
            address(this),
            address(liquidityRouter),
            amount
        );
        liquidityRouter.modifyLiquidity{ value: value }(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: liquidity,
                salt: bytes32(0)
            }),
            bytes("")
        );
    }

    function _assertClean(LpTokenVault vault) private view {
        assertEq(address(router).balance, DUST);
        assertEq(arc.balanceOf(address(router)), DUST / SCALE);
        assertEq(usdg.balanceOf(address(router)), 0);
        assertEq(cashcat.balanceOf(address(router)), 0);
        assertEq(weth.balanceOf(address(router)), 0);
        assertEq(vault.balanceOf(address(router)), 0);
        assertEq(arc.allowance(address(router), address(vault)), 0);
        assertEq(usdg.allowance(address(router), address(vault)), 0);
        assertEq(cashcat.allowance(address(router), address(vault)), 0);
    }

    function _asVault(LpTokenVault vault) private pure returns (ILpTokenVault) {
        return ILpTokenVault(address(vault));
    }

    function _single(PoolKey memory key) private pure returns (PoolKey[] memory route) {
        route = new PoolKey[](1);
        route[0] = key;
    }
}
