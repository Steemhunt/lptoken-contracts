// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { FixedPoint96 } from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { Pool } from "@uniswap/v4-core/src/libraries/Pool.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Boundary ticks for the permanent vault position.
/// @dev Uniswap V4 caps `liquidityGross` per tick, and that cap is shared by every position
/// using the tick as a boundary. A vault position keeps growing — every `mintPair` and
/// `compound` adds liquidity at the same two ticks — so anyone who saturates one of them
/// stops the vault permanently while leaving redemption intact. At the extreme usable ticks
/// saturation is nearly free, because the assets a position holds there are worth almost
/// nothing: one tick-spacing-wide position beside `maxUsableTick` fills the cap for about
/// 2e-5 of the counter currency.
///
/// The range is therefore placed where saturating either boundary costs more of that leg
/// than can exist: a multiple of an ERC-20's total supply, or an unobtainable amount of the
/// native currency. Everything inside stays exactly as before — the position still spans
/// every price the market can realistically reach, and the price leaving it is the ordinary
/// one-sided case the vault already handles.
library VaultRange {
    error UnprotectablePool(int24 lower, int24 upper);

    /// @notice Multiple of a leg's total supply an attacker would need to hold to saturate
    /// that side's boundary tick. Above one so a token that mints further after its launch
    /// keeps the boundary out of reach.
    uint256 internal constant SUPPLY_MULTIPLE = 10;
    /// @notice Stand-in supply for the native currency, which has no `totalSupply`.
    uint256 internal constant NATIVE_BUDGET = 1_000_000 ether;

    /// @notice Boundary ticks for a pool's vault position.
    function ticks(PoolKey memory key) internal view returns (int24 lower, int24 upper) {
        return ticks(key.tickSpacing, budget(key.currency0), budget(key.currency1));
    }

    /// @notice Amount of `currency` that saturating its boundary tick must cost.
    /// @dev A leg with no supply yet bounds nothing, so its boundary stays at the usable tick:
    /// there is no launch to protect until someone mints, and minting is what a launch needs.
    function budget(Currency currency) internal view returns (uint256) {
        if (currency.isAddressZero()) return NATIVE_BUDGET;
        uint256 supply = IERC20(Currency.unwrap(currency)).totalSupply();
        return supply == 0 ? 1 : SUPPLY_MULTIPLE * supply;
    }

    /// @notice Widest tick range whose boundaries cost at least `budget0` of currency0 and
    /// `budget1` of currency1 to saturate, except where a budget is small enough that its
    /// boundary lands on the usable tick and there is nothing further out to place it at.
    /// @dev A tick-spacing-wide position beside a boundary is the cheapest way to fill that
    /// boundary's cap. Below the pool price such a position holds only currency1 and above it
    /// only currency0, so with `unit = maxLiquidityPerTick * (Q96 - sqrtPrice(-tickSpacing))`
    /// the two costs are `unit * sqrtPrice(t) / Q96^2` and `unit / sqrtPrice(t)`. Inverting
    /// them gives the price each boundary may not pass, and rounding lands on the tick-spacing
    /// multiple on the expensive side of it.
    function ticks(int24 tickSpacing, uint256 budget0, uint256 budget1)
        internal
        pure
        returns (int24 lower, int24 upper)
    {
        uint256 unit = uint256(Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing))
            * (FixedPoint96.Q96 - TickMath.getSqrtPriceAtTick(-tickSpacing));

        lower = _align(
            _tickAtOrBelow(FullMath.mulDiv(budget1, FixedPoint96.Q96 * FixedPoint96.Q96, unit)) + 1,
            tickSpacing,
            true
        );
        upper = _align(_tickAtOrBelow(unit / budget0), tickSpacing, false);

        int24 minimumTick = TickMath.minUsableTick(tickSpacing);
        int24 maximumTick = TickMath.maxUsableTick(tickSpacing);
        if (lower < minimumTick) lower = minimumTick;
        if (upper > maximumTick) upper = maximumTick;
        // Both boundaries can only be priced out of reach while the two budgets fit inside what
        // one tick's liquidity cap is worth. A pool whose legs are both large enough to break
        // that has no protectable range at any placement and cannot host a vault.
        if (lower >= upper) revert UnprotectablePool(lower, upper);
    }

    /// @dev Highest tick whose price does not exceed `sqrtPriceX96`, saturating at the ends of
    /// the tick domain so an out-of-domain budget yields a boundary the caller rejects rather
    /// than a revert inside `TickMath`.
    function _tickAtOrBelow(uint256 sqrtPriceX96) private pure returns (int24) {
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE) return TickMath.MIN_TICK;
        if (sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_TICK;
        return TickMath.getTickAtSqrtPrice(uint160(sqrtPriceX96));
    }

    function _align(int24 tick, int24 tickSpacing, bool roundUp) private pure returns (int24) {
        int24 aligned = (tick / tickSpacing) * tickSpacing;
        if (roundUp) return aligned < tick ? aligned + tickSpacing : aligned;
        return aligned > tick ? aligned - tickSpacing : aligned;
    }
}
