// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { Script } from "forge-std/Script.sol";

abstract contract DeploymentBase is Script {
    error InvalidAddress();
    error InvalidChain(uint256 expected, uint256 actual);
    error InvalidCodeHash(address target, bytes32 expected, bytes32 actual);
    error MissingCode(address target);

    function _requireChain(uint256 expectedChainId) internal view {
        if (block.chainid != expectedChainId) revert InvalidChain(expectedChainId, block.chainid);
    }

    function _requireNonzeroAddress(address target) internal pure {
        if (target == address(0)) revert InvalidAddress();
    }

    function _requireCodeHash(address target, bytes32 expected) internal view {
        _requireNonzeroAddress(target);
        if (target.code.length == 0) revert MissingCode(target);
        bytes32 actual = target.codehash;
        if (expected == bytes32(0) || actual != expected) {
            revert InvalidCodeHash(target, expected, actual);
        }
    }
}
