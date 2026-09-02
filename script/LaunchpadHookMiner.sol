// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";

import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @notice Finds a CREATE2 salt whose address enables only V4's before-initialize callback.
/// @dev The init-code hash is computed once by the caller so mining hashes only the CREATE2
/// preimage on each iteration. The search bound matches Uniswap V4's HookMiner utility.
library LaunchpadHookMiner {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 internal constant MAX_LOOP = 160_444;

    error HookAddressNotFound();

    function find(address deployer, bytes32 initCodeHash)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        for (uint256 i; i < MAX_LOOP; ++i) {
            salt = bytes32(i);
            hookAddress = Create2.computeAddress(salt, initCodeHash, deployer);
            if (uint160(hookAddress) & Hooks.ALL_HOOK_MASK == Hooks.BEFORE_INITIALIZE_FLAG) {
                return (hookAddress, salt);
            }
        }
        revert HookAddressNotFound();
    }
}
