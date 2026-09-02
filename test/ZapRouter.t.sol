// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { IWETH9 } from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import { Vm } from "forge-std/Vm.sol";

import { LpTokenVault } from "../src/LpTokenVault.sol";
import { TokenLaunchpad } from "../src/TokenLaunchpad.sol";
import { ILpTokenFactory } from "../src/interfaces/ILpTokenFactory.sol";
import { ILpTokenVault } from "../src/interfaces/ILpTokenVault.sol";
import { ZapRouter } from "../src/periphery/ZapRouter.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockPermitERC20 } from "./mocks/MockPermitERC20.sol";
import { MockWETH } from "./mocks/MockWETH.sol";
import { TaxedERC20, TaxedLiquidityProvider } from "./mocks/TestActors.sol";
import { LpTokenTestBase } from "./utils/LpTokenTestBase.sol";

/// @dev A permit that verifies the real signature — the unsigned probe is rejected, a real one
/// is accepted — and grants nothing: the class no off-chain check can see, since its permit
/// call succeeds, and the reason the router checks the allowance it was to leave.
contract PhantomPermitERC20 is MockPermitERC20 {
    constructor(string memory name_, string memory symbol_) MockPermitERC20(name_, symbol_, 18) { }

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public override {
        super.permit(owner, spender, value, deadline, v, r, s);
        _approve(owner, spender, 0);
    }
}

