// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { ERC20PermitBase } from "../src/ERC20PermitBase.sol";
import { LaunchToken } from "../src/LaunchToken.sol";
import { LpTokenVault } from "../src/LpTokenVault.sol";
import { TokenLaunchpad } from "../src/TokenLaunchpad.sol";
import { LpTokenTestBase } from "./utils/LpTokenTestBase.sol";

/// @notice Stock OpenZeppelin permit token, used to pin this suite's digest helper to the
/// audited implementation before the helper is trusted against our own tokens.
contract ReferencePermitToken is ERC20, ERC20Permit {
    constructor(string memory name_) ERC20(name_, "REF") ERC20Permit(name_) {
        _mint(msg.sender, 1_000e18);
    }
}

/// @notice EIP-2612 on both protocol tokens. Every digest here is assembled the way a client
/// does it — domain name read from `name()` — so these also pin that a wallet following the
/// convention agrees with the contract.
contract ERC20PermitTest is LpTokenTestBase {
    TokenLaunchpad internal launchpad;
    LaunchToken internal launchToken;
    LpTokenVault internal vault;

    uint256 internal ownerKey = 0xA11CE;
    address internal signer;
    address internal spender = makeAddr("spender");

    function setUp() public override {
        super.setUp();
        signer = vm.addr(ownerKey);

        launchpad = _deployLaunchpad(manager, factory, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE);
        vm.prank(owner);
        factory.bindLaunchpad(address(launchpad));

        address creator = makeAddr("launch-creator");
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        (address token,,) = launchpad.createToken{ value: LAUNCH_INITIAL_LP_QUOTE }(
            TokenLaunchpad.TokenMetadata({
                name: "Permit Cat",
                symbol: "PCAT",
                imageUrl: "ipfs://permit",
                websiteUrl: "https://example.com",
                twitterHandle: "permit_cat",
                telegramHandle: "permit_cat"
            }),
            keccak256("permit"),
            0,
            0,
            LAUNCH_START_TICK,
            LAUNCH_INITIAL_LP_QUOTE,
            block.timestamp
        );
        launchToken = LaunchToken(token);

        PoolKey memory key = _erc20Key(address(cashcat), address(usdg));
        _initLivePool(key, 0);
        vault = _launch(address(cashcat), key, 1_000e18, 1_000e6);
    }

    /// Builds the digest the way a client would: the domain name is whatever `name()` says.
    function _digest(
        address token,
        address approvedSpender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) private view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(IERC20Metadata(token).name())),
                keccak256("1"),
                block.chainid,
                token
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                signer,
                approvedSpender,
                value,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _sign(address token, uint256 value, uint256 deadline)
        private
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        return vm.sign(
            ownerKey, _digest(token, spender, value, IERC20Permit(token).nonces(signer), deadline)
        );
    }

    /// The helper must reproduce OpenZeppelin's own digest, otherwise everything below only
    /// proves that our contracts agree with this file.
    function testDigestHelperMatchesOpenZeppelin() public {
        ReferencePermitToken referenceToken = new ReferencePermitToken("Permit Cat");
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(referenceToken), 5e18, block.timestamp + 1);

        referenceToken.permit(signer, spender, 5e18, block.timestamp + 1, v, r, s);
        assertEq(referenceToken.allowance(signer, spender), 5e18);
    }

    function testLaunchTokenPermitApproves() public {
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(launchToken), 7e18, deadline);

        launchToken.permit(signer, spender, 7e18, deadline, v, r, s);

        assertEq(launchToken.allowance(signer, spender), 7e18);
        assertEq(launchToken.nonces(signer), 1);
    }

    function testVaultPermitApproves() public {
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(vault), 9e18, deadline);

        vault.permit(signer, spender, 9e18, deadline, v, r, s);

        assertEq(vault.allowance(signer, spender), 9e18);
        assertEq(vault.nonces(signer), 1);
    }

    /// The vault's name is resolved per clone from its target, so the domain must follow it
    /// rather than anything captured when the implementation was constructed.
    function testVaultDomainUsesItsOwnDerivedName() public view {
        assertEq(vault.name(), "lpCash Cat");
        assertEq(
            vault.DOMAIN_SEPARATOR(),
            keccak256(
                abi.encode(
                    keccak256(
                        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                    ),
                    keccak256(bytes("lpCash Cat")),
                    keccak256("1"),
                    block.chainid,
                    address(vault)
                )
            )
        );
    }

    /// Two vaults share one implementation, so a domain captured at its construction would
    /// make this signature replayable across every market.
    function testVaultPermitIsNotReplayableOnAnotherVault() public {
        PoolKey memory key = _erc20Key(address(weth), address(usdg));
        _initLivePool(key, 0);
        LpTokenVault other = _launch(address(weth), key, 10e18, 10_000e6);
        assertTrue(other.DOMAIN_SEPARATOR() != vault.DOMAIN_SEPARATOR());

        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(vault), 9e18, deadline);

        vm.expectPartialRevert(ERC20PermitBase.ERC2612InvalidSigner.selector);
        other.permit(signer, spender, 9e18, deadline, v, r, s);
    }

    function testPermitRejectsAnExpiredDeadline() public {
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(launchToken), 1e18, deadline);

        vm.expectRevert(
            abi.encodeWithSelector(ERC20PermitBase.ERC2612ExpiredSignature.selector, deadline)
        );
        launchToken.permit(signer, spender, 1e18, deadline, v, r, s);
    }

    /// A signature for one field set must not authorize another, and the nonce must burn.
    function testPermitRejectsTamperedValueAndReplay() public {
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(launchToken), 1e18, deadline);

        vm.expectPartialRevert(ERC20PermitBase.ERC2612InvalidSigner.selector);
        launchToken.permit(signer, spender, 2e18, deadline, v, r, s);

        launchToken.permit(signer, spender, 1e18, deadline, v, r, s);

        vm.expectPartialRevert(ERC20PermitBase.ERC2612InvalidSigner.selector);
        launchToken.permit(signer, spender, 1e18, deadline, v, r, s);
    }

    function testEip712DomainReportsTheSigningDomain() public view {
        (
            bytes1 fields,
            string memory domainName,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = vault.eip712Domain();

        assertEq(fields, hex"0f");
        assertEq(domainName, vault.name());
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(vault));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    // --- Standing Permit2 allowance ----------------------------------------------------

    function testPermit2ConstantIsTheCanonicalSingleton() public view {
        assertEq(launchToken.PERMIT2(), 0x000000000022D473030F116dDEE9F6B43aC78BA3);
        assertEq(vault.PERMIT2(), launchToken.PERMIT2());
    }

    function testPermit2AllowanceIsInfiniteWithoutAnApproval() public view {
        assertEq(launchToken.allowance(signer, launchToken.PERMIT2()), type(uint256).max);
        assertEq(vault.allowance(signer, vault.PERMIT2()), type(uint256).max);
    }

    /// The point of the standing allowance: Permit2 moves tokens with no approval behind it,
    /// and spending never writes the allowance down.
    function testPermit2TransfersWithoutAnApprovalAndKeepsInfinity() public {
        address permit2 = launchToken.PERMIT2();

        deal(address(launchToken), signer, 10e18);
        vm.prank(permit2);
        launchToken.transferFrom(signer, spender, 4e18);
        assertEq(launchToken.balanceOf(spender), 4e18);
        assertEq(launchToken.allowance(signer, permit2), type(uint256).max);

        deal(address(vault), signer, 10e18);
        vm.prank(permit2);
        vault.transferFrom(signer, spender, 4e18);
        assertEq(vault.balanceOf(spender), 4e18);
        assertEq(vault.allowance(signer, permit2), type(uint256).max);
    }

    /// Everyone else keeps ordinary ERC-20 semantics, including the spend-down.
    function testOrdinarySpenderIsUnaffected() public {
        deal(address(launchToken), signer, 10e18);
        assertEq(launchToken.allowance(signer, spender), 0);

        vm.prank(spender);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        launchToken.transferFrom(signer, spender, 1e18);

        vm.prank(signer);
        launchToken.approve(spender, 3e18);
        vm.prank(spender);
        launchToken.transferFrom(signer, spender, 1e18);
        assertEq(launchToken.allowance(signer, spender), 2e18);
    }

    /// A finite approval for Permit2 could never take effect, so it is refused rather than
    /// widened into the infinite grant the caller did not ask for.
    function testApprovingPermit2ForLessIsRejected() public {
        address permit2 = launchToken.PERMIT2();

        vm.prank(signer);
        vm.expectRevert(ERC20PermitBase.Permit2AllowanceIsFixedAtInfinity.selector);
        launchToken.approve(permit2, 5e18);

        vm.prank(signer);
        vm.expectRevert(ERC20PermitBase.Permit2AllowanceIsFixedAtInfinity.selector);
        launchToken.approve(permit2, 0);

        assertEq(launchToken.allowance(signer, permit2), type(uint256).max);
    }

    /// Approving what the token already reports is the one accepted amount.
    function testApprovingPermit2ForInfinityIsAccepted() public {
        address permit2 = vault.PERMIT2();

        vm.expectEmit(true, true, false, true, address(vault));
        emit IERC20.Approval(signer, permit2, type(uint256).max);
        vm.prank(signer);
        vault.approve(permit2, type(uint256).max);

        assertEq(vault.allowance(signer, permit2), type(uint256).max);
    }

    /// A signed approval is held to the same rule as an on-chain one.
    function testPermitNamingPermit2ForLessIsRejected() public {
        address permit2 = vault.PERMIT2();
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            ownerKey, _digest(address(vault), permit2, 5e18, vault.nonces(signer), deadline)
        );

        vm.expectRevert(ERC20PermitBase.Permit2AllowanceIsFixedAtInfinity.selector);
        vault.permit(signer, permit2, 5e18, deadline, v, r, s);
    }
}
