// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { DeploymentBase } from "../script/DeploymentBase.s.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract DeploymentBaseHarness is DeploymentBase {
    function requireChain(uint256 expectedChainId) external view {
        _requireChain(expectedChainId);
    }

    function requireNonzeroAddress(address target) external pure {
        _requireNonzeroAddress(target);
    }

    function requireCodeHash(address target, bytes32 expected) external view {
        _requireCodeHash(target, expected);
    }
}

contract DeploymentBaseTest is Test {
    DeploymentBaseHarness private harness;

    function setUp() public {
        harness = new DeploymentBaseHarness();
    }

    function testChainAndAddressValidation() public view {
        harness.requireChain(block.chainid);
        harness.requireNonzeroAddress(address(1));
    }

    function testChainAndAddressValidationRejectsMismatchAndZero() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentBase.InvalidChain.selector, block.chainid + 1, block.chainid
            )
        );
        harness.requireChain(block.chainid + 1);

        vm.expectRevert(DeploymentBase.InvalidAddress.selector);
        harness.requireNonzeroAddress(address(0));
    }

    function testCodeHashValidationAcceptsReviewedContract() public {
        MockERC20 token = new MockERC20("Code", "CODE", 18);
        harness.requireCodeHash(address(token), address(token).codehash);
    }

    function testCodeHashValidationRejectsInvalidTargetsAndHashes() public {
        vm.expectRevert(DeploymentBase.InvalidAddress.selector);
        harness.requireCodeHash(address(0), bytes32(uint256(1)));

        address noCode = makeAddr("no deployment code");
        vm.expectRevert(abi.encodeWithSelector(DeploymentBase.MissingCode.selector, noCode));
        harness.requireCodeHash(noCode, bytes32(uint256(1)));

        MockERC20 token = new MockERC20("Code", "CODE", 18);
        bytes32 actual = address(token).codehash;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentBase.InvalidCodeHash.selector, address(token), bytes32(0), actual
            )
        );
        harness.requireCodeHash(address(token), bytes32(0));

        bytes32 wrong = bytes32(uint256(actual) ^ 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentBase.InvalidCodeHash.selector, address(token), wrong, actual
            )
        );
        harness.requireCodeHash(address(token), wrong);
    }
}
