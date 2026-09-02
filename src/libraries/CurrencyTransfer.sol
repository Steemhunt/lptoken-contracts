// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Shared currency layer for native-or-ERC20 flows: exact pulls, checked and
/// failure-safe transfers, and PoolManager delta settlement. Centralizing the
/// zero-address branches keeps the vault and periphery byte-for-byte consistent.
library CurrencyTransfer {
    using SafeERC20 for IERC20;
    using SafeCast for int256;

    error TaxedOrRebasingToken(address token);
    error NativeTransferFailed(address receiver, uint256 amount);

    /// @dev ERC-20 only: pulls exactly `amount` and rejects any fee-on-transfer or
    /// rebasing shortfall. Native currency never uses a pull; entry points take it as
    /// exact `msg.value`.
    function pullExact(address token, address payer, uint256 amount) internal {
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(payer, address(this), amount);
        if (IERC20(token).balanceOf(address(this)) - beforeBalance != amount) {
            revert TaxedOrRebasingToken(token);
        }
    }

    /// @dev Checked transfer of either leg; reverts when a native receiver rejects.
    function transfer(Currency currency, address receiver, uint256 amount) internal {
        if (amount == 0) return;
        if (currency.isAddressZero()) {
            (bool nativeSuccess,) = receiver.call{ value: amount }("");
            if (!nativeSuccess) revert NativeTransferFailed(receiver, amount);
        } else {
            IERC20(Currency.unwrap(currency)).safeTransfer(receiver, amount);
        }
    }

    /// @dev Failure-safe transfer with a caller-selected native gas stipend. ERC-20
    /// transfers still receive ordinary call gas so standard token implementations work.
    function tryTransfer(Currency currency, address to, uint256 amount, uint256 nativeGas)
        internal
        returns (bool)
    {
        if (amount == 0) return true;
        if (currency.isAddressZero()) {
            (bool nativeSuccess,) = to.call{ value: amount, gas: nativeGas }("");
            return nativeSuccess;
        }
        (bool success, bytes memory result) =
            Currency.unwrap(currency).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!success) return false;
        if (result.length == 0) return true;
        if (result.length != 32) return false;
        uint256 returned;
        assembly ("memory-safe") {
            returned := mload(add(result, 0x20))
        }
        return returned == 1;
    }

    /// @dev Settles both legs of a PoolManager balance delta: negative amounts are paid
    /// (native via sync/`settle{value}`, ERC-20 via sync/transfer/settle) and positive
    /// amounts are taken to the caller.
    function settleDelta(
        IPoolManager manager,
        Currency currency0,
        Currency currency1,
        BalanceDelta delta
    ) internal {
        settle(manager, currency0, delta.amount0());
        settle(manager, currency1, delta.amount1());
    }

    function settle(IPoolManager manager, Currency currency, int128 delta) internal {
        if (delta < 0) {
            uint256 owed = (-int256(delta)).toUint256();
            if (currency.isAddressZero()) {
                // The synced-currency slot is transient and transaction-global, and
                // PoolManager.sync is permissionless, so any earlier caller can leave an
                // ERC-20 synced and make an unsynced native settle revert. Syncing the
                // zero address resets that slot, matching v4-periphery's DeltaResolver.
                manager.sync(currency);
                manager.settle{ value: owed }();
            } else {
                manager.sync(currency);
                IERC20(Currency.unwrap(currency)).safeTransfer(address(manager), owed);
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, address(this), int256(delta).toUint256());
        }
    }
}
