// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import { MockERC20 } from "./mocks/MockERC20.sol";
import { LpTokenTestBase } from "./utils/LpTokenTestBase.sol";

/// @notice The economic assumption behind `LpTokenVault.compoundLiquidityCap`.
///
/// A JIT attacker moves the price, waits for someone to add liquidity at that price, then
/// moves it back. Their gain is the added liquidity's mispricing loss,
/// `L_c * (sqrt(p') - sqrt(p))^2 / sqrt(p')`, which grows quadratically in the deviation,
/// while their irreducible cost is the LP fee on both swap legs, which grows linearly.
/// Solving gives a profit condition of `L_c > f * L_pool * (r + 1) / (r - 1)`, so no
/// deviation pays while `L_c <= f * L_pool`.
///
/// These tests pin that bound against the real PoolManager. The pool starts at tick 0 so
/// the price is exactly 1 and an actor's net value is simply (token0 + token1).
contract CompoundCapBreakEvenTest is LpTokenTestBase {
    using StateLibrary for IPoolManager;

    uint24 internal constant LAUNCH_FEE = 10_000; // 1%, the platform launch fee
    int24 internal constant LAUNCH_SPACING = 200;
    int256 internal constant POOL_LIQUIDITY = 1e21;

    /// r = sqrt(p'/p) = 1.0001^(tick/2), i.e. 1.1x, 2x, 10x, 100x, 1000x, 10000x.
    int24[6] internal MANIPULATIONS =
        [int24(1_906), int24(13_862), int24(46_052), int24(92_103), int24(138_155), int24(184_207)];

    PoolKey internal key;
    address internal atk = makeAddr("jit-attacker");
    address internal victim = makeAddr("compounder");

    function setUp() public override {
        super.setUp();
        MockERC20 t0 = new MockERC20("Zero", "ZERO", 18);
        MockERC20 t1 = new MockERC20("One", "ONE", 18);
        key = _erc20Key(address(t0), address(t1), LAUNCH_FEE, LAUNCH_SPACING);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        _addFullRangeLiquidity(key, address(this), POOL_LIQUIDITY);

        MockERC20(Currency.unwrap(key.currency0)).mint(atk, 1e30);
        MockERC20(Currency.unwrap(key.currency1)).mint(atk, 1e30);
        vm.startPrank(atk);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _attackerValue() private view returns (uint256) {
        return MockERC20(Currency.unwrap(key.currency0)).balanceOf(atk)
            + MockERC20(Currency.unwrap(key.currency1)).balanceOf(atk);
    }

    /// Moves the pool to `targetTick` with a price limit, so the swap costs exactly the
    /// move and stops there.
    function _moveTo(int24 targetTick) private {
        (, int24 current,,) = manager.getSlot0(key.toId());
        if (current == targetTick) return;
        vm.prank(atk);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: targetTick < current,
                amountSpecified: -int256(5e29),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(targetTick)
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
    }

    /// Net value change for the attacker; positive means the attack paid.
    function _runAttack(int24 manipulatedTick, int256 deployedLiquidity)
        private
        returns (int256 netValue)
    {
        uint256 before = _attackerValue();
        _moveTo(manipulatedTick);
        if (deployedLiquidity > 0) {
            // A distinct salt keeps this a fresh position. The shared v4 test router
            // otherwise merges it into the seed position, whose accrued fees trip the
            // router's own delta assertions.
            _addRangeLiquidity(
                key,
                victim,
                TickMath.minUsableTick(key.tickSpacing),
                TickMath.maxUsableTick(key.tickSpacing),
                deployedLiquidity,
                keccak256("victim")
            );
        }
        _moveTo(0);
        netValue = int256(_attackerValue()) - int256(before);
    }

    function _liquidityBps(uint256 bps) private pure returns (int256) {
        return (POOL_LIQUIDITY * int256(bps)) / 10_000;
    }

    /// Control: with nothing added mid-attack the round trip only ever burns fees.
    function testRoundTripWithoutDeploymentAlwaysLoses() public {
        for (uint256 i; i < MANIPULATIONS.length; ++i) {
            uint256 snap = vm.snapshotState();
            assertLt(_runAttack(MANIPULATIONS[i], 0), 0, "round trip was free");
            vm.revertToState(snap);
        }
    }

    /// The bound itself: deploying the fee fraction of pool liquidity never pays, at any
    /// manipulation depth. `LpTokenVault` caps at half of `f / (1 - f)`, another 2x below.
    function testDeployingTheFeeFractionIsNeverProfitable() public {
        uint256 feeBps = uint256(LAUNCH_FEE) / 100; // 10_000 pips == 100 bps
        for (uint256 i; i < MANIPULATIONS.length; ++i) {
            uint256 snap = vm.snapshotState();
            int256 net = _runAttack(MANIPULATIONS[i], _liquidityBps(feeBps));
            emit log_named_int("attacker net at fee-fraction deployment", net);
            assertLt(net, 0, "deploying the fee fraction paid the attacker");
            vm.revertToState(snap);
        }
    }

    /// The bound is tight: a little above the fee fraction the attack turns profitable,
    /// so the cap must never be raised past it.
    function testBreakEvenSitsJustAboveTheFeeFraction() public {
        // Deepest manipulation, where (r + 1) / (r - 1) is closest to 1.
        int24 deepest = MANIPULATIONS[MANIPULATIONS.length - 1];
        uint256 snap = vm.snapshotState();
        assertLt(_runAttack(deepest, _liquidityBps(100)), 0);
        vm.revertToState(snap);

        snap = vm.snapshotState();
        assertGt(_runAttack(deepest, _liquidityBps(105)), 0, "bound is looser than assumed");
        vm.revertToState(snap);
    }
}
