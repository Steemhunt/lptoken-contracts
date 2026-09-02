// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

interface ILpTokenVault {
    struct BootstrapParams {
        address payer;
        uint256 targetAmount;
        uint256 counterAmount;
        int24 expectedTick;
        uint24 maxTickDeviation;
        int24 tickLower;
        int24 tickUpper;
        uint128 minExistingLiquidity;
        uint128 minLiquidityAdded;
        uint256 minShares;
        address receiver;
    }

    function COMPOUND_INTERVAL() external view returns (uint64);
    function COMPOUND_SAFETY_BPS() external view returns (uint256);
    function BPS() external view returns (uint256);
    function SHARE_FEE_BPS() external view returns (uint256);
    function MIN_FEEABLE_SHARES() external view returns (uint256);
    function factory() external view returns (address);
    function treasury() external view returns (address);
    function launchFeeSource() external view returns (address);
    function target() external view returns (address);
    /// @notice Whether the target's name and symbol read as strings from the vault's own
    /// caller context, which curated admission requires of the bootstrapped vault.
    function targetMetadataReadable() external view returns (bool);
    function counter() external view returns (Currency);
    function counterIsNative() external view returns (bool);
    function targetIsCurrency0() external view returns (bool);
    function poolKey() external view returns (PoolKey memory);
    function poolId() external view returns (bytes32);
    /// @notice Protocol-owned liquidity live in this pool right now.
    function compoundBase() external view returns (uint128);
    function lastCompoundAt() external view returns (uint64);
    function compoundAvailableAt() external view returns (uint64);
    function compoundLiquidityCap() external view returns (uint128);
    function totalSupply() external view returns (uint256);
    function totalAssets() external view returns (uint256 targetAssets, uint256 counterAssets);
    /// @notice Launch-position fees currently receivable by this vault as holder NAV.
    function pendingLaunchFees() external view returns (uint256 targetFees, uint256 counterFees);
    function pendingFees() external view returns (uint256 targetFees, uint256 counterFees);
    /// @notice Gross pro-rata asset claim before the redeem share fee.
    function claimForShares(uint256 shares)
        external
        view
        returns (uint256 targetClaim, uint256 counterClaim);
    /// @return shares Net shares delivered after the share fee.
    function previewMintPair(uint256 maxTarget, uint256 maxCounter)
        external
        view
        returns (uint256 shares, uint256 targetUsed, uint256 counterUsed);
    /// @notice Previews asset output after charging the redeem share fee.
    function previewRedeem(uint256 shares)
        external
        view
        returns (uint256 targetOut, uint256 counterOut);
    function previewCompound()
        external
        view
        returns (
            uint256 targetToDeploy,
            uint256 counterToDeploy,
            uint128 availableLiquidity,
            uint128 liquidityCap,
            uint128 executableLiquidity,
            uint64 availableAt
        );

    function bootstrap(BootstrapParams calldata params)
        external
        payable
        returns (uint256 receiverShares, uint128 liquidityAdded);

    function mintPair(
        uint256 maxTarget,
        uint256 maxCounter,
        uint256 minShares,
        address receiver,
        uint256 deadline
    ) external payable returns (uint256 shares, uint256 targetUsed, uint256 counterUsed);

    function redeem(
        uint256 shares,
        uint256 minTarget,
        uint256 minCounter,
        address receiver,
        uint256 deadline
    ) external returns (uint256 targetOut, uint256 counterOut);

    function compound(uint128 minLiquidityAdded, uint256 deadline)
        external
        returns (uint128 liquidityAdded);
}
