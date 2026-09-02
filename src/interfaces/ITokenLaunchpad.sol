// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

interface ITokenLaunchpad {
    function poolManager() external view returns (IPoolManager);
    function factory() external view returns (address);
    function initialLpQuote() external view returns (uint256);
    function startTick() external view returns (int24);
    function bootstrapTargetAmount() external view returns (uint256);
    function liquidityVault() external view returns (address);
    function isToken(address token) external view returns (bool);
    function poolKey(address token) external view returns (PoolKey memory);
}
