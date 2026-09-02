// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

import { CurrencyTransfer } from "../src/libraries/CurrencyTransfer.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { NativeRejector, TaxedERC20 } from "./mocks/TestActors.sol";

contract CurrencyTransferHarness {
    receive() external payable { }

    function pullExact(address token, address payer, uint256 amount) external {
        CurrencyTransfer.pullExact(token, payer, amount);
    }

    function transfer(Currency currency, address receiver, uint256 amount) external {
        CurrencyTransfer.transfer(currency, receiver, amount);
    }

    function tryTransfer(Currency currency, address receiver, uint256 amount)
        external
        returns (bool)
    {
        return CurrencyTransfer.tryTransfer(currency, receiver, amount, 30_000);
    }
}

contract TransferReturnToken {
    enum Behavior {
        True,
        False,
        Empty,
        Malformed,
        Oversized,
        Revert
    }

    Behavior public behavior;

    function setBehavior(Behavior behavior_) external {
        behavior = behavior_;
    }

    fallback() external {
        if (msg.sig != IERC20.transfer.selector) revert();
        Behavior selected = behavior;
        if (selected == Behavior.Revert) revert();
        if (selected == Behavior.Empty) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (selected == Behavior.Malformed) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (selected == Behavior.Oversized) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 64)
            }
        }
        uint256 returned = selected == Behavior.True ? 1 : 0;
        assembly ("memory-safe") {
            mstore(0, returned)
            return(0, 32)
        }
    }
}

contract CurrencyTransferTest is Test {
    CurrencyTransferHarness private harness;
    address private receiver = makeAddr("currency receiver");

    function setUp() public {
        harness = new CurrencyTransferHarness();
    }

    function testPullExactAcceptsStandardTokenAndRejectsTaxedToken() public {
        MockERC20 standard = new MockERC20("Standard", "STD", 18);
        standard.mint(address(this), 10 ether);
        standard.approve(address(harness), 10 ether);
        harness.pullExact(address(standard), address(this), 10 ether);
        assertEq(standard.balanceOf(address(harness)), 10 ether);

        TaxedERC20 taxed = new TaxedERC20();
        taxed.mint(address(this), 10 ether);
        taxed.approve(address(harness), 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(CurrencyTransfer.TaxedOrRebasingToken.selector, address(taxed))
        );
        harness.pullExact(address(taxed), address(this), 10 ether);
    }

    function testTransferHandlesZeroNativeAndErc20Paths() public {
        NativeRejector rejector = new NativeRejector();
        harness.transfer(Currency.wrap(address(0)), address(rejector), 0);

        vm.deal(address(harness), 2 ether);
        uint256 receiverBefore = receiver.balance;
        harness.transfer(Currency.wrap(address(0)), receiver, 1 ether);
        assertEq(receiver.balance - receiverBefore, 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                CurrencyTransfer.NativeTransferFailed.selector, address(rejector), 1 ether
            )
        );
        harness.transfer(Currency.wrap(address(0)), address(rejector), 1 ether);

        MockERC20 token = new MockERC20("Transfer", "XFER", 18);
        token.mint(address(harness), 5 ether);
        harness.transfer(Currency.wrap(address(token)), receiver, 5 ether);
        assertEq(token.balanceOf(receiver), 5 ether);
    }

    function testTryTransferHandlesNativeSuccessAndFailure() public {
        vm.deal(address(harness), 2 ether);
        assertTrue(harness.tryTransfer(Currency.wrap(address(0)), receiver, 1 ether));
        assertEq(receiver.balance, 1 ether);

        NativeRejector rejector = new NativeRejector();
        assertFalse(harness.tryTransfer(Currency.wrap(address(0)), address(rejector), 1 ether));
        assertEq(address(harness).balance, 1 ether);
    }

    function testTryTransferAcceptsOnlyCanonicalErc20ReturnValues() public {
        TransferReturnToken token = new TransferReturnToken();
        Currency currency = Currency.wrap(address(token));

        token.setBehavior(TransferReturnToken.Behavior.True);
        assertTrue(harness.tryTransfer(currency, receiver, 1));

        token.setBehavior(TransferReturnToken.Behavior.False);
        assertFalse(harness.tryTransfer(currency, receiver, 1));

        token.setBehavior(TransferReturnToken.Behavior.Empty);
        assertTrue(harness.tryTransfer(currency, receiver, 1));

        token.setBehavior(TransferReturnToken.Behavior.Malformed);
        assertFalse(harness.tryTransfer(currency, receiver, 1));

        token.setBehavior(TransferReturnToken.Behavior.Oversized);
        assertFalse(harness.tryTransfer(currency, receiver, 1));

        token.setBehavior(TransferReturnToken.Behavior.Revert);
        assertFalse(harness.tryTransfer(currency, receiver, 1));
    }
}
