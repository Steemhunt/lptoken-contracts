// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IProtocolFees } from "@uniswap/v4-core/src/interfaces/IProtocolFees.sol";
import { ProtocolFeeLibrary } from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { LpTokenVault } from "../src/LpTokenVault.sol";
import { TokenLaunchpad } from "../src/TokenLaunchpad.sol";
import { ILaunchFeeSource } from "../src/interfaces/ILaunchFeeSource.sol";
import { LpTokenLens } from "../src/periphery/LpTokenLens.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { LpTokenTestBase } from "./utils/LpTokenTestBase.sol";

contract LpTokenLensTest is LpTokenTestBase {
    using ProtocolFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    LpTokenLens internal lens;
    LpTokenVault internal vault;
    PoolKey internal key;

    function setUp() public override {
        super.setUp();
        vm.warp(1 days);
        lens = new LpTokenLens();
        key = _erc20Key(address(cashcat), address(usdg));
        _initLivePool(key, 0);
        vault = _launch(address(cashcat), key, 1_000e18, 1_000e6);
    }

    function testSnapshotMatchesEveryUnderlyingValue() public {
        IProtocolFees(address(manager)).setProtocolFeeController(address(this));
        uint24 packedProtocolFee = (uint24(500) << 12) | uint24(700);
        IProtocolFees(address(manager)).setProtocolFee(key, packedProtocolFee);

        _swap(key, makeAddr("zero-for-one trader"), true, 100e18);
        _swap(key, makeAddr("one-for-zero trader"), false, 100e6);

        LpTokenLens.VaultSnapshot memory value = lens.snapshot(vault);
        PoolKey memory actualKey = vault.poolKey();
        PoolId id = actualKey.toId();
        (uint160 sqrtPriceX96, int24 poolTick, uint24 protocolFee,) = manager.getSlot0(id);
        (uint256 principalTarget, uint256 principalCounter) = vault.positionPrincipal();
        (uint256 pendingTarget, uint256 pendingCounter) = vault.pendingFees();
        (uint256 pendingLaunchTarget, uint256 pendingLaunchCounter) = vault.pendingLaunchFees();
        (uint256 idleTarget, uint256 idleCounter) = vault.idleBalances();
        (uint256 totalTarget, uint256 totalCounter) = vault.totalAssets();

        assertEq(value.vault, address(vault));
        assertEq(value.target, vault.target());
        assertEq(value.counter, Currency.unwrap(vault.counter()));
        assertEq(value.treasury, vault.treasury());
        assertEq(value.launchFeeSource, vault.launchFeeSource());
        assertEq(value.counterIsNative, vault.counterIsNative());
        assertEq(value.targetIsCurrency0, vault.targetIsCurrency0());
        assertEq(value.poolId, PoolId.unwrap(id));
        assertEq(value.lpFee, actualKey.fee);
        assertEq(value.tickSpacing, actualKey.tickSpacing);
        assertEq(value.tickLower, vault.tickLower());
        assertEq(value.tickUpper, vault.tickUpper());
        (int24 positionLower, int24 positionUpper) = vault.positionTicks();
        assertEq(positionLower, value.tickLower);
        assertEq(positionUpper, value.tickUpper);
        assertEq(value.sqrtPriceX96, sqrtPriceX96);
        assertEq(value.poolTick, poolTick);
        assertEq(value.protocolFee, protocolFee);
        assertEq(value.protocolFeeZeroForOne, protocolFee.getZeroForOneFee());
        assertEq(value.protocolFeeOneForZero, protocolFee.getOneForZeroFee());
        assertEq(value.poolLiquidity, manager.getLiquidity(id));
        assertEq(value.positionLiquidity, vault.positionLiquidity());
        assertEq(value.principalTarget, principalTarget);
        assertEq(value.principalCounter, principalCounter);
        assertEq(value.pendingTarget, pendingTarget);
        assertEq(value.pendingCounter, pendingCounter);
        assertEq(value.pendingLaunchTarget, pendingLaunchTarget);
        assertEq(value.pendingLaunchCounter, pendingLaunchCounter);
        assertEq(value.idleTarget, idleTarget);
        assertEq(value.idleCounter, idleCounter);
        assertEq(value.totalTarget, totalTarget);
        assertEq(value.totalCounter, totalCounter);
        assertEq(value.totalSupply, vault.totalSupply());
        assertEq(value.shareFeeBps, vault.SHARE_FEE_BPS());
        assertEq(value.lastCompoundAt, vault.lastCompoundAt());
        assertEq(value.compoundAvailableAt, vault.compoundAvailableAt());
        assertEq(value.compoundBase, vault.compoundBase());
        assertEq(value.compoundLiquidityCap, vault.compoundLiquidityCap());

        assertGt(value.pendingTarget + value.pendingCounter, 0);
        assertEq(value.protocolFee, packedProtocolFee);
        assertEq(value.launchFeeSource, address(0));
    }

    function testSnapshotIncludesPendingLaunchNav() public {
        TokenLaunchpad launchpad =
            _deployLaunchpad(manager, factory, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE);
        vm.prank(owner);
        factory.bindLaunchpad(address(launchpad));

        TokenLaunchpad.TokenMetadata memory metadata = TokenLaunchpad.TokenMetadata({
            name: "Lens Launch Token",
            symbol: "LLT",
            imageUrl: "ipfs://lens-launch-token",
            websiteUrl: "https://example.com",
            twitterHandle: "lens_launch",
            telegramHandle: "lens_launch_chat"
        });
        uint256 initialBuy = 0.1 ether;
        uint256 value = launchpad.initialLpQuote() + initialBuy;
        vm.deal(alice, value);
        vm.prank(alice);
        (address token, address vaultAddress,) = launchpad.createToken{ value: value }(
            metadata,
            keccak256("lens pending launch fees"),
            0,
            TickMath.MIN_SQRT_PRICE + 1,
            LAUNCH_START_TICK,
            LAUNCH_INITIAL_LP_QUOTE,
            block.timestamp
        );
        LpTokenVault platformVault = LpTokenVault(payable(vaultAddress));

        (, ILaunchFeeSource.FeeAmounts memory pendingNav,) =
            ILaunchFeeSource(platformVault.launchFeeSource()).pendingFees(token);
        (, uint256 pendingNavCounter) = platformVault.pendingLaunchFees();
        assertEq(pendingNav.counter, pendingNavCounter);
        assertGt(pendingNavCounter, 0);
        assertEq(platformVault.launchFeeSource(), address(launchpad.liquidityVault()));
        assertEq(platformVault.target(), token);

        LpTokenLens.VaultSnapshot memory snapshot = lens.snapshot(platformVault);
        (uint256 totalTarget, uint256 totalCounter) = platformVault.totalAssets();
        assertEq(snapshot.totalTarget, totalTarget);
        assertEq(snapshot.totalCounter, totalCounter);
        assertEq(snapshot.pendingLaunchCounter, pendingNavCounter);
    }

    function testFactorySnapshotsPaginatesAndHandlesEmptyWindows() public {
        MockERC20 second = new MockERC20("Second Target", "SECOND", 18);
        MockERC20 third = new MockERC20("Third Target", "THIRD", 18);
        PoolKey memory secondKey = _erc20Key(address(second), address(usdg));
        PoolKey memory thirdKey = _erc20Key(address(third), address(usdg));
        _initLivePool(secondKey, 0);
        _initLivePool(thirdKey, 0);

        address predictedSecond = factory.predictVault(address(second), secondKey);
        LpTokenVault secondVault = _launch(address(second), secondKey, 1_000e18, 1_000e6);
        LpTokenVault thirdVault = _launch(address(third), thirdKey, 1_000e18, 1_000e6);
        assertEq(address(secondVault), predictedSecond);

        LpTokenLens.VaultSnapshot[] memory firstPage = lens.factorySnapshots(factory, 0, 2);
        assertEq(firstPage.length, 2);
        assertEq(firstPage[0].vault, address(vault));
        assertEq(firstPage[1].vault, address(secondVault));

        LpTokenLens.VaultSnapshot[] memory tail = lens.factorySnapshots(factory, 1, 10);
        assertEq(tail.length, 2);
        assertEq(tail[0].vault, address(secondVault));
        assertEq(tail[1].vault, address(thirdVault));

        assertEq(lens.factorySnapshots(factory, 0, 0).length, 0);
        assertEq(lens.factorySnapshots(factory, factory.vaultCount(), 1).length, 0);
        assertEq(lens.factorySnapshots(factory, type(uint256).max, 1).length, 0);
        assertEq(factory.vaultAt(2), address(thirdVault));
    }

    function testPreviewWrappersMatchVaultViews() public view {
        (uint256 expectedShares, uint256 expectedTarget, uint256 expectedCounter) =
            vault.previewMintPair(25e18, 25e6);
        (uint256 shares, uint256 targetUsed, uint256 counterUsed) =
            lens.previewMintPair(vault, 25e18, 25e6);
        assertEq(shares, expectedShares);
        assertEq(targetUsed, expectedTarget);
        assertEq(counterUsed, expectedCounter);

        uint256 redeemShares = vault.balanceOf(alice) / 3;
        (uint256 expectedTargetOut, uint256 expectedCounterOut) = vault.previewRedeem(redeemShares);
        (uint256 targetOut, uint256 counterOut) = lens.previewRedeem(vault, redeemShares);
        assertEq(targetOut, expectedTargetOut);
        assertEq(counterOut, expectedCounterOut);

        (shares, targetUsed, counterUsed) = lens.previewMintPair(vault, 0, 0);
        assertEq(shares, 0);
        assertEq(targetUsed, 0);
        assertEq(counterUsed, 0);
        (targetOut, counterOut) = lens.previewRedeem(vault, 0);
        assertEq(targetOut, 0);
        assertEq(counterOut, 0);
    }

    function testRegisteredRecognizesEveryFactoryVaultAndRejectsForeignAddress() public {
        PoolKey memory otherKey = _erc20Key(address(cashcat), address(weth));
        _initLivePool(otherKey, 0);
        LpTokenVault otherVault = _launch(address(cashcat), otherKey, 1_000e18, 1_000e18);

        assertTrue(lens.isRegistered(factory, vault));
        assertTrue(lens.isRegistered(factory, otherVault));
        assertFalse(lens.isRegistered(factory, LpTokenVault(payable(address(cashcat)))));
    }
}

