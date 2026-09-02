// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { ProtocolFeeLibrary } from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { LpTokenFactory } from "../LpTokenFactory.sol";
import { LpTokenVault } from "../LpTokenVault.sol";

/// @notice Read-only aggregation over lpTOKEN vaults. Pool-wide context (slot0, active
/// liquidity, Uniswap protocol fee) is reported separately from vault-owned assets and is
/// never counted as a shareholder claim.
contract LpTokenLens {
    using ProtocolFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    struct VaultSnapshot {
        // Identity
        address vault;
        address target;
        address counter;
        address treasury;
        address launchFeeSource;
        bool counterIsNative;
        bool targetIsCurrency0;
        bytes32 poolId;
        uint24 lpFee;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        // Pool-wide context (not vault-owned)
        uint160 sqrtPriceX96;
        int24 poolTick;
        uint24 protocolFee;
        uint16 protocolFeeZeroForOne;
        uint16 protocolFeeOneForZero;
        uint128 poolLiquidity;
        // Vault-owned position and balances
        uint128 positionLiquidity;
        uint256 principalTarget;
        uint256 principalCounter;
        uint256 pendingTarget;
        uint256 pendingCounter;
        uint256 pendingLaunchTarget;
        uint256 pendingLaunchCounter;
        uint256 idleTarget;
        uint256 idleCounter;
        uint256 totalTarget;
        uint256 totalCounter;
        uint256 totalSupply;
        uint256 shareFeeBps;
        uint64 lastCompoundAt;
        uint64 compoundAvailableAt;
        uint128 compoundBase;
        uint128 compoundLiquidityCap;
    }

    function snapshot(LpTokenVault vault) public view returns (VaultSnapshot memory value) {
        PoolKey memory key = vault.poolKey();
        PoolId id = key.toId();
        IPoolManager manager = vault.poolManager();

        value.vault = address(vault);
        value.target = vault.target();
        value.treasury = vault.treasury();
        value.launchFeeSource = vault.launchFeeSource();
        value.targetIsCurrency0 = Currency.unwrap(key.currency0) == value.target;
        Currency counter = value.targetIsCurrency0 ? key.currency1 : key.currency0;
        value.counter = Currency.unwrap(counter);
        value.counterIsNative = counter.isAddressZero();
        value.poolId = PoolId.unwrap(id);
        value.lpFee = key.fee;
        value.tickSpacing = key.tickSpacing;
        (value.tickLower, value.tickUpper) = vault.positionTicks();

        (value.sqrtPriceX96, value.poolTick, value.protocolFee,) = manager.getSlot0(id);
        value.protocolFeeZeroForOne = value.protocolFee.getZeroForOneFee();
        value.protocolFeeOneForZero = value.protocolFee.getOneForZeroFee();
        value.poolLiquidity = manager.getLiquidity(id);

        value.positionLiquidity = vault.positionLiquidity();
        (value.principalTarget, value.principalCounter) = vault.positionPrincipal();
        (value.pendingTarget, value.pendingCounter) = vault.pendingFees();
        (value.pendingLaunchTarget, value.pendingLaunchCounter) = vault.pendingLaunchFees();
        (value.idleTarget, value.idleCounter) = vault.idleBalances();
        (value.totalTarget, value.totalCounter) = vault.totalAssets();
        value.totalSupply = vault.totalSupply();
        value.shareFeeBps = vault.SHARE_FEE_BPS();
        value.lastCompoundAt = vault.lastCompoundAt();
        value.compoundAvailableAt = vault.compoundAvailableAt();
        value.compoundBase = vault.compoundBase();
        value.compoundLiquidityCap = vault.compoundLiquidityCap();
    }

    function factorySnapshots(LpTokenFactory factory, uint256 offset, uint256 limit)
        external
        view
        returns (VaultSnapshot[] memory values)
    {
        uint256 count = factory.vaultCount();
        if (offset >= count || limit == 0) return new VaultSnapshot[](0);
        uint256 remaining = count - offset;
        uint256 length = limit < remaining ? limit : remaining;
        values = new VaultSnapshot[](length);
        for (uint256 i; i < values.length; ++i) {
            values[i] = snapshot(LpTokenVault(payable(factory.vaultAt(offset + i))));
        }
    }

    function previewMintPair(LpTokenVault vault, uint256 maxTarget, uint256 maxCounter)
        external
        view
        returns (uint256 shares, uint256 targetUsed, uint256 counterUsed)
    {
        return vault.previewMintPair(maxTarget, maxCounter);
    }

    function previewRedeem(LpTokenVault vault, uint256 shares)
        external
        view
        returns (uint256 targetOut, uint256 counterOut)
    {
        return vault.previewRedeem(shares);
    }

    function isRegistered(LpTokenFactory factory, LpTokenVault vault) external view returns (bool) {
        return factory.isVault(address(vault))
            && factory.vaultOfPoolId(vault.poolKey().toId()) == address(vault);
    }
}
