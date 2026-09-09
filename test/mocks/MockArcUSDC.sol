// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Vm } from "forge-std/Vm.sol";

/// @notice Models Arc's two views of one balance: native wei and six-decimal ERC-20 USDC.
/// @dev Transfers use a journaled native transfer without invoking the recipient. The
/// test-only CREATE changes nonces and gas, so this is not a precompile gas/nonce model.
/// Only fixture minting uses vm.deal; using it in transfers would break revert atomicity.
contract MockArcUSDC is IERC20Metadata {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant SCALE = 1e12;

    uint256 public override totalSupply;
    mapping(address holder => mapping(address spender => uint256 amount)) public override allowance;

    function name() external pure returns (string memory) {
        return "USD Coin";
    }

    function symbol() external pure returns (string memory) {
        return "USDC";
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function balanceOf(address holder) public view returns (uint256) {
        return holder.balance / SCALE;
    }

    function mint(address recipient, uint256 amount) external {
        totalSupply += amount;
        VM.deal(recipient, recipient.balance + amount * SCALE);
        emit Transfer(address(0), recipient, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount)
        external
        returns (bool)
    {
        uint256 approved = allowance[sender][msg.sender];
        if (approved != type(uint256).max) {
            require(approved >= amount, "Insufficient allowance");
            allowance[sender][msg.sender] = approved - amount;
        }
        _transfer(sender, recipient, amount);
        return true;
    }

    function _transfer(address sender, address recipient, uint256 amount) private {
        require(recipient != address(0), "Invalid recipient");
        uint256 nativeAmount = amount * SCALE;
        require(sender.balance >= nativeAmount, "Insufficient balance");
        if (sender != recipient && nativeAmount != 0) {
            VM.prank(sender);
            new ArcUSDCForceSend{ value: nativeAmount }(payable(recipient));
        }
        emit Transfer(sender, recipient, amount);
    }
}

    /// @dev Created and destroyed in the same transaction, bypassing native receive hooks.
    contract ArcUSDCForceSend {
        constructor(address payable recipient) payable {
            selfdestruct(recipient);
        }
    }
