// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Nonces } from "@openzeppelin/contracts/utils/Nonces.sol";

/// @notice Signed approvals for this protocol's two ERC-20s: EIP-2612 under an EIP-712 domain
/// named by `name()`, plus a standing infinite allowance for the canonical Permit2 singleton.
/// @dev OpenZeppelin's `ERC20Permit` fixes the domain name at construction, which neither token
/// can use. `LpTokenVault` is a clone: its constructor runs once for the implementation, so a
/// name captured there would be shared by every vault while `name()` resolves per clone from
/// its own target. `LaunchToken` could capture its name, but reading it keeps one rule for both
/// and costs one hash of a short string per call. Deriving the domain from `name()` therefore
/// makes the mismatch that breaks a signature unrepresentable: a client that assembles the
/// domain from the token name, as EIP-2612 suggests, always agrees with this contract.
/// The domain is still reported by `eip712Domain()` for clients that read it (ERC-5267).
///
/// A name that changes changes the domain with it, invalidating signatures made under the old
/// one. Both tokens read a fixed name in practice — `LaunchToken` sets it once at deployment,
/// and a vault's name follows its target's — so this only reaches a vault curated onto a token
/// that renames itself, which is the same class of behavior the curated path already accepts.
abstract contract ERC20PermitBase is ERC20, Nonces, IERC20Permit {
    bytes32 private constant _DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant _PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );
    /// @dev The EIP-712 domain version is `"1"` for both tokens.
    bytes32 private constant _VERSION_HASH = keccak256("1");

    /// @notice Uniswap's Permit2, which holds a standing infinite allowance on both tokens.
    /// @dev Permit2 is immutable and goes out through the deterministic CREATE2 proxy, which
    /// lands it here on every chain deriving addresses the usual way, the reviewed Robinhood
    /// deployment included; the fork suite pins its codehash there. Chains that derive
    /// addresses differently, zkSync and the zkStack chains, carry Permit2 at another address
    /// instead, leaving this one empty. Deploying this bytecode there by hand would grant
    /// nobody anything and deliver none of the benefit; `DeployLpToken` refuses instead, since
    /// it requires the reviewed code at this address before broadcasting. Supporting such a
    /// chain therefore means moving the bound address, alongside the separately mined hook
    /// deployment those chains also break. The address is hardcoded because solady hardcodes
    /// it, so the tokens this pattern comes from carry the same bound.
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    error ERC2612ExpiredSignature(uint256 deadline);
    error ERC2612InvalidSigner(address signer, address owner);
    error Permit2AllowanceIsFixedAtInfinity();

    /// @notice Allowance of `spender` over `owner`'s tokens, always infinite for Permit2.
    /// @dev This removes the approval transaction, not the authorization: Permit2 moves nothing
    /// until the owner authorizes a spender at the Permit2 layer, by signature or by calling
    /// Permit2's own `approve`. On the `AllowanceTransfer` path this repository uses, that
    /// authorization is a stored record — spender, amount, expiration — and later transfers draw
    /// it down without a further signature, so one authorization covers repeated transfers until
    /// its amount is spent, it expires, or the owner revokes it at the Permit2 layer.
    /// `_spendAllowance` reads this value and skips its write once the allowance is infinite,
    /// which is also what makes Permit2's `transferFrom` bypass the allowance path entirely.
    function allowance(address owner, address spender)
        public
        view
        virtual
        override
        returns (uint256)
    {
        if (spender == PERMIT2) return type(uint256).max;
        return super.allowance(owner, spender);
    }

    /// @dev A finite approval for Permit2 cannot take effect, because `allowance` reports
    /// infinity regardless. Rejecting it says so, which is what solady does. Raising it to
    /// infinity instead would let the call read as a bounded grant while granting everything,
    /// and quietly widening an approval past what its caller asked for is worse than refusing
    /// a call that could never have meant what it said.
    function _approve(address owner, address spender, uint256 value, bool emitEvent)
        internal
        virtual
        override
    {
        if (spender == PERMIT2 && value != type(uint256).max) {
            revert Permit2AllowanceIsFixedAtInfinity();
        }
        super._approve(owner, spender, value, emitEvent);
    }

    /// @inheritdoc IERC20Permit
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() public view virtual returns (bytes32) {
        return keccak256(
            abi.encode(
                _DOMAIN_TYPEHASH,
                keccak256(bytes(name())),
                _VERSION_HASH,
                block.chainid,
                address(this)
            )
        );
    }

    /// @notice Reports this token's EIP-712 domain, as ERC-5267.
    /// @dev `fields` is `0x0f`: name, version, chainId, and verifyingContract are used.
    function eip712Domain()
        external
        view
        virtual
        returns (
            bytes1 fields,
            string memory domainName,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        return (hex"0f", name(), "1", block.chainid, address(this), bytes32(0), new uint256[](0));
    }

    /// @inheritdoc IERC20Permit
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual {
        if (block.timestamp > deadline) revert ERC2612ExpiredSignature(deadline);

        bytes32 structHash = keccak256(
            abi.encode(_PERMIT_TYPEHASH, owner, spender, value, _useNonce(owner), deadline)
        );
        address signer = ECDSA.recover(
            MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR(), structHash), v, r, s
        );
        if (signer != owner) revert ERC2612InvalidSigner(signer, owner);

        _approve(owner, spender, value);
    }

    /// @inheritdoc IERC20Permit
    function nonces(address owner)
        public
        view
        virtual
        override(IERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