contract ZapRouterTest is LpTokenTestBase {
    using StateLibrary for IPoolManager;

    PoolKey internal erc20Key;
    LpTokenVault internal erc20Vault;
    PoolKey internal nativeKey;
    LpTokenVault internal nativeVault;
    PoolKey internal nativeUsdgKey;
    MockWETH internal routeWeth;
    ZapRouter internal router;

    uint256 internal permitKey = 0xB0B0B;
    address internal permitSigner;
    MockPermitERC20 internal permitStable;
    ZapRouter internal permitRouter;
    PoolKey internal permitStableNativeKey;

    function setUp() public override {
        super.setUp();
        routeWeth = new MockWETH();
        router = new ZapRouter(factory, address(usdg), IWETH9(address(routeWeth)));

        erc20Key = _erc20Key(address(cashcat), address(usdg));
        _initLivePool(erc20Key, 0);
        erc20Vault = _launch(address(cashcat), erc20Key, 1_000e18, 1_000e18);

        nativeKey = _nativeKey(address(tok8));
        _initLivePool(nativeKey, 0);
        nativeVault = _launch(address(tok8), nativeKey, 1_000e18, 1_000e18);

        nativeUsdgKey = _nativeKey(address(usdg));
        _initLivePool(nativeUsdgKey, 0);

        permitSigner = vm.addr(permitKey);
        permitStable = new MockPermitERC20("Permit Stable", "PUSD", 18);
        permitRouter = new ZapRouter(factory, address(permitStable), IWETH9(address(routeWeth)));
        permitStableNativeKey = _nativeKey(address(permitStable));
        _initLivePool(permitStableNativeKey, 0);
    }

    function testVersion() public view {
        assertEq(router.version(), "2.0");
    }

    // --- Carried EIP-2612 approvals ----------------------------------------------------

    /// Builds the digest the client builds: the domain name is the token's own `name()`.
    function _permitDigest(address token, address spender, uint256 value, uint256 deadline)
        private
        view
        returns (bytes32)
    {
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
                permitSigner,
                spender,
                value,
                IERC20Permit(token).nonces(permitSigner),
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _signPermit(address token, address spender, uint256 value, uint256 deadline)
        private
        view
        returns (ZapRouter.PermitSignature memory permitSignature)
    {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(permitKey, _permitDigest(token, spender, value, deadline));
        return ZapRouter.PermitSignature(value, deadline, v, r, s);
    }

    /// The lpTOKEN share carries EIP-2612, so exiting needs no approval transaction.
    function testZapOutWithPermitNeedsNoApproval() public {
        uint256 shares = _mintSharesErc20(permitSigner, 100e18, 100e18);
        assertEq(erc20Vault.allowance(permitSigner, address(router)), 0);

        ZapRouter.PermitSignature memory permitSignature =
            _signPermit(address(erc20Vault), address(router), shares, block.timestamp + 1 days);

        vm.prank(permitSigner);
        uint256 counterOut = router.zapOutWithPermit(
            _asVault(erc20Vault), shares, 1, permitSigner, block.timestamp, permitSignature
        );

        assertGt(counterOut, 0);
        assertEq(erc20Vault.balanceOf(permitSigner), 0);
        assertEq(usdg.balanceOf(permitSigner), counterOut);
        _assertNoResidue(address(erc20Vault));
    }

    function testZapOutTargetWithPermitNeedsNoApproval() public {
        uint256 shares = _mintSharesErc20(permitSigner, 100e18, 100e18);
        uint256 targetBefore = cashcat.balanceOf(permitSigner);
        assertEq(erc20Vault.allowance(permitSigner, address(router)), 0);

        ZapRouter.PermitSignature memory permitSignature =
            _signPermit(address(erc20Vault), address(router), shares, block.timestamp + 1 days);

        vm.prank(permitSigner);
        uint256 targetOut = router.zapOutTargetWithPermit(
            _asVault(erc20Vault), shares, 1, permitSigner, block.timestamp, permitSignature
        );

        assertGt(targetOut, 0);
        assertEq(erc20Vault.balanceOf(permitSigner), 0);
        assertEq(cashcat.balanceOf(permitSigner), targetBefore + targetOut);
        _assertNoResidue(address(erc20Vault));
    }

    /// A permit signature is relayable, so a front-runner spending its nonce must not sink
    /// the zap: the approval it granted is already in place.
    function testZapOutSurvivesAFrontRunPermit() public {
        uint256 shares = _mintSharesErc20(permitSigner, 100e18, 100e18);
        ZapRouter.PermitSignature memory permitSignature =
            _signPermit(address(erc20Vault), address(router), shares, block.timestamp + 1 days);

        vm.prank(alice);
        IERC20Permit(address(erc20Vault))
            .permit(
                permitSigner,
                address(router),
                permitSignature.value,
                permitSignature.deadline,
                permitSignature.v,
                permitSignature.r,
                permitSignature.s
            );
        assertEq(erc20Vault.allowance(permitSigner, address(router)), shares);

        vm.prank(permitSigner);
        assertGt(
            router.zapOutWithPermit(
                _asVault(erc20Vault), shares, 1, permitSigner, block.timestamp, permitSignature
            ),
            0
        );
    }

    /// Swallowing the permit failure must not swallow the missing allowance behind it: a
    /// carried approval that left the allowance short is reported as its own failure, which
    /// is how a client tells it from every other reason the call might fail.
    function testUnusablePermitIsReportedAsNotGranted() public {
        uint256 shares = _mintSharesErc20(permitSigner, 100e18, 100e18);
        ZapRouter.PermitSignature memory permitSignature =
            _signPermit(address(erc20Vault), address(router), shares, block.timestamp + 1 days);
        permitSignature.r = bytes32(uint256(permitSignature.r) ^ 1);

        vm.prank(permitSigner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ZapRouter.CarriedApprovalNotGranted.selector, address(erc20Vault)
            )
        );
        router.zapOutWithPermit(
            _asVault(erc20Vault), shares, 1, permitSigner, block.timestamp, permitSignature
        );
    }

    /// A permit that verifies the signature and grants nothing cannot be told apart from a
    /// working one by any call made before the pull; the router sees the allowance it left
    /// and reports exactly that, on the counter of a zap in and on the target of a pair mint.
    function testPermitThatGrantsNothingIsReportedAsNotGranted() public {
        PhantomPermitERC20 counter = new PhantomPermitERC20("Phantom Dollar", "PHUSD");
        MockERC20 target = new MockERC20("Phantom Target", "PHTGT", 18);
        PoolKey memory key = _erc20Key(address(target), address(counter));
        _initLivePool(key, 0);
        LpTokenVault vault = _launch(address(target), key, 1_000e18, 1_000e18);

        counter.mint(permitSigner, 100e18);
        ZapRouter.PermitSignature memory counterPermit =
            _signPermit(address(counter), address(router), 100e18, block.timestamp + 1 days);
        vm.prank(permitSigner);
        vm.expectRevert(
            abi.encodeWithSelector(ZapRouter.CarriedApprovalNotGranted.selector, address(counter))
        );
        router.zapInWithPermit(
            _asVault(vault), 100e18, 50e18, 1, 1, permitSigner, block.timestamp, counterPermit
        );

        PhantomPermitERC20 phantomTarget = new PhantomPermitERC20("Phantom Pair", "PHP");
        MockPermitERC20 pairCounter = new MockPermitERC20("Pair Dollar", "PUSD", 18);
        PoolKey memory pairKey = _erc20Key(address(phantomTarget), address(pairCounter));
        _initLivePool(pairKey, 0);
        LpTokenVault pairVault = _launch(address(phantomTarget), pairKey, 1_000e18, 1_000e18);

        phantomTarget.mint(permitSigner, 100e18);
        pairCounter.mint(permitSigner, 100e18);
        uint256 untilThen = block.timestamp + 1 days;
        ZapRouter.PermitSignature memory targetPermit =
            _signPermit(address(phantomTarget), address(router), 100e18, untilThen);
        ZapRouter.PermitSignature memory pairCounterPermit =
            _signPermit(address(pairCounter), address(router), 100e18, untilThen);
        vm.prank(permitSigner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ZapRouter.CarriedApprovalNotGranted.selector, address(phantomTarget)
            )
        );
        router.mintPairWithPermit(
            _asVault(pairVault),
            100e18,
            100e18,
            1,
            permitSigner,
            block.timestamp,
            targetPermit,
            pairCounterPermit
        );
    }

    /// An ERC-20 counter that carries EIP-2612 is paid the same way on the way in.
    function testZapInWithPermitNeedsNoApproval() public {
        MockPermitERC20 counter = new MockPermitERC20("Permit Dollar", "PUSD", 18);
        MockERC20 target = new MockERC20("Permit Target", "PTGT", 18);
        PoolKey memory key = _erc20Key(address(target), address(counter));
        _initLivePool(key, 0);
        LpTokenVault vault = _launch(address(target), key, 1_000e18, 1_000e18);

        counter.mint(permitSigner, 100e18);
        assertEq(counter.allowance(permitSigner, address(router)), 0);
        ZapRouter.PermitSignature memory permitSignature =
            _signPermit(address(counter), address(router), 100e18, block.timestamp + 1 days);

        vm.prank(permitSigner);
        (uint256 shares,,) = router.zapInWithPermit(
            _asVault(vault), 100e18, 50e18, 1, 1, permitSigner, block.timestamp, permitSignature
        );

        assertGt(shares, 0);
        assertEq(vault.balanceOf(permitSigner), shares);
    }

    /// A target-only zap carries the target approval and needs no approval transaction.
    function testZapInTargetWithPermitNeedsNoApproval() public {
        MockERC20 counter = new MockERC20("Target Zap Dollar", "TZUSD", 18);
        MockPermitERC20 target = new MockPermitERC20("Target Zap Token", "TZT", 18);
        PoolKey memory key = _erc20Key(address(target), address(counter));
        _initLivePool(key, 0);
        LpTokenVault vault = _launch(address(target), key, 1_000e18, 1_000e18);

        target.mint(permitSigner, 100e18);
        assertEq(target.allowance(permitSigner, address(router)), 0);
        ZapRouter.PermitSignature memory permitSignature =
            _signPermit(address(target), address(router), 100e18, block.timestamp + 1 days);

        vm.prank(permitSigner);
        (uint256 shares, uint256 targetUsed, uint256 counterUsed) = router.zapInTargetWithPermit(
            _asVault(vault), 100e18, 50e18, 1, 1, permitSigner, block.timestamp, permitSignature
        );

        assertGt(shares, 0);
        assertGt(targetUsed, 50e18);
        assertGt(counterUsed, 0);
        assertEq(vault.balanceOf(permitSigner), shares);
        assertEq(target.balanceOf(address(router)), 0);
        assertEq(counter.balanceOf(address(router)), 0);
    }

    /// The routed path spends the input currency, so its twin must carry the approval for
    /// that token — through a real hop, not an empty route.
    function testZapInRoutedWithPermitNeedsNoApproval() public {
        uint256 inputAmount = 100e18;
        permitStable.mint(permitSigner, inputAmount);
        assertEq(permitStable.allowance(permitSigner, address(permitRouter)), 0);

        ZapRouter.PermitSignature memory permitSignature = _signPermit(
            address(permitStable), address(permitRouter), inputAmount, block.timestamp + 1 days
        );

        vm.prank(permitSigner);
        (uint256 shares, uint256 targetUsed, uint256 counterUsed) = permitRouter.zapInRoutedWithPermit(
            _asVault(nativeVault),
            Currency.wrap(address(permitStable)),
            inputAmount,
            _single(permitStableNativeKey),
            1,
            1e18,
            1,
            1,
            permitSigner,
            block.timestamp,
            permitSignature
        );

        assertGt(shares, 0);
        assertGt(targetUsed, 0);
        assertGt(counterUsed, 1e18);
        assertEq(nativeVault.balanceOf(permitSigner), shares);
        assertEq(permitStable.balanceOf(address(permitRouter)), 0, "input residue");
        assertEq(
            permitStable.allowance(address(permitRouter), address(nativeVault)), 0, "input approval"
        );
        _assertNoResidue(address(permitRouter), address(nativeVault));
    }

    /// A pair mint through the router needs no approval on either leg, and the shares land
    /// with the receiver rather than resting here.
    function testMintPairWithPermitNeedsNoApproval() public {
        MockPermitERC20 counter = new MockPermitERC20("Pair Stable", "PUSD", 18);
        MockPermitERC20 target = new MockPermitERC20("Pair Target", "PTGT", 18);
        PoolKey memory key = _erc20Key(address(target), address(counter));
        _initLivePool(key, 0);
        LpTokenVault vault = _launch(address(target), key, 1_000e18, 1_000e18);

        target.mint(permitSigner, 100e18);
        counter.mint(permitSigner, 100e18);
        assertEq(target.allowance(permitSigner, address(router)), 0);
        assertEq(counter.allowance(permitSigner, address(router)), 0);

        uint256 untilThen = block.timestamp + 1 days;
        ZapRouter.PermitSignature memory targetPermit =
            _signPermit(address(target), address(router), 100e18, untilThen);
        ZapRouter.PermitSignature memory counterPermit =
            _signPermit(address(counter), address(router), 100e18, untilThen);

        vm.prank(permitSigner);
        (uint256 shares, uint256 targetUsed, uint256 counterUsed) = router.mintPairWithPermit(
            _asVault(vault),
            100e18,
            100e18,
            1,
            permitSigner,
            block.timestamp,
            targetPermit,
            counterPermit
        );

        assertGt(shares, 0);
        assertGt(targetUsed, 0);
        assertGt(counterUsed, 0);
        assertEq(vault.balanceOf(permitSigner), shares);
        assertEq(vault.balanceOf(address(router)), 0, "share residue");
        assertEq(target.balanceOf(address(router)), 0, "target residue");
        assertEq(counter.balanceOf(address(router)), 0, "counter residue");
        assertEq(target.allowance(address(router), address(vault)), 0, "target approval");
        assertEq(counter.allowance(address(router), address(vault)), 0, "counter approval");
        // Whatever the mint declined came back rather than staying behind.
        assertEq(target.balanceOf(permitSigner), 100e18 - targetUsed);
        assertEq(counter.balanceOf(permitSigner), 100e18 - counterUsed);
    }

    /// A native counter carries the value instead of an approval, so only the target signs.
    function testMintPairWithPermitTakesNativeCounter() public {
        MockPermitERC20 target = new MockPermitERC20("Native Pair Target", "NPT", 18);
        PoolKey memory key = _nativeKey(address(target));
        _initLivePool(key, 0);
        LpTokenVault vault = _launch(address(target), key, 1_000e18, 1_000e18);

        target.mint(permitSigner, 100e18);
        vm.deal(permitSigner, 1 ether);
        assertEq(target.allowance(permitSigner, address(router)), 0);

        ZapRouter.PermitSignature memory absent;
        ZapRouter.PermitSignature memory targetPermit =
            _signPermit(address(target), address(router), 100e18, block.timestamp + 1 days);

        vm.prank(permitSigner);
        (uint256 shares, uint256 targetUsed, uint256 counterUsed) = router.mintPairWithPermit{
            value: 0.05 ether
        }(
            _asVault(vault),
            100e18,
            0.05 ether,
            1,
            permitSigner,
            block.timestamp,
            targetPermit,
            absent
        );

        assertGt(shares, 0);
        assertGt(targetUsed, 0);
        assertGt(counterUsed, 0);
        assertEq(vault.balanceOf(permitSigner), shares);
        assertEq(address(router).balance, 0, "native residue");
        assertEq(target.balanceOf(address(router)), 0, "target residue");
        // The counter binds this mint, so most of the target approval goes unused and would
        // stand here if the reset were dropped.
        assertLt(targetUsed, 100e18, "expected the counter to bind the mint");
        assertEq(target.allowance(address(router), address(vault)), 0, "target approval");
        assertEq(permitSigner.balance, 1 ether - counterUsed, "native refund");
    }

    /// The mint credits `receiver`, but what it declines belongs to whoever paid.
    function testMintPairWithPermitRefundsThePayerNotTheReceiver() public {
        MockPermitERC20 counter = new MockPermitERC20("Split Stable", "SUSD", 18);
        MockPermitERC20 target = new MockPermitERC20("Split Target", "STGT", 18);
        PoolKey memory key = _erc20Key(address(target), address(counter));
        _initLivePool(key, 0);
        LpTokenVault vault = _launch(address(target), key, 1_000e18, 1_000e18);

        // A lopsided pair, so the mint has to decline part of one leg.
        target.mint(permitSigner, 100e18);
        counter.mint(permitSigner, 10e18);
        uint256 untilThen = block.timestamp + 1 days;
        ZapRouter.PermitSignature memory targetPermit =
            _signPermit(address(target), address(router), 100e18, untilThen);
        ZapRouter.PermitSignature memory counterPermit =
            _signPermit(address(counter), address(router), 10e18, untilThen);

        address shareReceiver = makeAddr("pair mint receiver");
        vm.recordLogs();
        vm.prank(permitSigner);
        (uint256 shares, uint256 targetUsed, uint256 counterUsed) = router.mintPairWithPermit(
            _asVault(vault),
            100e18,
            10e18,
            1,
            shareReceiver,
            block.timestamp,
            targetPermit,
            counterPermit
        );

        assertGt(shares, 0);
        assertLt(targetUsed, 100e18, "expected part of the target to be declined");
        assertEq(vault.balanceOf(shareReceiver), shares, "shares went elsewhere");
        assertEq(vault.balanceOf(permitSigner), 0, "payer received shares");
        assertEq(target.balanceOf(permitSigner), 100e18 - targetUsed, "target refund misrouted");
        assertEq(counter.balanceOf(permitSigner), 10e18 - counterUsed, "counter refund misrouted");
        assertEq(target.balanceOf(shareReceiver), 0, "receiver took the target refund");
        assertEq(counter.balanceOf(shareReceiver), 0, "receiver took the counter refund");

        // The vault's `PairMinted` names the router as the minter; the router's own event is
        // where the payer is, distinct from the receiver, alongside what the mint returned.
        Vm.Log memory routed = _routerLog(ZapRouter.RoutedPairMinted.selector);
        assertEq(routed.topics[1], bytes32(uint256(uint160(permitSigner))), "event sender");
        assertEq(routed.topics[2], bytes32(uint256(uint160(address(vault)))), "event vault");
        assertEq(routed.topics[3], bytes32(uint256(uint160(shareReceiver))), "event receiver");
        (uint256 loggedTarget, uint256 loggedCounter, uint256 loggedShares) =
            abi.decode(routed.data, (uint256, uint256, uint256));
        assertEq(loggedTarget, targetUsed, "event targetUsed");
        assertEq(loggedCounter, counterUsed, "event counterUsed");
        assertEq(loggedShares, shares, "event shares");
    }

    /// The one log the router emitted under `selector` in the recorded span.
    function _routerLog(bytes32 selector) private returns (Vm.Log memory found) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(router) && logs[i].topics[0] == selector) {
                found = logs[i];
                ++matches;
            }
        }
        assertEq(matches, 1, "router event count");
    }

    /// The router route must land the same mint the vault's own entry point lands.
    function testMintPairWithPermitMatchesTheVaultDirectly() public {
        uint256 snapshot = vm.snapshotState();
        _fundAndApprove(cashcat, bob, address(erc20Vault), 100e18);
        _fundAndApprove(usdg, bob, address(erc20Vault), 100e18);
        vm.prank(bob);
        (uint256 directShares, uint256 directTarget, uint256 directCounter) =
            erc20Vault.mintPair(100e18, 100e18, 1, bob, block.timestamp);
        vm.revertToState(snapshot);

        _fundAndApprove(cashcat, bob, address(router), 100e18);
        _fundAndApprove(usdg, bob, address(router), 100e18);
        ZapRouter.PermitSignature memory absent;
        vm.prank(bob);
        (uint256 routedShares, uint256 routedTarget, uint256 routedCounter) = router.mintPairWithPermit(
            _asVault(erc20Vault), 100e18, 100e18, 1, bob, block.timestamp, absent, absent
        );

        assertEq(routedShares, directShares, "shares diverged");
        assertEq(routedTarget, directTarget, "targetUsed diverged");
        assertEq(routedCounter, directCounter, "counterUsed diverged");
        _assertNoResidue(address(erc20Vault));
    }

    /// Each twin is the plain entry point called with nothing carried, so all three must
    /// land on exactly what the plain form lands on.
    function testEveryPermitVariantMatchesItsPlainForm() public {
        ZapRouter.PermitSignature memory absent;

        uint256 snapshot = vm.snapshotState();
        uint256 shares = _mintSharesErc20(bob, 100e18, 100e18);
        vm.startPrank(bob);
        erc20Vault.approve(address(router), shares);
        uint256 plainOut = router.zapOut(_asVault(erc20Vault), shares, 1, bob, block.timestamp);
        vm.stopPrank();
        vm.revertToState(snapshot);

        uint256 sharesAgain = _mintSharesErc20(bob, 100e18, 100e18);
        vm.startPrank(bob);
        erc20Vault.approve(address(router), sharesAgain);
        uint256 carriedOut = router.zapOutWithPermit(
            _asVault(erc20Vault), sharesAgain, 1, bob, block.timestamp, absent
        );
        vm.stopPrank();
        assertEq(sharesAgain, shares, "zapOut shares diverged");
        assertEq(carriedOut, plainOut, "zapOut proceeds diverged");
        vm.revertToState(snapshot);

        shares = _mintSharesErc20(bob, 100e18, 100e18);
        vm.startPrank(bob);
        erc20Vault.approve(address(router), shares);
        plainOut = router.zapOutTarget(_asVault(erc20Vault), shares, 1, bob, block.timestamp);
        vm.stopPrank();
        vm.revertToState(snapshot);

        sharesAgain = _mintSharesErc20(bob, 100e18, 100e18);
        vm.startPrank(bob);
        erc20Vault.approve(address(router), sharesAgain);
        carriedOut = router.zapOutTargetWithPermit(
            _asVault(erc20Vault), sharesAgain, 1, bob, block.timestamp, absent
        );
        vm.stopPrank();
        assertEq(sharesAgain, shares, "zapOutTarget shares diverged");
        assertEq(carriedOut, plainOut, "zapOutTarget proceeds diverged");
        vm.revertToState(snapshot);

        usdg.mint(bob, 100e18);
        vm.startPrank(bob);
        usdg.approve(address(router), 100e18);
        (uint256 plainShares, uint256 plainTarget, uint256 plainCounter) =
            router.zapIn(_asVault(erc20Vault), 100e18, 50e18, 1, 1, bob, block.timestamp);
        vm.stopPrank();
        vm.revertToState(snapshot);

        usdg.mint(bob, 100e18);
        vm.startPrank(bob);
        usdg.approve(address(router), 100e18);
        (uint256 carriedShares, uint256 carriedTarget, uint256 carriedCounter) = router.zapInWithPermit(
            _asVault(erc20Vault), 100e18, 50e18, 1, 1, bob, block.timestamp, absent
        );
        vm.stopPrank();
        assertEq(carriedShares, plainShares, "zapIn shares diverged");
        assertEq(carriedTarget, plainTarget, "zapIn targetUsed diverged");
        assertEq(carriedCounter, plainCounter, "zapIn counterUsed diverged");
        vm.revertToState(snapshot);

        cashcat.mint(bob, 100e18);
        vm.startPrank(bob);
        cashcat.approve(address(router), 100e18);
        (uint256 plainTargetShares, uint256 plainTargetUsed, uint256 plainTargetCounter) =
            router.zapInTarget(_asVault(erc20Vault), 100e18, 50e18, 1, 1, bob, block.timestamp);
        vm.stopPrank();
        vm.revertToState(snapshot);

        cashcat.mint(bob, 100e18);
        vm.startPrank(bob);
        cashcat.approve(address(router), 100e18);
        (uint256 carriedTargetShares, uint256 carriedTargetUsed, uint256 carriedTargetCounter) = router.zapInTargetWithPermit(
            _asVault(erc20Vault), 100e18, 50e18, 1, 1, bob, block.timestamp, absent
        );
        vm.stopPrank();
        assertEq(carriedTargetShares, plainTargetShares, "zapInTarget shares diverged");
        assertEq(carriedTargetUsed, plainTargetUsed, "zapInTarget targetUsed diverged");
        assertEq(carriedTargetCounter, plainTargetCounter, "zapInTarget counterUsed diverged");
        vm.revertToState(snapshot);

        usdg.mint(bob, 100e18);
        vm.startPrank(bob);
        usdg.approve(address(router), 100e18);
        (uint256 plainRoutedShares, uint256 plainRoutedTarget, uint256 plainRoutedCounter) = router.zapInRouted(
            _asVault(nativeVault),
            Currency.wrap(address(usdg)),
            100e18,
            _single(nativeUsdgKey),
            80e18,
            40e18,
            1,
            1,
            bob,
            block.timestamp
        );
        vm.stopPrank();
        vm.revertToState(snapshot);

        usdg.mint(bob, 100e18);
        vm.startPrank(bob);
        usdg.approve(address(router), 100e18);
        (uint256 carriedRoutedShares, uint256 carriedRoutedTarget, uint256 carriedRoutedCounter) = router.zapInRoutedWithPermit(
            _asVault(nativeVault),
            Currency.wrap(address(usdg)),
            100e18,
            _single(nativeUsdgKey),
            80e18,
            40e18,
            1,
            1,
            bob,
            block.timestamp,
            absent
        );
        vm.stopPrank();
        assertEq(carriedRoutedShares, plainRoutedShares, "zapInRouted shares diverged");
        assertEq(carriedRoutedTarget, plainRoutedTarget, "zapInRouted targetUsed diverged");
        assertEq(carriedRoutedCounter, plainRoutedCounter, "zapInRouted counterUsed diverged");
    }

    function testZapInCounterFastPathErc20() public {
        uint256 counterAmount = 100e18;
        uint256 supplyBefore = erc20Vault.totalSupply();
        uint256 treasuryBefore = erc20Vault.balanceOf(treasury);
        usdg.mint(bob, counterAmount);
        vm.startPrank(bob);
        usdg.approve(address(router), counterAmount);
        (uint256 shares, uint256 targetUsed, uint256 counterUsed) =
            router.zapIn(_asVault(erc20Vault), counterAmount, 50e18, 1, 1, bob, block.timestamp);
        vm.stopPrank();

        assertGt(shares, 0);
        assertGt(targetUsed, 0);
        assertGt(counterUsed, 50e18);
        assertEq(erc20Vault.balanceOf(bob), shares);
        uint256 grossShares = erc20Vault.totalSupply() - supplyBefore;
        uint256 feeShares =
            FullMath.mulDivRoundingUp(grossShares, erc20Vault.SHARE_FEE_BPS(), erc20Vault.BPS());
        assertEq(shares, grossShares - feeShares);
        assertEq(erc20Vault.balanceOf(treasury) - treasuryBefore, feeShares);
        _assertNoResidue(address(erc20Vault));
    }

    function testZapInTargetFastPathErc20() public {
        uint256 targetAmount = 100e18;
        cashcat.mint(bob, targetAmount);
        uint256 targetBefore = cashcat.balanceOf(bob);
        uint256 counterBefore = usdg.balanceOf(bob);
        uint256 receiverSharesBefore = erc20Vault.balanceOf(alice);

        vm.startPrank(bob);
        cashcat.approve(address(router), targetAmount);
        vm.recordLogs();
        (uint256 shares, uint256 targetUsed, uint256 counterUsed) = router.zapInTarget(
            _asVault(erc20Vault), targetAmount, 50e18, 1, 1, alice, block.timestamp
        );
        vm.stopPrank();

        assertGt(shares, 0);
        assertGt(targetUsed, 50e18);
        assertGt(counterUsed, 0);
        assertEq(cashcat.balanceOf(bob), targetBefore - targetUsed);
        assertGe(usdg.balanceOf(bob), counterBefore);
        assertEq(erc20Vault.balanceOf(alice), receiverSharesBefore + shares);
        assertEq(erc20Vault.balanceOf(bob), 0);

        Vm.Log memory targetZap = _routerLog(ZapRouter.TargetZappedIn.selector);
        assertEq(targetZap.topics[1], bytes32(uint256(uint160(bob))), "event sender");
        assertEq(targetZap.topics[2], bytes32(uint256(uint160(address(erc20Vault)))), "event vault");
        assertEq(targetZap.topics[3], bytes32(uint256(uint160(alice))), "event receiver");
        (
            uint256 loggedTargetIn,
            uint256 loggedTargetSwapped,
            uint256 loggedCounterBought,
            uint256 loggedShares
        ) = abi.decode(targetZap.data, (uint256, uint256, uint256, uint256));
        assertEq(loggedTargetIn, targetAmount);
        assertEq(loggedTargetSwapped, 50e18);
        assertEq(loggedCounterBought, counterUsed + usdg.balanceOf(bob) - counterBefore);
        assertEq(loggedShares, shares);
        _assertNoResidue(address(erc20Vault));
    }

    function testZapInTargetFastPathNativeCounterRefundsSkew() public {
        uint256 targetAmount = 100e18;
        tok8.mint(bob, targetAmount);
        uint256 nativeBefore = bob.balance;

        vm.startPrank(bob);
        tok8.approve(address(router), targetAmount);
        (uint256 shares, uint256 targetUsed, uint256 counterUsed) = router.zapInTarget(
            _asVault(nativeVault), targetAmount, 90e18, 1, 1, bob, block.timestamp
        );
        vm.stopPrank();

        assertGt(shares, 0);
        assertGt(targetUsed, 90e18);
        assertGt(counterUsed, 0);
        assertEq(tok8.balanceOf(bob), targetAmount - targetUsed);
        assertGt(bob.balance, nativeBefore, "unused native counter was not refunded");
        assertEq(nativeVault.balanceOf(bob), shares);
        _assertNoResidue(address(nativeVault));
    }

    function testZapInTargetSupportsTargetAsCurrency0() public {
        MockERC20 low = _newTokenBelow(address(usdg));
        PoolKey memory lowKey = _erc20Key(address(low), address(usdg));
        _initLivePool(lowKey, 0);
        LpTokenVault lowVault = _launch(address(low), lowKey, 1_000e18, 1_000e18);

        low.mint(bob, 100e18);
        vm.startPrank(bob);
        low.approve(address(router), 100e18);
        (uint256 shares,,) =
            router.zapInTarget(_asVault(lowVault), 100e18, 50e18, 1, 1, bob, block.timestamp);
        vm.stopPrank();

        assertTrue(lowVault.targetIsCurrency0());
        assertGt(shares, 0);
    }

    function testZapInCounterFastPathNativeAndRefundsSkew() public {
        uint256 counterAmount = 100e18;
        vm.deal(bob, counterAmount);
        uint256 nativeBefore = bob.balance;
        uint256 targetBefore = tok8.balanceOf(bob);

        vm.prank(bob);
        (uint256 shares,, uint256 counterUsed) = router.zapIn{ value: counterAmount }(
            _asVault(nativeVault), counterAmount, 90e18, 1, 1, bob, block.timestamp
        );

        assertGt(shares, 0);
        assertEq(bob.balance, nativeBefore - counterUsed);
        assertGt(tok8.balanceOf(bob), targetBefore);
        _assertNoResidue(address(nativeVault));
    }

    function testZapInSupportsPlatformInitializerHookPool() public {
        TokenLaunchpad launchpad =
            _deployLaunchpad(manager, factory, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE);
        vm.prank(owner);
        factory.bindLaunchpad(address(launchpad));

        uint256 launchValue = launchpad.initialLpQuote();
        uint256 initialBuy = 0.01 ether;
        int24 launchStartTick = launchpad.startTick();
        vm.deal(alice, launchValue + initialBuy);
        vm.prank(alice);
        (address token, address vaultAddress, uint256 initialTargetOut) = launchpad.createToken{
            value: launchValue + initialBuy
        }(
            TokenLaunchpad.TokenMetadata("Zap Cat", "ZCAT", "", "", "", ""),
            keccak256("zap initializer hook"),
            0,
            0,
            launchStartTick,
            launchValue,
            block.timestamp
        );
        LpTokenVault vault = LpTokenVault(payable(vaultAddress));
        assertEq(address(vault.poolKey().hooks), address(launchpad));

        vm.startPrank(alice);
        IERC20Metadata(token).approve(address(router), initialTargetOut);
        (uint256 targetShares,,) = router.zapInTarget(
            _asVault(vault), initialTargetOut, initialTargetOut / 2, 1, 1, alice, block.timestamp
        );
        vm.stopPrank();

        uint256 counterAmount = 0.01 ether;
        vm.deal(bob, counterAmount);
        vm.prank(bob);
        (uint256 shares,,) = router.zapIn{ value: counterAmount }(
            _asVault(vault), counterAmount, counterAmount / 2, 1, 1, bob, block.timestamp
        );

        assertGt(targetShares, 0);
        assertEq(vault.balanceOf(alice), targetShares);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(bob), shares);

        uint256 targetBeforeExit = IERC20Metadata(token).balanceOf(alice);
        vm.startPrank(alice);
        vault.approve(address(router), targetShares);
        uint256 targetOut =
            router.zapOutTarget(_asVault(vault), targetShares, 1, alice, block.timestamp);
        vm.stopPrank();

        assertGt(targetOut, 0);
        assertEq(IERC20Metadata(token).balanceOf(alice), targetBeforeExit + targetOut);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(IERC20Metadata(token).balanceOf(address(router)), 0);
        _assertNoResidue(address(vault));
    }

    function testZapInCounterFastPathRefundsUnusedErc20Legs() public {
        uint256 counterAmount = 100e18;
        usdg.mint(bob, counterAmount);
        uint256 targetBefore = cashcat.balanceOf(bob);
        uint256 counterBefore = usdg.balanceOf(bob);
        vm.startPrank(bob);
        usdg.approve(address(router), counterAmount);
        (, uint256 targetUsed, uint256 counterUsed) =
            router.zapIn(_asVault(erc20Vault), counterAmount, 90e18, 1, 1, bob, block.timestamp);
        vm.stopPrank();

        assertGt(targetUsed, 0);
        assertGt(cashcat.balanceOf(bob), targetBefore);
        assertEq(usdg.balanceOf(bob), counterBefore - counterUsed);
        _assertNoResidue(address(erc20Vault));
    }

    function testZapInSupportsBothTargetOrderings() public {
        MockERC20 low = _newTokenBelow(address(usdg));
        PoolKey memory lowKey = _erc20Key(address(low), address(usdg));
        _initLivePool(lowKey, 0);
        LpTokenVault lowVault = _launch(address(low), lowKey, 1_000e18, 1_000e18);

        usdg.mint(bob, 100e18);
        vm.startPrank(bob);
        usdg.approve(address(router), 100e18);
        (uint256 shares,,) =
            router.zapIn(_asVault(lowVault), 100e18, 50e18, 1, 1, bob, block.timestamp);
        vm.stopPrank();

        assertTrue(lowVault.targetIsCurrency0());
        assertFalse(nativeVault.targetIsCurrency0());
        assertGt(shares, 0);
    }

    function testZapInValidatesValueAmountsDeadlineReceiverAndMinimums() public {
        vm.deal(bob, 10e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ZapRouter.InvalidMsgValue.selector, 9e18, 10e18));
        router.zapIn{ value: 9e18 }(_asVault(nativeVault), 10e18, 5e18, 1, 1, bob, block.timestamp);

        usdg.mint(bob, 100e18);
        vm.deal(bob, bob.balance + 1);
        vm.startPrank(bob);
        usdg.approve(address(router), 100e18);
        vm.expectRevert(abi.encodeWithSelector(ZapRouter.InvalidMsgValue.selector, 1, 0));
        router.zapIn{ value: 1 }(_asVault(erc20Vault), 10e18, 5e18, 1, 1, bob, block.timestamp);

        vm.expectRevert(ZapRouter.InvalidAmount.selector);
        router.zapIn(_asVault(erc20Vault), 0, 0, 0, 1, bob, block.timestamp);
        vm.expectRevert(ZapRouter.InvalidAmount.selector);
        router.zapIn(_asVault(erc20Vault), 10e18, 11e18, 0, 1, bob, block.timestamp);
        vm.expectRevert(ZapRouter.MinimumSharesRequired.selector);
        router.zapIn(_asVault(erc20Vault), 10e18, 5e18, 1, 0, bob, block.timestamp);
        vm.expectPartialRevert(ZapRouter.InsufficientSwapOutput.selector);
        router.zapIn(_asVault(erc20Vault), 10e18, 5e18, type(uint256).max, 1, bob, block.timestamp);
        vm.expectRevert(ZapRouter.DeadlineExpired.selector);
        router.zapIn(_asVault(erc20Vault), 10e18, 5e18, 1, 1, bob, block.timestamp - 1);
        vm.expectRevert(ZapRouter.InvalidAddress.selector);
        router.zapIn(_asVault(erc20Vault), 10e18, 5e18, 1, 1, address(0), block.timestamp);
        vm.expectRevert(ZapRouter.InvalidAddress.selector);
        router.zapIn(_asVault(erc20Vault), 10e18, 5e18, 1, 1, address(router), block.timestamp);
        vm.stopPrank();
    }

    function testZapInTargetValidatesValueAmountsDeadlineReceiverAndMinimums() public {
        cashcat.mint(bob, 100e18);
        vm.deal(bob, 1);
        vm.startPrank(bob);
        cashcat.approve(address(router), 100e18);

        (bool acceptedValue,) = address(router).call{ value: 1 }(
            abi.encodeWithSelector(
                ZapRouter.zapInTarget.selector,
                _asVault(erc20Vault),
                10e18,
                5e18,
                1,
                1,
                bob,
                block.timestamp
            )
        );
        assertFalse(acceptedValue);
        vm.expectRevert(ZapRouter.InvalidAmount.selector);
        router.zapInTarget(_asVault(erc20Vault), 0, 0, 0, 1, bob, block.timestamp);
        vm.expectRevert(ZapRouter.InvalidAmount.selector);
        router.zapInTarget(_asVault(erc20Vault), 10e18, 0, 0, 1, bob, block.timestamp);
        vm.expectRevert(ZapRouter.InvalidAmount.selector);
        router.zapInTarget(_asVault(erc20Vault), 10e18, 10e18, 0, 1, bob, block.timestamp);
        vm.expectRevert(ZapRouter.InvalidAmount.selector);
        router.zapInTarget(_asVault(erc20Vault), 10e18, 11e18, 0, 1, bob, block.timestamp);
        vm.expectRevert(ZapRouter.MinimumSharesRequired.selector);
        router.zapInTarget(_asVault(erc20Vault), 10e18, 5e18, 1, 0, bob, block.timestamp);
        vm.expectPartialRevert(ZapRouter.InsufficientSwapOutput.selector);
        router.zapInTarget(
            _asVault(erc20Vault), 10e18, 5e18, type(uint256).max, 1, bob, block.timestamp
        );
        vm.expectRevert(ZapRouter.DeadlineExpired.selector);
        router.zapInTarget(_asVault(erc20Vault), 10e18, 5e18, 1, 1, bob, block.timestamp - 1);
        vm.expectRevert(ZapRouter.InvalidAddress.selector);
        router.zapInTarget(_asVault(erc20Vault), 10e18, 5e18, 1, 1, address(0), block.timestamp);
        vm.expectRevert(ZapRouter.InvalidAddress.selector);
        router.zapInTarget(
            _asVault(erc20Vault), 10e18, 5e18, 1, 1, address(router), block.timestamp
        );
        vm.stopPrank();
    }

    function testZapInRoutedUsdgToNativeVault() public {
        uint256 inputAmount = 100e18;
        PoolKey[] memory route = _single(nativeUsdgKey);
        usdg.mint(bob, inputAmount);
        vm.startPrank(bob);
        usdg.approve(address(router), inputAmount);
        (uint256 shares, uint256 targetUsed, uint256 counterUsed) = router.zapInRouted(
            _asVault(nativeVault),
            Currency.wrap(address(usdg)),
            inputAmount,
            route,
            80e18,
            40e18,
            1,
            1,
            bob,
            block.timestamp
        );
        vm.stopPrank();

        assertGt(shares, 0);
        assertGt(targetUsed, 0);
        assertGt(counterUsed, 40e18);
        assertEq(nativeVault.balanceOf(bob), shares);
        _assertNoResidue(address(nativeVault));
    }

    function testZapInRoutedNativeToUsdgVault() public {
        uint256 inputAmount = 100e18;
        PoolKey[] memory route = _single(nativeUsdgKey);
        vm.deal(bob, inputAmount);
        vm.prank(bob);
        (uint256 shares,,) = router.zapInRouted{ value: inputAmount }(
            _asVault(erc20Vault),
            Currency.wrap(address(0)),
            inputAmount,
            route,
            80e18,
            40e18,
            1,
            1,
            bob,
            block.timestamp
        );

        assertGt(shares, 0);
        assertEq(erc20Vault.balanceOf(bob), shares);
        _assertNoResidue(address(erc20Vault));
    }

    function testZapInRoutedEnforcesMinimumCounterOutput() public {
        PoolKey[] memory route = _single(nativeUsdgKey);
        vm.deal(bob, 100e18);
        vm.prank(bob);
        vm.expectPartialRevert(ZapRouter.InsufficientCounterOutput.selector);
        router.zapInRouted{ value: 100e18 }(
            _asVault(erc20Vault),
            Currency.wrap(address(0)),
            100e18,
            route,
            type(uint256).max,
            1,
            1,
            1,
            bob,
            block.timestamp
        );
    }

    function testZapInRoutedWrapsNativeIntoWethCounterWithoutPoolHop() public {
        MockERC20 target = new MockERC20("Wrapped Target", "WT", 18);
        PoolKey memory key = _erc20Key(address(target), address(routeWeth));
        _initLivePool(key, 0);
        LpTokenVault vault = _launch(address(target), key, 1_000e18, 1_000e18);
        PoolKey[] memory emptyRoute = new PoolKey[](0);

        vm.deal(bob, 100e18);
        vm.prank(bob);
        (uint256 shares,,) = router.zapInRouted{ value: 100e18 }(
            _asVault(vault),
            Currency.wrap(address(0)),
            100e18,
            emptyRoute,
            100e18,
            50e18,
            1,
            1,
            bob,
            block.timestamp
        );

        assertGt(shares, 0);
        assertEq(vault.balanceOf(bob), shares);
        _assertNoResidue(address(vault));
        assertEq(routeWeth.balanceOf(address(router)), 0);
    }

    function testZapInRoutedWrapsNativeAtFirstRouteBoundary() public {
        PoolKey memory wethUsdgKey = _erc20Key(address(routeWeth), address(usdg));
        _initLivePool(wethUsdgKey, 0);
        PoolKey[] memory route = _single(wethUsdgKey);

        vm.deal(bob, 100e18);
        vm.prank(bob);
        (uint256 shares,,) = router.zapInRouted{ value: 100e18 }(
            _asVault(erc20Vault),
            Currency.wrap(address(0)),
            100e18,
            route,
            80e18,
            40e18,
            1,
            1,
            bob,
            block.timestamp
        );

        assertGt(shares, 0);
        assertEq(routeWeth.balanceOf(address(router)), 0);
        _assertNoResidue(address(erc20Vault));
    }

    function testZapInRoutedRejectsNoncanonicalInput() public {
        PoolKey[] memory route = _single(nativeKey);
        vm.expectRevert(abi.encodeWithSelector(ZapRouter.UnsupportedInput.selector, address(tok8)));
        router.zapInRouted(
            _asVault(nativeVault),
            Currency.wrap(address(tok8)),
            1e18,
            route,
            1,
            1,
            1,
            1,
            bob,
            block.timestamp
        );
    }

    function testZapInRoutedRejectsDiscontinuousPath() public {
        PoolKey memory unrelated = _erc20Key(address(cashcat), address(routeWeth));
        _initLivePool(unrelated, 0);
        PoolKey[] memory route = new PoolKey[](2);
        route[0] = nativeUsdgKey;
        route[1] = unrelated;

        vm.expectRevert(
            abi.encodeWithSelector(
                ZapRouter.RouteCurrencyMismatch.selector,
                1,
                Currency.unwrap(nativeUsdgKey.currency1)
            )
        );
        router.zapInRouted(
            _asVault(erc20Vault),
            Currency.wrap(address(0)),
            1e18,
            route,
            1,
            1,
            1,
            1,
            bob,
            block.timestamp
        );
    }

    function testZapInRoutedRejectsHookedAndDynamicPools() public {
        PoolKey[] memory route = new PoolKey[](1);
        route[0] = nativeUsdgKey;
        route[0].hooks = IHooks(address(0x1234));
        vm.expectRevert(
            abi.encodeWithSelector(ZapRouter.HookedPoolNotSupported.selector, address(0x1234))
        );
        router.zapInRouted(
            _asVault(erc20Vault),
            Currency.wrap(address(0)),
            1e18,
            route,
            1,
            1,
            1,
            1,
            bob,
            block.timestamp
        );

        route[0] = nativeUsdgKey;
        route[0].fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        vm.expectRevert(ZapRouter.DynamicFeePoolNotSupported.selector);
        router.zapInRouted(
            _asVault(erc20Vault),
            Currency.wrap(address(0)),
            1e18,
            route,
            1,
            1,
            1,
            1,
            bob,
            block.timestamp
        );
    }

    function testZapInRoutedRejectsUninitializedAndOverlongRoutes() public {
        PoolKey[] memory route = new PoolKey[](1);
        route[0] = _erc20Key(address(usdg), address(routeWeth));
        vm.expectRevert(abi.encodeWithSelector(ZapRouter.InvalidRoutePool.selector, 0));
        router.zapInRouted(
            _asVault(erc20Vault),
            Currency.wrap(address(usdg)),
            1e18,
            route,
            1,
            1,
            1,
            1,
            bob,
            block.timestamp
        );

        route = new PoolKey[](4);
        vm.expectRevert(abi.encodeWithSelector(ZapRouter.InvalidRouteLength.selector, 4));
        router.zapInRouted(
            _asVault(erc20Vault),
            Currency.wrap(address(usdg)),
            1e18,
            route,
            1,
            1,
            1,
            1,
            bob,
            block.timestamp
        );
    }

    function testZapInRoutedPartialHopRevertsAndRollsBack() public {
        MockERC20 counter = new MockERC20("Thin Counter", "THIN", 18);
        PoolKey memory thinRoute = _erc20Key(address(usdg), address(counter));
        manager.initialize(thinRoute, TickMath.getSqrtPriceAtTick(0));
        _addRangeLiquidity(thinRoute, address(this), -60, 60, 1e12);

        MockERC20 target = new MockERC20("Thin Target", "TT", 18);
        PoolKey memory vaultKey = _erc20Key(address(target), address(counter));
        _initLivePool(vaultKey, 0);
        LpTokenVault vault = _launch(address(target), vaultKey, 1_000e18, 1_000e18);
        PoolKey[] memory route = _single(thinRoute);

        uint256 inputAmount = 1e24;
        usdg.mint(bob, inputAmount);
        vm.startPrank(bob);
        usdg.approve(address(router), inputAmount);
        vm.expectPartialRevert(ZapRouter.IncompleteSwapInput.selector);
        router.zapInRouted(
            _asVault(vault),
            Currency.wrap(address(usdg)),
            inputAmount,
            route,
            1,
            1,
            1,
            1,
            bob,
            block.timestamp
        );
        vm.stopPrank();

        assertEq(usdg.balanceOf(bob), inputAmount);
        assertEq(vault.balanceOf(bob), 0);
    }

    function testZapInRoutedDoesNotConsumeDonatedIntermediate() public {
        MockERC20 intermediate = new MockERC20("Intermediate", "MID", 18);
        PoolKey memory first = _erc20Key(address(usdg), address(intermediate));
        PoolKey memory second = _nativeKey(address(intermediate));
        _initLivePool(first, 0);
        _initLivePool(second, 0);
        PoolKey[] memory route = new PoolKey[](2);
        route[0] = first;
        route[1] = second;

        uint256 donation = 7e18;
        intermediate.mint(address(router), donation);
        usdg.mint(bob, 100e18);
        vm.startPrank(bob);
        usdg.approve(address(router), 100e18);
        (uint256 shares,,) = router.zapInRouted(
            _asVault(nativeVault),
            Currency.wrap(address(usdg)),
            100e18,
            route,
            70e18,
            35e18,
            1,
            1,
            bob,
            block.timestamp
        );
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(intermediate.balanceOf(address(router)), donation);
    }

    function testZapInRoutedRejectsTaxedIntermediateOutputDespiteDonation() public {
        TaxedERC20 taxed = new TaxedERC20();
        PoolKey memory first = _erc20Key(address(usdg), address(taxed));
        manager.initialize(first, TickMath.getSqrtPriceAtTick(0));
        TaxedLiquidityProvider provider = new TaxedLiquidityProvider(manager);
        taxed.mint(address(provider), 1e24);
        usdg.mint(address(provider), 1e24);
        provider.provide(first, 1e18);

        PoolKey memory second = _nativeKey(address(taxed));
        manager.initialize(second, TickMath.getSqrtPriceAtTick(0));
        PoolKey[] memory route = new PoolKey[](2);
        route[0] = first;
        route[1] = second;
        taxed.mint(address(router), 1e21);

        usdg.mint(bob, 100e18);
        vm.startPrank(bob);
        usdg.approve(address(router), 100e18);
        vm.expectPartialRevert(ZapRouter.InexactSwapOutput.selector);
        router.zapInRouted(
            _asVault(nativeVault),
            Currency.wrap(address(usdg)),
            100e18,
            route,
            1,
            1,
            1,
            1,
            bob,
            block.timestamp
        );
        vm.stopPrank();
    }

    function testZapOutStrictlySwapsCompleteTargetLeg() public {
        uint256 shares = _mintSharesErc20(bob, 100e18, 100e18);
        uint256 counterBefore = usdg.balanceOf(bob);
        uint256 treasuryBefore = erc20Vault.balanceOf(treasury);
        uint256 supplyBefore = erc20Vault.totalSupply();
        uint256 feeShares =
            FullMath.mulDivRoundingUp(shares, erc20Vault.SHARE_FEE_BPS(), erc20Vault.BPS());

        vm.startPrank(bob);
        erc20Vault.approve(address(router), shares);
        uint256 counterOut = router.zapOut(_asVault(erc20Vault), shares, 1, bob, block.timestamp);
        vm.stopPrank();

        assertGt(counterOut, 0);
        assertEq(usdg.balanceOf(bob), counterBefore + counterOut);
        assertEq(erc20Vault.balanceOf(bob), 0);
        assertEq(erc20Vault.balanceOf(treasury) - treasuryBefore, feeShares);
        assertEq(erc20Vault.totalSupply(), supplyBefore - (shares - feeShares));
        _assertNoResidue(address(erc20Vault));
    }

    function testZapOutTargetStrictlySwapsCompleteCounterLeg() public {
        uint256 shares = _mintSharesErc20(bob, 100e18, 100e18);
        uint256 targetBefore = cashcat.balanceOf(alice);
        uint256 treasuryBefore = erc20Vault.balanceOf(treasury);
        uint256 supplyBefore = erc20Vault.totalSupply();
        uint256 feeShares =
            FullMath.mulDivRoundingUp(shares, erc20Vault.SHARE_FEE_BPS(), erc20Vault.BPS());

        vm.startPrank(bob);
        erc20Vault.approve(address(router), shares);
        vm.recordLogs();
        uint256 targetOut =
            router.zapOutTarget(_asVault(erc20Vault), shares, 1, alice, block.timestamp);
        vm.stopPrank();

        assertGt(targetOut, 0);
        assertEq(cashcat.balanceOf(alice), targetBefore + targetOut);
        assertEq(erc20Vault.balanceOf(bob), 0);
        assertEq(erc20Vault.balanceOf(treasury) - treasuryBefore, feeShares);
        assertEq(erc20Vault.totalSupply(), supplyBefore - (shares - feeShares));

        Vm.Log memory targetZap = _routerLog(ZapRouter.TargetZappedOut.selector);
        assertEq(targetZap.topics[1], bytes32(uint256(uint160(bob))), "event sender");
        assertEq(targetZap.topics[2], bytes32(uint256(uint160(address(erc20Vault)))), "event vault");
        assertEq(targetZap.topics[3], bytes32(uint256(uint160(alice))), "event receiver");
        (uint256 loggedShares, uint256 counterSwapped, uint256 loggedTargetOut) =
            abi.decode(targetZap.data, (uint256, uint256, uint256));
        assertEq(loggedShares, shares);
        assertGt(counterSwapped, 0);
        assertEq(loggedTargetOut, targetOut);
        _assertNoResidue(address(erc20Vault));
    }

    function testZapOutTargetSupportsTargetAsCurrency0() public {
        MockERC20 low = _newTokenBelow(address(usdg));
        PoolKey memory lowKey = _erc20Key(address(low), address(usdg));
        _initLivePool(lowKey, 0);
        LpTokenVault lowVault = _launch(address(low), lowKey, 1_000e18, 1_000e18);

        _fundAndApprove(low, bob, address(lowVault), 100e18);
        _fundAndApprove(usdg, bob, address(lowVault), 100e18);
        vm.prank(bob);
        (uint256 shares,,) = lowVault.mintPair(100e18, 100e18, 1, bob, block.timestamp);
        uint256 targetBefore = low.balanceOf(bob);

        vm.startPrank(bob);
        lowVault.approve(address(router), shares);
        uint256 targetOut = router.zapOutTarget(_asVault(lowVault), shares, 1, bob, block.timestamp);
        vm.stopPrank();

        assertTrue(lowVault.targetIsCurrency0());
        assertGt(targetOut, 0);
        assertEq(low.balanceOf(bob), targetBefore + targetOut);
        assertEq(low.balanceOf(address(router)), 0);
        assertEq(usdg.balanceOf(address(router)), 0);
        assertEq(lowVault.balanceOf(address(router)), 0);
    }

    function testZapOutPreservesPredonatedBalances() public {
        uint256 shares = _mintSharesErc20(bob, 100e18, 100e18);
        uint256 donation = 7e18;
        cashcat.mint(address(router), donation);
        usdg.mint(address(router), donation);

        vm.startPrank(bob);
        erc20Vault.approve(address(router), shares);
        router.zapOut(_asVault(erc20Vault), shares, 1, bob, block.timestamp);
        vm.stopPrank();

        assertEq(cashcat.balanceOf(address(router)), donation);
        assertEq(usdg.balanceOf(address(router)), donation);
        assertEq(erc20Vault.balanceOf(address(router)), 0);
    }

    function testZapOutTargetPreservesPredonatedBalances() public {
        uint256 shares = _mintSharesErc20(bob, 100e18, 100e18);
        uint256 donation = 7e18;
        cashcat.mint(address(router), donation);
        usdg.mint(address(router), donation);

        vm.startPrank(bob);
        erc20Vault.approve(address(router), shares);
        router.zapOutTarget(_asVault(erc20Vault), shares, 1, bob, block.timestamp);
        vm.stopPrank();

        assertEq(cashcat.balanceOf(address(router)), donation);
        assertEq(usdg.balanceOf(address(router)), donation);
        assertEq(erc20Vault.balanceOf(address(router)), 0);
    }

    function testZapOutEnforcesMinimumCounterOutput() public {
        uint256 shares = _mintSharesErc20(bob, 100e18, 100e18);
        vm.startPrank(bob);
        erc20Vault.approve(address(router), shares);
        vm.expectPartialRevert(ZapRouter.InsufficientCounterOutput.selector);
        router.zapOut(_asVault(erc20Vault), shares, type(uint256).max, bob, block.timestamp);
        vm.stopPrank();
    }

    function testZapOutTargetEnforcesMinimumTargetOutput() public {
        uint256 shares = _mintSharesErc20(bob, 100e18, 100e18);
        uint256 sharesBefore = erc20Vault.balanceOf(bob);
        vm.startPrank(bob);
        erc20Vault.approve(address(router), shares);
        vm.expectPartialRevert(ZapRouter.InsufficientTargetOutput.selector);
        router.zapOutTarget(_asVault(erc20Vault), shares, type(uint256).max, bob, block.timestamp);
        vm.stopPrank();

        assertEq(erc20Vault.balanceOf(bob), sharesBefore);
    }

    function testZapOutPartialTargetSwapRevertsEntireRedemption() public {
        (MockERC20 thinTarget, MockERC20 thinCounter, LpTokenVault thinVault) = _thinExitVault();

        uint256 deposit = 2_000_000;
        thinTarget.mint(bob, deposit);
        thinCounter.mint(bob, deposit);
        vm.startPrank(bob);
        thinTarget.approve(address(thinVault), deposit);
        thinCounter.approve(address(thinVault), deposit);
        (uint256 shares,,) = thinVault.mintPair(deposit, deposit, 1, bob, block.timestamp);
        vm.stopPrank();

        // A large target-only donation increases the shareholder claim without adding
        // pool liquidity, forcing the strict target-to-counter swap to hit its limit.
        thinTarget.mint(address(thinVault), 1e30);
        uint256 sharesBefore = thinVault.balanceOf(bob);
        vm.startPrank(bob);
        thinVault.approve(address(router), shares);
        vm.expectPartialRevert(ZapRouter.IncompleteSwapInput.selector);
        router.zapOut(_asVault(thinVault), shares, 1, bob, block.timestamp);
        vm.stopPrank();

        assertEq(thinVault.balanceOf(bob), sharesBefore);
    }

    function testZapOutTargetPartialCounterSwapRevertsEntireRedemption() public {
        (MockERC20 thinTarget, MockERC20 thinCounter, LpTokenVault thinVault) = _thinExitVault();

        uint256 deposit = 2_000_000;
        thinTarget.mint(bob, deposit);
        thinCounter.mint(bob, deposit);
        vm.startPrank(bob);
        thinTarget.approve(address(thinVault), deposit);
        thinCounter.approve(address(thinVault), deposit);
        (uint256 shares,,) = thinVault.mintPair(deposit, deposit, 1, bob, block.timestamp);
        vm.stopPrank();

        // The target-output path must atomically roll back if the redeemed counter cannot
        // be completely sold through the vault pool.
        thinCounter.mint(address(thinVault), 1e30);
        uint256 sharesBefore = thinVault.balanceOf(bob);
        vm.startPrank(bob);
        thinVault.approve(address(router), shares);
        vm.expectPartialRevert(ZapRouter.IncompleteSwapInput.selector);
        router.zapOutTarget(_asVault(thinVault), shares, 1, bob, block.timestamp);
        vm.stopPrank();

        assertEq(thinVault.balanceOf(bob), sharesBefore);
    }

    function testZapOutNativeCounterPaysEther() public {
        uint256 shares = _mintSharesNative(bob, 100e18, 100e18);
        uint256 balanceBefore = bob.balance;

        vm.startPrank(bob);
        nativeVault.approve(address(router), shares);
        uint256 counterOut = router.zapOut(_asVault(nativeVault), shares, 1, bob, block.timestamp);
        vm.stopPrank();

        assertGt(counterOut, 0);
        assertEq(bob.balance, balanceBefore + counterOut);
        _assertNoResidue(address(nativeVault));
    }

    function testZapOutTargetSwapsNativeCounterIntoTarget() public {
        uint256 shares = _mintSharesNative(bob, 100e18, 100e18);
        uint256 targetBefore = tok8.balanceOf(bob);
        uint256 nativeBefore = bob.balance;

        vm.startPrank(bob);
        nativeVault.approve(address(router), shares);
        uint256 targetOut =
            router.zapOutTarget(_asVault(nativeVault), shares, 1, bob, block.timestamp);
        vm.stopPrank();

        assertGt(targetOut, 0);
        assertEq(tok8.balanceOf(bob), targetBefore + targetOut);
        assertEq(bob.balance, nativeBefore);
        _assertNoResidue(address(nativeVault));
    }

    function testRejectsUnregisteredVaultBeforeReadingVaultData() public {
        vm.expectRevert(
            abi.encodeWithSelector(ZapRouter.UnregisteredVault.selector, address(cashcat))
        );
        router.zapIn(ILpTokenVault(address(cashcat)), 1e18, 1e18, 1, 1, bob, block.timestamp);
    }

    function testZapInPreservesPredonatedBalances() public {
        uint256 donation = 7e18;
        cashcat.mint(address(router), donation);
        usdg.mint(address(router), donation);
        usdg.mint(bob, 100e18);
        vm.startPrank(bob);
        usdg.approve(address(router), 100e18);
        router.zapIn(_asVault(erc20Vault), 100e18, 50e18, 1, 1, bob, block.timestamp);
        vm.stopPrank();

        assertEq(cashcat.balanceOf(address(router)), donation);
        assertEq(usdg.balanceOf(address(router)), donation);
    }

    function testZapInTargetPreservesPredonatedBalances() public {
        uint256 donation = 7e18;
        cashcat.mint(address(router), donation);
        usdg.mint(address(router), donation);
        cashcat.mint(bob, 100e18);
        vm.startPrank(bob);
        cashcat.approve(address(router), 100e18);
        router.zapInTarget(_asVault(erc20Vault), 100e18, 50e18, 1, 1, bob, block.timestamp);
        vm.stopPrank();

        assertEq(cashcat.balanceOf(address(router)), donation);
        assertEq(usdg.balanceOf(address(router)), donation);
    }

    function testUnlockCallbackOnlyPoolManager() public {
        vm.expectRevert(ZapRouter.OnlyPoolManager.selector);
        router.unlockCallback(bytes(""));
    }

    function testReceiveRejectsUntrustedNativeSender() public {
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        (bool success,) = address(router).call{ value: 1 ether }("");
        assertFalse(success);
    }

    function testConstructorRejectsInvalidDependencies() public {
        vm.expectRevert(ZapRouter.InvalidAddress.selector);
        new ZapRouter(ILpTokenFactory(bob), address(usdg), IWETH9(address(routeWeth)));

        ZapRouterFactoryStub invalidManagerFactory = new ZapRouterFactoryStub(IPoolManager(bob));
        vm.expectRevert(ZapRouter.InvalidAddress.selector);
        new ZapRouter(
            ILpTokenFactory(address(invalidManagerFactory)),
            address(usdg),
            IWETH9(address(routeWeth))
        );

        vm.expectRevert(ZapRouter.InvalidAddress.selector);
        new ZapRouter(factory, address(0), IWETH9(address(routeWeth)));

        vm.expectRevert(ZapRouter.InvalidAddress.selector);
        new ZapRouter(factory, address(routeWeth), IWETH9(address(routeWeth)));

        vm.expectRevert(ZapRouter.InvalidAddress.selector);
        new ZapRouter(factory, bob, IWETH9(address(routeWeth)));

        vm.expectRevert(ZapRouter.InvalidAddress.selector);
        new ZapRouter(factory, address(usdg), IWETH9(bob));
    }

    function _single(PoolKey memory key) private pure returns (PoolKey[] memory route) {
        route = new PoolKey[](1);
        route[0] = key;
    }

    function _asVault(LpTokenVault vault) private pure returns (ILpTokenVault) {
        return ILpTokenVault(address(vault));
    }

    function _assertNoResidue(address vault) private view {
        _assertNoResidue(address(router), vault);
    }

    function _assertNoResidue(address zapRouter, address vault) private view {
        assertEq(cashcat.balanceOf(zapRouter), 0, "target residue");
        assertEq(usdg.balanceOf(zapRouter), 0, "usdg residue");
        assertEq(tok8.balanceOf(zapRouter), 0, "tok8 residue");
        assertEq(address(zapRouter).balance, 0, "native residue");
        assertEq(LpTokenVault(payable(vault)).balanceOf(zapRouter), 0, "share residue");
        assertEq(cashcat.allowance(zapRouter, vault), 0, "target approval");
        assertEq(usdg.allowance(zapRouter, vault), 0, "usdg approval");
        assertEq(tok8.allowance(zapRouter, vault), 0, "tok8 approval");
    }

    function _thinExitVault()
        private
        returns (MockERC20 thinTarget, MockERC20 thinCounter, LpTokenVault thinVault)
    {
        thinTarget = new MockERC20("Thin Exit Target", "TET", 18);
        thinCounter = new MockERC20("Thin Exit Counter", "TEC", 18);
        PoolKey memory thinKey = _erc20Key(address(thinTarget), address(thinCounter));
        manager.initialize(thinKey, TickMath.getSqrtPriceAtTick(0));
        _addFullRangeLiquidity(thinKey, address(this), 2_000_000);
        thinVault = _launch(address(thinTarget), thinKey, 2_000_000, 2_000_000);
    }

    function _mintSharesErc20(address who, uint256 maxTarget, uint256 maxCounter)
        private
        returns (uint256 shares)
    {
        _fundAndApprove(cashcat, who, address(erc20Vault), maxTarget);
        _fundAndApprove(usdg, who, address(erc20Vault), maxCounter);
        vm.prank(who);
        (shares,,) = erc20Vault.mintPair(maxTarget, maxCounter, 0, who, block.timestamp);
    }

    function _mintSharesNative(address who, uint256 maxTarget, uint256 maxCounter)
        private
        returns (uint256 shares)
    {
        _fundAndApprove(tok8, who, address(nativeVault), maxTarget);
        vm.deal(who, who.balance + maxCounter);
        vm.prank(who);
        (shares,,) = nativeVault.mintPair{ value: maxCounter }(
            maxTarget, maxCounter, 0, who, block.timestamp
        );
    }
}

contract ZapRouterFactoryStub {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }
}
