// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import { LaunchpadHookMiner } from "../../script/LaunchpadHookMiner.sol";
import { LpTokenFactory } from "../../src/LpTokenFactory.sol";
import { TokenLaunchpad } from "../../src/TokenLaunchpad.sol";

abstract contract LaunchpadTestDeployer {
    error UnexpectedLaunchpadAddress(address expected, address actual);

    function _deployLaunchpad(
        IPoolManager manager,
        LpTokenFactory factory,
        int24 startTick,
        uint256 initialLpQuote
    ) internal returns (TokenLaunchpad launchpad) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(TokenLaunchpad).creationCode,
                abi.encode(manager, factory, startTick, initialLpQuote)
            )
        );
        (address expected, bytes32 salt) = LaunchpadHookMiner.find(address(this), initCodeHash);
        launchpad = new TokenLaunchpad{ salt: salt }(manager, factory, startTick, initialLpQuote);
        // `expectRevert` resumes this helper with a sentinel result after a rejected constructor.
        if (address(launchpad).code.length != 0 && address(launchpad) != expected) {
            revert UnexpectedLaunchpadAddress(expected, address(launchpad));
        }
    }
}