contract TokenLaunchpadViewsTest is LpTokenTestBase {
    TokenLaunchpad internal launchpad;

    function setUp() public override {
        super.setUp();
        launchpad = _deployLaunchpad(manager, factory, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE);
        vm.prank(owner);
        factory.bindLaunchpad(address(launchpad));
    }

    function testTokenPredictionsListingsAndPoolSelectors() public {
        TokenLaunchpad.TokenMetadata memory firstMetadata = _metadata("First Token", "FIRST");
        TokenLaunchpad.TokenMetadata memory secondMetadata = _metadata("Second Token", "SECOND");
        bytes32 firstSalt = keccak256("first listing");
        bytes32 secondSalt = keccak256("second listing");

        address predictedFirst = launchpad.predictTokenAddress(alice, firstMetadata, firstSalt);
        address predictedFirstVault = factory.predictLaunchpadVault(predictedFirst);
        vm.warp(100);
        (address firstToken, address firstVault,) = _create(alice, firstMetadata, firstSalt);
        vm.warp(200);
        (address secondToken, address secondVault,) = _create(bob, secondMetadata, secondSalt);

        assertEq(firstToken, predictedFirst);
        assertEq(firstVault, predictedFirstVault);
        assertEq(launchpad.getTokenCount(), 2);
        assertEq(launchpad.tokenIndex(firstToken), 1);
        assertEq(launchpad.tokenIndex(secondToken), 2);
        assertTrue(launchpad.isToken(firstToken));
        assertFalse(launchpad.isToken(address(cashcat)));

        TokenLaunchpad.TokenInfo memory first = launchpad.getTokenInfo(firstToken);
        _assertTokenInfo(first, firstToken, alice, firstVault, 100);
        TokenLaunchpad.TokenInfo memory second = launchpad.tokens(1);
        _assertTokenInfo(second, secondToken, bob, secondVault, 200);

        TokenLaunchpad.TokenInfo[] memory all = launchpad.getTokens(0, 2);
        assertEq(all.length, 2);
        assertEq(all[0].token, firstToken);
        assertEq(all[1].token, secondToken);

        TokenLaunchpad.TokenInfo[] memory tail = launchpad.getTokens(1, 99);
        assertEq(tail.length, 1);
        assertEq(tail[0].token, secondToken);
        assertEq(launchpad.getTokens(2, 99).length, 0);

        PoolKey memory firstKey = launchpad.poolKey(firstToken);
        assertTrue(firstKey.currency0.isAddressZero());
        assertEq(Currency.unwrap(firstKey.currency1), firstToken);
        assertEq(firstKey.fee, launchpad.LP_FEE());
        assertEq(firstKey.tickSpacing, launchpad.TICK_SPACING());
        assertEq(address(firstKey.hooks), address(launchpad));

        (int24 startTick, int24 lowerTick, int24 upperTick) = launchpad.poolTicks();
        assertEq(startTick, launchpad.startTick());
        assertEq(lowerTick, TickMath.minUsableTick(launchpad.TICK_SPACING()));
        assertEq(upperTick, launchpad.startTick());
        assertEq(launchpad.initialSqrtPriceX96(), TickMath.getSqrtPriceAtTick(startTick));
        assertGt(launchpad.bootstrapTargetAmount(), 0);
        assertEq(factory.vaultAt(0), firstVault);
        assertEq(factory.vaultAt(1), secondVault);
    }

    function testListingEmptyAndInvalidWindows() public {
        assertEq(launchpad.getTokenCount(), 0);
        assertEq(launchpad.getTokens(0, 0).length, 0);
        assertEq(launchpad.getTokens(10, 20).length, 0);

        vm.expectRevert(TokenLaunchpad.InvalidRange.selector);
        launchpad.getTokens(1, 0);

        vm.expectRevert(TokenLaunchpad.TokenNotFound.selector);
        launchpad.getTokenInfo(address(cashcat));
    }

    function _create(address creator, TokenLaunchpad.TokenMetadata memory metadata, bytes32 salt)
        private
        returns (address token, address vault, uint256 initialBuyTargetOut)
    {
        uint256 value = launchpad.initialLpQuote();
        vm.deal(creator, value);
        vm.prank(creator);
        return launchpad.createToken{ value: value }(
            metadata, salt, 0, 0, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE, block.timestamp
        );
    }

    function _assertTokenInfo(
        TokenLaunchpad.TokenInfo memory info,
        address token,
        address creator,
        address vault,
        uint64 createdAt
    ) private view {
        assertEq(info.token, token);
        assertEq(info.creator, creator);
        assertEq(info.vault, vault);
        assertEq(info.poolId, PoolId.unwrap(launchpad.poolKey(token).toId()));
        assertGt(info.launchLiquidity, 0);
        assertEq(info.createdAt, createdAt);
    }

    function _metadata(string memory name, string memory symbol)
        private
        pure
        returns (TokenLaunchpad.TokenMetadata memory metadata)
    {
        metadata = TokenLaunchpad.TokenMetadata({
            name: name,
            symbol: symbol,
            imageUrl: "ipfs://token",
            websiteUrl: "https://example.com",
            twitterHandle: "token",
            telegramHandle: "token_chat"
        });
    }
}
