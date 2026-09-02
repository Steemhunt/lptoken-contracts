// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Vm } from "forge-std/Vm.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { Pool } from "@uniswap/v4-core/src/libraries/Pool.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import { LaunchLiquidityVault } from "../src/LaunchLiquidityVault.sol";
import { LaunchToken } from "../src/LaunchToken.sol";
import { LpTokenFactory } from "../src/LpTokenFactory.sol";
import { LpTokenVault } from "../src/LpTokenVault.sol";
import { TokenLaunchpad } from "../src/TokenLaunchpad.sol";
import { ILaunchFeeSource } from "../src/interfaces/ILaunchFeeSource.sol";
import { LpTokenTestBase } from "./utils/LpTokenTestBase.sol";

contract LaunchFeeReceiver {
    enum Mode {
        Accept,
        Reject,
        BurnGas,
        Reenter
    }

    Mode public mode;
    LaunchLiquidityVault public source;
    address public token;
    bool public reentrySucceeded;

    function createToken(
        TokenLaunchpad launchpad,
        TokenLaunchpad.TokenMetadata calldata metadata,
        bytes32 salt
    ) external payable returns (address launchedToken, address vault, uint256 targetOut) {
        return launchpad.createToken{ value: msg.value }(
            metadata,
            salt,
            0,
            TickMath.MIN_SQRT_PRICE + 1,
            launchpad.startTick(),
            launchpad.initialLpQuote(),
            block.timestamp
        );
    }

    function setMode(Mode mode_, LaunchLiquidityVault source_, address token_) external {
        mode = mode_;
        source = source_;
        token = token_;
        reentrySucceeded = false;
    }

    receive() external payable {
        Mode currentMode = mode;
        if (currentMode == Mode.Reject) revert();
        if (currentMode == Mode.BurnGas) {
            assembly ("memory-safe") {
                for { } 1 { } { }
            }
        }
        if (currentMode == Mode.Reenter) {
            (reentrySucceeded,) =
                address(source).call(abi.encodeCall(LaunchLiquidityVault.distributeFees, (token)));
        }
    }
}

contract LaunchFeeMathHarness is LaunchLiquidityVault {
    constructor(IPoolManager poolManager_)
        LaunchLiquidityVault(poolManager_, address(this), address(this))
    { }

    function previewAllocation(
        uint256 grossTarget,
        uint256 grossCounter,
        uint8 targetRemainder,
        uint8 counterRemainder
    )
        external
        pure
        returns (
            FeeAmounts memory creator,
            FeeAmounts memory nav,
            FeeAmounts memory protocol,
            uint8 nextTargetRemainder,
            uint8 nextCounterRemainder
        )
    {
        return _previewAllocation(grossTarget, grossCounter, targetRemainder, counterRemainder);
    }
}

