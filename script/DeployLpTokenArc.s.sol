// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { console2 } from "forge-std/console2.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { LaunchLiquidityVault } from "../src/LaunchLiquidityVault.sol";
import { LpTokenFactory } from "../src/LpTokenFactory.sol";
import { LpTokenVault } from "../src/LpTokenVault.sol";
import { TokenLaunchpad } from "../src/TokenLaunchpad.sol";
import { LpTokenLens } from "../src/periphery/LpTokenLens.sol";
import { ZapRouterArc } from "../src/periphery/ZapRouterArc.sol";
import { DeploymentBase } from "./DeploymentBase.s.sol";
import { LaunchpadHookMiner } from "./LaunchpadHookMiner.sol";

/// @notice Arc-only deployment. Kept separate to preserve existing deployment source references.
/// @dev The signer is supplied by Forge's wallet options; this script never reads a private key.
contract DeployLpTokenArc is DeploymentBase {
    using stdJson for string;
    using SafeCast for int256;
    using SafeCast for uint256;

    error FactoryWiringMismatch();
    error LaunchpadAddressOccupied(address launchpad);
    error InvalidArcConfiguration();
    error UnexpectedDeployerNonce(uint64 expected, uint64 actual);
    error UsdcProxyChanged();

    // Arc USDC uses the original ZeppelinOS proxy slots, not EIP-1967.
    bytes32 private constant USDC_IMPLEMENTATION_SLOT =
        0x7050c9e0f4ca769c69bd3a8ef740bc37934f8e2c036e5a723fd8ee048ed3f8c3;
    bytes32 private constant USDC_ADMIN_SLOT =
        0x10d6a54a4754c8869d6886b5f5d7fbfa5b4522237ea5c60d11bc4e7a1ff9390b;

    function run()
        external
        returns (
            LpTokenFactory factory,
            TokenLaunchpad launchpad,
            LaunchLiquidityVault launchLiquidityVault,
            ZapRouterArc zapRouter,
            LpTokenLens lens
        )
    {
        string memory config = vm.readFile("config/arc-mainnet.json");
        _validateConfig(config);
        address deployer = config.readAddress(".addresses.deployer");
        address factoryOwnerTransferTarget = config.readAddress(".addresses.factoryOwner");
        address managerAddress = config.readAddress(".addresses.poolManager");
        address canonicalStable = config.readAddress(".addresses.canonicalStable");
        address permit2 = config.readAddress(".addresses.permit2");
        address treasury = config.readAddress(".addresses.treasury");
        int24 startTick = _readLaunchStartTick(config);
        uint256 initialLpQuote = vm.parseUint(config.readString(".launchTerms.initialLpQuoteWei"));

        IPoolManager manager = IPoolManager(managerAddress);
        manager.protocolFeeController();

        vm.startBroadcast(deployer);
        factory = new LpTokenFactory(manager, treasury, deployer);
        bytes32 launchpadInitCodeHash = keccak256(
            abi.encodePacked(
                type(TokenLaunchpad).creationCode,
                abi.encode(manager, factory, startTick, initialLpQuote)
            )
        );
        (address expectedLaunchpad, bytes32 launchpadSalt) =
            LaunchpadHookMiner.find(LaunchpadHookMiner.CREATE2_DEPLOYER, launchpadInitCodeHash);
        if (expectedLaunchpad.code.length != 0) {
            revert LaunchpadAddressOccupied(expectedLaunchpad);
        }
        launchpad =
            new TokenLaunchpad{ salt: launchpadSalt }(manager, factory, startTick, initialLpQuote);
        if (address(launchpad) != expectedLaunchpad) revert FactoryWiringMismatch();
        factory.bindLaunchpad(address(launchpad));
        launchLiquidityVault = launchpad.liquidityVault();
        zapRouter = new ZapRouterArc(factory);
        lens = new LpTokenLens();
        factory.transferOwnership(factoryOwnerTransferTarget);
        vm.stopBroadcast();

        LpTokenVault vaultImplementation = LpTokenVault(payable(factory.vaultImplementation()));
        if (
            address(factory.poolManager()) != managerAddress || factory.treasury() != treasury
                || factory.pendingTreasury() != address(0)
                || factory.owner() != factoryOwnerTransferTarget
                || factory.vaultImplementation() == address(0)
                || vaultImplementation.factory() != address(factory)
                || address(vaultImplementation.poolManager()) != managerAddress
                || vaultImplementation.treasury() != treasury
                || factory.launchpad() != address(launchpad) || launchpad.startTick() != startTick
                || vaultImplementation.PERMIT2() != permit2
                || launchpad.initialLpQuote() != initialLpQuote
                || launchpad.bootstrapTargetAmount() == 0
                || address(launchpad.poolManager()) != managerAddress
                || address(launchpad.factory()) != address(factory)
                || uint160(address(launchpad)) & Hooks.ALL_HOOK_MASK != Hooks.BEFORE_INITIALIZE_FLAG
                || address(launchLiquidityVault.poolManager()) != managerAddress
                || launchLiquidityVault.launchpad() != address(launchpad)
                || launchLiquidityVault.factory() != address(factory)
                || launchLiquidityVault.treasury() != treasury
                || address(zapRouter.poolManager()) != managerAddress
                || address(zapRouter.factory()) != address(factory)
                || zapRouter.canonicalStable() != canonicalStable
                || address(zapRouter.wrappedNative()) != canonicalStable
        ) revert FactoryWiringMismatch();

        console2.log("LpTokenFactory:", address(factory));
        console2.log("LpTokenFactory owner:", factory.owner());
        console2.log("LpTokenVault implementation:", factory.vaultImplementation());
        console2.log("TokenLaunchpad:", address(launchpad));
        console2.log("  initializer hook:", address(launchpad));
        console2.log("  start tick:", vm.toString(startTick));
        console2.log("  initial LP quote (wei):", initialLpQuote);
        console2.log("  bootstrap target:", launchpad.bootstrapTargetAmount());
        console2.log("  initial FDV (native wei):", launchpad.initialFdvNative());
        console2.log("LaunchLiquidityVault:", address(launchLiquidityVault));
        console2.log("ZapRouterArc:", address(zapRouter));
        console2.log("LpTokenLens:", address(lens));
    }

    function _validateConfig(string memory config) internal view {
        _requireChain(5042);
        address usdc = config.readAddress(".addresses.canonicalStable");
        address permit2 = config.readAddress(".addresses.permit2");
        if (
            config.readUint(".chainId") != 5042
                || usdc != 0x3600000000000000000000000000000000000000
                || permit2 != 0x000000000022D473030F116dDEE9F6B43aC78BA3
                || config.readAddress(".addresses.create2Deployer")
                    != LaunchpadHookMiner.CREATE2_DEPLOYER
        ) revert InvalidArcConfiguration();
        _requireCodeHash(
            config.readAddress(".addresses.poolManager"),
            config.readBytes32(".runtimeCodeHashes.poolManager")
        );
        _requireCodeHash(usdc, config.readBytes32(".runtimeCodeHashes.canonicalStable"));
        _requireCodeHash(permit2, config.readBytes32(".runtimeCodeHashes.permit2"));
        _requireCodeHash(
            LaunchpadHookMiner.CREATE2_DEPLOYER,
            config.readBytes32(".runtimeCodeHashes.create2Deployer")
        );
        address implementation = config.readAddress(".usdcProxy.implementation");
        if (
            vm.load(usdc, USDC_IMPLEMENTATION_SLOT) != bytes32(uint256(uint160(implementation)))
                || vm.load(usdc, USDC_ADMIN_SLOT)
                    != bytes32(uint256(uint160(config.readAddress(".usdcProxy.admin"))))
        ) revert UsdcProxyChanged();
        _requireCodeHash(
            implementation, config.readBytes32(".runtimeCodeHashes.usdcImplementation")
        );
        if (IERC20Metadata(usdc).decimals() != 6) revert InvalidArcConfiguration();
        _requireNonzeroAddress(config.readAddress(".addresses.treasury"));
        _requireNonzeroAddress(config.readAddress(".addresses.factoryOwner"));
        address deployer = config.readAddress(".addresses.deployer");
        _requireNonzeroAddress(deployer);
        if (deployer.code.length != 0) revert InvalidArcConfiguration();
        uint64 expectedNonce = uint256(config.readUint(".deployerNonce")).toUint64();
        uint64 actualNonce = vm.getNonce(deployer);
        if (actualNonce != expectedNonce) {
            revert UnexpectedDeployerNonce(expectedNonce, actualNonce);
        }
    }

    function _readLaunchStartTick(string memory config) internal pure returns (int24) {
        return config.readInt(".launchTerms.startTick").toInt24();
    }
}
