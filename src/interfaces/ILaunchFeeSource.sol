// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

interface ILaunchFeeSource {
    struct FeeAmounts {
        uint256 target;
        uint256 counter;
    }

    function poolManager() external view returns (IPoolManager);
    function launchpad() external view returns (address);
    function factory() external view returns (address);
    function treasury() external view returns (address);

    function distributeFees(address token) external;

    /// @notice Distribution with a caller-funded native payout allowance, for a recipient
    /// whose `receive` needs more gas than the source's default stipend. Kept under a
    /// separate name so `distributeFees` stays unambiguous for `abi.encodeCall` callers.
    function distributeFeesWithGas(address token, uint256 nativeGas) external;

    function pendingFees(address token)
        external
        view
        returns (FeeAmounts memory creator, FeeAmounts memory nav, FeeAmounts memory protocol);

    /// @notice Launch-position liquidity for `token` that is active at the pool's current
    /// tick and belongs to `lpTokenVault`, or zero. Non-withdrawable and only ever active
    /// alongside the caller's own pool, so it is a trustworthy floor on live liquidity.
    function activeLiquidity(address token, address lpTokenVault) external view returns (uint128);
}
