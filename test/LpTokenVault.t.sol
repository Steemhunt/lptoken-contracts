// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IProtocolFees } from "@uniswap/v4-core/src/interfaces/IProtocolFees.sol";
import { Pool } from "@uniswap/v4-core/src/libraries/Pool.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { Position } from "@uniswap/v4-core/src/libraries/Position.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import { LpTokenVault } from "../src/LpTokenVault.sol";
import { ILpTokenFactory } from "../src/interfaces/ILpTokenFactory.sol";
import { CurrencyTransfer } from "../src/libraries/CurrencyTransfer.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import {
    CallbackERC20,
    TaxedERC20,
    ForceSender,
    TaxedLiquidityProvider
} from "./mocks/TestActors.sol";
import { LpTokenTestBase } from "./utils/LpTokenTestBase.sol";

contract LpTokenVaultTest is LpTokenTestBase {
    using StateLibrary for IPoolManager;

    event ShareFeeCharged(
        address indexed shareAccount,
        address indexed treasury,
        bool indexed redemption,
        uint256 assessedShares,
        uint256 feeShares
    );

    PoolKey internal poolKey;
    LpTokenVault internal vault;

    function setUp() public override {
        super.setUp();
        poolKey = _erc20Key(address(cashcat), address(usdg));
        _initLivePool(poolKey, 0);
        vault = _launch(address(cashcat), poolKey, 1_000e18, 1_000e18);
    }

    // -------------------------------------------------------------------
    // Pair mint
    // -------------------------------------------------------------------

    function testShareFeePolicyConstantsAndExactBoundaries() public view {
        assertEq(vault.BPS(), 10_000);
        assertEq(vault.SHARE_FEE_BPS(), 30);
        assertEq(vault.MIN_FEEABLE_SHARES(), 334);

        assertLt(uint256(333) * 30, 10_000);
        assertGe(uint256(334) * 30, 10_000);
        assertEq(FullMath.mulDivRoundingUp(10_000, 30, 10_000), 30);
        assertEq(FullMath.mulDivRoundingUp(334, 30, 10_000), 2);
    }

    function testMintPairRejectsGrossSharesBelowFeeableMinimum() public {
        (uint256 maxTarget, uint256 maxCounter) = _amountsForGrossShares(332);
        (uint256 shares, uint256 targetUsed, uint256 counterUsed) =
            vault.previewMintPair(maxTarget, maxCounter);
        assertEq(shares, 0);
        assertEq(targetUsed, 0);
        assertEq(counterUsed, 0);

        _fundAndApprove(cashcat, bob, address(vault), maxTarget);
        _fundAndApprove(usdg, bob, address(vault), maxCounter);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LpTokenVault.InsufficientShares.selector, 332, 334));
        vault.mintPair(maxTarget, maxCounter, 0, bob, block.timestamp);
    }

    function testMintPairChargesCeilingFeeAtFeeableMinimum() public {
        (uint256 maxTarget, uint256 maxCounter) = _amountsForGrossShares(334);
        (uint256 previewShares,,) = vault.previewMintPair(maxTarget, maxCounter);
        assertEq(previewShares, 332);

        uint256 treasuryBefore = vault.balanceOf(treasury);
        _fundAndApprove(cashcat, bob, address(vault), maxTarget);
        _fundAndApprove(usdg, bob, address(vault), maxCounter);
        vm.prank(bob);
        (uint256 shares,,) =
            vault.mintPair(maxTarget, maxCounter, previewShares, bob, block.timestamp);

        assertEq(shares, 332);
        assertEq(vault.balanceOf(treasury) - treasuryBefore, 2);
    }

    function testMintPairEmitsShareFeeForReceiverWhenPayerDiffers() public {
        address receiver = makeAddr("mint receiver");
        (uint256 maxTarget, uint256 maxCounter) = _amountsForGrossShares(10_000);
        (uint256 previewShares,,) = vault.previewMintPair(maxTarget, maxCounter);
        assertEq(previewShares, 9_970);

        _fundAndApprove(cashcat, bob, address(vault), maxTarget);
        _fundAndApprove(usdg, bob, address(vault), maxCounter);
        vm.expectEmit(true, true, true, true, address(vault));
        emit ShareFeeCharged(receiver, treasury, false, 10_000, 30);
        vm.prank(bob);
        (uint256 shares,,) =
            vault.mintPair(maxTarget, maxCounter, previewShares, receiver, block.timestamp);

        assertEq(shares, 9_970);
        assertEq(vault.balanceOf(receiver), 9_970);
        assertEq(vault.balanceOf(treasury), 30);
        assertEq(vault.balanceOf(bob), 0);
    }

    function testMintPairMatchesPreviewAndProRata() public {
        (uint256 previewShares, uint256 previewTarget, uint256 previewCounter) =
            vault.previewMintPair(100e18, 100e18);
        assertGt(previewShares, 0);

        uint256 supplyBefore = vault.totalSupply();
        uint256 treasuryBefore = vault.balanceOf(treasury);
        _fundAndApprove(cashcat, bob, address(vault), 100e18);
        _fundAndApprove(usdg, bob, address(vault), 100e18);
        vm.prank(bob);
        (uint256 shares, uint256 targetUsed, uint256 counterUsed) =
            vault.mintPair(100e18, 100e18, previewShares, bob, block.timestamp);

        assertEq(shares, previewShares);
        assertEq(targetUsed, previewTarget);
        assertEq(counterUsed, previewCounter);
        assertEq(vault.balanceOf(bob), shares);
        uint256 grossShares = vault.totalSupply() - supplyBefore;
        uint256 feeShares = grossShares - shares;
        assertEq(
            feeShares, FullMath.mulDivRoundingUp(grossShares, vault.SHARE_FEE_BPS(), vault.BPS())
        );
        assertEq(vault.balanceOf(treasury) - treasuryBefore, feeShares);

        (uint256 targetClaim, uint256 counterClaim) = vault.claimForShares(grossShares);
        assertApproxEqAbs(targetClaim, targetUsed, 2);
        assertApproxEqAbs(counterClaim, counterUsed, 2);
    }

    function testExistingVaultRoutesNewMintAndRedeemFeesAfterTreasuryRotation() public {
        (uint256 firstTarget, uint256 firstCounter) = _amountsForGrossShares(10_000);
        _fundAndApprove(cashcat, bob, address(vault), firstTarget);
        _fundAndApprove(usdg, bob, address(vault), firstCounter);
        vm.prank(bob);
        vault.mintPair(firstTarget, firstCounter, 0, bob, block.timestamp);

        uint256 oldTreasuryShares = vault.balanceOf(treasury);
        assertEq(oldTreasuryShares, 30);

        address newTreasury = makeAddr("new treasury");
        vm.prank(treasury);
        factory.proposeTreasury(newTreasury);
        assertEq(vault.treasury(), treasury);
        vm.prank(newTreasury);
        factory.acceptTreasury();
        assertEq(vault.treasury(), newTreasury);

        (uint256 secondTarget, uint256 secondCounter) = _amountsForGrossShares(10_000);
        _fundAndApprove(cashcat, bob, address(vault), secondTarget);
        _fundAndApprove(usdg, bob, address(vault), secondCounter);
        vm.prank(bob);
        vault.mintPair(secondTarget, secondCounter, 0, bob, block.timestamp);

        assertEq(vault.balanceOf(treasury), oldTreasuryShares);
        assertEq(vault.balanceOf(newTreasury), 30);

        vm.prank(bob);
        vault.redeem(334, 0, 0, bob, block.timestamp);
        assertEq(vault.balanceOf(treasury), oldTreasuryShares);
        assertEq(vault.balanceOf(newTreasury), 32);
    }

    function testMintPairRejectsExpiredDeadlineZeroReceiverAndMinShares() public {
        _fundAndApprove(cashcat, bob, address(vault), 100e18);
        _fundAndApprove(usdg, bob, address(vault), 100e18);

        vm.prank(bob);
        vm.expectRevert(LpTokenVault.DeadlineExpired.selector);
        vault.mintPair(100e18, 100e18, 0, bob, block.timestamp - 1);

        vm.prank(bob);
        vm.expectRevert(LpTokenVault.InvalidAddress.selector);
        vault.mintPair(100e18, 100e18, 0, address(0), block.timestamp);

        (uint256 previewShares,,) = vault.previewMintPair(100e18, 100e18);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                LpTokenVault.InsufficientShares.selector, previewShares, previewShares + 1
            )
        );
        vault.mintPair(100e18, 100e18, previewShares + 1, bob, block.timestamp);
    }

    function testMintPairRejectsNonzeroMsgValueForErc20Counter() public {
        _fundAndApprove(cashcat, bob, address(vault), 100e18);
        _fundAndApprove(usdg, bob, address(vault), 100e18);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LpTokenVault.InvalidMsgValue.selector, 1 ether, 0));
        vault.mintPair{ value: 1 ether }(100e18, 100e18, 0, bob, block.timestamp);
    }

    function testFeeCollectionBeforeMintPreventsDilution() public {
        // Accrue unrecognized swap fees.
        _swap(poolKey, makeAddr("trader"), true, 50e18);
        _swap(poolKey, makeAddr("trader"), false, 50e18);
        (uint256 pendingTarget, uint256 pendingCounter) = vault.pendingFees();
        assertGt(pendingTarget + pendingCounter, 0);

        (uint256 aliceTargetBefore, uint256 aliceCounterBefore) =
            vault.claimForShares(vault.balanceOf(alice));

        uint256 supplyBefore = vault.totalSupply();
        // Bob mints at the fee-inclusive preview. Gross backed shares preserve price;
        // the receiver gets the net and Treasury gets the share fee.
        (uint256 shares, uint256 targetUsed, uint256 counterUsed) = _mintAs(bob, 100e18, 100e18);
        uint256 grossShares = vault.totalSupply() - supplyBefore;
        (uint256 grossTarget, uint256 grossCounter) = vault.claimForShares(grossShares);
        assertApproxEqAbs(grossTarget, targetUsed, 2);
        assertApproxEqAbs(grossCounter, counterUsed, 2);
        assertLt(shares, grossShares);

        (uint256 aliceTargetAfter, uint256 aliceCounterAfter) =
            vault.claimForShares(vault.balanceOf(alice));
        assertGe(aliceTargetAfter + 2, aliceTargetBefore);
        assertGe(aliceCounterAfter + 2, aliceCounterBefore);
    }

    function testMintPairRepricesAndBooksTargetTransferCallbackFees() public {
        CallbackERC20 callbackTarget = new CallbackERC20("Callback", "CALL", 18);
        PoolKey memory callbackKey = _erc20Key(address(callbackTarget), address(usdg));
        _initLivePool(callbackKey, 0);
        LpTokenVault callbackVault =
            _launch(address(callbackTarget), callbackKey, 1_000e18, 1_000e18);
        _configureSwapCallback(callbackTarget, address(callbackVault), callbackKey, 100e18);

        callbackTarget.mint(bob, 100e18);
        vm.prank(bob);
        callbackTarget.approve(address(callbackVault), type(uint256).max);
        _fundAndApprove(usdg, bob, address(callbackVault), 100e18);
        (uint256 previewShares,,) = callbackVault.previewMintPair(100e18, 100e18);

        vm.prank(bob);
        (uint256 shares, uint256 targetUsed, uint256 counterUsed) =
            callbackVault.mintPair(100e18, 100e18, 0, bob, block.timestamp);

        assertGt(shares, 0);
        assertLt(shares, previewShares);
        assertEq(callbackTarget.callbackCount(), 1);
        (uint256 pendingTarget, uint256 pendingCounter) = callbackVault.pendingFees();
        assertEq(pendingTarget + pendingCounter, 0);
        uint256 grossShares = shares + callbackVault.balanceOf(treasury);
        (uint256 targetClaim, uint256 counterClaim) = callbackVault.claimForShares(grossShares);
        assertApproxEqAbs(targetClaim, targetUsed, 3);
        assertApproxEqAbs(counterClaim, counterUsed, 3);
    }

    function testMintPairRepricesAndBooksCounterTransferCallbackFees() public {
        CallbackERC20 callbackCounter = new CallbackERC20("Callback", "CALL", 18);
        PoolKey memory callbackKey = _erc20Key(address(tok8), address(callbackCounter));
        _initLivePool(callbackKey, 0);
        LpTokenVault callbackVault = _launch(address(tok8), callbackKey, 1_000e18, 1_000e18);
        _configureSwapCallback(callbackCounter, address(callbackVault), callbackKey, 100e18);

        _fundAndApprove(tok8, bob, address(callbackVault), 100e18);
        callbackCounter.mint(bob, 100e18);
        vm.prank(bob);
        callbackCounter.approve(address(callbackVault), type(uint256).max);
        (uint256 previewShares,,) = callbackVault.previewMintPair(100e18, 100e18);

        vm.prank(bob);
        (uint256 shares, uint256 targetUsed, uint256 counterUsed) =
            callbackVault.mintPair(100e18, 100e18, 0, bob, block.timestamp);

        assertGt(shares, 0);
        assertLt(shares, previewShares);
        assertEq(callbackCounter.callbackCount(), 1);
        (uint256 pendingTarget, uint256 pendingCounter) = callbackVault.pendingFees();
        assertEq(pendingTarget + pendingCounter, 0);
        uint256 grossShares = shares + callbackVault.balanceOf(treasury);
        (uint256 targetClaim, uint256 counterClaim) = callbackVault.claimForShares(grossShares);
        assertApproxEqAbs(targetClaim, targetUsed, 3);
        assertApproxEqAbs(counterClaim, counterUsed, 3);
    }

    function testTinyMintCannotDeployIdleBacklog() public {
        // Build a pending backlog. The mint collects it but may deploy only its deposits.
        _swap(poolKey, makeAddr("trader"), true, 200e18);
        _swap(poolKey, makeAddr("trader"), false, 200e18);
        uint128 liquidityBefore = vault.positionLiquidity();

        // A dust mint may deploy at most its own deposits.
        (, uint256 targetUsed, uint256 counterUsed) = _mintAs(bob, 0.0001e18, 0.0001e18);
        uint128 liquidityAfter = vault.positionLiquidity();

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolKey.toId());
        uint128 depositCap = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(vault.tickLower()),
            TickMath.getSqrtPriceAtTick(vault.tickUpper()),
            vault.targetIsCurrency0() ? targetUsed : counterUsed,
            vault.targetIsCurrency0() ? counterUsed : targetUsed
        );
        assertLe(liquidityAfter - liquidityBefore, depositCap);

        (uint256 idleTargetAfter, uint256 idleCounterAfter) = vault.idleBalances();
        assertGt(idleTargetAfter + idleCounterAfter, 0);
    }

    // -------------------------------------------------------------------
    // Redeem
    // -------------------------------------------------------------------

    function testRedeemRejectsAndPreviewsZeroBelowFeeableMinimum() public {
        (uint256 targetOut, uint256 counterOut) = vault.previewRedeem(333);
        assertEq(targetOut, 0);
        assertEq(counterOut, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LpTokenVault.InsufficientShares.selector, 333, 334));
        vault.redeem(333, 0, 0, alice, block.timestamp);
    }

    function testRedeemEmitsCeilingShareFeeAtFeeableMinimum() public {
        uint256 halfMinimum = 167;
        (uint256 targetOut, uint256 counterOut) = vault.previewRedeem(halfMinimum);
        assertEq(targetOut, 0);
        assertEq(counterOut, 0);

        for (uint256 i; i < 2; ++i) {
            vm.prank(alice);
            vm.expectRevert(
                abi.encodeWithSelector(
                    LpTokenVault.InsufficientShares.selector, halfMinimum, uint256(334)
                )
            );
            vault.redeem(halfMinimum, 0, 0, alice, block.timestamp);
        }

        uint256 treasuryBefore = vault.balanceOf(treasury);
        vm.expectEmit(true, true, true, true, address(vault));
        emit ShareFeeCharged(alice, treasury, true, 334, 2);
        vm.prank(alice);
        vault.redeem(334, 0, 0, alice, block.timestamp);
        assertEq(vault.balanceOf(treasury) - treasuryBefore, 2);
    }

    function testRedeemTenThousandSharesChargesExactlyThirty() public {
        uint256 treasuryBefore = vault.balanceOf(treasury);
        vm.expectEmit(true, true, true, true, address(vault));
        emit ShareFeeCharged(alice, treasury, true, 10_000, 30);
        vm.prank(alice);
        vault.redeem(10_000, 0, 0, alice, block.timestamp);
        assertEq(vault.balanceOf(treasury) - treasuryBefore, 30);
    }

    function testAcceptedRedeemFragmentationCannotReduceShareFee() public {
        uint256 chunkShares = 500;
        uint256 chunkCount = 20;
        uint256 combinedShares = chunkShares * chunkCount;
        uint256 combinedFee =
            FullMath.mulDivRoundingUp(combinedShares, vault.SHARE_FEE_BPS(), vault.BPS());
        uint256 expectedSplitFee =
            chunkCount * FullMath.mulDivRoundingUp(chunkShares, vault.SHARE_FEE_BPS(), vault.BPS());
        assertGe(chunkShares, vault.MIN_FEEABLE_SHARES());
        assertEq(expectedSplitFee, 40);

        uint256 treasuryBefore = vault.balanceOf(treasury);
        for (uint256 i; i < chunkCount; ++i) {
            vm.prank(alice);
            vault.redeem(chunkShares, 0, 0, alice, block.timestamp);
        }

        uint256 chargedSplitFee = vault.balanceOf(treasury) - treasuryBefore;
        assertEq(combinedFee, 30);
        assertEq(chargedSplitFee, expectedSplitFee);
        assertGe(chargedSplitFee, combinedFee);
    }

    function testRedeemProportionalAndEnforcesMinimums() public {
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 half = aliceShares / 2;
        (uint256 previewTarget, uint256 previewCounter) = vault.previewRedeem(half);

        vm.prank(alice);
        vm.expectPartialRevert(LpTokenVault.InsufficientTarget.selector);
        vault.redeem(half, previewTarget + 1e18, 0, alice, block.timestamp);

        vm.prank(alice);
        (uint256 targetOut, uint256 counterOut) =
            vault.redeem(half, previewTarget - 2, previewCounter - 2, alice, block.timestamp);
        assertApproxEqRel(targetOut, previewTarget, 1e9);
        assertApproxEqRel(counterOut, previewCounter, 1e9);
        assertEq(cashcat.balanceOf(alice), targetOut);
        assertEq(usdg.balanceOf(alice), counterOut);
        assertEq(vault.balanceOf(alice), aliceShares - half);
    }

    function testRedeemRemainsProportionalAcrossPriceMoves() public {
        _mintAs(bob, 500e18, 500e18);
        // Push the price hard in one direction.
        _swap(poolKey, makeAddr("whale"), true, 5_000e18);

        uint256 supply = vault.totalSupply();
        uint256 bobShares = vault.balanceOf(bob);
        uint256 redeemedShares =
            bobShares - FullMath.mulDivRoundingUp(bobShares, vault.SHARE_FEE_BPS(), vault.BPS());
        (uint256 targetAssets, uint256 counterAssets) = vault.totalAssets();

        vm.prank(bob);
        (uint256 targetOut, uint256 counterOut) =
            vault.redeem(bobShares, 0, 0, bob, block.timestamp);
        assertApproxEqRel(targetOut, targetAssets * redeemedShares / supply, 1e12);
        assertApproxEqRel(counterOut, counterAssets * redeemedShares / supply, 1e12);
    }

    function testFullActiveSupplyRedeemLeavesDeadAndTreasuryClaims() public {
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 expectedFee =
            FullMath.mulDivRoundingUp(aliceShares, vault.SHARE_FEE_BPS(), vault.BPS());
        vm.prank(alice);
        vault.redeem(aliceShares, 0, 0, alice, block.timestamp);

        assertEq(vault.balanceOf(treasury), expectedFee);
        assertEq(vault.totalSupply(), vault.DEAD_SHARES() + expectedFee);
        assertGt(vault.positionLiquidity(), 0);
        (uint256 targetAssets, uint256 counterAssets) = vault.totalAssets();
        (uint256 residualTarget, uint256 residualCounter) =
            vault.claimForShares(vault.totalSupply());
        assertEq(residualTarget, targetAssets);
        assertEq(residualCounter, counterAssets);
    }

    function testBootstrapIsShareFeeExempt() public view {
        assertEq(vault.balanceOf(treasury), 0);
        assertEq(
            vault.totalSupply(),
            vault.balanceOf(alice) + vault.balanceOf(vault.DEAD_SHARE_RECEIVER())
        );
    }

    function testOrdinaryTransfersAreFeeFree() public {
        uint256 amount = vault.balanceOf(alice) / 4;
        uint256 treasuryBefore = vault.balanceOf(treasury);
        vm.prank(alice);
        assertTrue(vault.transfer(bob, amount));
        assertEq(vault.balanceOf(bob), amount);
        assertEq(vault.balanceOf(treasury), treasuryBefore);
    }

    function testTreasuryRedeemIsNotFeeExempt() public {
        _mintAs(bob, 100e18, 100e18);
        uint256 submitted = vault.balanceOf(treasury);
        uint256 feeShares = FullMath.mulDivRoundingUp(submitted, vault.SHARE_FEE_BPS(), vault.BPS());
        assertGt(submitted, 0);

        vm.prank(treasury);
        vault.redeem(submitted, 0, 0, treasury, block.timestamp);
        assertEq(vault.balanceOf(treasury), feeShares);
    }

    function testFuzzShareFeeSplitsBackedGrossMint(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1e6, 100e18);
        uint256 supplyBefore = vault.totalSupply();
        uint256 treasuryBefore = vault.balanceOf(treasury);
        (uint256 shares, uint256 targetUsed, uint256 counterUsed) = _mintAs(bob, amount, amount);

        uint256 grossShares = vault.totalSupply() - supplyBefore;
        uint256 feeShares =
            FullMath.mulDivRoundingUp(grossShares, vault.SHARE_FEE_BPS(), vault.BPS());
        assertEq(shares, grossShares - feeShares);
        assertEq(vault.balanceOf(treasury) - treasuryBefore, feeShares);
        (uint256 targetClaim, uint256 counterClaim) = vault.claimForShares(grossShares);
        assertApproxEqAbs(targetClaim, targetUsed, 2);
        assertApproxEqAbs(counterClaim, counterUsed, 2);
    }

    // -------------------------------------------------------------------
    // Full-range fee accounting
    // -------------------------------------------------------------------

    function testFullRangeFeesRemainEntirelyInHolderNav() public {
        _swap(poolKey, makeAddr("trader"), true, 100e18);
        (uint256 pendingTarget, uint256 pendingCounter) = vault.pendingFees();
        assertGt(pendingTarget + pendingCounter, 0);
        (uint256 targetAssets, uint256 counterAssets) = vault.totalAssets();
        (uint256 targetClaim, uint256 counterClaim) = vault.claimForShares(vault.totalSupply());
        assertEq(targetClaim, targetAssets);
        assertEq(counterClaim, counterAssets);
    }

    function testUniswapProtocolFeeChangeKeepsAccountingConsistent() public {
        // This test contract owns the PoolManager artifact deployment.
        IProtocolFees(address(manager)).setProtocolFeeController(address(this));
        uint24 packed = (uint24(500) << 12) | uint24(500);
        IProtocolFees(address(manager)).setProtocolFee(poolKey, packed);

        _swap(poolKey, makeAddr("trader"), true, 100e18);
        (uint256 feesTarget, uint256 feesCounter) = vault.pendingFees();
        assertGt(feesTarget + feesCounter, 0);

        (uint256 targetAssets, uint256 counterAssets) = vault.totalAssets();
        (uint256 claimTarget, uint256 claimCounter) = vault.claimForShares(vault.totalSupply());
        assertEq(claimTarget, targetAssets);
        assertEq(claimCounter, counterAssets);

        // The vault never tries to double-subtract the Uniswap protocol fee.
        (,, uint24 protocolFee,) = vault.slot0();
        assertEq(protocolFee, packed);
    }

    // -------------------------------------------------------------------
    // Compound
    // -------------------------------------------------------------------

    function testCompoundIsPermissionlessAfterCooldown() public {
        _donateIdle(1e12, 1e12);
        vm.warp(vault.compoundAvailableAt());

        uint128 liquidityBefore = vault.positionLiquidity();
        vm.prank(bob);
        uint128 added = vault.compound(1, block.timestamp);

        assertGt(added, 0);
        assertEq(vault.positionLiquidity(), liquidityBefore + added);
        assertEq(vault.lastCompoundAt(), uint64(block.timestamp));
        assertEq(vault.compoundBase(), vault.positionLiquidity());
    }

    function testCompoundEnforcesTenMinuteCooldown() public {
        _donateIdle(1e12, 1e12);
        uint64 availableAt = vault.compoundAvailableAt();
        assertEq(availableAt, vault.lastCompoundAt() + vault.COMPOUND_INTERVAL());
        assertEq(vault.COMPOUND_INTERVAL(), 10 minutes);
        (,, uint128 availableLiquidity,, uint128 executableLiquidity, uint64 previewAvailableAt) =
            vault.previewCompound();
        assertGt(availableLiquidity, 0);
        assertEq(executableLiquidity, 0);
        assertEq(previewAvailableAt, availableAt);

        vm.warp(uint256(availableAt) - 1);
        vm.expectRevert(abi.encodeWithSelector(LpTokenVault.CompoundCooldown.selector, availableAt));
        vault.compound(0, block.timestamp);

        vm.warp(availableAt);
        assertGt(vault.compound(0, block.timestamp), 0);
    }

    function testCompoundBacklogIsPartiallyDeployedAtFeeDerivedCap() public {
        _donateIdle(1e21, 1e21);
        vm.warp(vault.compoundAvailableAt());
        (
            uint256 targetToDeploy,
            uint256 counterToDeploy,
            uint128 availableLiquidity,
            uint128 liquidityCap,
            uint128 executableLiquidity,
            uint64 availableAt
        ) = vault.previewCompound();
        assertGt(availableLiquidity, liquidityCap);
        assertEq(executableLiquidity, liquidityCap);
        assertEq(availableAt, block.timestamp);
        assertEq(liquidityCap, _expectedCompoundCap(vault.compoundBase()));

        (uint256 idleTargetBefore, uint256 idleCounterBefore) = vault.idleBalances();
        uint128 added = vault.compound(liquidityCap, block.timestamp);
        (uint256 idleTargetAfter, uint256 idleCounterAfter) = vault.idleBalances();

        assertEq(added, liquidityCap);
        assertApproxEqAbs(idleTargetBefore - idleTargetAfter, targetToDeploy, 1);
        assertApproxEqAbs(idleCounterBefore - idleCounterAfter, counterToDeploy, 1);
        assertGt(idleTargetAfter, 0);
        assertGt(idleCounterAfter, 0);
    }

    function testCompoundBoundsOversizedIdleDonationsWithoutOverflow() public {
        _donateIdle(type(uint128).max, type(uint128).max);
        vm.warp(vault.compoundAvailableAt());
        (,, uint128 availableLiquidity, uint128 liquidityCap, uint128 executableLiquidity,) =
            vault.previewCompound();

        assertGe(availableLiquidity, liquidityCap);
        assertEq(executableLiquidity, liquidityCap);
        assertEq(vault.compound(liquidityCap, block.timestamp), liquidityCap);
    }

    function testCompoundCapCannotExceedRemainingPositionHeadroom() public {
        uint128 headroom = 7;
        // Manufacture the uint128 boundary directly; reaching it through valid int128
        // liquidity additions would make this otherwise pure cap test impractical.
        bytes32 poolStateSlot =
            keccak256(abi.encodePacked(PoolId.unwrap(poolKey.toId()), StateLibrary.POOLS_SLOT));
        bytes32 positionsSlot = bytes32(uint256(poolStateSlot) + StateLibrary.POSITIONS_OFFSET);
        bytes32 positionId = Position.calculatePositionKey(
            address(vault), vault.tickLower(), vault.tickUpper(), vault.POSITION_SALT()
        );
        bytes32 positionSlot = keccak256(abi.encodePacked(positionId, positionsSlot));
        vm.store(address(manager), positionSlot, bytes32(uint256(type(uint128).max - headroom)));

        assertEq(vault.positionLiquidity(), type(uint128).max - headroom);
        assertEq(vault.compoundLiquidityCap(), headroom);
    }

    function testCompoundRespectsExternallyConsumedBoundaryTickHeadroom() public {
        uint128 headroom = 7;
        uint128 maxLiquidityPerTick = Pool.tickSpacingToMaxLiquidityPerTick(SPACING);
        (uint128 lowerGrossBefore,) = manager.getTickLiquidity(poolKey.toId(), vault.tickLower());
        (uint128 upperGrossBefore,) = manager.getTickLiquidity(poolKey.toId(), vault.tickUpper());
        uint128 externalLiquidity = maxLiquidityPerTick - lowerGrossBefore - headroom;

        address rival = makeAddr("boundary rival");
        cashcat.mint(rival, uint256(externalLiquidity) * 2);
        usdg.mint(rival, uint256(externalLiquidity) * 2);
        _addRangeLiquidity(
            poolKey, rival, vault.tickLower(), SPACING, int256(uint256(externalLiquidity))
        );

        (uint128 lowerGrossAfterExternal,) =
            manager.getTickLiquidity(poolKey.toId(), vault.tickLower());
        (uint128 upperGrossAfterExternal,) =
            manager.getTickLiquidity(poolKey.toId(), vault.tickUpper());
        assertEq(lowerGrossAfterExternal, maxLiquidityPerTick - headroom);
        assertEq(upperGrossAfterExternal, upperGrossBefore);

        _donateIdle(1e21, 1e21);
        vm.warp(vault.compoundAvailableAt());
        (,, uint128 availableLiquidity, uint128 liquidityCap, uint128 executableLiquidity,) =
            vault.previewCompound();
        assertEq(availableLiquidity, headroom);
        assertEq(liquidityCap, headroom);
        assertEq(executableLiquidity, headroom);
        assertEq(vault.compound(headroom, block.timestamp), headroom);

        (uint128 saturatedLowerGross,) = manager.getTickLiquidity(poolKey.toId(), vault.tickLower());
        assertEq(saturatedLowerGross, maxLiquidityPerTick);

        vm.warp(vault.compoundAvailableAt());
        (,, availableLiquidity, liquidityCap, executableLiquidity,) = vault.previewCompound();
        assertEq(availableLiquidity, 0);
        assertEq(liquidityCap, 0);
        assertEq(executableLiquidity, 0);
    }

    function testCompoundBacklogProgressesAtNextInterval() public {
        _donateIdle(1e21, 1e21);
        vm.warp(vault.compoundAvailableAt());
        uint128 firstAdded = vault.compound(1, block.timestamp);
        (uint256 idleTargetAfterFirst, uint256 idleCounterAfterFirst) = vault.idleBalances();

        vm.warp(vault.compoundAvailableAt());
        (,,,, uint128 secondExecutable,) = vault.previewCompound();
        uint128 secondAdded = vault.compound(secondExecutable, block.timestamp);
        (uint256 idleTargetAfterSecond, uint256 idleCounterAfterSecond) = vault.idleBalances();

        assertGt(firstAdded, 0);
        assertGt(secondAdded, 0);
        assertEq(secondAdded, secondExecutable);
        assertLt(idleTargetAfterSecond, idleTargetAfterFirst);
        assertLt(idleCounterAfterSecond, idleCounterAfterFirst);
    }

    function testCompoundCannotRepeatInSameInterval() public {
        _donateIdle(1e21, 1e21);
        vm.warp(vault.compoundAvailableAt());
        vault.compound(1, block.timestamp);
        uint64 nextAvailableAt = vault.compoundAvailableAt();

        vm.expectRevert(
            abi.encodeWithSelector(LpTokenVault.CompoundCooldown.selector, nextAvailableAt)
        );
        vault.compound(0, block.timestamp);
    }

    function testProportionalMintScalesCompoundCapWithoutInflatingExistingShare() public {
        _donateIdle(1e21, 1e21);
        vm.warp(vault.compoundAvailableAt());
        uint128 liquidityBefore = vault.positionLiquidity();
        uint128 capBefore = vault.compoundLiquidityCap();
        uint256 supplyBefore = vault.totalSupply();
        uint256 aliceShares = vault.balanceOf(alice);

        _mintAs(bob, 1_000e18, 1_000e18);

        uint128 liquidityAfter = vault.positionLiquidity();
        uint128 capAfter = vault.compoundLiquidityCap();
        uint256 supplyAfter = vault.totalSupply();
        assertGt(liquidityAfter, liquidityBefore);
        assertEq(vault.compoundBase(), liquidityAfter);
        assertGt(capAfter, capBefore);

        uint256 allowanceBefore = FullMath.mulDiv(capBefore, aliceShares, supplyBefore);
        uint256 allowanceAfter = FullMath.mulDiv(capAfter, aliceShares, supplyAfter);
        assertApproxEqAbs(
            allowanceAfter, allowanceBefore, 1, "mint inflated an existing share's cap"
        );
        assertGt(vault.compound(1, block.timestamp), 0);
    }

    function testRedeemAndMintKeepCompoundBaseProportionalToSupply() public {
        uint128 liquidityBefore = vault.positionLiquidity();
        uint256 supplyBefore = vault.totalSupply();
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares / 2, 0, 0, alice, block.timestamp);

        uint128 currentLiquidity = vault.positionLiquidity();
        uint256 currentSupply = vault.totalSupply();
        assertLt(currentLiquidity, liquidityBefore);
        assertEq(vault.compoundBase(), currentLiquidity);
        assertGe(
            uint256(currentLiquidity) * supplyBefore,
            uint256(liquidityBefore) * currentSupply,
            "redeem diluted liquidity per share"
        );
        uint128 reducedCap = vault.compoundLiquidityCap();
        assertEq(reducedCap, _expectedCompoundCap(currentLiquidity));

        _mintAs(bob, 1_000e18, 1_000e18);
        uint128 liquidityAfterMint = vault.positionLiquidity();
        uint256 supplyAfterMint = vault.totalSupply();
        assertGt(liquidityAfterMint, currentLiquidity);
        assertEq(vault.compoundBase(), liquidityAfterMint);
        assertGe(
            uint256(liquidityAfterMint) * currentSupply,
            uint256(currentLiquidity) * supplyAfterMint,
            "mint diluted liquidity per share"
        );
        assertGt(vault.compoundLiquidityCap(), reducedCap);
    }

    function testCompoundDeploysEntireCandidateBelowCap() public {
        _donateIdle(1e12, 1e12);
        vm.warp(vault.compoundAvailableAt());
        (
            uint256 targetToDeploy,
            uint256 counterToDeploy,
            uint128 availableLiquidity,
            uint128 liquidityCap,
            uint128 executableLiquidity,
            uint64 availableAt
        ) = vault.previewCompound();
        assertGt(availableLiquidity, 0);
        assertLt(availableLiquidity, liquidityCap);
        assertEq(executableLiquidity, availableLiquidity);
        assertEq(availableAt, block.timestamp);

        (uint256 idleTargetBefore, uint256 idleCounterBefore) = vault.idleBalances();
        uint128 added = vault.compound(executableLiquidity, block.timestamp);
        (uint256 idleTargetAfter, uint256 idleCounterAfter) = vault.idleBalances();

        assertEq(added, availableLiquidity);
        assertApproxEqAbs(idleTargetBefore - idleTargetAfter, targetToDeploy, 1);
        assertApproxEqAbs(idleCounterBefore - idleCounterAfter, counterToDeploy, 1);
    }

    function testCompoundFailsClosedOnStaleDeadlineAndMinLiquidity() public {
        vm.warp(vault.compoundAvailableAt());
        vm.expectRevert(LpTokenVault.DeadlineExpired.selector);
        vault.compound(0, block.timestamp - 1);

        _donateIdle(1e12, 1e12);
        (,,,, uint128 executableLiquidity,) = vault.previewCompound();
        vm.expectRevert(
            abi.encodeWithSelector(
                LpTokenVault.InsufficientLiquidityAdded.selector,
                executableLiquidity,
                executableLiquidity + 1
            )
        );
        vault.compound(executableLiquidity + 1, block.timestamp);
    }

    function testCompoundRejectsZeroMatchedLiquidity() public {
        vm.warp(vault.compoundAvailableAt());
        (,,,, uint128 executableLiquidity,) = vault.previewCompound();
        assertEq(executableLiquidity, 0);

        vm.expectRevert(
            abi.encodeWithSelector(LpTokenVault.InsufficientLiquidityAdded.selector, 0, 0)
        );
        vault.compound(0, block.timestamp);
    }

    function testCompoundIsSwaplessAndLeavesOneSidedResidueIdle() public {
        // One-sided donation creates one-sided recognized fees.
        (uint256 donate0, uint256 donate1) =
            vault.targetIsCurrency0() ? (uint256(50e18), uint256(0)) : (uint256(0), uint256(50e18));
        _donate(poolKey, makeAddr("donor"), donate0, donate1);

        int24 tickBefore = _currentTick(poolKey);
        vm.warp(vault.compoundAvailableAt());
        vm.expectPartialRevert(LpTokenVault.InsufficientLiquidityAdded.selector);
        vault.compound(1, block.timestamp);

        // Nothing was swapped: the price is untouched and the residue remains pending NAV.
        assertEq(_currentTick(poolKey), tickBefore);
        (uint256 pendingTarget, uint256 pendingCounter) = vault.pendingFees();
        assertGt(pendingTarget + pendingCounter, 0);

        // The residue remains redeemable pro rata.
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        (uint256 targetOut, uint256 counterOut) =
            vault.redeem(aliceShares, 0, 0, alice, block.timestamp);
        assertGt(targetOut + counterOut, 0);
    }

    // -------------------------------------------------------------------
    // External liquidity and pool-wide state
    // -------------------------------------------------------------------

    function testExternalPositionsNeverEnterVaultAccounting() public {
        (uint256 targetBefore, uint256 counterBefore) = vault.totalAssets();
        uint128 positionBefore = vault.positionLiquidity();

        address rival = makeAddr("rival");
        _addRangeLiquidity(poolKey, rival, -SPACING, SPACING, 1e18);
        _addFullRangeLiquidity(poolKey, rival, 1e18);

        (uint256 targetAfter, uint256 counterAfter) = vault.totalAssets();
        assertEq(vault.positionLiquidity(), positionBefore);
        assertEq(targetAfter, targetBefore);
        assertEq(counterAfter, counterBefore);
    }

    function testOtherLpFeesCannotBeCollectedByVault() public {
        // The external full-range LP from setUp holds most of the pool. Vault fee share
        // must be proportional to vault liquidity only.
        uint128 vaultLiquidity = vault.positionLiquidity();
        uint128 poolLiquidity = manager.getLiquidity(poolKey.toId());
        assertGt(poolLiquidity, vaultLiquidity);

        uint256 amountIn = 100e18;
        _swap(poolKey, makeAddr("trader"), true, amountIn);
        (uint256 pending0,) = _pendingSorted();
        uint256 totalFee0 = amountIn * FEE / 1e6;
        uint256 expectedVaultShare = totalFee0 * vaultLiquidity / poolLiquidity;
        assertApproxEqRel(pending0, expectedVaultShare, 5e15);
        assertLt(pending0, totalFee0);
    }

    function testSwapsAndDonationsAccrueProRata() public {
        uint128 vaultLiquidity = vault.positionLiquidity();
        uint128 poolLiquidity = manager.getLiquidity(poolKey.toId());

        _donate(poolKey, makeAddr("donor"), 100e18, 100e18);
        (uint256 pending0, uint256 pending1) = _pendingSorted();
        assertApproxEqRel(pending0, uint256(100e18) * vaultLiquidity / poolLiquidity, 5e15);
        assertApproxEqRel(pending1, uint256(100e18) * vaultLiquidity / poolLiquidity, 5e15);

        // The complete accrued amounts remain included in holder NAV.
        (uint256 targetAssets, uint256 counterAssets) = vault.totalAssets();
        (uint256 targetClaim, uint256 counterClaim) = vault.claimForShares(vault.totalSupply());
        assertEq(targetClaim, targetAssets);
        assertEq(counterClaim, counterAssets);
    }

    function testDirectAssetDonationBenefitsExistingHolders() public {
        (uint256 targetBefore,) = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();

        cashcat.mint(address(this), 10e18);
        cashcat.transfer(address(vault), 10e18);

        (uint256 targetAfter,) = vault.totalAssets();
        assertEq(vault.totalSupply(), supplyBefore);
        assertEq(targetAfter, targetBefore + 10e18);
    }

    function testForcedEtherCannotMintSharesOrChangeErc20Assets() public {
        uint256 supplyBefore = vault.totalSupply();
        (uint256 targetAssets, uint256 counterAssets) = vault.totalAssets();

        ForceSender sender = new ForceSender{ value: 5 ether }();
        sender.force(payable(address(vault)));
        assertEq(address(vault).balance, 5 ether);

        // Forced native currency is not a leg of this ERC20/ERC20 vault.
        assertEq(vault.totalSupply(), supplyBefore);
        (uint256 targetAssetsAfter, uint256 counterAssetsAfter) = vault.totalAssets();
        assertEq(targetAssetsAfter, targetAssets);
        assertEq(counterAssetsAfter, counterAssets);
    }

    // -------------------------------------------------------------------
    // Support boundary and authentication
    // -------------------------------------------------------------------

    function testTaxedTokenFailsSafelyAtLaunch() public {
        TaxedERC20 taxed = new TaxedERC20();
        PoolKey memory taxedKey = _erc20Key(address(taxed), address(usdg));
        manager.initialize(taxedKey, TickMath.getSqrtPriceAtTick(0));
        // A taxed pool can exist through gross-up routers; the vault must still refuse it.
        TaxedLiquidityProvider provider = new TaxedLiquidityProvider(manager);
        taxed.mint(address(provider), 1e24);
        usdg.mint(address(provider), 1e24);
        provider.provide(taxedKey, 1e18);
        assertGt(manager.getLiquidity(taxedKey.toId()), 0);

        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(taxed), taxedKey, 1_000e18, 1_000e18, 0, 0);
        address predicted = factory.predictVault(address(taxed), taxedKey);
        taxed.mint(owner, 1_000e18);
        usdg.mint(owner, 1_000e18);
        vm.startPrank(owner);
        taxed.approve(predicted, type(uint256).max);
        usdg.approve(predicted, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(CurrencyTransfer.TaxedOrRebasingToken.selector, address(taxed))
        );
        factory.launch(params);
        vm.stopPrank();
    }

    function testUnlockCallbackOnlyPoolManager() public {
        vm.expectRevert(LpTokenVault.OnlyPoolManager.selector);
        vault.unlockCallback(abi.encode(int256(0)));
    }

    function testReceiveRejectsDirectNative() public {
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        (bool success,) = address(vault).call{ value: 1 ether }("");
        assertFalse(success);
    }

    function testNoPrivilegedOwnerOrTreasuryPrincipalWithdrawal() public {
        _mintAs(bob, 100e18, 100e18);
        uint256 treasuryShares = vault.balanceOf(treasury);
        assertGt(treasuryShares, 0);

        // Compound only moves holder NAV into the vault's own position.
        _swap(poolKey, makeAddr("trader"), true, 100e18);
        _swap(poolKey, makeAddr("trader"), false, 100e18);
        (uint256 targetAssetsBefore, uint256 counterAssetsBefore) = vault.totalAssets();
        vm.warp(vault.compoundAvailableAt());
        vault.compound(0, block.timestamp);
        (uint256 targetAssetsAfter, uint256 counterAssetsAfter) = vault.totalAssets();
        assertApproxEqAbs(targetAssetsAfter, targetAssetsBefore, 2);
        assertApproxEqAbs(counterAssetsAfter, counterAssetsBefore, 2);
    }

    // -------------------------------------------------------------------
    // Decimals and volatile counters
    // -------------------------------------------------------------------

    function testCounterDecimalsSixEightEighteen() public {
        MockERC20[3] memory counters = [usdg, tok8, weth];
        uint256[3] memory seeds = [uint256(1_000e6), uint256(1_000e8), uint256(1_000e18)];
        for (uint256 i; i < counters.length; ++i) {
            MockERC20 token = new MockERC20("Fresh Target", "FRESH", 18);
            PoolKey memory key = _erc20Key(address(token), address(counters[i]));
            _initLivePool(key, 0);
            LpTokenVault fresh = _launch(address(token), key, 1_000e18, seeds[i]);

            _fundAndApprove(token, bob, address(fresh), 10e18);
            _fundAndApprove(counters[i], bob, address(fresh), seeds[i] / 100);
            vm.prank(bob);
            (uint256 shares,,) = fresh.mintPair(10e18, seeds[i] / 100, 0, bob, block.timestamp);
            assertGt(shares, 0);

            vm.prank(bob);
            (uint256 targetOut, uint256 counterOut) =
                fresh.redeem(shares, 0, 0, bob, block.timestamp);
            assertGt(targetOut, 0);
            assertGt(counterOut, 0);
        }
    }

    function testVolatileCounterSurvivesLargeMoves() public {
        MockERC20 spacex = new MockERC20("Space X", "SPACEX", 18);
        MockERC20 token = new MockERC20("Vol Target", "VOL", 18);
        PoolKey memory key = _erc20Key(address(token), address(spacex));
        _initLivePool(key, 0);
        LpTokenVault volatileVault = _launch(address(token), key, 1_000e18, 1_000e18);

        for (uint256 i; i < 3; ++i) {
            _swap(key, makeAddr("whale"), true, 2_000e18);
            _swap(key, makeAddr("whale"), false, 1_000e18);
        }
        (uint256 targetAssets, uint256 counterAssets) = volatileVault.totalAssets();
        (uint256 claimTarget, uint256 claimCounter) =
            volatileVault.claimForShares(volatileVault.totalSupply());
        assertEq(claimTarget, targetAssets);
        assertEq(claimCounter, counterAssets);

        uint256 aliceShares = volatileVault.balanceOf(alice);
        vm.prank(alice);
        (uint256 targetOut, uint256 counterOut) =
            volatileVault.redeem(aliceShares, 0, 0, alice, block.timestamp);
        assertGt(targetOut + counterOut, 0);
    }

    function testVaultAccountingBelowFullRangeLowerTick() public {
        _assertVaultAccountingOutsideFullRange(true);
    }

    function testVaultAccountingAboveFullRangeUpperTick() public {
        _assertVaultAccountingOutsideFullRange(false);
    }

    // -------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------

    function _mintAs(address who, uint256 maxTarget, uint256 maxCounter)
        private
        returns (uint256 shares, uint256 targetUsed, uint256 counterUsed)
    {
        _fundAndApprove(cashcat, who, address(vault), maxTarget);
        _fundAndApprove(usdg, who, address(vault), maxCounter);
        vm.prank(who);
        (shares, targetUsed, counterUsed) =
            vault.mintPair(maxTarget, maxCounter, 0, who, block.timestamp);
    }

    function _amountsForGrossShares(uint256 grossShares)
        private
        view
        returns (uint256 targetAmount, uint256 counterAmount)
    {
        uint256 supply = vault.totalSupply();
        (uint256 targetAssets, uint256 counterAssets) = vault.totalAssets();
        targetAmount = FullMath.mulDivRoundingUp(grossShares, targetAssets, supply);
        counterAmount = FullMath.mulDivRoundingUp(grossShares, counterAssets, supply);
    }

    function _donateIdle(uint256 targetAmount, uint256 counterAmount) private {
        cashcat.mint(address(vault), targetAmount);
        usdg.mint(address(vault), counterAmount);
    }

    function _expectedCompoundCap(uint128 baseLiquidity) private view returns (uint128) {
        return uint128(
            uint256(baseLiquidity) * vault.lpFee() * vault.COMPOUND_SAFETY_BPS()
                / ((1_000_000 - vault.lpFee()) * vault.BPS())
        );
    }

    function _pendingSorted() private view returns (uint256 pending0, uint256 pending1) {
        (uint256 pendingTarget, uint256 pendingCounter) = vault.pendingFees();
        return vault.targetIsCurrency0()
            ? (pendingTarget, pendingCounter)
            : (pendingCounter, pendingTarget);
    }

    function _assertVaultAccountingOutsideFullRange(bool below) private {
        MockERC20 targetToken = new MockERC20("Extreme Target", "EXT", 18);
        MockERC20 counterToken = new MockERC20("Extreme Counter", "XCOUNT", 18);
        PoolKey memory key = _erc20Key(address(targetToken), address(counterToken));
        int24 boundary = below
            ? TickMath.minUsableTick(key.tickSpacing)
            : TickMath.maxUsableTick(key.tickSpacing);
        int24 initialTick = below ? boundary + key.tickSpacing : boundary - key.tickSpacing;
        manager.initialize(key, TickMath.getSqrtPriceAtTick(initialTick));
        _addFullRangeLiquidity(key, address(this), 1e8);

        uint256 amount0 = below ? 1e30 : 1e12;
        uint256 amount1 = below ? 1e12 : 1e30;
        bool targetIsCurrency0 = Currency.unwrap(key.currency0) == address(targetToken);
        LpTokenVault extremeVault = _launch(
            address(targetToken),
            key,
            targetIsCurrency0 ? amount0 : amount1,
            targetIsCurrency0 ? amount1 : amount0
        );
        _swap(key, makeAddr(below ? "lower-bound trader" : "upper-bound trader"), below, 1e35);

        int24 currentTick = _currentTick(key);
        if (below) assertLt(currentTick, extremeVault.tickLower());
        else assertGt(currentTick, extremeVault.tickUpper());

        (uint256 principalTarget, uint256 principalCounter) = extremeVault.positionPrincipal();
        (uint256 principal0, uint256 principal1) = extremeVault.targetIsCurrency0()
            ? (principalTarget, principalCounter)
            : (principalCounter, principalTarget);
        if (below) {
            assertGt(principal0, 0);
            assertEq(principal1, 0);
        } else {
            assertEq(principal0, 0);
            assertGt(principal1, 0);
        }

        targetToken.mint(address(extremeVault), 1e18);
        counterToken.mint(address(extremeVault), 1e18);
        vm.warp(extremeVault.compoundAvailableAt());
        (,, uint128 availableLiquidity, uint128 liquidityCap, uint128 executableLiquidity,) =
            extremeVault.previewCompound();
        // Beyond the full-range bound every position is inactive, so the pool reports no
        // active liquidity. Manipulating a price nobody can trade against is free, so the
        // base clamps to zero and compound is closed here rather than deploying blind.
        assertGt(availableLiquidity, 0);
        assertEq(manager.getLiquidity(key.toId()), 0);
        assertEq(extremeVault.compoundBase(), 0);
        assertEq(liquidityCap, 0);
        assertEq(executableLiquidity, 0);
        vm.expectRevert(
            abi.encodeWithSelector(LpTokenVault.InsufficientLiquidityAdded.selector, 0, 0)
        );
        extremeVault.compound(0, block.timestamp);

        // Accounting and exit must still be exact out here.
        uint256 shares = extremeVault.balanceOf(alice) / 2;
        (uint256 previewTarget, uint256 previewCounter) = extremeVault.previewRedeem(shares);
        vm.prank(alice);
        (uint256 targetOut, uint256 counterOut) =
            extremeVault.redeem(shares, 0, 0, alice, block.timestamp);
        assertApproxEqRel(targetOut, previewTarget, 1e9);
        assertApproxEqRel(counterOut, previewCounter, 1e9);
    }
}
