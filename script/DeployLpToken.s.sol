// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { console2 } from "forge-std/console2.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { IWETH9 } from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import { LaunchLiquidityVault } from "../src/LaunchLiquidityVault.sol";
import { LpTokenFactory } from "../src/LpTokenFactory.sol";
import { LpTokenVault } from "../src/LpTokenVault.sol";
import { TokenLaunchpad } from "../src/TokenLaunchpad.sol";
import { LpTokenLens } from "../src/periphery/LpTokenLens.sol";
import { ZapRouter } from "../src/periphery/ZapRouter.sol";
import { DeploymentBase } from "./DeploymentBase.s.sol";
import { LaunchpadHookMiner } from "./LaunchpadHookMiner.sol";

contract DeployLpToken is DeploymentBase {
    using stdJson for string;
    using SafeCast for int256;

    error FactoryWiringMismatch();
    error LaunchpadAddressOccupied(address launchpad);

    function run()
        external
        returns (
            LpTokenFactory factory,
            TokenLaunchpad launchpad,
            LaunchLiquidityVault launchLiquidityVault,
            ZapRouter zapRouter,
            LpTokenLens lens
        )
    {
        string memory configPath = vm.envOr(
            "DEPLOYMENT_CONFIG", string("config/robinhood-mainnet.json")
        );
        string memory config = vm.readFile(configPath);
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address factoryOwnerTransferTarget = vm.envOr("FACTORY_OWNER_TRANSFER_TARGET", address(0));
        uint256 expectedChainId = config.readUint(".chainId");
        address managerAddress = config.readAddress(".addresses.poolManager");
        address canonicalStable = config.readAddress(".addresses.canonicalStable");
        address wrappedNative = config.readAddress(".addresses.wrappedNative");
        address permit2 = config.readAddress(".addresses.permit2");
        address treasury = config.readAddress(".addresses.treasury");
        int24 startTick = _readLaunchStartTick(config);
        uint256 initialLpQuote = vm.parseUint(config.readString(".launchTerms.initialLpQuoteWei"));

        _requireChain(expectedChainId);
        _requireCodeHash(managerAddress, config.readBytes32(".runtimeCodeHashes.poolManager"));
        _requireCodeHash(canonicalStable, config.readBytes32(".runtimeCodeHashes.canonicalStable"));
        _requireCodeHash(wrappedNative, config.readBytes32(".runtimeCodeHashes.wrappedNative"));
        // Every launch token and vault share hands this address unlimited `transferFrom`, so
        // the deployment stops unless it carries the reviewed code. Absent or unexpected code
        // fails here rather than after the first launch. The verification below pins that this
        // is the same Permit2 the tokens name.
        _requireCodeHash(permit2, config.readBytes32(".runtimeCodeHashes.permit2"));
        _requireNonzeroAddress(treasury);
        _requireNonzeroAddress(factoryOwnerTransferTarget);

        IPoolManager manager = IPoolManager(managerAddress);
        manager.protocolFeeController();
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);
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
        zapRouter = new ZapRouter(factory, canonicalStable, IWETH9(wrappedNative));
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
                || address(zapRouter.wrappedNative()) != wrappedNative
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
        console2.log("ZapRouter:", address(zapRouter));
        console2.log("LpTokenLens:", address(lens));
    }

    function _readLaunchStartTick(string memory config) internal pure returns (int24) {
        return config.readInt(".launchTerms.startTick").toInt24();
    }
}
