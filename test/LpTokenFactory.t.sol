// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { LpTokenFactory } from "../src/LpTokenFactory.sol";
import { LpTokenVault } from "../src/LpTokenVault.sol";
import { VaultRange } from "../src/libraries/VaultRange.sol";
import { ILpTokenFactory } from "../src/interfaces/ILpTokenFactory.sol";
import { LpTokenLens } from "../src/periphery/LpTokenLens.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { CallbackERC20 } from "./mocks/TestActors.sol";
import { LpTokenTestBase } from "./utils/LpTokenTestBase.sol";

/// @dev ERC-20 whose metadata behavior switches after deployment, modeling a curated target
/// that changes its implementation once admitted. Every unreadable shape seen in the wild or
/// adversarially useful is one mode: reverting, a bytes32 name, empty returndata, a read
/// that burns every unit of forwarded gas, and a cheap, successful canonical 480-byte
/// string — 544 bytes of returndata, just past the probe's copy limit. That last call
/// succeeding within the probe's gas cap is what distinguishes the size-cap branch from
/// the out-of-gas branch a larger bomb would die in.
contract MutableMetadataToken is MockERC20 {
    enum Mode {
        Honest,
        Reverting,
        Bytes32Shape,
        Empty,
        GasBurn,
        Oversized
    }

    Mode public nameMode;
    Mode public symbolMode;

    constructor() MockERC20("Mutable", "MUT", 18) { }

    function setMode(Mode mode_) external {
        nameMode = mode_;
        symbolMode = mode_;
    }

    function setNameMode(Mode mode_) external {
        nameMode = mode_;
    }

    function setSymbolMode(Mode mode_) external {
        symbolMode = mode_;
    }

    function name() public view override returns (string memory) {
        return _metadata(nameMode, super.name());
    }

    function symbol() public view override returns (string memory) {
        return _metadata(symbolMode, super.symbol());
    }

    function _metadata(Mode shape, string memory honest) private pure returns (string memory) {
        if (shape == Mode.Honest) return honest;
        if (shape == Mode.Reverting) revert();
        if (shape == Mode.Bytes32Shape) {
            assembly {
                mstore(0x00, "Maker")
                return(0x00, 0x20)
            }
        }
        if (shape == Mode.Empty) {
            assembly {
                return(0x00, 0x00)
            }
        }
        if (shape == Mode.GasBurn) {
            assembly {
                for { } 1 { } { mstore(0x00, keccak256(0x00, 0x40)) }
            }
        }
        assembly {
            mstore(0x00, 0x20)
            mstore(0x20, 480)
            return(0x00, 544)
        }
    }
}

/// @dev Metadata keyed on the calling vault's own share supply: readable only before
/// bootstrap mints it, or only after, depending on the flag. Which side admits decides
/// what state the admission probe actually observes.
contract SupplyGatedMetadataToken is MockERC20 {
    bool public readableOnlyAfterBootstrap;

    constructor() MockERC20("Staged", "STAGE", 18) { }

    function setReadableOnlyAfterBootstrap(bool value) external {
        readableOnlyAfterBootstrap = value;
    }

    function name() public view override returns (string memory) {
        _gate();
        return super.name();
    }

    function symbol() public view override returns (string memory) {
        _gate();
        return super.symbol();
    }

    function _gate() private view {
        bool callerHasSupply = IERC20(msg.sender).totalSupply() != 0;
        if (callerHasSupply != readableOnlyAfterBootstrap) revert();
    }
}

/// @dev Metadata readable only to one chosen caller. Probed from anywhere else it reverts,
/// so which contract runs the admission probe decides whether this target admits.
contract CallerGatedMetadataToken is MockERC20 {
    address public reader;

    constructor() MockERC20("Gated", "GATE", 18) { }

    function setReader(address reader_) external {
        reader = reader_;
    }

    function name() public view override returns (string memory) {
        if (msg.sender != reader) revert();
        return super.name();
    }

    function symbol() public view override returns (string memory) {
        if (msg.sender != reader) revert();
        return super.symbol();
    }
}

