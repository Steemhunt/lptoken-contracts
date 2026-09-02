// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice Mintable ERC-20 that also accepts EIP-2612 approvals, standing in for a counter
/// currency that supports them — the reviewed chain's canonical stablecoin does. Kept
/// separate from `MockERC20`, whose `decimals` and `_update` are not virtual.
contract MockPermitERC20 is ERC20, ERC20Permit {
    uint8 private immutable _tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
