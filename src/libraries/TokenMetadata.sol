// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

/// @notice Guarded reader for another token's `name()`/`symbol()`. The Factory admits a
/// curated target only when both read as strings, and `LpTokenVault` keeps reading them
/// live afterwards, so the read itself must never be the failure: it reports instead of
/// re-raising, and it is gas- and size-capped so a hostile target can make its metadata
/// unavailable but never this call unaffordable.
library TokenMetadata {
    /// @dev An honest metadata read is a short storage read, orders of magnitude inside
    /// both caps.
    uint256 internal constant GAS_LIMIT = 100_000;
    uint256 internal constant BYTES_LIMIT = 512;

    /// @notice Reads `selector` on `token` as one decodable string whose declared bounds
    /// fit inside the returndata. `ok` is false — never a revert — for everything else: a
    /// reverting or gas-burning target, returndata that is not that string shape, or a
    /// flood past the cap, which is size-checked before anything is copied.
    function read(address token, bytes4 selector)
        internal
        view
        returns (bool ok, string memory value)
    {
        bool success;
        uint256 size;
        assembly ("memory-safe") {
            mstore(0x00, selector)
            success := staticcall(GAS_LIMIT, token, 0x00, 0x04, 0x00, 0x00)
            size := returndatasize()
        }
        if (!success || size < 64 || size > BYTES_LIMIT) return (false, "");
        bytes memory data = new bytes(size);
        assembly ("memory-safe") {
            returndatacopy(add(data, 0x20), 0x00, size)
        }
        (uint256 offset, uint256 length) = abi.decode(data, (uint256, uint256));
        if (offset != 32 || length > size - 64) return (false, "");
        return (true, abi.decode(data, (string)));
    }
}