contract LpTokenFactoryTest is LpTokenTestBase {
    using StateLibrary for IPoolManager;

    event TreasuryTransferProposed(
        address indexed currentTreasury, address indexed proposedTreasury
    );
    event TreasuryTransferred(address indexed previousTreasury, address indexed newTreasury);

    PoolKey internal cashcatUsdg;
    PoolKey internal callbackRemovalKey;
    uint128 internal callbackRemovalLiquidity;

    function setUp() public override {
        super.setUp();
        cashcatUsdg = _erc20Key(address(cashcat), address(usdg));
        _initLivePool(cashcatUsdg, 0);
    }

    function testFactoryRejectsZeroManagerOrTreasury() public {
        vm.expectRevert(LpTokenFactory.InvalidAddress.selector);
        new LpTokenFactory(IPoolManager(address(0)), treasury, owner);

        vm.expectRevert(LpTokenFactory.InvalidAddress.selector);
        new LpTokenFactory(manager, address(0), owner);
    }

    function testOnlyCurrentTreasuryCanProposeNonzeroSuccessor() public {
        assertEq(factory.pendingTreasury(), address(0));

        vm.prank(owner);
        vm.expectRevert(LpTokenFactory.OnlyTreasury.selector);
        factory.proposeTreasury(alice);

        vm.prank(treasury);
        vm.expectRevert(LpTokenFactory.InvalidAddress.selector);
        factory.proposeTreasury(address(0));

        vm.expectEmit(true, true, false, true, address(factory));
        emit TreasuryTransferProposed(treasury, alice);
        vm.prank(treasury);
        factory.proposeTreasury(alice);

        assertEq(factory.treasury(), treasury);
        assertEq(factory.pendingTreasury(), alice);
    }

    function testOnlyLatestPendingTreasuryCanAcceptAndOldTreasuryLosesAuthority() public {
        vm.prank(treasury);
        factory.proposeTreasury(alice);
        vm.prank(treasury);
        factory.proposeTreasury(bob);

        vm.prank(alice);
        vm.expectRevert(LpTokenFactory.OnlyPendingTreasury.selector);
        factory.acceptTreasury();

        vm.expectEmit(true, true, false, true, address(factory));
        emit TreasuryTransferred(treasury, bob);
        vm.prank(bob);
        factory.acceptTreasury();

        assertEq(factory.treasury(), bob);
        assertEq(factory.pendingTreasury(), address(0));

        vm.prank(treasury);
        vm.expectRevert(LpTokenFactory.OnlyTreasury.selector);
        factory.proposeTreasury(alice);

        vm.prank(bob);
        factory.proposeTreasury(alice);
        assertEq(factory.pendingTreasury(), alice);
    }

    function testCurrentTreasuryCanReplaceAndClearPendingHandoffWithAcceptedSelfProposal() public {
        vm.prank(treasury);
        factory.proposeTreasury(alice);
        vm.prank(treasury);
        factory.proposeTreasury(treasury);

        vm.prank(alice);
        vm.expectRevert(LpTokenFactory.OnlyPendingTreasury.selector);
        factory.acceptTreasury();

        vm.prank(treasury);
        factory.acceptTreasury();
        assertEq(factory.treasury(), treasury);
        assertEq(factory.pendingTreasury(), address(0));
    }

    function testLaunchAcceptsExistingHooklessStaticPool() public {
        (, int24 tickBefore,,) = manager.getSlot0(cashcatUsdg.toId());
        uint128 poolLiquidityBefore = manager.getLiquidity(cashcatUsdg.toId());

        (address vaultAddress, uint256 shares, uint128 liquidityAdded) =
            _launchFull(address(cashcat), cashcatUsdg, 1_000e18, 1_000e6, 0, 0);
        LpTokenVault vault = LpTokenVault(payable(vaultAddress));

        assertGt(shares, 0);
        assertGt(liquidityAdded, 0);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.balanceOf(vault.DEAD_SHARE_RECEIVER()), vault.DEAD_SHARES());
        assertEq(uint256(shares) + vault.DEAD_SHARES(), uint256(liquidityAdded));
        assertEq(vault.positionLiquidity(), liquidityAdded);

        // The launch joined the pool without touching its price.
        (, int24 tickAfter,,) = manager.getSlot0(cashcatUsdg.toId());
        assertEq(tickAfter, tickBefore);
        assertEq(manager.getLiquidity(cashcatUsdg.toId()), poolLiquidityBefore + liquidityAdded);

        // Registry state.
        assertEq(factory.vaultOfPoolId(cashcatUsdg.toId()), vaultAddress);
        assertTrue(factory.isVault(vaultAddress));
        assertEq(factory.vaultCount(), 1);
        assertEq(factory.vaultAt(0), vaultAddress);
        assertEq(factory.predictVault(address(cashcat), cashcatUsdg), vaultAddress);

        // Vault immutable wiring.
        assertEq(vault.factory(), address(factory));
        assertEq(address(vault.poolManager()), address(manager));
        assertEq(vault.treasury(), treasury);
        assertEq(vault.target(), address(cashcat));
        assertEq(Currency.unwrap(vault.counter()), address(usdg));
        assertFalse(vault.counterIsNative());
        assertEq(vault.lpFee(), FEE);
        assertEq(vault.tickSpacing(), SPACING);
        assertEq(vault.poolId(), PoolId.unwrap(cashcatUsdg.toId()));
        (int24 lower, int24 upper) = VaultRange.ticks(cashcatUsdg);
        assertEq(vault.tickLower(), lower);
        assertEq(vault.tickUpper(), upper);
        assertEq(vault.symbol(), "lpCASHCAT");
        assertEq(vault.name(), "lpCash Cat");
    }

    /// @dev A target that cannot answer `name()` and `symbol()` as readable strings is not
    /// admissible at all: the vault's metadata and the EIP-712 domain behind its `permit`
    /// derive from them. Every unreadable shape is rejected with the same error, and the
    /// same pool launches once the target reads honestly again.
    function testLaunchRejectsTargetWithUnreadableMetadata() public {
        MutableMetadataToken target = new MutableMetadataToken();
        PoolKey memory key = _erc20Key(address(target), address(usdg));
        _initLivePool(key, 0);
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(target), key, 1_000e18, 1_000e6, 0, 0);
        // The probe runs on the bootstrapped vault, so every rejected attempt funds a full
        // bootstrap first; the revert returns the funding for the next attempt.
        _fundLaunch(
            address(target),
            key,
            owner,
            factory.predictVault(address(target), key),
            1_000e18,
            1_000e6
        );

        MutableMetadataToken.Mode[5] memory unreadable = [
            MutableMetadataToken.Mode.Reverting,
            MutableMetadataToken.Mode.Bytes32Shape,
            MutableMetadataToken.Mode.Empty,
            MutableMetadataToken.Mode.GasBurn,
            MutableMetadataToken.Mode.Oversized
        ];
        for (uint256 i; i < unreadable.length; ++i) {
            target.setMode(unreadable[i]);
            vm.prank(owner);
            vm.expectRevert(
                abi.encodeWithSelector(
                    LpTokenFactory.UnreadableTargetMetadata.selector, address(target)
                )
            );
            factory.launch(params);
        }

        // Each field is required on its own: one readable side cannot carry the other.
        target.setMode(MutableMetadataToken.Mode.Honest);
        target.setNameMode(MutableMetadataToken.Mode.Reverting);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                LpTokenFactory.UnreadableTargetMetadata.selector, address(target)
            )
        );
        factory.launch(params);

        target.setMode(MutableMetadataToken.Mode.Honest);
        target.setSymbolMode(MutableMetadataToken.Mode.Bytes32Shape);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                LpTokenFactory.UnreadableTargetMetadata.selector, address(target)
            )
        );
        factory.launch(params);

        target.setMode(MutableMetadataToken.Mode.Honest);
        LpTokenVault vault = _launch(address(target), key, 1_000e18, 1_000e6);
        assertEq(vault.name(), "lpMutable");
        assertEq(vault.symbol(), "lpMUT");
    }

    /// @dev A target that answers only its probing caller must not admit. The probe runs
    /// through the bootstrapped vault clone, so this test pins the same direct caller used
    /// for the admission snapshot — a Factory-context probe here would have admitted a
    /// vault that falls back from its first block. The same target gated to the predicted
    /// vault address launches, and the vault reads it at that snapshot.
    function testLaunchRejectsTargetReadableOnlyToTheFactory() public {
        CallerGatedMetadataToken target = new CallerGatedMetadataToken();
        target.setReader(address(factory));
        PoolKey memory key = _erc20Key(address(target), address(usdg));
        _initLivePool(key, 0);
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(target), key, 1_000e18, 1_000e6, 0, 0);
        _fundLaunch(
            address(target),
            key,
            owner,
            factory.predictVault(address(target), key),
            1_000e18,
            1_000e6
        );

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                LpTokenFactory.UnreadableTargetMetadata.selector, address(target)
            )
        );
        factory.launch(params);

        target.setReader(factory.predictVault(address(target), key));
        LpTokenVault vault = _launch(address(target), key, 1_000e18, 1_000e6);
        assertEq(vault.name(), "lpGated");
        assertEq(vault.symbol(), "lpGATE");
    }

    /// @dev The probe must observe the operating vault, not the empty pre-bootstrap clone:
    /// a target readable only while the probing vault has zero supply would otherwise admit
    /// and fall back from its first block, without changing at all. Conversely a target
    /// readable only once supply exists admits and keeps reading — supply never returns to
    /// zero — pinning that the snapshot is taken after bootstrap.
    function testLaunchProbesMetadataAgainstTheBootstrappedVault() public {
        SupplyGatedMetadataToken target = new SupplyGatedMetadataToken();
        PoolKey memory key = _erc20Key(address(target), address(usdg));
        _initLivePool(key, 0);
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(target), key, 1_000e18, 1_000e6, 0, 0);
        _fundLaunch(
            address(target),
            key,
            owner,
            factory.predictVault(address(target), key),
            1_000e18,
            1_000e6
        );

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                LpTokenFactory.UnreadableTargetMetadata.selector, address(target)
            )
        );
        factory.launch(params);

        target.setReadableOnlyAfterBootstrap(true);
        LpTokenVault vault = _launch(address(target), key, 1_000e18, 1_000e6);
        assertEq(vault.name(), "lpStaged");
        assertEq(vault.symbol(), "lpSTAGE");
        assertTrue(vault.targetMetadataReadable());
    }

    /// @dev Admission cannot pin a target's future behavior: one that turns unreadable
    /// after its launch must reach the fallback rather than revert, because the vault's
    /// EIP-712 domain reads `name()` on every `DOMAIN_SEPARATOR()` call, so a re-raised
    /// decode failure would take `permit` down with it. The read heals when the target
    /// does.
    function testVaultMetadataFallsBackWhenTargetTurnsUnreadable() public {
        MutableMetadataToken target = new MutableMetadataToken();
        PoolKey memory key = _erc20Key(address(target), address(usdg));
        _initLivePool(key, 0);
        LpTokenVault vault = _launch(address(target), key, 1_000e18, 1_000e6);
        assertEq(vault.name(), "lpMutable");
        assertEq(vault.symbol(), "lpMUT");

        MutableMetadataToken.Mode[3] memory unreadable = [
            MutableMetadataToken.Mode.Reverting,
            MutableMetadataToken.Mode.Bytes32Shape,
            MutableMetadataToken.Mode.Empty
        ];
        for (uint256 i; i < unreadable.length; ++i) {
            target.setMode(unreadable[i]);
            assertEq(vault.name(), "lpToken");
            assertEq(vault.symbol(), "lpTOKEN");
        }
        assertEq(
            vault.DOMAIN_SEPARATOR(),
            keccak256(
                abi.encode(
                    keccak256(
                        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                    ),
                    keccak256("lpToken"),
                    keccak256("1"),
                    block.chainid,
                    address(vault)
                )
            )
        );

        target.setMode(MutableMetadataToken.Mode.Honest);
        assertEq(vault.name(), "lpMutable");
    }

    /// @dev The metadata probe is gas- and size-capped, so a target that turns hostile
    /// after admission reads as unavailable metadata at a bounded cost, instead of making
    /// `name()` — and the EIP-712 domain behind `permit` with it — unaffordable. The
    /// consumption bounds are what pin the gas cap: uncapped, the burning read costs 63/64
    /// of everything the caller has. The oversized mode pins the size cap, so the test
    /// first proves that call succeeds within the probe's own gas budget — its fallback
    /// can then only come from the returndata check, not from callee failure.
    function testVaultMetadataProbeIsGasAndSizeCapped() public {
        MutableMetadataToken target = new MutableMetadataToken();
        PoolKey memory key = _erc20Key(address(target), address(usdg));
        _initLivePool(key, 0);
        LpTokenVault vault = _launch(address(target), key, 1_000e18, 1_000e6);

        target.setMode(MutableMetadataToken.Mode.GasBurn);
        uint256 gasBefore = gasleft();
        string memory vaultName = vault.name();
        uint256 nameGasUsed = gasBefore - gasleft();
        assertEq(vaultName, "lpToken");
        assertLt(nameGasUsed, 200_000);

        target.setMode(MutableMetadataToken.Mode.Oversized);
        (bool directSuccess, bytes memory directData) =
            address(target).staticcall{ gas: 100_000 }(abi.encodeWithSignature("symbol()"));
        assertTrue(directSuccess);
        assertEq(directData.length, 544);

        gasBefore = gasleft();
        string memory vaultSymbol = vault.symbol();
        uint256 symbolGasUsed = gasBefore - gasleft();
        assertEq(vaultSymbol, "lpTOKEN");
        assertLt(symbolGasUsed, 200_000);
    }

    function testLaunchBothTargetOrderings() public {
        MockERC20 low = _newTokenBelow(address(usdg));
        MockERC20 high = _newTokenAbove(address(usdg));
        PoolKey memory lowKey = _erc20Key(address(low), address(usdg));
        PoolKey memory highKey = _erc20Key(address(high), address(usdg));
        _initLivePool(lowKey, 0);
        _initLivePool(highKey, 0);

        LpTokenVault lowVault = _launch(address(low), lowKey, 1_000e18, 1_000e6);
        LpTokenVault highVault = _launch(address(high), highKey, 1_000e18, 1_000e6);

        assertTrue(lowVault.targetIsCurrency0());
        assertFalse(highVault.targetIsCurrency0());
        assertEq(lowVault.target(), address(low));
        assertEq(highVault.target(), address(high));
        assertEq(Currency.unwrap(lowVault.counter()), address(usdg));
        assertEq(Currency.unwrap(highVault.counter()), address(usdg));
    }

    function testLaunchNativeCounterPool() public {
        PoolKey memory nativeKey = _nativeKey(address(cashcat));
        _initLivePool(nativeKey, 0);

        (address vaultAddress, uint256 shares,) =
            _launchFull(address(cashcat), nativeKey, 1_000e18, 1_000e18, 0, 0);
        LpTokenVault vault = LpTokenVault(payable(vaultAddress));

        assertGt(shares, 0);
        assertTrue(vault.counterIsNative());
        assertFalse(vault.targetIsCurrency0());
        assertEq(Currency.unwrap(vault.counter()), address(0));
        assertGt(address(manager).balance, 0);
    }

    function testLaunchNativeCounterRejectsWrongMsgValue() public {
        PoolKey memory nativeKey = _nativeKey(address(cashcat));
        _initLivePool(nativeKey, 0);
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(cashcat), nativeKey, 1_000e18, 1_000e18, 0, 0);
        address predicted = factory.predictVault(address(cashcat), nativeKey);
        _fundLaunch(address(cashcat), nativeKey, owner, predicted, 1_000e18, 2_000e18);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(LpTokenFactory.InvalidMsgValue.selector, 999e18, 1_000e18)
        );
        factory.launch{ value: 999e18 }(params);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(LpTokenFactory.InvalidMsgValue.selector, 1_001e18, 1_000e18)
        );
        factory.launch{ value: 1_001e18 }(params);
    }

    function testLaunchErc20CounterRejectsNonzeroMsgValue() public {
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(cashcat), cashcatUsdg, 1_000e18, 1_000e6, 0, 0);
        address predicted = factory.predictVault(address(cashcat), cashcatUsdg);
        _fundLaunch(address(cashcat), cashcatUsdg, owner, predicted, 1_000e18, 1_000e6);
        vm.deal(owner, 1 ether);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LpTokenFactory.InvalidMsgValue.selector, 1 ether, 0));
        factory.launch{ value: 1 ether }(params);
    }

    function testLaunchOnlyOwner() public {
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(cashcat), cashcatUsdg, 1_000e18, 1_000e6, 0, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.launch(params);
    }

    function testLaunchRejectsHookedPool() public {
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(cashcat), cashcatUsdg, 1_000e18, 1_000e6, 0, 0);
        params.poolKey.hooks = IHooks(address(0xBEEF));
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(LpTokenFactory.HookedPoolNotSupported.selector, address(0xBEEF))
        );
        factory.launch(params);
    }

    function testLaunchRejectsDynamicFeePool() public {
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(cashcat), cashcatUsdg, 1_000e18, 1_000e6, 0, 0);
        params.poolKey.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        vm.prank(owner);
        vm.expectRevert(LpTokenFactory.DynamicFeePoolNotSupported.selector);
        factory.launch(params);
    }

    function testLaunchRejectsInvalidFee() public {
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(cashcat), cashcatUsdg, 1_000e18, 1_000e6, 0, 0);
        params.poolKey.fee = LPFeeLibrary.MAX_LP_FEE + 1;
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(LpTokenFactory.InvalidFee.selector, LPFeeLibrary.MAX_LP_FEE + 1)
        );
        factory.launch(params);
    }

    function testLaunchRejectsFeeBelowCompoundSafetyFloor() public {
        uint24 fee = factory.MIN_POOL_LP_FEE() - 1;
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(cashcat), cashcatUsdg, 1_000e18, 1_000e6, 0, 0);
        params.poolKey.fee = fee;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LpTokenFactory.InvalidFee.selector, fee));
        factory.launch(params);
    }

    function testLaunchAcceptsCompoundSafetyFeeFloor() public {
        MockERC20 token = new MockERC20("Minimum Fee Target", "MINFEE", 18);
        PoolKey memory key =
            _erc20Key(address(token), address(usdg), factory.MIN_POOL_LP_FEE(), SPACING);
        _initLivePool(key, 0);

        LpTokenVault minimumFeeVault = _launch(address(token), key, 1_000e18, 1_000e18);
        assertEq(minimumFeeVault.lpFee(), factory.MIN_POOL_LP_FEE());
    }

    function testLaunchRejectsOneHundredPercentFee() public {
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(cashcat), cashcatUsdg, 1_000e18, 1_000e6, 0, 0);
        params.poolKey.fee = LPFeeLibrary.MAX_LP_FEE;

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(LpTokenFactory.InvalidFee.selector, LPFeeLibrary.MAX_LP_FEE)
        );
        factory.launch(params);
    }

    function testLaunchRejectsInvalidTickSpacing() public {
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(cashcat), cashcatUsdg, 1_000e18, 1_000e6, 0, 0);
        params.poolKey.tickSpacing = 0;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LpTokenFactory.InvalidTickSpacing.selector, 0));
        factory.launch(params);

        params.poolKey.tickSpacing = int24(TickMath.MAX_TICK_SPACING) + 1;
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                LpTokenFactory.InvalidTickSpacing.selector, int24(TickMath.MAX_TICK_SPACING) + 1
            )
        );
        factory.launch(params);
    }

    function testLaunchRejectsUnsortedCurrencies() public {
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(cashcat), cashcatUsdg, 1_000e18, 1_000e6, 0, 0);
        (params.poolKey.currency0, params.poolKey.currency1) =
        (params.poolKey.currency1, params.poolKey.currency0);
        vm.prank(owner);
        vm.expectRevert(LpTokenFactory.CurrencyOrder.selector);
        factory.launch(params);
    }

    function testLaunchRejectsTargetNotInPool() public {
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(weth), cashcatUsdg, 1_000e18, 1_000e6, 0, 0);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(LpTokenFactory.TargetNotInPool.selector, address(weth))
        );
        factory.launch(params);
    }

    function testLaunchRejectsNonContractTarget() public {
        address eoaTarget = makeAddr("not a contract");
        PoolKey memory key = _erc20Key(eoaTarget, address(usdg));
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(cashcat), cashcatUsdg, 1_000e18, 1_000e6, 0, 0);
        params.target = eoaTarget;
        params.poolKey = key;
        vm.prank(owner);
        vm.expectRevert(LpTokenFactory.InvalidAddress.selector);
        factory.launch(params);
    }

    function testLaunchRejectsUninitializedPool() public {
        PoolKey memory key = _erc20Key(address(weth), address(usdg));
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(weth), key, 1_000e18, 1_000e6, 0, 0);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(LpTokenFactory.PoolNotInitialized.selector, key.toId())
        );
        factory.launch(params);
    }

    function testLaunchRejectsZeroLiquidityPool() public {
        PoolKey memory key = _erc20Key(address(weth), address(usdg));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(weth), key, 1_000e18, 1_000e6, 0, 0);
        params.minExistingLiquidity = 0;
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(LpTokenFactory.InsufficientExistingLiquidity.selector, 0, 0)
        );
        factory.launch(params);
    }

    function testLaunchRejectsBelowMinimumExistingLiquidity() public {
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(cashcat), cashcatUsdg, 1_000e18, 1_000e6, 0, 0);
        uint128 liquidity = manager.getLiquidity(cashcatUsdg.toId());
        params.minExistingLiquidity = liquidity + 1;
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                LpTokenFactory.InsufficientExistingLiquidity.selector, liquidity, liquidity + 1
            )
        );
        factory.launch(params);
    }

    function testLaunchRejectsTickDeviation() public {
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(cashcat), cashcatUsdg, 1_000e18, 1_000e6, 0, 0);
        params.expectedTick = _currentTick(cashcatUsdg) + 101;
        params.maxTickDeviation = 100;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LpTokenFactory.TickDeviation.selector, 101, 100));
        factory.launch(params);
    }

    function testLaunchRechecksTickAfterTargetTransferCallback() public {
        CallbackERC20 callbackTarget = new CallbackERC20("Callback", "CALL", 18);
        PoolKey memory key = _erc20Key(address(callbackTarget), address(usdg));
        _initLivePool(key, 0);
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(callbackTarget), key, 1_000e18, 1_000e18, 0, 0);
        params.maxTickDeviation = 0;
        address predicted = factory.predictVault(address(callbackTarget), key);
        _fundLaunch(address(callbackTarget), key, owner, predicted, 1_000e18, 1_000e18);
        _configureSwapCallback(callbackTarget, predicted, key, 100e18);

        vm.prank(owner);
        vm.expectPartialRevert(LpTokenVault.TickDeviation.selector);
        factory.launch(params);

        assertEq(factory.vaultOfPoolId(key.toId()), address(0));
        assertEq(factory.vaultCount(), 0);
    }

    function testLaunchRechecksLiquidityAfterCounterTransferCallback() public {
        MockERC20 targetToken = new MockERC20("Target", "TARGET", 18);
        CallbackERC20 callbackCounter = new CallbackERC20("Callback", "CALL", 18);
        PoolKey memory key = _erc20Key(address(targetToken), address(callbackCounter));
        _initLivePool(key, 0);
        uint128 existingLiquidity = manager.getLiquidity(key.toId());
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(targetToken), key, 1_000e18, 1_000e18, 0, 0);
        params.minExistingLiquidity = existingLiquidity;
        address predicted = factory.predictVault(address(targetToken), key);
        _fundLaunch(address(targetToken), key, owner, predicted, 1_000e18, 1_000e18);
        callbackRemovalKey = key;
        callbackRemovalLiquidity = existingLiquidity;
        callbackCounter.configureTransferFromCallback(
            predicted, address(this), abi.encodeCall(this.removeLiquidityOnCallback, ())
        );

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                LpTokenVault.InsufficientExistingLiquidity.selector, 0, existingLiquidity
            )
        );
        factory.launch(params);

        assertEq(factory.vaultOfPoolId(key.toId()), address(0));
        assertEq(factory.vaultCount(), 0);
    }

    function removeLiquidityOnCallback() external {
        liquidityRouter.modifyLiquidity(
            callbackRemovalKey,
            _fullRangeParams(callbackRemovalKey, -int256(uint256(callbackRemovalLiquidity))),
            bytes("")
        );
    }

    function testLaunchRejectsExpiredDeadline() public {
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(cashcat), cashcatUsdg, 1_000e18, 1_000e6, 0, 0);
        params.deadline = block.timestamp - 1;
        vm.prank(owner);
        vm.expectRevert(LpTokenFactory.DeadlineExpired.selector);
        factory.launch(params);
    }

    function testLaunchAcceptsSameTargetAcrossDifferentPools() public {
        LpTokenVault firstVault = _launch(address(cashcat), cashcatUsdg, 1_000e18, 1_000e6);
        PoolKey memory otherKey = _erc20Key(address(cashcat), address(weth));
        _initLivePool(otherKey, 0);
        LpTokenVault secondVault = _launch(address(cashcat), otherKey, 1_000e18, 1_000e18);

        assertNotEq(address(firstVault), address(secondVault));
        assertEq(firstVault.target(), address(cashcat));
        assertEq(secondVault.target(), address(cashcat));
        assertEq(factory.vaultOfPoolId(cashcatUsdg.toId()), address(firstVault));
        assertEq(factory.vaultOfPoolId(otherKey.toId()), address(secondVault));
        assertTrue(factory.isVault(address(firstVault)));
        assertTrue(factory.isVault(address(secondVault)));
        assertEq(factory.vaultCount(), 2);
    }

    function testLaunchRejectsDuplicatePoolId() public {
        address vaultAddress = address(_launch(address(cashcat), cashcatUsdg, 1_000e18, 1_000e6));

        // Same pool, other leg as target: the PoolId is already wrapped.
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(usdg), cashcatUsdg, 1_000e6, 1_000e18, 0, 0);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                LpTokenFactory.PoolAlreadyWrapped.selector, cashcatUsdg.toId(), vaultAddress
            )
        );
        factory.launch(params);
    }

    function testLaunchRejectsRecursiveVaultLeg() public {
        LpTokenVault vault = _launch(address(cashcat), cashcatUsdg, 1_000e18, 1_000e6);

        PoolKey memory recursiveKey = _erc20Key(address(vault), address(weth));
        _initLivePoolWithShares(recursiveKey, vault);
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(weth), recursiveKey, 1_000e18, 1_000e18, 0, 0);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(LpTokenFactory.RecursiveVaultLeg.selector, address(vault))
        );
        factory.launch(params);
    }

    function testLaunchEnforcesMinimumLiquidityAdded() public {
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(cashcat), cashcatUsdg, 1_000e18, 1_000e6, type(uint128).max, 0);
        address predicted = factory.predictVault(address(cashcat), cashcatUsdg);
        _fundLaunch(address(cashcat), cashcatUsdg, owner, predicted, 1_000e18, 1_000e6);
        vm.prank(owner);
        vm.expectPartialRevert(LpTokenVault.InsufficientLiquidityAdded.selector);
        factory.launch(params);
    }

    function testLaunchEnforcesMinimumShares() public {
        ILpTokenFactory.LaunchParams memory params =
            _launchParams(address(cashcat), cashcatUsdg, 1_000e18, 1_000e6, 0, type(uint256).max);
        address predicted = factory.predictVault(address(cashcat), cashcatUsdg);
        _fundLaunch(address(cashcat), cashcatUsdg, owner, predicted, 1_000e18, 1_000e6);
        vm.prank(owner);
        vm.expectPartialRevert(LpTokenVault.InsufficientShares.selector);
        factory.launch(params);
    }

    function testLaunchBoundsFollowTheVaultRangeRule() public {
        int24[2] memory spacings = [int24(60), int24(200)];
        for (uint256 i; i < spacings.length; ++i) {
            MockERC20 token = new MockERC20("Spaced", "SPACED", 18);
            PoolKey memory key = _erc20Key(address(token), address(usdg), FEE, spacings[i]);
            _initLivePool(key, 0);
            LpTokenVault vault = _launch(address(token), key, 1_000e18, 1_000e6);
            (int24 lower, int24 upper) = VaultRange.ticks(key);
            assertEq(vault.tickLower(), lower);
            assertEq(vault.tickUpper(), upper);
            assertGt(lower, TickMath.minUsableTick(spacings[i]));
            assertLt(upper, TickMath.maxUsableTick(spacings[i]));
            assertGt(vault.positionLiquidity(), 0);
        }
    }

    function testLensSnapshotSeparatesVaultAndPoolState() public {
        LpTokenVault vault = _launch(address(cashcat), cashcatUsdg, 1_000e18, 1_000e6);
        LpTokenLens lens = new LpTokenLens();

        LpTokenLens.VaultSnapshot memory snap = lens.snapshot(vault);
        assertEq(snap.vault, address(vault));
        assertEq(snap.target, address(cashcat));
        assertEq(snap.counter, address(usdg));
        assertFalse(snap.counterIsNative);
        assertEq(snap.lpFee, FEE);
        assertEq(snap.tickSpacing, SPACING);
        assertEq(snap.poolId, PoolId.unwrap(cashcatUsdg.toId()));
        assertGt(snap.poolLiquidity, snap.positionLiquidity);
        assertGt(snap.positionLiquidity, 0);
        assertEq(snap.protocolFee, 0);
        assertEq(snap.totalSupply, vault.totalSupply());
        assertTrue(lens.isRegistered(factory, vault));

        LpTokenLens.VaultSnapshot[] memory snaps = lens.factorySnapshots(factory, 0, 10);
        assertEq(snaps.length, 1);
        assertEq(snaps[0].vault, address(vault));
    }

    function _initLivePoolWithShares(PoolKey memory key, LpTokenVault vault) private {
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        // Provide share-token liquidity from alice, who holds vault shares.
        MockERC20(address(weth)).mint(alice, 1e30);
        vm.startPrank(alice);
        vault.approve(address(liquidityRouter), type(uint256).max);
        MockERC20(address(weth)).approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(key, _fullRangeParams(key, 1e6), bytes(""));
        vm.stopPrank();
    }

    function _fullRangeParams(PoolKey memory key, int256 liquidityDelta)
        private
        pure
        returns (ModifyLiquidityParams memory)
    {
        return ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing),
            liquidityDelta: liquidityDelta,
            salt: bytes32(0)
        });
    }
}
