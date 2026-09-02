// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

interface ILpTokenFactory {
    struct LaunchParams {
        address target;
        PoolKey poolKey;
        uint256 targetAmount;
        uint256 counterAmount;
        int24 expectedTick;
        uint24 maxTickDeviation;
        uint128 minExistingLiquidity;
        uint128 minLiquidityAdded;
        uint256 minShares;
        address receiver;
        uint256 deadline;
    }

    function MIN_POOL_LP_FEE() external view returns (uint24);
    function poolManager() external view returns (IPoolManager);
    function treasury() external view returns (address);
    function pendingTreasury() external view returns (address);
    function owner() external view returns (address);
    function launchpad() external view returns (address);
    function vaultImplementation() external view returns (address);
    function vaultOfPoolId(PoolId poolId) external view returns (address);
    function isVault(address candidate) external view returns (bool);
    function vaultCount() external view returns (uint256);
    function vaultAt(uint256 index) external view returns (address);
    function predictLaunchpadVault(address target) external view returns (address predicted);
    function proposeTreasury(address proposedTreasury) external;
    function acceptTreasury() external;
    function launchFromLaunchpad(address target, uint256 targetAmount)
        external
        payable
        returns (address vault, uint256 shares, uint128 liquidityAdded);
}
