// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { SqrtPriceMath } from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @dev Verifies the inverse-rounding assumption used when a vault computes liquidity
/// from token budgets before PoolManager derives the required token deltas.
contract LiquidityRoundingTest is Test {
    function testFuzzLiquidityRoundDownRemainsFundable(
        int24 currentTick,
        uint128 amount0,
        uint128 amount1,
        int24 tickSpacing
    ) public pure {
        tickSpacing = int24(
            bound(
                int256(tickSpacing),
                int256(TickMath.MIN_TICK_SPACING),
                int256(TickMath.MAX_TICK_SPACING)
            )
        );
        int24 lowerTick = TickMath.minUsableTick(tickSpacing);
        int24 upperTick = TickMath.maxUsableTick(tickSpacing);
        currentTick = int24(
            bound(
                int256(currentTick),
                int256(lowerTick + tickSpacing),
                int256(upperTick - tickSpacing)
            )
        );
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(lowerTick);
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(upperTick);

        uint128 maximumLiquidity = uint128(type(int128).max);
        uint256 maximumAmount0 = SqrtPriceMath.getAmount0Delta(
            sqrtPriceX96, sqrtPriceUpperX96, maximumLiquidity, false
        );
        uint256 maximumAmount1 = SqrtPriceMath.getAmount1Delta(
            sqrtPriceLowerX96, sqrtPriceX96, maximumLiquidity, false
        );
        if (maximumAmount0 > type(uint128).max) maximumAmount0 = type(uint128).max;
        if (maximumAmount1 > type(uint128).max) maximumAmount1 = type(uint128).max;
        uint256 minimumAmount0 =
            SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtPriceUpperX96, 1, true);
        uint256 minimumAmount1 =
            SqrtPriceMath.getAmount1Delta(sqrtPriceLowerX96, sqrtPriceX96, 1, true);
        amount0 = uint128(bound(uint256(amount0), minimumAmount0, maximumAmount0));
        amount1 = uint128(bound(uint256(amount1), minimumAmount1, maximumAmount1));

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, amount0, amount1
        );
        assertGt(liquidity, 0);
        assertLe(liquidity, maximumLiquidity);

        uint256 required0 =
            SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtPriceUpperX96, liquidity, true);
        uint256 required1 =
            SqrtPriceMath.getAmount1Delta(sqrtPriceLowerX96, sqrtPriceX96, liquidity, true);
        assertLe(required0, amount0);
        assertLe(required1, amount1);
    }
}
