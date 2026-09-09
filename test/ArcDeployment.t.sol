// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { stdJson } from "forge-std/StdJson.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { DeploymentBase } from "../script/DeploymentBase.s.sol";
import { DeployLpTokenArc } from "../script/DeployLpTokenArc.s.sol";
import { LpTokenFactory } from "../src/LpTokenFactory.sol";
import { LpTokenVault } from "../src/LpTokenVault.sol";
import { TokenLaunchpad } from "../src/TokenLaunchpad.sol";
import { LaunchLiquidityVault } from "../src/LaunchLiquidityVault.sol";
import { ILpTokenVault } from "../src/interfaces/ILpTokenVault.sol";
import { LpTokenLens } from "../src/periphery/LpTokenLens.sol";
import { ZapRouterArc } from "../src/periphery/ZapRouterArc.sol";
import { MockArcUSDC } from "./mocks/MockArcUSDC.sol";
import { LpTokenTestBase } from "./utils/LpTokenTestBase.sol";

contract ArcDeploymentHarness is DeployLpTokenArc {
    function validateConfig(string memory config) external view {
        _validateConfig(config);
    }

    function readLaunchStartTick(string memory config) external pure returns (int24) {
        return _readLaunchStartTick(config);
    }
}

/// @notice Exercises the actual script's preflight guards and the approved launch economics.
/// The end-to-end fixture deploys locally, without calling the script's broadcast entry point.
contract ArcDeploymentTest is LpTokenTestBase {
    using stdJson for string;
    using StateLibrary for IPoolManager;

    address private constant USDC = 0x3600000000000000000000000000000000000000;
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address private constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 private constant IMPLEMENTATION_SLOT =
        0x7050c9e0f4ca769c69bd3a8ef740bc37934f8e2c036e5a723fd8ee048ed3f8c3;
    bytes32 private constant ADMIN_SLOT =
        0x10d6a54a4754c8869d6886b5f5d7fbfa5b4522237ea5c60d11bc4e7a1ff9390b;
    uint256 private constant APPROVED_FDV = 5_033_524_916_457_046_939_596;
    uint256 private constant APPROVED_BOOTSTRAP_TARGET = 198_668_155_271_444_303_391_907;

    ArcDeploymentHarness private harness;
    string private config;
    address private deployer;
    address private implementation;

    function setUp() public override {
        super.setUp();
        vm.chainId(5042);
        harness = new ArcDeploymentHarness();
        config = vm.readFile("config/arc-mainnet.json");
        deployer = config.readAddress(".addresses.deployer");
        implementation = config.readAddress(".usdcProxy.implementation");

        // The shared-balance mock supplies real six-decimal behavior. Proxy slots are
        // modeled separately so a pointer change is tested despite an unchanged code hash.
        vm.etch(USDC, address(new MockArcUSDC()).code);
        vm.etch(PERMIT2, hex"00");
        vm.etch(CREATE2_DEPLOYER, hex"00");
        vm.etch(implementation, hex"00");
        vm.store(USDC, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(implementation))));
        vm.store(
            USDC, ADMIN_SLOT, bytes32(uint256(uint160(config.readAddress(".usdcProxy.admin"))))
        );
        _replaceConfigString(".addresses.poolManager", vm.toString(address(manager)));
        _replaceConfigString(
            ".runtimeCodeHashes.poolManager", vm.toString(address(manager).codehash)
        );
        _replaceConfigString(".runtimeCodeHashes.canonicalStable", vm.toString(USDC.codehash));
        _replaceConfigString(".runtimeCodeHashes.permit2", vm.toString(PERMIT2.codehash));
        _replaceConfigString(
            ".runtimeCodeHashes.create2Deployer", vm.toString(CREATE2_DEPLOYER.codehash)
        );
        _replaceConfigString(
            ".runtimeCodeHashes.usdcImplementation", vm.toString(implementation.codehash)
        );
    }

    function testCheckedInConfigurationPinsApprovedArcEconomics() public {
        string memory productionConfig = vm.readFile("config/arc-mainnet.json");
        assertEq(productionConfig.readUint(".chainId"), 5042);
        assertEq(productionConfig.readUint(".deployerNonce"), 0);
        assertEq(productionConfig.readAddress(".addresses.canonicalStable"), USDC);
        assertEq(productionConfig.readAddress(".addresses.permit2"), PERMIT2);
        assertEq(productionConfig.readAddress(".addresses.create2Deployer"), CREATE2_DEPLOYER);
        assertEq(harness.readLaunchStartTick(productionConfig), 122_000);
        assertEq(
            vm.parseUint(productionConfig.readString(".launchTerms.initialLpQuoteWei")), 1 ether
        );
    }

    function testValidationAcceptsReviewedFixtureWithoutDeploying() public view {
        harness.validateConfig(config);
        assertEq(vm.getNonce(deployer), 0);
    }

    function testValidationRejectsWrongNetworkBeforeDeployment() public {
        vm.chainId(8453);
        vm.expectRevert(abi.encodeWithSelector(DeploymentBase.InvalidChain.selector, 5042, 8453));
        harness.validateConfig(config);
        assertEq(vm.getNonce(deployer), 0);
    }

    function testValidationRejectsWrongCanonicalCurrencyOrPermit2() public {
        string memory original = config;
        _replaceConfigString(".addresses.canonicalStable", vm.toString(address(usdg)));
        vm.expectRevert(DeployLpTokenArc.InvalidArcConfiguration.selector);
        harness.validateConfig(config);
        config = original;
        _replaceConfigString(".addresses.permit2", vm.toString(address(usdg)));
        vm.expectRevert(DeployLpTokenArc.InvalidArcConfiguration.selector);
        harness.validateConfig(config);
    }

    function testValidationRejectsMissingCreate2Helper() public {
        vm.etch(CREATE2_DEPLOYER, bytes(""));
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentBase.MissingCode.selector, CREATE2_DEPLOYER)
        );
        harness.validateConfig(config);
    }

    function testValidationRejectsChangedDependencyRuntime() public {
        vm.etch(PERMIT2, hex"01");
        vm.expectPartialRevert(DeploymentBase.InvalidCodeHash.selector);
        harness.validateConfig(config);
    }

    function testValidationRejectsProxyPointerChangesWithUnchangedProxyCode() public {
        bytes32 originalCodeHash = USDC.codehash;
        vm.store(USDC, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(address(manager)))));
        vm.expectRevert(DeployLpTokenArc.UsdcProxyChanged.selector);
        harness.validateConfig(config);
        vm.store(USDC, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(implementation))));
        vm.store(USDC, ADMIN_SLOT, bytes32(uint256(uint160(bob))));
        vm.expectRevert(DeployLpTokenArc.UsdcProxyChanged.selector);
        harness.validateConfig(config);
        assertEq(USDC.codehash, originalCodeHash);
    }

    function testValidationRejectsChangedImplementationCodeOrDecimals() public {
        vm.etch(implementation, hex"01");
        vm.expectPartialRevert(DeploymentBase.InvalidCodeHash.selector);
        harness.validateConfig(config);
        vm.etch(implementation, hex"00");
        vm.mockCall(USDC, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        vm.expectRevert(DeployLpTokenArc.InvalidArcConfiguration.selector);
        harness.validateConfig(config);
    }

    function testValidationRejectsChangedNonceOrContractDeployer() public {
        vm.setNonce(deployer, 1);
        vm.expectRevert(
            abi.encodeWithSelector(DeployLpTokenArc.UnexpectedDeployerNonce.selector, 0, 1)
        );
        harness.validateConfig(config);
        vm.etch(deployer, hex"00");
        vm.expectRevert(DeployLpTokenArc.InvalidArcConfiguration.selector);
        harness.validateConfig(config);
    }

    function testValidationRejectsZeroOwnerOrTreasury() public {
        string memory original = config;
        _replaceConfigString(".addresses.factoryOwner", vm.toString(address(0)));
        vm.expectRevert(DeploymentBase.InvalidAddress.selector);
        harness.validateConfig(config);
        config = original;
        _replaceConfigString(".addresses.treasury", vm.toString(address(0)));
        vm.expectRevert(DeploymentBase.InvalidAddress.selector);
        harness.validateConfig(config);
    }

    function testApprovedTermsLaunchLockedLiquidityAndSupportArcTrading() public {
        (LpTokenFactory localFactory, TokenLaunchpad launchpad, ZapRouterArc router) =
            _deployApprovedSuite();
        assertEq(launchpad.initialFdvNative(), APPROVED_FDV);
        assertEq(launchpad.bootstrapTargetAmount(), APPROVED_BOOTSTRAP_TARGET);
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        (address token, address vaultAddress, uint256 initialBuy) = launchpad.createToken{
            value: 1 ether
        }(
            TokenLaunchpad.TokenMetadata("Arc Launch", "ARC", "", "", "", ""),
            keccak256("approved Arc terms"),
            0,
            TickMath.MIN_SQRT_PRICE + 1,
            122_000,
            1 ether,
            block.timestamp
        );
        assertEq(initialBuy, 0);
        assertEq(alice.balance, 1 ether, "The seed is consumed once at token creation");
        assertEq(IERC20(token).balanceOf(alice), 0);
        assertEq(address(launchpad).balance, 0);
        LpTokenVault vault = LpTokenVault(payable(vaultAddress));
        PoolKey memory key = launchpad.poolKey(token);
        assertEq(Currency.unwrap(key.currency0), address(0));
        assertEq(Currency.unwrap(key.currency1), token);
        assertTrue(token != USDC, "The launch pool must not alias native and ERC20 USDC");
        assertEq(address(key.hooks), address(launchpad));
        assertEq(key.fee, 10_000);
        assertEq(key.tickSpacing, 200);
        (, int24 initialTick,,) = manager.getSlot0(key.toId());
        assertEq(initialTick, 122_000);
        assertTrue(localFactory.isVault(vaultAddress));
        assertTrue(launchpad.isToken(token));
        assertEq(localFactory.vaultOfPoolId(key.toId()), vaultAddress);
        uint256 deadShares = vault.balanceOf(vault.DEAD_SHARE_RECEIVER());
        assertEq(deadShares, vault.totalSupply());
        assertEq(deadShares, 445_722_334_333_591_511_675);
        assertGt(deadShares, vault.DEAD_SHARES());
        LaunchLiquidityVault locked = launchpad.liquidityVault();
        (address creator, address registeredVault, uint128 permanentLiquidity, int24 pinnedTick) =
            locked.positions(token);
        assertEq(creator, alice);
        assertEq(registeredVault, vaultAddress);
        assertEq(pinnedTick, 122_000);
        assertGt(permanentLiquidity, 0);

        _swap(key, bob, true, 1 ether);
        assertGt(IERC20(token).balanceOf(bob), 0);
        (, int24 tickAfterBuy,,) = manager.getSlot0(key.toId());
        assertLt(tickAfterBuy, initialTick);
        uint256 creatorBeforeFees = alice.balance;
        locked.distributeFees(token);
        assertGt(alice.balance, creatorBeforeFees);

        // The same balance received as native funding is spent through USDC's ERC20 view.
        vm.deal(bob, bob.balance + 1 ether);
        vm.prank(bob);
        MockArcUSDC(USDC).approve(address(router), 1e6);
        vm.prank(bob);
        (uint256 shares,,) = router.zapInRouted(
            ILpTokenVault(vaultAddress),
            Currency.wrap(USDC),
            1e6,
            new PoolKey[](0),
            1 ether,
            0.5 ether,
            1,
            1,
            bob,
            block.timestamp
        );
        assertGt(shares, 0);
        vm.prank(bob);
        vault.approve(address(router), shares);
        vm.prank(bob);
        assertGt(router.zapOut(ILpTokenVault(vaultAddress), shares, 1, bob, block.timestamp), 0);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.balanceOf(vault.DEAD_SHARE_RECEIVER()), deadShares);
        (,, uint128 finalPermanentLiquidity, int24 finalPinnedTick) = locked.positions(token);
        assertEq(finalPermanentLiquidity, permanentLiquidity);
        assertEq(finalPinnedTick, pinnedTick);
        assertEq(address(router).balance, 0);
        assertEq(IERC20(token).balanceOf(address(router)), 0);
    }

    function _deployApprovedSuite()
        private
        returns (LpTokenFactory localFactory, TokenLaunchpad launchpad, ZapRouterArc router)
    {
        harness.validateConfig(config);
        address finalOwner = config.readAddress(".addresses.factoryOwner");
        address configuredTreasury = config.readAddress(".addresses.treasury");
        localFactory = new LpTokenFactory(manager, configuredTreasury, deployer);
        launchpad = _deployLaunchpad(
            manager,
            localFactory,
            harness.readLaunchStartTick(config),
            vm.parseUint(config.readString(".launchTerms.initialLpQuoteWei"))
        );
        vm.prank(deployer);
        localFactory.bindLaunchpad(address(launchpad));
        router = new ZapRouterArc(localFactory);
        LpTokenLens lens = new LpTokenLens();
        vm.prank(deployer);
        localFactory.transferOwnership(finalOwner);

        assertEq(localFactory.owner(), finalOwner);
        assertEq(localFactory.treasury(), configuredTreasury);
        assertEq(localFactory.launchpad(), address(launchpad));
        assertEq(launchpad.initialLpQuote(), 1 ether);
        assertEq(uint160(address(launchpad)) & Hooks.ALL_HOOK_MASK, Hooks.BEFORE_INITIALIZE_FLAG);
        assertEq(launchpad.liquidityVault().factory(), address(localFactory));
        assertEq(launchpad.liquidityVault().treasury(), configuredTreasury);
        assertEq(router.version(), "2.0-arc");
        assertEq(address(router.factory()), address(localFactory));
        assertEq(address(router.poolManager()), address(manager));
        assertEq(router.canonicalStable(), USDC);
        assertEq(address(router.wrappedNative()), USDC);
        assertGt(address(lens).code.length, 0);
        assertEq(address(localFactory).balance, 0);
        assertEq(address(launchpad).balance, 0, "Deploying the suite does not fund a seed");
        assertEq(address(router).balance, 0);
    }

    function _replaceConfigString(string memory path, string memory replacement) private {
        config = vm.replace(config, config.readString(path), replacement);
    }
}
