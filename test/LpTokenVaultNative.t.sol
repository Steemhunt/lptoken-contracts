// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { LpTokenFactory } from "../src/LpTokenFactory.sol";
import { LpTokenVault } from "../src/LpTokenVault.sol";
import { CurrencyTransfer } from "../src/libraries/CurrencyTransfer.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { CallbackERC20, ForceSender, NativeRejector } from "./mocks/TestActors.sol";
import { LpTokenTestBase } from "./utils/LpTokenTestBase.sol";

contract LpTokenVaultNativeTest is LpTokenTestBase {
    using StateLibrary for IPoolManager;

    PoolKey internal poolKey;
    LpTokenVault internal vault;

    function setUp() public override {
        super.setUp();
        poolKey = _nativeKey(address(cashcat));
        _initLivePool(poolKey, 0);
        vault = _launch(address(cashcat), poolKey, 1_000e18, 1_000e18);
    }

    function testNativeLaunchForwardsExactValueIntoPosition() public view {
        assertTrue(vault.counterIsNative());
        assertFalse(vault.targetIsCurrency0());
        assertGt(vault.positionLiquidity(), 0);
        (uint256 targetPrincipal, uint256 counterPrincipal) = vault.positionPrincipal();
        assertGt(targetPrincipal, 0);
        assertGt(counterPrincipal, 0);
    }

    function testNativeMintPairRefundsUnusedValue() public {
        _fundAndApprove(cashcat, bob, address(vault), 10e18);
        // Counter budget is deliberately double what the target cap allows.
        uint256 maxCounter = 20e18;
        vm.deal(bob, maxCounter);
        (uint256 previewShares,, uint256 previewCounterUsed) =
            vault.previewMintPair(10e18, maxCounter);
        assertLt(previewCounterUsed, maxCounter);

        vm.prank(bob);
        (uint256 shares,, uint256 counterUsed) = vault.mintPair{ value: maxCounter }(
            10e18, maxCounter, previewShares, bob, block.timestamp
        );
        assertEq(shares, previewShares);
        assertEq(counterUsed, previewCounterUsed);
        assertEq(bob.balance, maxCounter - counterUsed);
    }

    function testNativeMintPairRejectsWrongMsgValue() public {
        _fundAndApprove(cashcat, bob, address(vault), 10e18);
        vm.deal(bob, 20e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LpTokenVault.InvalidMsgValue.selector, 9e18, 10e18));
        vault.mintPair{ value: 9e18 }(10e18, 10e18, 0, bob, block.timestamp);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LpTokenVault.InvalidMsgValue.selector, 11e18, 10e18));
        vault.mintPair{ value: 11e18 }(10e18, 10e18, 0, bob, block.timestamp);
    }

    function testMsgValueCannotInflatePreMintAssets() public {
        // The view preview (no value in flight) must equal the shares minted while the
        // deposit's msg.value sits in the vault balance mid-call.
        (uint256 previewShares,,) = vault.previewMintPair(10e18, 10e18);
        _fundAndApprove(cashcat, bob, address(vault), 10e18);
        vm.deal(bob, 10e18);
        vm.prank(bob);
        (uint256 shares,,) = vault.mintPair{ value: 10e18 }(10e18, 10e18, 0, bob, block.timestamp);
        assertEq(shares, previewShares);
    }

    function testNativeMintRepricesAfterTargetTransferCallbackFees() public {
        CallbackERC20 callbackTarget = new CallbackERC20("Callback", "CALL", 18);
        PoolKey memory callbackKey = _nativeKey(address(callbackTarget));
        _initLivePool(callbackKey, 0);
        LpTokenVault callbackVault =
            _launch(address(callbackTarget), callbackKey, 1_000e18, 1_000e18);
        _configureSwapCallback(callbackTarget, address(callbackVault), callbackKey, 100e18);

        callbackTarget.mint(bob, 100e18);
        vm.prank(bob);
        callbackTarget.approve(address(callbackVault), type(uint256).max);
        uint256 maxCounter = 150e18;
        vm.deal(bob, maxCounter);
        (uint256 previewShares,,) = callbackVault.previewMintPair(100e18, maxCounter);

        vm.prank(bob);
        (uint256 shares, uint256 targetUsed, uint256 counterUsed) = callbackVault.mintPair{
            value: maxCounter
        }(
            100e18, maxCounter, 0, bob, block.timestamp
        );

        assertGt(shares, 0);
        assertLt(shares, previewShares);
        assertEq(callbackTarget.callbackCount(), 1);
        assertEq(bob.balance, maxCounter - counterUsed);
        (uint256 pendingTarget, uint256 pendingCounter) = callbackVault.pendingFees();
        assertEq(pendingTarget + pendingCounter, 0);
        uint256 grossShares = shares + callbackVault.balanceOf(treasury);
        (uint256 targetClaim, uint256 counterClaim) = callbackVault.claimForShares(grossShares);
        assertApproxEqAbs(targetClaim, targetUsed, 3);
        assertApproxEqAbs(counterClaim, counterUsed, 3);
    }

    function testNativeRedeemPaysOutBothLegs() public {
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 half = aliceShares / 2;
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        (uint256 targetOut, uint256 counterOut) = vault.redeem(half, 0, 0, alice, block.timestamp);
        assertGt(targetOut, 0);
        assertGt(counterOut, 0);
        assertEq(cashcat.balanceOf(alice), targetOut);
        assertEq(alice.balance, balanceBefore + counterOut);
    }

    function testNativeRedeemToRejectingReceiverFailsClosed() public {
        NativeRejector rejector = new NativeRejector();
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectPartialRevert(CurrencyTransfer.NativeTransferFailed.selector);
        vault.redeem(aliceShares / 2, 0, 0, address(rejector), block.timestamp);
    }

    function testNativeFeeAccrualAndPermissionlessCompound() public {
        _swap(poolKey, makeAddr("trader"), true, 50e18);
        _swap(poolKey, makeAddr("trader"), false, 50e18);
        (uint256 feesTarget, uint256 feesCounter) = vault.pendingFees();
        assertGt(feesTarget + feesCounter, 0);

        uint128 liquidityBefore = vault.positionLiquidity();
        vm.warp(vault.compoundAvailableAt());
        vm.prank(bob);
        uint128 added = vault.compound(0, block.timestamp);
        assertGt(added, 0);
        assertEq(vault.positionLiquidity(), liquidityBefore + added);
    }

    function testNativeShareFeeUsesVaultSharesEvenWhenTreasuryRejectsNative() public {
        NativeRejector rejectingTreasury = new NativeRejector();
        LpTokenFactory rejectingFactory =
            new LpTokenFactory(manager, address(rejectingTreasury), owner);
        MockERC20 token = new MockERC20("Second Target", "SECOND", 18);
        PoolKey memory key = _nativeKey(address(token));
        _initLivePool(key, 0);

        address predicted = rejectingFactory.predictVault(address(token), key);
        token.mint(owner, 1_000e18);
        vm.deal(owner, 1_000e18);
        vm.startPrank(owner);
        token.approve(predicted, type(uint256).max);
        (address vaultAddress,,) = rejectingFactory.launch{ value: 1_000e18 }(
            _launchParams(address(token), key, 1_000e18, 1_000e18, 0, 0)
        );
        vm.stopPrank();
        LpTokenVault rejectingVault = LpTokenVault(payable(vaultAddress));

        _fundAndApprove(token, bob, address(rejectingVault), 100e18);
        vm.deal(bob, 100e18);
        vm.prank(bob);
        rejectingVault.mintPair{ value: 100e18 }(100e18, 100e18, 0, bob, block.timestamp);
        assertGt(rejectingVault.balanceOf(address(rejectingTreasury)), 0);
    }

    function testForcedNativeCannotMintSharesAndAccruesToHolders() public {
        uint256 supplyBefore = vault.totalSupply();
        (, uint256 counterAssetsBefore) = vault.totalAssets();

        ForceSender sender = new ForceSender{ value: 3 ether }();
        sender.force(payable(address(vault)));

        // Forced native counter behaves exactly like a direct asset donation: supply is
        // untouched and the value accrues pro rata to existing holders.
        assertEq(vault.totalSupply(), supplyBefore);
        (, uint256 counterAssetsAfter) = vault.totalAssets();
        assertEq(counterAssetsAfter, counterAssetsBefore + 3 ether);
    }

    function testNativeLiquidityRefundsFlowThroughPoolManagerOnly() public {
        // Direct native transfers are rejected; only PoolManager settlement may pay in.
        uint256 balanceBefore = address(vault).balance;
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        (bool success,) = address(vault).call{ value: 1 ether }("");
        assertFalse(success);
        assertEq(address(vault).balance, balanceBefore);
    }
}