contract TokenLaunchpadTest is LpTokenTestBase {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    event LaunchFeesAllocated(
        address indexed token,
        address indexed lpTokenVault,
        address indexed creator,
        uint256 allocatedTarget,
        uint256 allocatedCounter,
        uint256 creatorTarget,
        uint256 creatorCounter,
        uint256 navTarget,
        uint256 navCounter,
        uint256 protocolCounter,
        uint8 targetRemainder,
        uint8 counterRemainder
    );
    event LaunchFeePayout(
        address indexed token,
        address indexed receiver,
        LaunchLiquidityVault.FeeRecipient indexed recipient,
        uint256 targetAmount,
        uint256 counterAmount,
        bool targetSuccess,
        bool counterSuccess
    );

    TokenLaunchpad internal launchpad;
    LaunchLiquidityVault internal launchLiquidityVault;

    function setUp() public override {
        super.setUp();
        launchpad = _deployLaunchpad(manager, factory, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE);
        launchLiquidityVault = launchpad.liquidityVault();
        vm.prank(owner);
        factory.bindLaunchpad(address(launchpad));
    }

    /// @dev The launch-fee source is part of the clone's immutable arguments, so the generic
    /// prediction helper has to resolve it for a platform PoolKey or it points at an address
    /// where no vault exists.
    function testPredictVaultResolvesTheLaunchpadFeeSource() public {
        (address token, address vaultAddress,) =
            _create(alice, _metadata(), keccak256("predict parity"), 0);
        PoolKey memory key = launchpad.poolKey(token);

        assertEq(factory.predictVault(token, key), vaultAddress);
        assertEq(factory.predictLaunchpadVault(token), vaultAddress);

        // A second pool holding the same token is an ordinary curated launch: no fee source,
        // and therefore a different clone address.
        assertTrue(factory.predictVault(token, _erc20Key(token, address(usdg))) != vaultAddress);
    }

    function testLaunchPoolUsesOnlyTheInitializerHookPermission() public view {
        PoolKey memory key = launchpad.poolKey(address(cashcat));

        assertEq(address(key.hooks), address(launchpad));
        assertEq(uint160(address(key.hooks)) & Hooks.ALL_HOOK_MASK, Hooks.BEFORE_INITIALIZE_FLAG);
    }

    function testConstructorRejectsUnminedHookAddress() public {
        vm.expectRevert();
        new TokenLaunchpad(manager, factory, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE);
    }

    function testThirdPartyCannotPreinitializePredictedLaunchPool() public {
        TokenLaunchpad.TokenMetadata memory metadata = _metadata();
        bytes32 salt = keccak256("protected initialization");
        address predictedToken = launchpad.predictTokenAddress(alice, metadata, salt);
        PoolKey memory key = launchpad.poolKey(predictedToken);
        uint160 initialSqrtPriceX96 = launchpad.initialSqrtPriceX96();

        vm.prank(bob);
        vm.expectRevert();
        manager.initialize(key, initialSqrtPriceX96);
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, 0);

        (address token,,) = _create(alice, metadata, salt, 0);
        assertEq(token, predictedToken);
        (sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, initialSqrtPriceX96);
    }

    function testLaunchCreatesBoundaryPositionAndLockedFullRangeVault() public {
        TokenLaunchpad.TokenMetadata memory metadata = _metadata();
        bytes32 salt = keccak256("first launch");
        address predictedToken = launchpad.predictTokenAddress(alice, metadata, salt);
        address predictedVault = factory.predictLaunchpadVault(predictedToken);

        (address token, address vaultAddress, uint256 initialBuyOut) =
            _create(alice, metadata, salt, 0);
        LpTokenVault vault = LpTokenVault(payable(vaultAddress));
        PoolKey memory key = launchpad.poolKey(token);

        assertEq(token, predictedToken);
        assertEq(vaultAddress, predictedVault);
        assertEq(initialBuyOut, 0);
        assertTrue(launchpad.isToken(token));
        assertEq(factory.vaultOfPoolId(key.toId()), vaultAddress);
        assertEq(vault.launchFeeSource(), address(launchLiquidityVault));
        assertTrue(vault.counterIsNative());
        assertFalse(vault.targetIsCurrency0());
        assertEq(vault.lpFee(), launchpad.LP_FEE());
        assertEq(vault.tickSpacing(), launchpad.TICK_SPACING());
        assertEq(address(vault.poolKey().hooks), address(launchpad));
        assertEq(vault.poolId(), PoolId.unwrap(key.toId()));

        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, launchpad.initialSqrtPriceX96());
        assertEq(tick, launchpad.startTick());

        (address creator, address recordedVault, uint128 launchLiquidity,) =
            launchLiquidityVault.positions(token);
        assertEq(creator, alice);
        assertEq(recordedVault, vaultAddress);
        assertGt(launchLiquidity, 0);

        // At the exact upper boundary, the token-only launch position is inactive.
        // The newly bootstrapped full-range vault is the pool's only active liquidity.
        assertEq(manager.getLiquidity(key.toId()), vault.positionLiquidity());
        (uint128 recordedLaunchLiquidity,,) = manager.getPositionInfo(
            key.toId(),
            address(launchLiquidityVault),
            TickMath.minUsableTick(launchpad.TICK_SPACING()),
            launchpad.startTick(),
            bytes32(0)
        );
        assertEq(recordedLaunchLiquidity, launchLiquidity);

        assertEq(vault.totalSupply(), vault.balanceOf(vault.DEAD_SHARE_RECEIVER()));
        assertEq(vault.balanceOf(alice), 0);
        assertEq(IERC20(token).balanceOf(address(launchpad)), 0);
        assertEq(LaunchToken(token).totalSupply(), launchpad.TOKEN_SUPPLY());
    }

    function testAtomicCreatorInitialBuyMovesIntoLaunchRange() public {
        uint256 buyAmount = 0.1 ether;
        (address token, address vaultAddress, uint256 targetOut) =
            _create(alice, _metadata(), keccak256("initial buy"), buyAmount);
        PoolKey memory key = launchpad.poolKey(token);
        LpTokenVault vault = LpTokenVault(payable(vaultAddress));

        assertGt(targetOut, 0);
        assertEq(IERC20(token).balanceOf(alice), targetOut);
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertLt(tick, launchpad.startTick());

        (,, uint128 launchLiquidity,) = launchLiquidityVault.positions(token);
        assertEq(manager.getLiquidity(key.toId()), launchLiquidity + vault.positionLiquidity());
        (, uint256 pendingVaultPositionQuote) = vault.pendingFees();
        assertGt(pendingVaultPositionQuote, 0);
        (, ILaunchFeeSource.FeeAmounts memory pendingNav,) = launchLiquidityVault.pendingFees(token);
        assertGt(pendingNav.counter, 0);
    }

    function testLaunchFeeReceivableIsIncludedBeforeFirstPublicMint() public {
        uint256 buyAmount = 0.1 ether;
        (address token, address vaultAddress,) =
            _create(alice, _metadata(), keccak256("receivable"), buyAmount);
        LpTokenVault vault = LpTokenVault(payable(vaultAddress));
        (, uint256 pendingQuote) = vault.pendingLaunchFees();
        assertGt(pendingQuote, 0);

        uint256 maxTarget = IERC20(token).balanceOf(alice) / 100;
        uint256 maxQuote = 0.001 ether;
        (uint256 previewShares,,) = vault.previewMintPair(maxTarget, maxQuote);
        assertGt(previewShares, 0);

        vm.prank(alice);
        assertTrue(IERC20(token).transfer(bob, maxTarget));
        vm.prank(bob);
        IERC20(token).approve(vaultAddress, maxTarget);
        vm.deal(bob, maxQuote);
        vm.prank(bob);
        (uint256 shares,,) =
            vault.mintPair{ value: maxQuote }(maxTarget, maxQuote, 0, bob, block.timestamp);

        assertEq(shares, previewShares);
        (uint256 pendingTargetAfter, uint256 pendingQuoteAfter) = vault.pendingLaunchFees();
        assertEq(pendingTargetAfter, 0);
        assertEq(pendingQuoteAfter, 0);
    }

    function testLaunchFeesUseGroupedPendingViewAndPermissionlessDistribution() public {
        (address token, address vaultAddress,) =
            _create(alice, _metadata(), keccak256("launch fee distribution"), 0.1 ether);

        (
            ILaunchFeeSource.FeeAmounts memory creator,
            ILaunchFeeSource.FeeAmounts memory nav,
            ILaunchFeeSource.FeeAmounts memory protocol
        ) = launchLiquidityVault.pendingFees(token);
        assertEq(creator.target, 0);
        assertEq(nav.target, 0);
        assertEq(protocol.target, 0);
        assertGt(nav.counter, 0);
        assertEq(creator.counter, nav.counter * 2);
        assertEq(protocol.counter, nav.counter * 2);

        uint256 creatorBefore = alice.balance;
        uint256 navBefore = vaultAddress.balance;
        uint256 protocolBefore = treasury.balance;
        vm.prank(bob);
        launchLiquidityVault.distributeFees(token);

        assertEq(alice.balance - creatorBefore, creator.counter);
        assertEq(vaultAddress.balance - navBefore, nav.counter);
        assertEq(treasury.balance - protocolBefore, protocol.counter);
        (creator, nav, protocol) = launchLiquidityVault.pendingFees(token);
        assertEq(creator.target + creator.counter, 0);
        assertEq(nav.target + nav.counter, 0);
        assertEq(protocol.target + protocol.counter, 0);
    }

    function testExistingVaultAndSharedLaunchVaultResolveTreasuryRotationTogether() public {
        (address token, address vaultAddress,) =
            _create(alice, _metadata(), keccak256("treasury getter rotation"), 0.1 ether);
        LpTokenVault existingVault = LpTokenVault(payable(vaultAddress));
        assertEq(existingVault.treasury(), treasury);
        assertEq(launchLiquidityVault.treasury(), treasury);

        address newTreasury = makeAddr("shared new treasury");
        vm.prank(treasury);
        factory.proposeTreasury(newTreasury);
        assertEq(existingVault.treasury(), treasury);
        assertEq(launchLiquidityVault.treasury(), treasury);

        vm.prank(newTreasury);
        factory.acceptTreasury();
        assertEq(existingVault.treasury(), newTreasury);
        assertEq(launchLiquidityVault.treasury(), newTreasury);

        (,, ILaunchFeeSource.FeeAmounts memory protocol) = launchLiquidityVault.pendingFees(token);
        uint256 oldTreasuryBefore = treasury.balance;
        uint256 newTreasuryBefore = newTreasury.balance;
        launchLiquidityVault.distributeFees(token);
        assertEq(treasury.balance, oldTreasuryBefore);
        assertEq(newTreasury.balance - newTreasuryBefore, protocol.counter);
    }

    function testLaunchTargetFeesSplitFortySixtyWithoutProtocolCut() public {
        (address token, address vaultAddress, uint256 targetOut) =
            _create(alice, _metadata(), keccak256("target fee split"), 0.1 ether);
        PoolKey memory key = launchpad.poolKey(token);
        launchLiquidityVault.distributeFees(token);

        uint256 targetIn = targetOut / 4;
        vm.prank(alice);
        IERC20(token).approve(address(swapRouter), targetIn);
        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -targetIn.toInt256(),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );

        (
            ILaunchFeeSource.FeeAmounts memory creator,
            ILaunchFeeSource.FeeAmounts memory nav,
            ILaunchFeeSource.FeeAmounts memory protocol
        ) = launchLiquidityVault.pendingFees(token);
        assertGt(creator.target, 0);
        assertEq(nav.target * 2, creator.target * 3);
        assertEq(protocol.target, 0);
        assertEq(creator.counter + nav.counter + protocol.counter, 0);

        uint256 creatorBefore = IERC20(token).balanceOf(alice);
        uint256 navBefore = IERC20(token).balanceOf(vaultAddress);
        uint256 protocolBefore = IERC20(token).balanceOf(treasury);
        vm.prank(bob);
        launchLiquidityVault.distributeFees(token);
        assertEq(IERC20(token).balanceOf(alice) - creatorBefore, creator.target);
        assertEq(IERC20(token).balanceOf(vaultAddress) - navBefore, nav.target);
        assertEq(IERC20(token).balanceOf(treasury), protocolBefore);
    }

    function testLaunchAllocationEventCarriesRemainderIntoCompleteBucket() public {
        (address token, address vaultAddress,) =
            _create(alice, _metadata(), keccak256("split remainder"), 0.1 ether);
        PoolKey memory key = launchpad.poolKey(token);

        vm.recordLogs();
        launchLiquidityVault.distributeFees(token);
        (uint8 targetRemainder, uint8 counterRemainder) =
            _lastAllocationRemainders(vm.getRecordedLogs(), token);

        while (counterRemainder < 4) {
            vm.deal(address(this), address(this).balance + 2);
            donateRouter.donate{ value: 2 }(key, 2, 0, bytes(""));
            vm.recordLogs();
            launchLiquidityVault.distributeFees(token);
            uint8 previousRemainder = counterRemainder;
            (targetRemainder, counterRemainder) =
                _lastAllocationRemainders(vm.getRecordedLogs(), token);
            assertEq(counterRemainder, previousRemainder + 1);
        }
        assertEq(counterRemainder, 4);

        uint256 creatorBefore = alice.balance;
        uint256 navBefore = vaultAddress.balance;
        uint256 protocolBefore = treasury.balance;
        vm.deal(address(this), address(this).balance + 2);
        donateRouter.donate{ value: 2 }(key, 2, 0, bytes(""));

        vm.expectEmit(true, true, true, true, address(launchLiquidityVault));
        emit LaunchFeesAllocated(
            token, vaultAddress, alice, 0, 5, 0, 2, 0, 1, 2, targetRemainder, 0
        );
        vm.expectEmit(true, true, true, true, address(launchLiquidityVault));
        emit LaunchFeePayout(
            token, alice, LaunchLiquidityVault.FeeRecipient.Creator, 0, 2, true, true
        );
        vm.expectEmit(true, true, true, true, address(launchLiquidityVault));
        emit LaunchFeePayout(
            token, treasury, LaunchLiquidityVault.FeeRecipient.Protocol, 0, 2, true, true
        );
        launchLiquidityVault.distributeFees(token);

        assertEq(alice.balance - creatorBefore, 2);
        assertEq(vaultAddress.balance - navBefore, 1);
        assertEq(treasury.balance - protocolBefore, 2);
    }

    function testLaunchSplitMathIsFrequencyIndependentForEveryRemainder() public {
        LaunchFeeMathHarness harness = new LaunchFeeMathHarness(manager);

        for (uint8 initialRemainder; initialRemainder < 5; ++initialRemainder) {
            (
                ILaunchFeeSource.FeeAmounts memory oneCreator,
                ILaunchFeeSource.FeeAmounts memory oneNav,
                ILaunchFeeSource.FeeAmounts memory oneProtocol,
                uint8 oneTargetRemainder,
                uint8 oneCounterRemainder
            ) = harness.previewAllocation(5, 5, initialRemainder, initialRemainder);

            ILaunchFeeSource.FeeAmounts memory fragmentedCreator;
            ILaunchFeeSource.FeeAmounts memory fragmentedNav;
            ILaunchFeeSource.FeeAmounts memory fragmentedProtocol;
            uint8 fragmentedTargetRemainder = initialRemainder;
            uint8 fragmentedCounterRemainder = initialRemainder;
            for (uint256 i; i < 5; ++i) {
                (
                    ILaunchFeeSource.FeeAmounts memory creator,
                    ILaunchFeeSource.FeeAmounts memory nav,
                    ILaunchFeeSource.FeeAmounts memory protocol,
                    uint8 nextTargetRemainder,
                    uint8 nextCounterRemainder
                ) = harness.previewAllocation(
                    1, 1, fragmentedTargetRemainder, fragmentedCounterRemainder
                );
                fragmentedCreator.target += creator.target;
                fragmentedCreator.counter += creator.counter;
                fragmentedNav.target += nav.target;
                fragmentedNav.counter += nav.counter;
                fragmentedProtocol.counter += protocol.counter;
                fragmentedTargetRemainder = nextTargetRemainder;
                fragmentedCounterRemainder = nextCounterRemainder;
            }

            assertEq(fragmentedCreator.target, oneCreator.target);
            assertEq(fragmentedCreator.counter, oneCreator.counter);
            assertEq(fragmentedNav.target, oneNav.target);
            assertEq(fragmentedNav.counter, oneNav.counter);
            assertEq(fragmentedProtocol.counter, oneProtocol.counter);
            assertEq(fragmentedTargetRemainder, oneTargetRemainder);
            assertEq(fragmentedCounterRemainder, oneCounterRemainder);
        }
    }

    function testCreatorCounterPayoutFailureDoesNotBlockNavOrProtocolAndRetries() public {
        LaunchFeeReceiver receiver = new LaunchFeeReceiver();
        uint256 value = launchpad.initialLpQuote() + 0.1 ether;
        vm.deal(address(this), value);
        (address token, address vaultAddress,) = receiver.createToken{ value: value }(
            launchpad, _metadata(), keccak256("rejecting creator")
        );
        receiver.setMode(LaunchFeeReceiver.Mode.Reject, launchLiquidityVault, token);

        (
            ILaunchFeeSource.FeeAmounts memory creator,
            ILaunchFeeSource.FeeAmounts memory nav,
            ILaunchFeeSource.FeeAmounts memory protocol
        ) = launchLiquidityVault.pendingFees(token);
        uint256 navBefore = vaultAddress.balance;
        uint256 protocolBefore = treasury.balance;
        vm.expectEmit(true, true, true, false, address(launchLiquidityVault));
        emit LaunchFeesAllocated(
            token,
            vaultAddress,
            address(receiver),
            creator.target + nav.target,
            creator.counter + nav.counter + protocol.counter,
            creator.target,
            creator.counter,
            nav.target,
            nav.counter,
            protocol.counter,
            0,
            0
        );
        vm.expectEmit(true, true, true, true, address(launchLiquidityVault));
        emit LaunchFeePayout(
            token, address(receiver), LaunchLiquidityVault.FeeRecipient.Creator, 0, 0, true, false
        );
        vm.expectEmit(true, true, true, true, address(launchLiquidityVault));
        emit LaunchFeePayout(
            token,
            treasury,
            LaunchLiquidityVault.FeeRecipient.Protocol,
            0,
            protocol.counter,
            true,
            true
        );
        launchLiquidityVault.distributeFees(token);
        assertEq(vaultAddress.balance - navBefore, nav.counter);
        assertEq(treasury.balance - protocolBefore, protocol.counter);
        assertEq(address(receiver).balance, 0);

        (creator, nav, protocol) = launchLiquidityVault.pendingFees(token);
        assertGt(creator.counter, 0);
        assertEq(nav.target + nav.counter + protocol.target + protocol.counter, 0);
        receiver.setMode(LaunchFeeReceiver.Mode.Accept, launchLiquidityVault, token);
        vm.expectEmit(true, true, true, true, address(launchLiquidityVault));
        emit LaunchFeePayout(
            token,
            address(receiver),
            LaunchLiquidityVault.FeeRecipient.Creator,
            0,
            creator.counter,
            true,
            true
        );
        launchLiquidityVault.distributeFees(token);
        assertEq(address(receiver).balance, creator.counter);
        (creator,,) = launchLiquidityVault.pendingFees(token);
        assertEq(creator.target + creator.counter, 0);
    }

    function testGasBurningCreatorCannotGriefDistributionAndCanRetry() public {
        LaunchFeeReceiver receiver = new LaunchFeeReceiver();
        uint256 value = launchpad.initialLpQuote() + 0.1 ether;
        vm.deal(address(this), value);
        (address token, address vaultAddress,) = receiver.createToken{ value: value }(
            launchpad, _metadata(), keccak256("gas burning creator")
        );
        receiver.setMode(LaunchFeeReceiver.Mode.BurnGas, launchLiquidityVault, token);

        (
            ILaunchFeeSource.FeeAmounts memory creator,
            ILaunchFeeSource.FeeAmounts memory nav,
            ILaunchFeeSource.FeeAmounts memory protocol
        ) = launchLiquidityVault.pendingFees(token);
        vm.expectEmit(true, true, true, false, address(launchLiquidityVault));
        emit LaunchFeesAllocated(token, vaultAddress, address(receiver), 0, 0, 0, 0, 0, 0, 0, 0, 0);
        vm.expectEmit(true, true, true, true, address(launchLiquidityVault));
        emit LaunchFeePayout(
            token, address(receiver), LaunchLiquidityVault.FeeRecipient.Creator, 0, 0, true, false
        );
        vm.expectEmit(true, true, true, true, address(launchLiquidityVault));
        emit LaunchFeePayout(
            token,
            treasury,
            LaunchLiquidityVault.FeeRecipient.Protocol,
            0,
            protocol.counter,
            true,
            true
        );
        launchLiquidityVault.distributeFees(token);
        (creator, nav, protocol) = launchLiquidityVault.pendingFees(token);
        assertGt(creator.counter, 0);
        assertEq(nav.target + nav.counter + protocol.target + protocol.counter, 0);

        // Vault synchronization retries the failed payout, but the bounded callback gas
        // keeps an untrusted creator from blocking an otherwise valid public mint.
        LpTokenVault vault = LpTokenVault(payable(vaultAddress));
        uint256 maxTarget = IERC20(token).balanceOf(address(receiver)) / 10;
        (, uint256 targetUsed, uint256 counterUsed) = vault.previewMintPair(maxTarget, 0.01 ether);
        assertGt(targetUsed, 0);
        assertGt(counterUsed, 0);
        vm.prank(address(receiver));
        IERC20(token).approve(vaultAddress, targetUsed);
        vm.deal(address(receiver), counterUsed);
        vm.prank(address(receiver));
        (uint256 mintedShares,,) = vault.mintPair{ value: counterUsed }(
            targetUsed, counterUsed, 0, address(receiver), block.timestamp
        );
        assertGt(mintedShares, 0);
        (creator,,) = launchLiquidityVault.pendingFees(token);
        assertGt(creator.counter, 0);

        receiver.setMode(LaunchFeeReceiver.Mode.Accept, launchLiquidityVault, token);
        vm.expectEmit(true, true, true, true, address(launchLiquidityVault));
        emit LaunchFeePayout(
            token,
            address(receiver),
            LaunchLiquidityVault.FeeRecipient.Creator,
            0,
            creator.counter,
            true,
            true
        );
        launchLiquidityVault.distributeFees(token);
        assertEq(address(receiver).balance, creator.counter);
    }

    function testCreatorTargetPayoutFailureDoesNotBlockNavAndRetries() public {
        (address token, address vaultAddress, uint256 targetOut) =
            _create(alice, _metadata(), keccak256("rejecting target payout"), 0.1 ether);
        PoolKey memory key = launchpad.poolKey(token);
        launchLiquidityVault.distributeFees(token);

        uint256 targetIn = targetOut / 4;
        vm.prank(alice);
        IERC20(token).approve(address(swapRouter), targetIn);
        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -targetIn.toInt256(),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );

        (ILaunchFeeSource.FeeAmounts memory creator, ILaunchFeeSource.FeeAmounts memory nav,) =
            launchLiquidityVault.pendingFees(token);
        assertGt(creator.target, 0);
        assertEq(creator.counter + nav.counter, 0);
        uint256 creatorBefore = IERC20(token).balanceOf(alice);
        uint256 navBefore = IERC20(token).balanceOf(vaultAddress);
        vm.mockCallRevert(
            token,
            abi.encodeCall(IERC20.transfer, (alice, creator.target)),
            abi.encodeWithSignature("Error(string)", "reject")
        );
        vm.expectEmit(true, true, true, false, address(launchLiquidityVault));
        emit LaunchFeesAllocated(token, vaultAddress, alice, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        vm.expectEmit(true, true, true, true, address(launchLiquidityVault));
        emit LaunchFeePayout(
            token, alice, LaunchLiquidityVault.FeeRecipient.Creator, 0, 0, false, true
        );
        launchLiquidityVault.distributeFees(token);
        vm.clearMockedCalls();

        assertEq(IERC20(token).balanceOf(alice), creatorBefore);
        assertEq(IERC20(token).balanceOf(vaultAddress) - navBefore, nav.target);
        (creator, nav,) = launchLiquidityVault.pendingFees(token);
        assertGt(creator.target, 0);
        assertEq(nav.target + nav.counter, 0);

        vm.expectEmit(true, true, true, true, address(launchLiquidityVault));
        emit LaunchFeePayout(
            token, alice, LaunchLiquidityVault.FeeRecipient.Creator, creator.target, 0, true, true
        );
        launchLiquidityVault.distributeFees(token);
        assertEq(IERC20(token).balanceOf(alice) - creatorBefore, creator.target);
        (creator,,) = launchLiquidityVault.pendingFees(token);
        assertEq(creator.target + creator.counter, 0);
    }

    function testReentrantCreatorCannotReenterDistribution() public {
        LaunchFeeReceiver receiver = new LaunchFeeReceiver();
        uint256 value = launchpad.initialLpQuote() + 0.1 ether;
        vm.deal(address(this), value);
        (address token,,) = receiver.createToken{ value: value }(
            launchpad, _metadata(), keccak256("reentrant creator")
        );
        receiver.setMode(LaunchFeeReceiver.Mode.Reenter, launchLiquidityVault, token);
        (ILaunchFeeSource.FeeAmounts memory creator,,) = launchLiquidityVault.pendingFees(token);

        launchLiquidityVault.distributeFees(token);
        assertEq(address(receiver).balance, creator.counter);
        assertFalse(receiver.reentrySucceeded());
        (creator,,) = launchLiquidityVault.pendingFees(token);
        assertEq(creator.target + creator.counter, 0);
    }

    function testProtocolPayoutFailureDoesNotBlockCreatorOrNavAndRetries() public {
        LaunchFeeReceiver protocolReceiver = new LaunchFeeReceiver();
        LpTokenFactory localFactory = new LpTokenFactory(manager, address(protocolReceiver), owner);
        TokenLaunchpad localLaunchpad =
            _deployLaunchpad(manager, localFactory, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE);
        vm.prank(owner);
        localFactory.bindLaunchpad(address(localLaunchpad));

        uint256 value = localLaunchpad.initialLpQuote() + 0.1 ether;
        vm.deal(alice, value);
        vm.prank(alice);
        (address token, address vaultAddress,) = localLaunchpad.createToken{ value: value }(
            _metadata(),
            keccak256("rejecting protocol"),
            0,
            TickMath.MIN_SQRT_PRICE + 1,
            LAUNCH_START_TICK,
            LAUNCH_INITIAL_LP_QUOTE,
            block.timestamp
        );
        LaunchLiquidityVault localLiquidityVault = localLaunchpad.liquidityVault();
        protocolReceiver.setMode(LaunchFeeReceiver.Mode.Reject, localLiquidityVault, token);

        (
            ILaunchFeeSource.FeeAmounts memory creator,
            ILaunchFeeSource.FeeAmounts memory nav,
            ILaunchFeeSource.FeeAmounts memory protocol
        ) = localLiquidityVault.pendingFees(token);
        assertEq(creator.target + nav.target + protocol.target, 0);
        assertGt(creator.counter, 0);
        assertGt(protocol.counter, 0);
        uint256 creatorBefore = alice.balance;
        uint256 navBefore = vaultAddress.balance;
        vm.expectEmit(true, true, true, false, address(localLiquidityVault));
        emit LaunchFeesAllocated(token, vaultAddress, alice, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        vm.expectEmit(true, true, true, true, address(localLiquidityVault));
        emit LaunchFeePayout(
            token, alice, LaunchLiquidityVault.FeeRecipient.Creator, 0, creator.counter, true, true
        );
        vm.expectEmit(true, true, true, true, address(localLiquidityVault));
        emit LaunchFeePayout(
            token,
            address(protocolReceiver),
            LaunchLiquidityVault.FeeRecipient.Protocol,
            0,
            0,
            true,
            false
        );
        localLiquidityVault.distributeFees(token);
        assertEq(alice.balance - creatorBefore, creator.counter);
        assertEq(vaultAddress.balance - navBefore, nav.counter);
        assertEq(address(protocolReceiver).balance, 0);

        (creator, nav, protocol) = localLiquidityVault.pendingFees(token);
        assertEq(creator.target + creator.counter + nav.target + nav.counter, 0);
        assertGt(protocol.counter, 0);

        address newTreasury = makeAddr("rotated protocol receiver");
        vm.prank(address(protocolReceiver));
        localFactory.proposeTreasury(newTreasury);
        assertEq(localLiquidityVault.treasury(), address(protocolReceiver));
        vm.prank(newTreasury);
        localFactory.acceptTreasury();
        assertEq(localLiquidityVault.treasury(), newTreasury);

        vm.expectEmit(true, true, true, true, address(localLiquidityVault));
        emit LaunchFeePayout(
            token,
            newTreasury,
            LaunchLiquidityVault.FeeRecipient.Protocol,
            0,
            protocol.counter,
            true,
            true
        );
        localLiquidityVault.distributeFees(token);
        assertEq(address(protocolReceiver).balance, 0);
        assertEq(newTreasury.balance, protocol.counter);
    }

    function testNavTransferFailureRevertsCollectionAtomically() public {
        (address token, address vaultAddress,) =
            _create(alice, _metadata(), keccak256("atomic nav"), 0.1 ether);
        (, ILaunchFeeSource.FeeAmounts memory navBefore,) = launchLiquidityVault.pendingFees(token);
        assertGt(navBefore.counter, 0);

        vm.mockCallRevert(
            vaultAddress, bytes(""), abi.encodeWithSignature("Error(string)", "reject")
        );
        vm.expectRevert();
        launchLiquidityVault.distributeFees(token);
        vm.clearMockedCalls();

        (, ILaunchFeeSource.FeeAmounts memory navAfter,) = launchLiquidityVault.pendingFees(token);
        assertEq(navAfter.target, navBefore.target);
        assertEq(navAfter.counter, navBefore.counter);
        assertEq(vaultAddress.balance, 0);
    }

    function testLaunchRejectsExpiredDeadlineAtomically() public {
        vm.warp(10);
        TokenLaunchpad.TokenMetadata memory metadata = _metadata();
        bytes32 salt = keccak256("expired deadline");
        address predicted = launchpad.predictTokenAddress(alice, metadata, salt);
        uint256 value = launchpad.initialLpQuote();

        vm.deal(alice, value);
        vm.prank(alice);
        vm.expectRevert(TokenLaunchpad.DeadlineExpired.selector);
        launchpad.createToken{ value: value }(
            metadata, salt, 0, 0, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE, block.timestamp - 1
        );

        _assertLaunchRolledBack(predicted, value);
    }

    function testLaunchRejectsMinimumInitialBuyOutputAtomically() public {
        TokenLaunchpad.TokenMetadata memory metadata = _metadata();
        bytes32 salt = keccak256("minimum initial buy output");
        address predicted = launchpad.predictTokenAddress(alice, metadata, salt);
        uint256 value = launchpad.initialLpQuote() + 0.1 ether;

        vm.deal(alice, value);
        vm.prank(alice);
        vm.expectPartialRevert(TokenLaunchpad.InsufficientInitialBuyOutput.selector);
        launchpad.createToken{ value: value }(
            metadata,
            salt,
            type(uint256).max,
            TickMath.MIN_SQRT_PRICE + 1,
            LAUNCH_START_TICK,
            LAUNCH_INITIAL_LP_QUOTE,
            block.timestamp
        );

        _assertLaunchRolledBack(predicted, value);
    }

    function testInitialBuyHonorsPriceLimitAndRefundsPartialFill() public {
        uint256 initialBuy = 0.1 ether;
        uint160 priceLimit = TickMath.getSqrtPriceAtTick(launchpad.startTick() - 200);
        uint256 value = launchpad.initialLpQuote() + initialBuy;
        TokenLaunchpad.TokenMetadata memory metadata = _metadata();
        bytes32 salt = keccak256("partial initial buy");

        vm.deal(alice, value);
        vm.prank(alice);
        (address token,, uint256 targetOut) = launchpad.createToken{ value: value }(
            metadata,
            salt,
            0,
            priceLimit,
            LAUNCH_START_TICK,
            LAUNCH_INITIAL_LP_QUOTE,
            block.timestamp
        );

        assertGt(targetOut, 0);
        assertGt(alice.balance, 0);
        assertLt(alice.balance, initialBuy);
        assertEq(IERC20(token).balanceOf(alice), targetOut);
        assertEq(address(launchpad).balance, 0);
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(launchpad.poolKey(token).toId());
        assertEq(sqrtPriceX96, priceLimit);
    }

    function testLaunchRejectsInvalidInitialBuyPriceLimitAtomically() public {
        TokenLaunchpad.TokenMetadata memory metadata = _metadata();
        bytes32 salt = keccak256("invalid initial buy limit");
        address predicted = launchpad.predictTokenAddress(alice, metadata, salt);
        uint256 value = launchpad.initialLpQuote() + 0.1 ether;
        uint160 invalidPriceLimit = launchpad.initialSqrtPriceX96();

        vm.deal(alice, value);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Pool.PriceLimitAlreadyExceeded.selector, invalidPriceLimit, invalidPriceLimit
            )
        );
        launchpad.createToken{ value: value }(
            metadata,
            salt,
            0,
            invalidPriceLimit,
            LAUNCH_START_TICK,
            LAUNCH_INITIAL_LP_QUOTE,
            block.timestamp
        );

        _assertLaunchRolledBack(predicted, value);
    }

    function testCreatorCanUpdateValidatedMetadata() public {
        (address token,,) = _create(alice, _metadata(), keccak256("metadata"), 0);
        LaunchToken launchToken = LaunchToken(token);

        vm.prank(alice);
        launchToken.updateMetadata(
            "ipfs://new-image", "https://example.com/new", "new_handle", "new_chat"
        );
        assertEq(launchToken.imageUrl(), "ipfs://new-image");
        assertEq(launchToken.twitterHandle(), "new_handle");

        vm.prank(bob);
        vm.expectRevert(LaunchToken.OnlyCreator.selector);
        launchToken.updateMetadata("", "", "", "");
    }

    function testLaunchCallbacksRejectUnauthorizedCallers() public {
        PoolKey memory key = launchpad.poolKey(address(cashcat));
        vm.expectRevert(TokenLaunchpad.OnlySelfInitialization.selector);
        launchpad.beforeInitialize(address(this), key, 0);

        vm.expectRevert(TokenLaunchpad.OnlyPoolManager.selector);
        launchpad.unlockCallback(bytes(""));

        vm.expectRevert(LaunchLiquidityVault.OnlyPoolManager.selector);
        launchLiquidityVault.unlockCallback(bytes(""));

        vm.deal(address(this), 1);
        (bool success, bytes memory returnData) =
            address(launchLiquidityVault).call{ value: 1 }(bytes(""));
        assertFalse(success);
        assertEq(returnData, abi.encodeWithSelector(LaunchLiquidityVault.OnlyPoolManager.selector));
    }

    function testLaunchLiquidityVaultRejectsUnauthorizedPositionCalls() public {
        vm.prank(bob);
        vm.expectRevert(LaunchLiquidityVault.OnlyLaunchpad.selector);
        launchLiquidityVault.addPosition(address(cashcat), alice, bob, 1);
    }

    function testLaunchLiquidityVaultRejectsInvalidPositionInputs() public {
        vm.prank(address(launchpad));
        vm.expectRevert(LaunchLiquidityVault.InvalidAddress.selector);
        launchLiquidityVault.addPosition(address(0), alice, bob, 1);

        vm.prank(address(launchpad));
        vm.expectRevert(LaunchLiquidityVault.InvalidAddress.selector);
        launchLiquidityVault.addPosition(address(cashcat), address(0), bob, 1);

        vm.prank(address(launchpad));
        vm.expectRevert(LaunchLiquidityVault.InvalidAddress.selector);
        launchLiquidityVault.addPosition(address(cashcat), alice, address(0), 1);

        vm.prank(address(launchpad));
        vm.expectRevert(
            abi.encodeWithSelector(LaunchLiquidityVault.InvalidInitialBalance.selector, 0, 1)
        );
        launchLiquidityVault.addPosition(address(cashcat), alice, bob, 1);

        vm.prank(address(launchpad));
        vm.expectRevert(LaunchLiquidityVault.ZeroLiquidity.selector);
        launchLiquidityVault.addPosition(address(cashcat), alice, bob, 0);

        vm.expectRevert(LaunchLiquidityVault.PositionNotFound.selector);
        launchLiquidityVault.distributeFees(address(cashcat));

        vm.prank(address(manager));
        vm.expectRevert(LaunchLiquidityVault.PositionNotFound.selector);
        launchLiquidityVault.unlockCallback(abi.encode(uint8(0), address(cashcat)));

        (address token,,) = _create(alice, _metadata(), keccak256("duplicate position"), 0);
        vm.prank(address(launchpad));
        vm.expectRevert(LaunchLiquidityVault.AlreadyRegistered.selector);
        launchLiquidityVault.addPosition(token, alice, bob, 0);
    }

    function testLaunchContractsRejectInvalidConstructorDependencies() public {
        vm.expectRevert(TokenLaunchpad.InvalidAddress.selector);
        _deployLaunchpad(
            IPoolManager(address(0)), factory, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE
        );

        vm.expectRevert(TokenLaunchpad.InvalidAddress.selector);
        _deployLaunchpad(
            manager, LpTokenFactory(address(0)), LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE
        );

        vm.expectRevert(TokenLaunchpad.InvalidAddress.selector);
        _deployLaunchpad(IPoolManager(bob), factory, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE);

        vm.expectRevert(TokenLaunchpad.InvalidAddress.selector);
        _deployLaunchpad(manager, LpTokenFactory(bob), LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE);

        LpTokenFactory mismatchedFactory =
            new LpTokenFactory(IPoolManager(address(liquidityRouter)), treasury, owner);
        vm.expectRevert(TokenLaunchpad.InvalidAddress.selector);
        _deployLaunchpad(manager, mismatchedFactory, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE);

        vm.expectRevert(LaunchLiquidityVault.InvalidAddress.selector);
        new LaunchLiquidityVault(IPoolManager(address(0)), address(this), address(factory));

        vm.expectRevert(LaunchLiquidityVault.InvalidAddress.selector);
        new LaunchLiquidityVault(manager, address(0), address(factory));

        vm.expectRevert(LaunchLiquidityVault.InvalidAddress.selector);
        new LaunchLiquidityVault(manager, address(this), address(0));
    }

    function testFactoryLaunchFromLaunchpadRequiresBoundRegisteredCaller() public {
        uint256 bootstrapTarget = launchpad.bootstrapTargetAmount();

        vm.prank(bob);
        vm.expectRevert(LpTokenFactory.OnlyLaunchpad.selector);
        factory.launchFromLaunchpad(address(cashcat), bootstrapTarget);

        vm.prank(address(launchpad));
        vm.expectRevert(
            abi.encodeWithSelector(
                LpTokenFactory.UnregisteredLaunchToken.selector, address(cashcat)
            )
        );
        factory.launchFromLaunchpad(address(cashcat), bootstrapTarget);
    }

    function testFactoryLaunchFromLaunchpadRejectsInvalidDerivedPoolTerms() public {
        address target = address(cashcat);
        uint256 bootstrapTarget = launchpad.bootstrapTargetAmount();
        PoolKey memory key = launchpad.poolKey(target);

        PoolKey memory invalidKey = key;
        invalidKey.currency0 = Currency.wrap(address(usdg));
        _expectInvalidDerivedLaunch(target, invalidKey, bootstrapTarget);

        invalidKey = key;
        invalidKey.currency1 = Currency.wrap(address(usdg));
        _expectInvalidDerivedLaunch(target, invalidKey, bootstrapTarget);

        invalidKey = key;
        invalidKey.hooks = IHooks(bob);
        _expectInvalidDerivedLaunch(target, invalidKey, bootstrapTarget);

        invalidKey = key;
        invalidKey.fee = launchpad.LP_FEE() + 1;
        _expectInvalidDerivedLaunch(target, invalidKey, bootstrapTarget);

        invalidKey = key;
        invalidKey.tickSpacing = launchpad.TICK_SPACING() + 1;
        _expectInvalidDerivedLaunch(target, invalidKey, bootstrapTarget);

        _expectInvalidDerivedLaunch(target, key, bootstrapTarget + 1);
    }

    function testFactoryLaunchFromLaunchpadRejectsInvalidValueTickAndFeeSource() public {
        address target = address(cashcat);
        uint256 bootstrapTarget = launchpad.bootstrapTargetAmount();
        uint256 bootstrapQuote = launchpad.initialLpQuote();
        PoolKey memory key = launchpad.poolKey(target);

        _mockRegisteredLaunchTarget(target, key);
        vm.prank(address(launchpad));
        vm.expectRevert(
            abi.encodeWithSelector(LpTokenFactory.InvalidMsgValue.selector, 0, bootstrapQuote)
        );
        factory.launchFromLaunchpad(target, bootstrapTarget);
        vm.clearMockedCalls();

        uint160 wrongSqrtPrice =
            TickMath.getSqrtPriceAtTick(launchpad.startTick() - launchpad.TICK_SPACING());
        vm.prank(address(launchpad));
        manager.initialize(key, wrongSqrtPrice);
        _mockRegisteredLaunchTarget(target, key);
        vm.deal(address(launchpad), bootstrapQuote);
        vm.prank(address(launchpad));
        vm.expectRevert(LpTokenFactory.InvalidLaunchpadPool.selector);
        factory.launchFromLaunchpad{ value: bootstrapQuote }(target, bootstrapTarget);
        vm.clearMockedCalls();

        target = address(usdg);
        key = launchpad.poolKey(target);
        uint160 initialSqrtPriceX96 = launchpad.initialSqrtPriceX96();
        vm.prank(address(launchpad));
        manager.initialize(key, initialSqrtPriceX96);
        _mockRegisteredLaunchTarget(target, key);
        vm.mockCall(
            address(launchpad),
            abi.encodeWithSelector(bytes4(keccak256("liquidityVault()"))),
            abi.encode(address(0))
        );
        vm.deal(address(launchpad), bootstrapQuote);
        vm.prank(address(launchpad));
        vm.expectRevert(LpTokenFactory.InvalidAddress.selector);
        factory.launchFromLaunchpad{ value: bootstrapQuote }(target, bootstrapTarget);
        vm.clearMockedCalls();
    }

    function testOnlyOwnerCanBindLaunchpadAndBindingIsPermanent() public {
        LpTokenFactory freshFactory = new LpTokenFactory(manager, treasury, owner);
        TokenLaunchpad freshLaunchpad =
            _deployLaunchpad(manager, freshFactory, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE);

        vm.prank(bob);
        vm.expectRevert();
        freshFactory.bindLaunchpad(address(freshLaunchpad));

        vm.prank(owner);
        freshFactory.bindLaunchpad(address(freshLaunchpad));
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                LpTokenFactory.LaunchpadAlreadyBound.selector, address(freshLaunchpad)
            )
        );
        freshFactory.bindLaunchpad(address(freshLaunchpad));
    }

    function testBindingRejectsLaunchpadFromAnotherFactory() public {
        LpTokenFactory freshFactory = new LpTokenFactory(manager, treasury, owner);

        vm.prank(owner);
        vm.expectRevert(LpTokenFactory.InvalidAddress.selector);
        freshFactory.bindLaunchpad(address(launchpad));
    }

    function testBindingRejectsMismatchedLaunchFeeSource() public {
        LpTokenFactory freshFactory = new LpTokenFactory(manager, treasury, owner);
        TokenLaunchpad freshLaunchpad =
            _deployLaunchpad(manager, freshFactory, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE);
        vm.mockCall(
            address(freshLaunchpad),
            abi.encodeWithSelector(bytes4(keccak256("liquidityVault()"))),
            abi.encode(address(launchLiquidityVault))
        );

        vm.prank(owner);
        vm.expectRevert(LpTokenFactory.InvalidAddress.selector);
        freshFactory.bindLaunchpad(address(freshLaunchpad));
    }

    function testBindingRejectsLaunchFeeSourceFromAnotherFactory() public {
        LpTokenFactory freshFactory = new LpTokenFactory(manager, treasury, owner);
        TokenLaunchpad freshLaunchpad =
            _deployLaunchpad(manager, freshFactory, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE);
        LpTokenFactory otherFactory = new LpTokenFactory(manager, treasury, owner);
        LaunchLiquidityVault mismatchedSource =
            new LaunchLiquidityVault(manager, address(freshLaunchpad), address(otherFactory));
        vm.mockCall(
            address(freshLaunchpad),
            abi.encodeWithSelector(bytes4(keccak256("liquidityVault()"))),
            abi.encode(address(mismatchedSource))
        );

        vm.prank(owner);
        vm.expectRevert(LpTokenFactory.InvalidAddress.selector);
        freshFactory.bindLaunchpad(address(freshLaunchpad));
    }

    function testLaunchRejectsInsufficientBootstrapValueAtomically() public {
        TokenLaunchpad.TokenMetadata memory metadata = _metadata();
        bytes32 salt = keccak256("insufficient value");
        address predicted = launchpad.predictTokenAddress(alice, metadata, salt);
        uint256 bootstrapQuote = launchpad.initialLpQuote();
        vm.deal(alice, bootstrapQuote);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenLaunchpad.InvalidMsgValue.selector, bootstrapQuote - 1, bootstrapQuote
            )
        );
        launchpad.createToken{ value: bootstrapQuote - 1 }(
            metadata, salt, 0, 0, LAUNCH_START_TICK, bootstrapQuote, block.timestamp
        );
        assertEq(predicted.code.length, 0);
        assertFalse(launchpad.isToken(predicted));
    }

    function testLaunchRejectsInvalidTokenNameAndSymbolLengths() public {
        TokenLaunchpad.TokenMetadata memory metadata = _metadata();
        metadata.name = "A";
        _expectCreateRevert(
            metadata, keccak256("short name"), LaunchToken.InvalidTokenName.selector
        );

        metadata = _metadata();
        metadata.name = "1234567890123456789012345678901234567890123456789";
        _expectCreateRevert(metadata, keccak256("long name"), LaunchToken.InvalidTokenName.selector);

        metadata = _metadata();
        metadata.symbol = "A";
        _expectCreateRevert(
            metadata, keccak256("short symbol"), LaunchToken.InvalidTokenSymbol.selector
        );

        metadata = _metadata();
        metadata.symbol = "ABCDEFGHIJK";
        _expectCreateRevert(
            metadata, keccak256("long symbol"), LaunchToken.InvalidTokenSymbol.selector
        );
    }

    function testMetadataUrlAndHandleLengthBoundaries() public {
        string memory maximumImageUrl = _repeatedAscii(2_048, "i");
        string memory maximumWebsiteUrl = _repeatedAscii(2_048, "w");
        string memory maximumTwitterHandle = _repeatedAscii(15, "t");
        string memory maximumTelegramHandle = _repeatedAscii(32, "g");
        LaunchToken boundaryToken = new LaunchToken(
            "Boundary Token",
            "BOUND",
            maximumImageUrl,
            maximumWebsiteUrl,
            maximumTwitterHandle,
            maximumTelegramHandle,
            alice,
            address(this)
        );

        assertEq(bytes(boundaryToken.imageUrl()).length, 2_048);
        assertEq(bytes(boundaryToken.websiteUrl()).length, 2_048);
        assertEq(bytes(boundaryToken.twitterHandle()).length, 15);
        assertEq(bytes(boundaryToken.telegramHandle()).length, 32);

        vm.expectRevert(LaunchToken.MetadataUrlTooLong.selector);
        _deployMetadataToken(_repeatedAscii(2_049, "i"), "", "", "");

        vm.expectRevert(LaunchToken.MetadataUrlTooLong.selector);
        _deployMetadataToken("", _repeatedAscii(2_049, "w"), "", "");

        vm.expectRevert(LaunchToken.InvalidTwitterHandle.selector);
        _deployMetadataToken("", "", _repeatedAscii(16, "t"), "");

        vm.expectRevert(LaunchToken.InvalidTelegramHandle.selector);
        _deployMetadataToken("", "", "", _repeatedAscii(33, "g"));
    }

    function testMetadataHandleCharacterValidation() public {
        LaunchToken validToken = _deployMetadataToken("", "", "valid_123", "valid_chat_456");
        assertEq(validToken.twitterHandle(), "valid_123");
        assertEq(validToken.telegramHandle(), "valid_chat_456");

        vm.expectRevert(LaunchToken.InvalidTwitterHandle.selector);
        _deployMetadataToken("", "", "Uppercase", "");

        vm.expectRevert(LaunchToken.InvalidTwitterHandle.selector);
        _deployMetadataToken("", "", "punctuation!", "");

        vm.expectRevert(LaunchToken.InvalidTwitterHandle.selector);
        _deployMetadataToken("", "", unicode"nonasciié", "");

        vm.expectRevert(LaunchToken.InvalidTelegramHandle.selector);
        _deployMetadataToken("", "", "", "Invalid-Chat");
    }

    function testLaunchTokenConstructorRejectsZeroCreatorOrInitialHolder() public {
        vm.expectRevert(LaunchToken.InvalidAddress.selector);
        _deployMetadataTokenWithOwners(address(0), address(this));

        vm.expectRevert(LaunchToken.InvalidAddress.selector);
        _deployMetadataTokenWithOwners(alice, address(0));
    }

    function _create(
        address creator,
        TokenLaunchpad.TokenMetadata memory metadata,
        bytes32 salt,
        uint256 initialBuy
    ) private returns (address token, address vault, uint256 targetOut) {
        uint256 value = launchpad.initialLpQuote() + initialBuy;
        vm.deal(creator, value);
        vm.prank(creator);
        return launchpad.createToken{ value: value }(
            metadata,
            salt,
            0,
            TickMath.MIN_SQRT_PRICE + 1,
            LAUNCH_START_TICK,
            LAUNCH_INITIAL_LP_QUOTE,
            block.timestamp
        );
    }

    function _expectCreateRevert(
        TokenLaunchpad.TokenMetadata memory metadata,
        bytes32 salt,
        bytes4 selector
    ) private {
        uint256 value = launchpad.initialLpQuote();
        vm.deal(alice, value);
        vm.prank(alice);
        vm.expectRevert(selector);
        launchpad.createToken{ value: value }(
            metadata, salt, 0, 0, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE, block.timestamp
        );
    }

    function _expectInvalidDerivedLaunch(
        address target,
        PoolKey memory key,
        uint256 bootstrapTarget
    ) private {
        _mockRegisteredLaunchTarget(target, key);
        vm.prank(address(launchpad));
        vm.expectRevert(LpTokenFactory.InvalidLaunchpadPool.selector);
        factory.launchFromLaunchpad(target, bootstrapTarget);
        vm.clearMockedCalls();
    }

    function _mockRegisteredLaunchTarget(address target, PoolKey memory key) private {
        vm.mockCall(
            address(launchpad),
            abi.encodeWithSelector(TokenLaunchpad.isToken.selector, target),
            abi.encode(true)
        );
        vm.mockCall(
            address(launchpad),
            abi.encodeWithSelector(TokenLaunchpad.poolKey.selector, target),
            abi.encode(key)
        );
    }

    function _assertLaunchRolledBack(address predictedToken, uint256 creatorBalance) private view {
        assertEq(predictedToken.code.length, 0);
        assertFalse(launchpad.isToken(predictedToken));
        assertEq(factory.vaultOfPoolId(launchpad.poolKey(predictedToken).toId()), address(0));
        assertEq(launchpad.getTokenCount(), 0);
        assertEq(alice.balance, creatorBalance);
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(launchpad.poolKey(predictedToken).toId());
        assertEq(sqrtPriceX96, 0);
    }

    function _deployMetadataToken(
        string memory imageUrl,
        string memory websiteUrl,
        string memory twitterHandle,
        string memory telegramHandle
    ) private returns (LaunchToken token) {
        token = new LaunchToken(
            "Metadata Token",
            "META",
            imageUrl,
            websiteUrl,
            twitterHandle,
            telegramHandle,
            alice,
            address(this)
        );
    }

    function _deployMetadataTokenWithOwners(address creator, address initialHolder)
        private
        returns (LaunchToken token)
    {
        token = new LaunchToken("Metadata Token", "META", "", "", "", "", creator, initialHolder);
    }

    function _lastAllocationRemainders(Vm.Log[] memory logs, address token)
        private
        returns (uint8 targetRemainder, uint8 counterRemainder)
    {
        bytes32 signature = keccak256(
            "LaunchFeesAllocated(address,address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint8,uint8)"
        );
        bytes32 indexedToken = bytes32(uint256(uint160(token)));
        for (uint256 i = logs.length; i > 0; --i) {
            Vm.Log memory entry = logs[i - 1];
            if (
                entry.emitter == address(launchLiquidityVault) && entry.topics.length == 4
                    && entry.topics[0] == signature && entry.topics[1] == indexedToken
            ) {
                (,,,,,,, targetRemainder, counterRemainder) = abi.decode(
                    entry.data,
                    (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint8, uint8)
                );
                return (targetRemainder, counterRemainder);
            }
        }
        fail();
    }

    function _repeatedAscii(uint256 length, bytes1 character)
        private
        pure
        returns (string memory result)
    {
        bytes memory value = new bytes(length);
        for (uint256 i; i < length; ++i) {
            value[i] = character;
        }
        result = string(value);
    }

    function _metadata() private pure returns (TokenLaunchpad.TokenMetadata memory metadata) {
        metadata = TokenLaunchpad.TokenMetadata({
            name: "Launch Cat",
            symbol: "LCAT",
            imageUrl: "ipfs://launch-cat",
            websiteUrl: "https://example.com",
            twitterHandle: "launch_cat",
            telegramHandle: "launch_cat_chat"
        });
    }
}
