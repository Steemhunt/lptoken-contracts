// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.26;

// Compile the official PoolManager with the optimizer settings used by Uniswap v4.
// Integration tests deploy this artifact while the protocol remains on Solidity 0.8.36.
import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";
