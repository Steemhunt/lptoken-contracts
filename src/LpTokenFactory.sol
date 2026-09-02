// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { SignedMath } from "@openzeppelin/contracts/utils/math/SignedMath.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { LpTokenVault } from "./LpTokenVault.sol";
import { ILaunchFeeSource } from "./interfaces/ILaunchFeeSource.sol";
import { ILpTokenFactory } from "./interfaces/ILpTokenFactory.sol";
import { ILpTokenVault } from "./interfaces/ILpTokenVault.sol";
import { ITokenLaunchpad } from "./interfaces/ITokenLaunchpad.sol";
import { LaunchPoolConfig } from "./libraries/LaunchPoolConfig.sol";
import { VaultRange } from "./libraries/VaultRange.sol";

/// @notice Deploys immutable lpTOKEN vaults for the bound permissionless token launchpad
/// and for owner-curated existing Uniswap V4 pools. The Factory never initializes or moves
/// a pool. Curated pools remain hookless, while platform pools use only the bound launchpad's
/// initializer hook. Every vault stays bound to its exact, static-fee PoolKey forever.
/// @dev Ownership stays renounceable on purpose. Renouncing is the deliberate one-way lever
/// for permanently closing new curated admissions, and it is safe to expose because owner
/// authority reaches nothing else: it cannot move a vault, pause redemption, upgrade logic,
/// rotate the treasury, withdraw principal, or stop anyone from launching. Over the bound
/// launchpad that authority covers the terms of future launches alone, so renouncing freezes
/// `startTick` and `initialLpQuote` at their last values rather than closing the path; every
/// launch after that runs on the frozen terms. The launchpad binding is itself one-time and
/// must therefore land before any renouncement, after which renouncing leaves every live
/// market fully operational.
contract LpTokenFactory is ILpTokenFactory, Ownable, ReentrancyGuardTransient {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    /// @notice Lowest supported static pool fee, denominated in Uniswap fee pips.
    uint24 public constant MIN_POOL_LP_FEE = 2_000;

    IPoolManager public immutable poolManager;
    address public treasury;
    address public pendingTreasury;
    address public immutable vaultImplementation;
    address public launchpad;

    mapping(PoolId poolId => address vault) public vaultOfPoolId;
    mapping(address vault => bool canonical) public isVault;
    address[] private _vaults;

    error InvalidAddress();
    error DeadlineExpired();
    error InvalidMsgValue(uint256 provided, uint256 expected);
    error TargetNotInPool(address target);
    error HookedPoolNotSupported(address hooks);
    error UnreadableTargetMetadata(address target);
    error DynamicFeePoolNotSupported();
    error InvalidFee(uint24 fee);
    error InvalidTickSpacing(int24 tickSpacing);
    error CurrencyOrder();
    error PoolNotInitialized(PoolId poolId);
    error InsufficientExistingLiquidity(uint128 liquidity, uint128 minimum);
    error TickDeviation(uint24 deviation, uint24 maximum);
    error PoolAlreadyWrapped(PoolId poolId, address vault);
    error RecursiveVaultLeg(address leg);
    error LaunchpadAlreadyBound(address launchpad);
    error OnlyLaunchpad();
    error OnlyTreasury();
    error OnlyPendingTreasury();
    error UnregisteredLaunchToken(address target);
    error InvalidLaunchpadPool();

    event VaultLaunched(
        address indexed target,
        address indexed vault,
        address indexed launcher,
        PoolId poolId,
        Currency currency0,
        Currency currency1,
        address hooks,
        address counter,
        bool counterIsNative,
        uint24 fee,
        int24 tickSpacing,
        int24 tickLower,
        int24 tickUpper,
        int24 launchTick,
        uint24 protocolFee,
        uint256 targetAmount,
        uint256 counterAmount,
        uint256 receiverShares,
        uint128 liquidityAdded,
        address launchFeeSource
    );
    event LaunchpadBound(address indexed launchpad);
    event TreasuryTransferProposed(
        address indexed currentTreasury, address indexed proposedTreasury
    );
    event TreasuryTransferred(address indexed previousTreasury, address indexed newTreasury);

    constructor(IPoolManager poolManager_, address treasury_, address initialOwner_)
        Ownable(initialOwner_)
    {
        if (address(poolManager_) == address(0) || treasury_ == address(0)) {
            revert InvalidAddress();
        }
        poolManager = poolManager_;
        treasury = treasury_;
        vaultImplementation = address(new LpTokenVault(address(this), poolManager_));
    }

    /// @notice Nominates the next Treasury. A new nomination replaces any pending one.
    /// @dev Only the current Treasury controls rotation; Factory ownership has no authority.
    function proposeTreasury(address proposedTreasury) external {
        address currentTreasury = treasury;
        if (msg.sender != currentTreasury) revert OnlyTreasury();
        if (proposedTreasury == address(0)) revert InvalidAddress();
        pendingTreasury = proposedTreasury;
        emit TreasuryTransferProposed(currentTreasury, proposedTreasury);
    }

    /// @notice Accepts Treasury authority after nomination by the current Treasury.
    function acceptTreasury() external {
        address proposedTreasury = pendingTreasury;
        if (msg.sender != proposedTreasury) revert OnlyPendingTreasury();
        address previousTreasury = treasury;
        delete pendingTreasury;
        treasury = proposedTreasury;
        emit TreasuryTransferred(previousTreasury, proposedTreasury);
    }

    /// @notice Curates an existing hookless static-fee pool into an immutable vault.
    /// @dev Tick and active-liquidity checks are same-transaction spot/JIT guards, not an
    /// oracle or durable-TVL proof. The owner supplies the reviewed bounds and depth floor.
    /// The target must answer `name()` and `symbol()` as readable strings to the vault
    /// itself: its metadata, and the EIP-712 domain behind its `permit`, derive from them
    /// live, so admission probes them through the bootstrapped clone's own caller context —
    /// a point-in-time snapshot of the operating vault's read.
    function launch(LaunchParams calldata params)
        external
        payable
        onlyOwner
        nonReentrant
        returns (address vault, uint256 shares, uint128 liquidityAdded)
    {
        if (block.timestamp > params.deadline) revert DeadlineExpired();
        if (params.receiver == address(0)) revert InvalidAddress();
        if (address(params.poolKey.hooks) != address(0)) {
            revert HookedPoolNotSupported(address(params.poolKey.hooks));
        }

        (PoolId id, bool targetIsCurrency0, Currency counterCurrency) = _validatePool(
            params.target,
            params.poolKey,
            params.expectedTick,
            params.maxTickDeviation,
            params.minExistingLiquidity,
            true
        );

        bool counterIsNative = counterCurrency.isAddressZero();
        uint256 expectedValue = counterIsNative ? params.counterAmount : 0;
        if (msg.value != expectedValue) revert InvalidMsgValue(msg.value, expectedValue);

        int24 lower;
        int24 upper;
        (vault, lower, upper) = _deployVault(params.poolKey, id, targetIsCurrency0, address(0));

        uint128 bootstrapMinimum =
            params.minExistingLiquidity == 0 ? 1 : params.minExistingLiquidity;
        (shares, liquidityAdded) = ILpTokenVault(payable(vault)).bootstrap{ value: msg.value }(
            ILpTokenVault.BootstrapParams({
                payer: msg.sender,
                targetAmount: params.targetAmount,
                counterAmount: params.counterAmount,
                expectedTick: params.expectedTick,
                maxTickDeviation: params.maxTickDeviation,
                tickLower: lower,
                tickUpper: upper,
                minExistingLiquidity: bootstrapMinimum,
                minLiquidityAdded: params.minLiquidityAdded,
                minShares: params.minShares,
                receiver: params.receiver
            })
        );
        // Probed through the bootstrapped clone, not from this Factory or before bootstrap:
        // a target may answer by caller or by the vault's own state, and the admission
        // snapshot should be the operating vault's read. A failed probe unwinds the entire
        // launch — clone, registry writes, transfers, liquidity, and shares.
        if (!ILpTokenVault(payable(vault)).targetMetadataReadable()) {
            revert UnreadableTargetMetadata(params.target);
        }

        _emitVaultLaunched(
            params.target,
            params.poolKey,
            vault,
            id,
            counterCurrency,
            params.targetAmount,
            params.counterAmount,
            shares,
            liquidityAdded,
            address(0),
            lower,
            upper
        );
    }

    /// @notice Permanently authorizes the platform launchpad. The binding cannot be
    /// rotated, keeping the privileged launch path auditable after deployment.
    function bindLaunchpad(address launchpad_) external onlyOwner {
        if (launchpad != address(0)) revert LaunchpadAlreadyBound(launchpad);
        if (launchpad_ == address(0) || launchpad_.code.length == 0) revert InvalidAddress();
        ITokenLaunchpad platform = ITokenLaunchpad(launchpad_);
        address launchFeeSource = platform.liquidityVault();
        PoolKey memory launchKey = platform.poolKey(address(1));
        if (
            address(platform.poolManager()) != address(poolManager)
                || platform.factory() != address(this) || launchFeeSource.code.length == 0
                || address(launchKey.hooks) != launchpad_
                || address(ILaunchFeeSource(launchFeeSource).poolManager()) != address(poolManager)
                || ILaunchFeeSource(launchFeeSource).launchpad() != launchpad_
                || ILaunchFeeSource(launchFeeSource).factory() != address(this)
        ) revert InvalidAddress();
        launchpad = launchpad_;
        emit LaunchpadBound(launchpad_);
    }

    /// @notice Specialized atomic path for tokens created by the permanently bound
    /// platform launchpad. Pool, quote contribution, fee source and share receiver are
    /// derived rather than caller-selectable.
    function launchFromLaunchpad(address target, uint256 targetAmount)
        external
        payable
        nonReentrant
        returns (address vault, uint256 shares, uint128 liquidityAdded)
    {
        address launchpad_ = launchpad;
        if (msg.sender != launchpad_) revert OnlyLaunchpad();
        ITokenLaunchpad platform = ITokenLaunchpad(launchpad_);
        if (!platform.isToken(target)) revert UnregisteredLaunchToken(target);

        // Read the launchpad's current terms so admission follows the owner-selected economics
        // for this launch rather than assuming compiled-in values that differ per chain.
        int24 startTick = platform.startTick();
        PoolKey memory key = platform.poolKey(target);
        if (
            !key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != target
                || address(key.hooks) != launchpad_ || key.fee != LaunchPoolConfig.LP_FEE
                || key.tickSpacing != LaunchPoolConfig.TICK_SPACING
                || targetAmount != platform.bootstrapTargetAmount()
        ) {
            revert InvalidLaunchpadPool();
        }
        uint256 counterAmount = platform.initialLpQuote();
        if (msg.value != counterAmount) revert InvalidMsgValue(msg.value, counterAmount);

        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        if (tick != startTick) revert InvalidLaunchpadPool();
        (PoolId id, bool targetIsCurrency0, Currency counterCurrency) =
            _validatePool(target, key, tick, 0, 0, false);
        address launchFeeSource = platform.liquidityVault();
        if (launchFeeSource == address(0) || launchFeeSource.code.length == 0) {
            revert InvalidAddress();
        }

        int24 lower;
        int24 upper;
        (vault, lower, upper) = _deployVault(key, id, targetIsCurrency0, launchFeeSource);
        (shares, liquidityAdded) = ILpTokenVault(payable(vault)).bootstrap{ value: msg.value }(
            ILpTokenVault.BootstrapParams({
                payer: msg.sender,
                targetAmount: targetAmount,
                counterAmount: counterAmount,
                expectedTick: startTick,
                maxTickDeviation: 0,
                tickLower: lower,
                tickUpper: upper,
                minExistingLiquidity: 0,
                minLiquidityAdded: 1,
                minShares: 0,
                receiver: LaunchPoolConfig.DEAD
            })
        );

        _emitVaultLaunched(
            target,
            key,
            vault,
            id,
            counterCurrency,
            targetAmount,
            counterAmount,
            shares,
            liquidityAdded,
            launchFeeSource,
            lower,
            upper
        );
    }

    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }

    function vaultAt(uint256 index) external view returns (address) {
        return _vaults[index];
    }

    function owner() public view override(ILpTokenFactory, Ownable) returns (address) {
        return Ownable.owner();
    }

    /// @notice Predicts the vault address for an exact target and PoolKey. The launch-fee
    /// source is part of the clone's immutable arguments and therefore part of its address,
    /// so a platform-launch PoolKey must resolve the bound launchpad's source instead of
    /// assuming a curated launch has none.
    function predictVault(address target_, PoolKey calldata poolKey_)
        external
        view
        returns (address predicted)
    {
        bool targetIsCurrency0 = Currency.unwrap(poolKey_.currency0) == target_;
        return _predictVault(poolKey_, targetIsCurrency0, _launchFeeSourceFor(target_, poolKey_));
    }

    function predictLaunchpadVault(address target_) public view returns (address predicted) {
        address launchpad_ = launchpad;
        if (launchpad_ == address(0)) revert InvalidAddress();
        ITokenLaunchpad platform = ITokenLaunchpad(launchpad_);
        return _predictVault(platform.poolKey(target_), false, platform.liquidityVault());
    }

    function vaultSalt(PoolId poolId_) public pure returns (bytes32) {
        return keccak256(abi.encode("lp{TOKEN}.vault", PoolId.unwrap(poolId_)));
    }

    function _validatePool(
        address target,
        PoolKey memory key,
        int24 expectedTick,
        uint24 maxTickDeviation,
        uint128 minExistingLiquidity,
        bool requireActiveLiquidity
    ) private view returns (PoolId id, bool targetIsCurrency0, Currency counterCurrency) {
        address leg0 = Currency.unwrap(key.currency0);
        address leg1 = Currency.unwrap(key.currency1);

        if (LPFeeLibrary.isDynamicFee(key.fee)) revert DynamicFeePoolNotSupported();
        if (
            !LPFeeLibrary.isValid(key.fee) || key.fee < MIN_POOL_LP_FEE
                || key.fee == LPFeeLibrary.MAX_LP_FEE
        ) revert InvalidFee(key.fee);
        if (
            key.tickSpacing < TickMath.MIN_TICK_SPACING
                || key.tickSpacing > TickMath.MAX_TICK_SPACING
        ) revert InvalidTickSpacing(key.tickSpacing);
        if (leg0 >= leg1) revert CurrencyOrder();

        if (target == address(0) || target.code.length == 0) revert InvalidAddress();
        if (target != leg0 && target != leg1) {
            revert TargetNotInPool(target);
        }
        targetIsCurrency0 = target == leg0;
        counterCurrency = targetIsCurrency0 ? key.currency1 : key.currency0;
        if (isVault[leg0]) revert RecursiveVaultLeg(leg0);
        if (isVault[leg1]) revert RecursiveVaultLeg(leg1);

        id = key.toId();
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized(id);
        uint128 liquidity = poolManager.getLiquidity(id);
        if (liquidity < minExistingLiquidity || (requireActiveLiquidity && liquidity == 0)) {
            revert InsufficientExistingLiquidity(liquidity, minExistingLiquidity);
        }
        uint24 deviation = SignedMath.abs(int256(tick) - int256(expectedTick)).toUint24();
        if (deviation > maxTickDeviation) {
            revert TickDeviation(deviation, maxTickDeviation);
        }

        address existingPoolVault = vaultOfPoolId[id];
        if (existingPoolVault != address(0)) revert PoolAlreadyWrapped(id, existingPoolVault);
    }

    function _emitVaultLaunched(
        address target,
        PoolKey memory key,
        address vault,
        PoolId id,
        Currency counterCurrency,
        uint256 targetAmount,
        uint256 counterAmount,
        uint256 shares,
        uint128 liquidityAdded,
        address launchFeeSource,
        int24 tickLower,
        int24 tickUpper
    ) private {
        (, int24 launchTick, uint24 protocolFee,) = poolManager.getSlot0(id);
        emit VaultLaunched(
            target,
            vault,
            msg.sender,
            id,
            key.currency0,
            key.currency1,
            address(key.hooks),
            Currency.unwrap(counterCurrency),
            counterCurrency.isAddressZero(),
            key.fee,
            key.tickSpacing,
            tickLower,
            tickUpper,
            launchTick,
            protocolFee,
            targetAmount,
            counterAmount,
            shares,
            liquidityAdded,
            launchFeeSource
        );
    }

    /// @dev Returns the boundary ticks alongside the clone: they are pinned into the vault by
    /// `bootstrap` rather than folded into the clone arguments, so the address a caller
    /// predicted and approved cannot move when a leg's supply changes before the launch.
    function _deployVault(
        PoolKey memory key,
        PoolId id,
        bool targetIsCurrency0,
        address launchFeeSource
    ) private returns (address vault, int24 lower, int24 upper) {
        (lower, upper) = _vaultTicks(key, launchFeeSource);
        vault = Clones.cloneDeterministicWithImmutableArgs(
            vaultImplementation, _vaultArgs(key, targetIsCurrency0, launchFeeSource), vaultSalt(id)
        );
        vaultOfPoolId[id] = vault;
        isVault[vault] = true;
        _vaults.push(vault);
    }

    function _predictVault(PoolKey memory key, bool targetIsCurrency0, address launchFeeSource)
        private
        view
        returns (address)
    {
        return Clones.predictDeterministicAddressWithImmutableArgs(
            vaultImplementation,
            _vaultArgs(key, targetIsCurrency0, launchFeeSource),
            vaultSalt(key.toId()),
            address(this)
        );
    }

    /// @dev Every launch pool pairs the native currency with the same fixed supply, so its
    /// range is the pinned pair rather than a fresh derivation. That keeps the launchpad views
    /// answerable before the token exists, and `VaultRange.t.sol` holds the two in step.
    function _vaultTicks(PoolKey memory key, address launchFeeSource)
        private
        view
        returns (int24 lower, int24 upper)
    {
        if (launchFeeSource != address(0)) return LaunchPoolConfig.vaultTicks();
        return VaultRange.ticks(key);
    }

    /// @dev Only the exact PoolKey the launchpad derives for a token it created carries a
    /// launch-fee source, matching `launchFromLaunchpad`. Any other pool, including a second
    /// pool holding the same token, is an ordinary curated launch with no source.
    function _launchFeeSourceFor(address target_, PoolKey calldata key)
        private
        view
        returns (address)
    {
        address launchpad_ = launchpad;
        if (launchpad_ == address(0)) return address(0);
        ITokenLaunchpad platform = ITokenLaunchpad(launchpad_);
        if (!platform.isToken(target_)) return address(0);
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(platform.poolKey(target_).toId())) {
            return address(0);
        }
        return platform.liquidityVault();
    }

    function _vaultArgs(PoolKey memory key, bool targetIsCurrency0, address launchFeeSource)
        private
        pure
        returns (bytes memory)
    {
        return abi.encode(
            LpTokenVault.ImmutableArgs({
                currency0: key.currency0,
                currency1: key.currency1,
                fee: key.fee,
                tickSpacing: key.tickSpacing,
                hooks: key.hooks,
                targetIsCurrency0: targetIsCurrency0,
                launchFeeSource: launchFeeSource
            })
        );
    }
}
