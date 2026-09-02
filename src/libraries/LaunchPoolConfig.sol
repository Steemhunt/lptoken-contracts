// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { FixedPoint96 } from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { SqrtPriceMath } from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @notice Launch pool invariants shared by every deployment: the pool always pairs the chain's
/// native currency (currency0) with the newly created token (currency1) at a 1% static fee.
/// The start tick and bootstrap quote are mutable native-denominated economics held by the
/// TokenLaunchpad, not constants in this library.
library LaunchPoolConfig {
    using SafeCast for uint256;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 internal constant TOKEN_SUPPLY = 1_000_000_000e18;
    uint24 internal constant LP_FEE = 10_000;
    int24 internal constant TICK_SPACING = 200;

    function poolKey(address token, IHooks hooks) internal pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: hooks
        });
    }

    /// @notice Boundary ticks of the lpTOKEN vault position, and their prices. These are what
    /// `VaultRange` derives for a `TICK_SPACING` pool pairing the native currency with
    /// `TOKEN_SUPPLY`: saturating either tick's shared liquidity cap would cost ten times the
    /// token supply or a million units of the native currency, while the range still spans
    /// every price the market can reach — 5.7e17x above and 3.7e8x below a 198000 launch tick.
    /// Every launch shares them, so they are pinned alongside the other product constants;
    /// `VaultRange.t.sol` asserts all four against the rule and against `TickMath`.
    int24 internal constant VAULT_TICK_LOWER = -210_800;
    int24 internal constant VAULT_TICK_UPPER = 395_200;
    uint160 internal constant VAULT_SQRT_PRICE_LOWER = 2_097_222_954_085_974_151_159_020;
    uint160 internal constant VAULT_SQRT_PRICE_UPPER =
        30_207_131_890_974_724_802_496_785_596_243_271_085;

    function vaultTicks() internal pure returns (int24 lower, int24 upper) {
        return (VAULT_TICK_LOWER, VAULT_TICK_UPPER);
    }

    /// @notice Permanent one-sided launch range: the minimum usable tick up to `startTick`.
    function launchTicks(int24 startTick) internal pure returns (int24 lower, int24 upper) {
        return (TickMath.minUsableTick(TICK_SPACING), startTick);
    }

    /// @notice Nominal liquidity for target-only funds across the permanent launch range.
    function launchLiquidity(int24 startTick, uint256 targetAmount)
        internal
        pure
        returns (uint128)
    {
        (int24 lowerTick, int24 upperTick) = launchTicks(startTick);
        return LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(lowerTick),
            TickMath.getSqrtPriceAtTick(upperTick),
            targetAmount
        );
    }

    /// @notice Target amount that fully matches the given native bootstrap contribution
    /// across the vault range at the given launch price, or zero when no launch could: a
    /// quote whose liquidity exceeds what a position can hold is unmatchable, and reads as
    /// invalid terms at the caller instead of a revert out of the liquidity math.
    function bootstrapTargetAmount(int24 startTick, uint256 initialLpQuote)
        internal
        pure
        returns (uint256 targetAmount)
    {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(startTick);
        uint256 priceRange = VAULT_SQRT_PRICE_UPPER - sqrtPriceX96;
        uint256 intermediate =
            FullMath.mulDiv(sqrtPriceX96, VAULT_SQRT_PRICE_UPPER, FixedPoint96.Q96);
        // Largest quote whose `LiquidityAmounts.getLiquidityForAmount0` result still fits a
        // position, checked before that multiplication runs: far enough past it, the floored
        // result itself outgrows uint256 and `FullMath` bare-reverts instead of reporting.
        uint256 maximumQuote = FullMath.mulDivRoundingUp(
            uint256(type(uint128).max) + 1, priceRange, intermediate
        ) - 1;
        if (initialLpQuote > maximumQuote) return 0;
        uint128 liquidity = FullMath.mulDiv(initialLpQuote, intermediate, priceRange).toUint128();
        targetAmount =
            SqrtPriceMath.getAmount1Delta(VAULT_SQRT_PRICE_LOWER, sqrtPriceX96, liquidity, true);
    }

    /// @notice Vault liquidity the bootstrap pair funds at the given launch price, which
    /// is also the vault's initial share supply. Mirrors what `LpTokenVault.bootstrap` deploys
    /// from the same amounts at the same price, so terms can be checked before a launch.
    function bootstrapLiquidity(int24 startTick, uint256 initialLpQuote, uint256 targetAmount)
        internal
        pure
        returns (uint128)
    {
        // The token is currency1, so the quote is amount0 and the matched target is amount1.
        return LiquidityAmounts.getLiquidityForAmounts(
            TickMath.getSqrtPriceAtTick(startTick),
            VAULT_SQRT_PRICE_LOWER,
            VAULT_SQRT_PRICE_UPPER,
            initialLpQuote,
            targetAmount
        );
    }
}
