// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolDonateTest } from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import { PoolModifyLiquidityTest } from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import { LpTokenFactory } from "../../src/LpTokenFactory.sol";
import { LpTokenVault } from "../../src/LpTokenVault.sol";
import { ILpTokenFactory } from "../../src/interfaces/ILpTokenFactory.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { CallbackERC20 } from "../mocks/TestActors.sol";
import { LaunchpadTestDeployer } from "./LaunchpadTestDeployer.sol";

/// @notice Shared fixture deploying the official PoolManager artifact plus canonical
/// v4-core test routers. Curated pools are hookless; platform pools use only the
/// launchpad's before-initialize permission.
abstract contract LpTokenTestBase is Test, LaunchpadTestDeployer {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    /// @dev Canonical launch terms used by the suite, matching the Robinhood deployment.
    int24 internal constant LAUNCH_START_TICK = 198_000;
    uint256 internal constant LAUNCH_INITIAL_LP_QUOTE = 0.001 ether;

    uint24 internal constant FEE = 3_000;
    int24 internal constant SPACING = 60;
    int256 internal constant EXTERNAL_LIQUIDITY = 1e21;

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolSwapTest internal swapRouter;
    PoolDonateTest internal donateRouter;
    LpTokenFactory internal factory;

    MockERC20 internal usdg;
    MockERC20 internal tok8;
    MockERC20 internal weth;
    MockERC20 internal cashcat;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal treasury = makeAddr("treasury");

    receive() external payable { }

    function setUp() public virtual {
        manager = IPoolManager(
            deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this)))
        );
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
        donateRouter = new PoolDonateTest(manager);
        factory = new LpTokenFactory(manager, treasury, owner);

        usdg = new MockERC20("Global Dollar", "USDG", 6);
        tok8 = new MockERC20("Octo", "OCTO", 8);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        cashcat = new MockERC20("Cash Cat", "CASHCAT", 18);
    }

    function _erc20Key(address a, address b) internal pure returns (PoolKey memory key) {
        return _erc20Key(a, b, FEE, SPACING);
    }

    function _erc20Key(address a, address b, uint24 fee, int24 spacing)
        internal
        pure
        returns (PoolKey memory key)
    {
        (address token0, address token1) = a < b ? (a, b) : (b, a);
        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(address(0))
        });
    }

    function _nativeKey(address token) internal pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: FEE,
            tickSpacing: SPACING,
            hooks: IHooks(address(0))
        });
    }

    function _initLivePool(PoolKey memory key, int24 tick) internal {
        manager.initialize(key, TickMath.getSqrtPriceAtTick(tick));
        _addFullRangeLiquidity(key, address(this), EXTERNAL_LIQUIDITY);
    }

    function _addFullRangeLiquidity(PoolKey memory key, address provider, int256 liquidityDelta)
        internal
    {
        _addRangeLiquidity(
            key,
            provider,
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            liquidityDelta
        );
    }

    function _addRangeLiquidity(
        PoolKey memory key,
        address provider,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    ) internal {
        _addRangeLiquidity(key, provider, tickLower, tickUpper, liquidityDelta, bytes32(0));
    }

    function _addRangeLiquidity(
        PoolKey memory key,
        address provider,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bytes32 salt
    ) internal {
        uint256 value;
        if (liquidityDelta > 0) {
            value = _fundForPool(key, provider, address(liquidityRouter));
        }
        vm.prank(provider);
        liquidityRouter.modifyLiquidity{ value: value }(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: salt
            }),
            bytes("")
        );
    }

    function _swap(PoolKey memory key, address trader, bool zeroForOne, uint256 amountIn) internal {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        uint256 value;
        if (input.isAddressZero()) {
            vm.deal(trader, trader.balance + amountIn);
            value = amountIn;
        } else {
            MockERC20(Currency.unwrap(input)).mint(trader, amountIn);
            vm.prank(trader);
            MockERC20(Currency.unwrap(input)).approve(address(swapRouter), type(uint256).max);
        }
        vm.prank(trader);
        swapRouter.swap{ value: value }(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amountIn.toInt256(),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
    }

    function _configureSwapCallback(
        CallbackERC20 callbackToken,
        address callbackRecipient,
        PoolKey memory key,
        uint256 amountIn
    ) internal {
        bool zeroForOne =
            Currency.unwrap(key.currency0) == address(callbackToken);
        callbackToken.mint(address(callbackToken), amountIn);
        vm.prank(address(callbackToken));
        callbackToken.approve(address(swapRouter), type(uint256).max);
        callbackToken.configureTransferFromCallback(
            callbackRecipient,
            address(swapRouter),
            abi.encodeCall(
                PoolSwapTest.swap,
                (
                    key,
                    SwapParams({
                        zeroForOne: zeroForOne,
                        amountSpecified: -amountIn.toInt256(),
                        sqrtPriceLimitX96: zeroForOne
                            ? TickMath.MIN_SQRT_PRICE + 1
                            : TickMath.MAX_SQRT_PRICE - 1
                    }),
                    PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
                    bytes("")
                )
            )
        );
    }

    function _donate(PoolKey memory key, address donor, uint256 amount0, uint256 amount1) internal {
        uint256 value;
        if (key.currency0.isAddressZero()) {
            vm.deal(donor, donor.balance + amount0);
            value = amount0;
        } else {
            MockERC20(Currency.unwrap(key.currency0)).mint(donor, amount0);
            vm.prank(donor);
            MockERC20(Currency.unwrap(key.currency0))
                .approve(address(donateRouter), type(uint256).max);
        }
        MockERC20(Currency.unwrap(key.currency1)).mint(donor, amount1);
        vm.prank(donor);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), type(uint256).max);
        vm.prank(donor);
        donateRouter.donate{ value: value }(key, amount0, amount1, bytes(""));
    }

    function _launch(
        address target,
        PoolKey memory key,
        uint256 targetAmount,
        uint256 counterAmount
    ) internal returns (LpTokenVault vault) {
        (address vaultAddress,,) = _launchFull(target, key, targetAmount, counterAmount, 0, 0);
        vault = LpTokenVault(payable(vaultAddress));
    }

    function _launchFull(
        address target,
        PoolKey memory key,
        uint256 targetAmount,
        uint256 counterAmount,
        uint128 minLiquidityAdded,
        uint256 minShares
    ) internal returns (address vaultAddress, uint256 shares, uint128 liquidityAdded) {
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(target, key, targetAmount, counterAmount, minLiquidityAdded, minShares);
        address predicted = factory.predictVault(target, key);
        _fundLaunch(target, key, owner, predicted, targetAmount, counterAmount);
        bool nativeCounter = key.currency0.isAddressZero();
        vm.prank(owner);
        (vaultAddress, shares, liquidityAdded) =
            factory.launch{ value: nativeCounter ? counterAmount : 0 }(params);
    }

    function _launchParams(
        address target,
        PoolKey memory key,
        uint256 targetAmount,
        uint256 counterAmount,
        uint128 minLiquidityAdded,
        uint256 minShares
    ) internal view returns (ILpTokenFactory.LaunchParams memory params) {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        params = ILpTokenFactory.LaunchParams({
            target: target,
            poolKey: key,
            targetAmount: targetAmount,
            counterAmount: counterAmount,
            expectedTick: tick,
            maxTickDeviation: 100,
            minExistingLiquidity: 1,
            minLiquidityAdded: minLiquidityAdded,
            minShares: minShares,
            receiver: alice,
            deadline: block.timestamp
        });
    }

    function _fundLaunch(
        address target,
        PoolKey memory key,
        address payer,
        address vault,
        uint256 targetAmount,
        uint256 counterAmount
    ) internal {
        MockERC20(target).mint(payer, targetAmount);
        vm.prank(payer);
        MockERC20(target).approve(vault, type(uint256).max);
        Currency counterCurrency =
            Currency.unwrap(key.currency0) == target ? key.currency1 : key.currency0;
        if (counterCurrency.isAddressZero()) {
            vm.deal(payer, payer.balance + counterAmount);
        } else {
            MockERC20(Currency.unwrap(counterCurrency)).mint(payer, counterAmount);
            vm.prank(payer);
            MockERC20(Currency.unwrap(counterCurrency)).approve(vault, type(uint256).max);
        }
    }

    function _fundForPool(PoolKey memory key, address provider, address spender)
        internal
        returns (uint256 value)
    {
        if (key.currency0.isAddressZero()) {
            value = 1e24;
            vm.deal(provider, provider.balance + value);
        } else {
            MockERC20(Currency.unwrap(key.currency0)).mint(provider, 1e30);
            vm.prank(provider);
            MockERC20(Currency.unwrap(key.currency0)).approve(spender, type(uint256).max);
        }
        MockERC20(Currency.unwrap(key.currency1)).mint(provider, 1e30);
        vm.prank(provider);
        MockERC20(Currency.unwrap(key.currency1)).approve(spender, type(uint256).max);
    }

    function _fundAndApprove(MockERC20 token, address who, address spender, uint256 amount)
        internal
    {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(spender, type(uint256).max);
    }

    function _currentTick(PoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(key.toId());
    }

    function _newTokenBelow(address benchmark) internal returns (MockERC20 token) {
        for (uint256 i; i < 128; ++i) {
            token = new MockERC20("Low", "LOW", 18);
            if (address(token) < benchmark) return token;
        }
        revert("no token below benchmark");
    }

    function _newTokenAbove(address benchmark) internal returns (MockERC20 token) {
        for (uint256 i; i < 128; ++i) {
            token = new MockERC20("High", "HIGH", 18);
            if (address(token) > benchmark) return token;
        }
        revert("no token above benchmark");
    }
}
