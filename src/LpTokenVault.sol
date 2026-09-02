// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { SignedMath } from "@openzeppelin/contracts/utils/math/SignedMath.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { FixedPoint128 } from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { Pool } from "@uniswap/v4-core/src/libraries/Pool.sol";
import { SqrtPriceMath } from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import { ERC20PermitBase } from "./ERC20PermitBase.sol";
import { CurrencyTransfer } from "./libraries/CurrencyTransfer.sol";
import { TokenMetadata } from "./libraries/TokenMetadata.sol";
import { ILaunchFeeSource } from "./interfaces/ILaunchFeeSource.sol";
import { ILpTokenFactory } from "./interfaces/ILpTokenFactory.sol";
import { ILpTokenVault } from "./interfaces/ILpTokenVault.sol";

/// @notice Immutable passive vault owning a single salt-0 position, spanning the range
/// `VaultRange` pins at launch, in one exact, static-fee Uniswap V4 PoolKey. Shares are an
/// exact pro-rata claim on two raw currencies; the vault never swaps, never prices in a
/// foreign numeraire, and never treats pool-wide liquidity as its own.
contract LpTokenVault is ERC20PermitBase, ReentrancyGuardTransient, IUnlockCallback {
    using SafeCast for int256;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    uint256 public constant BPS = 10_000;
    uint256 public constant DEAD_SHARES = 1_000_000;
    /// @notice Fee charged in backed lpTOKEN shares on public mint and redeem flows.
    uint256 public constant SHARE_FEE_BPS = 30;
    /// @notice Smallest public assessment whose exact 30-bps fee is at least one raw share.
    uint256 public constant MIN_FEEABLE_SHARES = (BPS + SHARE_FEE_BPS - 1) / SHARE_FEE_BPS;
    uint64 public constant COMPOUND_INTERVAL = 10 minutes;
    uint256 public constant COMPOUND_SAFETY_BPS = 5_000;
    address public constant DEAD_SHARE_RECEIVER = 0x000000000000000000000000000000000000dEaD;
    bytes32 public constant POSITION_SALT = bytes32(0);

    address private immutable _factory;
    IPoolManager private immutable _poolManager;

    struct ImmutableArgs {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        int24 tickSpacing;
        IHooks hooks;
        bool targetIsCurrency0;
        address launchFeeSource;
    }

    /// @dev Immutable clone configuration and values derived exclusively from it. Loading this
    /// once per entry point keeps dependencies explicit without caching dynamic pool state.
    struct VaultContext {
        Currency targetCurrency;
        Currency counterCurrency;
        PoolId poolId;
        address launchFeeSource;
        uint24 fee;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        bool targetIsCurrency0;
    }

    /// @dev Dynamic position and receivable state used to quote one proportional mint.
    struct PortfolioSnapshot {
        uint160 sqrtPriceX96;
        uint128 liquidity;
        uint256 targetAssets;
        uint256 counterAssets;
        uint256 idleTarget;
        uint256 idleCounter;
    }

    uint64 public lastCompoundAt;
    /// @dev Boundary ticks of the permanent position, pinned by the Factory at bootstrap and
    /// never moved. They are not clone arguments because they follow the legs' supply, which
    /// keeps changing: deriving them per call would let a later mint move the position, and
    /// folding them into the clone address would make it drift between prediction and launch.
    int24 private _tickLower;
    int24 private _tickUpper;

    error OnlyFactory();
    error OnlyPoolManager();
    error AlreadyBootstrapped();
    error NotBootstrapped();
    error DeadlineExpired();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidMsgValue(uint256 provided, uint256 expected);
    error InsufficientShares(uint256 shares, uint256 minimum);
    error InsufficientTarget(uint256 amount, uint256 minimum);
    error InsufficientCounter(uint256 amount, uint256 minimum);
    error InsufficientLiquidityAdded(uint128 liquidity, uint128 minimum);
    error InsufficientExistingLiquidity(uint128 liquidity, uint128 minimum);
    error TickDeviation(uint24 deviation, uint24 maximum);
    error CompoundCooldown(uint64 availableAt);
    error NativeOnlyFromAuthorizedSource();

    event Bootstrapped(
        address indexed payer,
        address indexed receiver,
        uint256 targetIn,
        uint256 counterIn,
        uint256 receiverShares,
        uint256 deadShares,
        uint128 liquidity
    );
    event PairMinted(
        address indexed sender,
        address indexed receiver,
        uint256 targetIn,
        uint256 counterIn,
        uint256 shares,
        uint256 totalSupply,
        uint128 liquidity
    );
    event Redeemed(
        address indexed sender,
        address indexed receiver,
        uint256 shares,
        uint256 targetOut,
        uint256 counterOut,
        uint256 totalSupply,
        uint128 liquidity
    );
    event PositionFeesCollected(uint256 targetFees, uint256 counterFees, uint256 totalSupply);
    /// @notice Reports the backed-share fee charged to the receiving account on mint or
    /// the submitting owner on redeem.
    event ShareFeeCharged(
        address indexed shareAccount,
        address indexed treasury,
        bool indexed redemption,
        uint256 assessedShares,
        uint256 feeShares
    );
    event Compounded(
        address indexed caller,
        uint256 targetDeployed,
        uint256 counterDeployed,
        uint128 liquidityAdded,
        uint128 totalLiquidity
    );

    /// @notice Reverts if the caller-provided deadline has passed.
    modifier checkDeadline(uint256 deadline) {
        _checkDeadline(deadline);
        _;
    }

    constructor(address factory_, IPoolManager poolManager_) ERC20("", "") {
        if (factory_ == address(0) || address(poolManager_) == address(0)) {
            revert InvalidAddress();
        }
        _factory = factory_;
        _poolManager = poolManager_;
    }

    receive() external payable {
        if (msg.sender != address(_poolManager) && msg.sender != launchFeeSource()) {
            revert NativeOnlyFromAuthorizedSource();
        }
    }

    function factory() public view returns (address) {
        return _factory;
    }

    function poolManager() public view returns (IPoolManager) {
        return _poolManager;
    }

    function treasury() public view returns (address) {
        return ILpTokenFactory(_factory).treasury();
    }

    function launchFeeSource() public view returns (address) {
        return _immutableArgs().launchFeeSource;
    }

    function target() public view returns (address) {
        return Currency.unwrap(_targetCurrency(_immutableArgs()));
    }

    function counter() public view returns (Currency) {
        return _counterCurrency(_immutableArgs());
    }

    function counterIsNative() public view returns (bool) {
        return _counterCurrency(_immutableArgs()).isAddressZero();
    }

    function targetIsCurrency0() public view returns (bool) {
        return _immutableArgs().targetIsCurrency0;
    }

    function currency0() public view returns (Currency) {
        return _immutableArgs().currency0;
    }

    function currency1() public view returns (Currency) {
        return _immutableArgs().currency1;
    }

    function lpFee() public view returns (uint24) {
        return _immutableArgs().fee;
    }

    function tickSpacing() public view returns (int24) {
        return _immutableArgs().tickSpacing;
    }

    function tickLower() public view returns (int24) {
        return _tickLower;
    }

    function tickUpper() public view returns (int24) {
        return _tickUpper;
    }

    function poolKey() public view returns (PoolKey memory key) {
        return _poolKey(_immutableArgs());
    }

    function poolId() public view returns (bytes32) {
        return PoolId.unwrap(_poolKey(_immutableArgs()).toId());
    }

    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 poolLpFee)
    {
        return _poolManager.getSlot0(_poolKey(_immutableArgs()).toId());
    }

    function name() public view override returns (string memory) {
        return _targetMetadata(IERC20Metadata.name.selector, "lpToken");
    }

    function symbol() public view override returns (string memory) {
        return _targetMetadata(IERC20Metadata.symbol.selector, "lpTOKEN");
    }

    /// @notice Whether the target's name and symbol currently read as strings from this
    /// vault's own caller context. The Factory requires this at a curated admission,
    /// probing through the vault after bootstrap rather than from itself, since a target
    /// may answer by caller or by this vault's state. That makes admission a point-in-time
    /// snapshot of the operating vault's read — a target keying on still-later context can
    /// only diverge afterward, which is the fallback's class.
    function targetMetadataReadable() external view returns (bool) {
        (bool nameReadable,) = _readTargetMetadata(IERC20Metadata.name.selector);
        if (!nameReadable) return false;
        (bool symbolReadable,) = _readTargetMetadata(IERC20Metadata.symbol.selector);
        return symbolReadable;
    }

    /// @dev Prefixes the target's metadata field with "lp". Admission required both fields
    /// to read as strings from this same caller context on the bootstrapped vault, so the
    /// fallback covers one class: a target whose answer diverged after that snapshot, the
    /// same class as one that renames itself. Reporting instead of reverting is what keeps
    /// every name-derived read — the EIP-712 domain and `permit` included — alive on such a
    /// market; `TokenMetadata`'s caps keep a hostile target from making the read
    /// unaffordable instead.
    function _targetMetadata(bytes4 selector, string memory fallbackValue)
        private
        view
        returns (string memory)
    {
        (bool ok, string memory value) = _readTargetMetadata(selector);
        if (!ok) return fallbackValue;
        return string.concat("lp", value);
    }

    function _readTargetMetadata(bytes4 selector)
        private
        view
        returns (bool ok, string memory value)
    {
        return TokenMetadata.read(target(), selector);
    }

    function bootstrap(ILpTokenVault.BootstrapParams calldata params)
        external
        payable
        nonReentrant
        returns (uint256 receiverShares, uint128 liquidityAdded)
    {
        if (msg.sender != factory()) revert OnlyFactory();
        VaultContext memory context = _loadContext();
        if (totalSupply() != 0) revert AlreadyBootstrapped();
        if (params.receiver == address(0)) revert InvalidAddress();
        if (params.targetAmount == 0 || params.counterAmount == 0) revert InvalidAmount();
        // The context was loaded before the range existed, so it takes the same values the
        // position is being pinned to and every later call reads back from storage.
        context.tickLower = params.tickLower;
        context.tickUpper = params.tickUpper;
        _tickLower = params.tickLower;
        _tickUpper = params.tickUpper;
        _receiveCounterExact(context, params.payer, params.counterAmount, params.counterAmount);
        CurrencyTransfer.pullExact(
            Currency.unwrap(context.targetCurrency), params.payer, params.targetAmount
        );
        _validateBootstrapState(
            context, params.expectedTick, params.maxTickDeviation, params.minExistingLiquidity
        );

        liquidityAdded = _deployCapped(context, params.targetAmount, params.counterAmount);
        if (liquidityAdded < params.minLiquidityAdded || liquidityAdded == 0) {
            revert InsufficientLiquidityAdded(liquidityAdded, params.minLiquidityAdded);
        }

        uint256 initialShares = uint256(liquidityAdded);
        if (initialShares <= DEAD_SHARES) revert InvalidAmount();
        receiverShares = initialShares - DEAD_SHARES;
        if (receiverShares < params.minShares) {
            revert InsufficientShares(receiverShares, params.minShares);
        }

        _mint(DEAD_SHARE_RECEIVER, DEAD_SHARES);
        _mint(params.receiver, receiverShares);
        lastCompoundAt = uint64(block.timestamp);
        emit Bootstrapped(
            params.payer,
            params.receiver,
            params.targetAmount,
            params.counterAmount,
            receiverShares,
            DEAD_SHARES,
            liquidityAdded
        );
    }

    function _validateBootstrapState(
        VaultContext memory context,
        int24 expectedTick,
        uint24 maxTickDeviation,
        uint128 minExistingLiquidity
    ) private view {
        IPoolManager manager = _poolManager;
        (, int24 currentTick,,) = manager.getSlot0(context.poolId);
        uint24 deviation = SignedMath.abs(int256(currentTick) - int256(expectedTick)).toUint24();
        if (deviation > maxTickDeviation) revert TickDeviation(deviation, maxTickDeviation);

        uint128 liquidity = manager.getLiquidity(context.poolId);
        if (liquidity < minExistingLiquidity) {
            revert InsufficientExistingLiquidity(liquidity, minExistingLiquidity);
        }
    }

    /// @notice Deposits a proportional pair, mints fully backed gross shares, and sends
    /// the share fee to Treasury. `shares` and `minShares` are net receiver shares.
    function mintPair(
        uint256 maxTarget,
        uint256 maxCounter,
        uint256 minShares,
        address receiver,
        uint256 deadline
    )
        external
        payable
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 shares, uint256 targetUsed, uint256 counterUsed)
    {
        VaultContext memory context = _loadContext();
        if (receiver == address(0)) revert InvalidAddress();
        if (totalSupply() == 0) revert NotBootstrapped();
        bool isNativeCounter = context.counterCurrency.isAddressZero();
        uint256 expectedMsgValue = isNativeCounter ? maxCounter : 0;
        if (msg.value != expectedMsgValue) revert InvalidMsgValue(msg.value, expectedMsgValue);

        // Quote first, then pull only the quoted amounts. A supported ERC-20 may still
        // execute arbitrary code from transferFrom, so authoritative fee collection and
        // share price must come after both pulls.
        (, uint256 quotedGrossShares, uint256 targetDeposited, uint256 counterDeposited,) =
            _previewMintPair(context, maxTarget, maxCounter, 0, msg.value);
        if (quotedGrossShares < MIN_FEEABLE_SHARES) {
            revert InsufficientShares(quotedGrossShares, MIN_FEEABLE_SHARES);
        }
        if (targetDeposited == 0 || counterDeposited == 0) {
            revert InsufficientShares(0, minShares);
        }

        CurrencyTransfer.pullExact(
            Currency.unwrap(context.targetCurrency), msg.sender, targetDeposited
        );
        if (!isNativeCounter) {
            CurrencyTransfer.pullExact(
                Currency.unwrap(context.counterCurrency), msg.sender, counterDeposited
            );
        }

        _syncLaunchFees(context);
        _collectPositionFees(context);
        uint256 counterExcluded = isNativeCounter ? msg.value : counterDeposited;
        uint256 grossShares;
        uint128 liquidityAdded;
        (shares, grossShares, targetUsed, counterUsed, liquidityAdded) = _previewMintPair(
            context, targetDeposited, counterDeposited, targetDeposited, counterExcluded
        );
        if (grossShares < MIN_FEEABLE_SHARES) {
            revert InsufficientShares(grossShares, MIN_FEEABLE_SHARES);
        }
        if (shares == 0 || shares < minShares) revert InsufficientShares(shares, minShares);

        // Scale every component of the existing portfolio by the same gross-share ratio.
        // The proportional position addition preserves liquidity per share, while the
        // remainder of each deposit preserves idle assets per share. A mint therefore
        // cannot move pre-existing idle NAV into the pool at a caller-selected price.
        _deployLiquidity(context, liquidityAdded);
        _mint(receiver, shares);
        uint256 feeShares = grossShares - shares;
        address treasuryAddress = treasury();
        if (feeShares != 0) _mint(treasuryAddress, feeShares);
        emit ShareFeeCharged(receiver, treasuryAddress, false, grossShares, feeShares);
        CurrencyTransfer.transfer(context.targetCurrency, msg.sender, targetDeposited - targetUsed);
        uint256 counterReceived = isNativeCounter ? maxCounter : counterDeposited;
        CurrencyTransfer.transfer(
            context.counterCurrency, msg.sender, counterReceived - counterUsed
        );
        emit PairMinted(
            msg.sender,
            receiver,
            targetUsed,
            counterUsed,
            shares,
            totalSupply(),
            _positionLiquidity(context)
        );
    }

    /// @notice Transfers the share fee to Treasury, burns the remaining submitted shares,
    /// and returns the corresponding net asset claim.
    function redeem(
        uint256 shares,
        uint256 minTarget,
        uint256 minCounter,
        address receiver,
        uint256 deadline
    )
        external
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 targetOut, uint256 counterOut)
    {
        VaultContext memory context = _loadContext();
        if (shares == 0 || receiver == address(0)) revert InvalidAmount();
        if (shares < MIN_FEEABLE_SHARES) {
            revert InsufficientShares(shares, MIN_FEEABLE_SHARES);
        }
        _syncLaunchFees(context);
        _collectPositionFees(context);

        uint256 supply = totalSupply();
        uint256 feeShares = _shareFee(shares);
        uint256 redeemedShares = shares - feeShares;
        (uint256 targetClaim, uint256 counterClaim) = _totalAssets(context, 0, 0);
        targetOut = FullMath.mulDiv(targetClaim, redeemedShares, supply);
        counterOut = FullMath.mulDiv(counterClaim, redeemedShares, supply);

        address treasuryAddress = treasury();
        if (feeShares != 0) _transfer(msg.sender, treasuryAddress, feeShares);
        _burn(msg.sender, redeemedShares);
        emit ShareFeeCharged(msg.sender, treasuryAddress, true, shares, feeShares);
        uint128 liquidityBefore = _positionLiquidity(context);
        uint128 liquidityToRemove =
            FullMath.mulDiv(liquidityBefore, redeemedShares, supply).toUint128();
        if (liquidityToRemove != 0) {
            (, BalanceDelta feesAccrued) = _modifyLiquidity(-uint256(liquidityToRemove).toInt256());
            _reportPositionFees(context, feesAccrued);
        }
        uint128 liquidityAfter = liquidityBefore - liquidityToRemove;

        (uint256 freeTarget, uint256 freeCounter) = _freeBalances(context, 0, 0);
        if (targetOut > freeTarget) targetOut = freeTarget;
        if (counterOut > freeCounter) counterOut = freeCounter;
        if (targetOut < minTarget) revert InsufficientTarget(targetOut, minTarget);
        if (counterOut < minCounter) revert InsufficientCounter(counterOut, minCounter);

        CurrencyTransfer.transfer(context.targetCurrency, receiver, targetOut);
        CurrencyTransfer.transfer(context.counterCurrency, receiver, counterOut);
        emit Redeemed(
            msg.sender, receiver, shares, targetOut, counterOut, totalSupply(), liquidityAfter
        );
    }

    /// @notice Permissionlessly reinvests matched free balances after the cooldown. Each
    /// call is capped relative to protocol-owned liquidity active in the pool; one-sided or
    /// capped residue stays idle and remains redeemable.
    /// @dev The cap and cooldown bound spot-timing exposure but do not observe fair value.
    /// This function uses current slot0, and a malicious caller controls its own minimum and
    /// deadline. It intentionally provides no oracle/TWAP or flash-manipulation proof. The
    /// contract deploys the computed executable amount, but a dust-sized success still starts
    /// the cooldown and can impose a small opportunity-cost grief.
    function compound(uint128 minLiquidityAdded, uint256 deadline)
        external
        nonReentrant
        checkDeadline(deadline)
        returns (uint128 liquidityAdded)
    {
        VaultContext memory context = _loadContext();
        if (totalSupply() == 0) revert NotBootstrapped();
        uint64 availableAt = compoundAvailableAt();
        if (block.timestamp < availableAt) revert CompoundCooldown(availableAt);
        _syncLaunchFees(context);
        _collectPositionFees(context);

        (uint256 freeTarget, uint256 freeCounter) = _freeBalances(context, 0, 0);
        (uint256 targetBefore, uint256 counterBefore) = (freeTarget, freeCounter);
        uint128 currentLiquidity = _positionLiquidity(context);
        uint128 liquidityCap =
            _compoundLiquidityCap(context, _liquidityCapacity(context, currentLiquidity));
        liquidityAdded = _liquidityForAmountsUpTo(context, freeTarget, freeCounter, liquidityCap);
        if (liquidityAdded < minLiquidityAdded || liquidityAdded == 0) {
            revert InsufficientLiquidityAdded(liquidityAdded, minLiquidityAdded);
        }
        _deployLiquidity(context, liquidityAdded);
        (uint256 targetAfter, uint256 counterAfter) = _freeBalances(context, 0, 0);
        uint128 totalLiquidity = currentLiquidity + liquidityAdded;
        lastCompoundAt = uint64(block.timestamp);
        emit Compounded(
            msg.sender,
            targetBefore - targetAfter,
            counterBefore - counterAfter,
            liquidityAdded,
            totalLiquidity
        );
    }

    function totalAssets() public view returns (uint256 targetAssets, uint256 counterAssets) {
        return _totalAssets(_loadContext(), 0, 0);
    }

    /// @notice Gross holder claim before the redeem share fee is applied.
    function claimForShares(uint256 shares)
        public
        view
        returns (uint256 targetClaim, uint256 counterClaim)
    {
        uint256 supply = totalSupply();
        if (supply == 0) return (0, 0);
        (uint256 targetAssets, uint256 counterAssets) = _totalAssets(_loadContext(), 0, 0);
        targetClaim = FullMath.mulDiv(targetAssets, shares, supply);
        counterClaim = FullMath.mulDiv(counterAssets, shares, supply);
    }

    function previewMintPair(uint256 maxTarget, uint256 maxCounter)
        external
        view
        returns (uint256 shares, uint256 targetUsed, uint256 counterUsed)
    {
        (shares,, targetUsed, counterUsed,) =
            _previewMintPair(_loadContext(), maxTarget, maxCounter, 0, 0);
    }

    function previewRedeem(uint256 shares)
        external
        view
        returns (uint256 targetOut, uint256 counterOut)
    {
        if (shares < MIN_FEEABLE_SHARES) return (0, 0);
        return claimForShares(shares - _shareFee(shares));
    }

    function compoundAvailableAt() public view returns (uint64) {
        return lastCompoundAt + COMPOUND_INTERVAL;
    }

    /// @notice Maximum liquidity deployable in the current interval. The cap is 50% of
    /// `f / (1 - f)` applied to the economic base, where `f` is the immutable pool LP fee.
    /// Shared boundary-tick headroom only constrains execution.
    function compoundLiquidityCap() public view returns (uint128) {
        VaultContext memory context = _loadContext();
        uint128 currentLiquidity = _positionLiquidity(context);
        return _compoundLiquidityCap(context, _liquidityCapacity(context, currentLiquidity));
    }

    /// @notice Protocol-owned liquidity that is live in this pool right now. A proportional
    /// mint scales the vault position, idle assets, and share supply together, so increasing
    /// this base cannot increase the compound allowance attributable to an existing share.
    /// External liquidity is excluded because it can be added temporarily without backing
    /// lpTOKEN shares. The permanent launch position counts only while it is in range.
    function compoundBase() public view returns (uint128) {
        return _compoundBase(_loadContext());
    }

    function _compoundBase(VaultContext memory context) private view returns (uint128) {
        (, int24 tick,,) = _poolManager.getSlot0(context.poolId);
        uint128 vaultBase;
        if (tick >= context.tickLower && tick < context.tickUpper) {
            vaultBase = _positionLiquidity(context);
        }

        uint256 protocolOwned = uint256(vaultBase) + uint256(_activeLaunchLiquidity(context));
        // Redundant while both terms are in range, kept so the invariant that the base
        // never exceeds live pool liquidity holds locally rather than by inference.
        uint256 active = _poolManager.getLiquidity(context.poolId);
        return uint128(protocolOwned < active ? protocolOwned : active);
    }

    /// @dev The permanent launch position shares this PoolKey and has no removal path, but
    /// its range ends at the launch tick, so the source reports zero once the price leaves
    /// it. The source also confirms the position belongs to this vault.
    function _activeLaunchLiquidity(VaultContext memory context) private view returns (uint128) {
        address source = context.launchFeeSource;
        if (source == address(0)) return 0;
        return ILaunchFeeSource(source)
            .activeLiquidity(Currency.unwrap(context.targetCurrency), address(this));
    }

    function _compoundLiquidityCap(VaultContext memory context, uint128 capacity)
        private
        view
        returns (uint128)
    {
        uint128 baseLiquidity = _compoundBase(context);

        uint24 fee = context.fee;
        uint256 cap = FullMath.mulDiv(
            baseLiquidity,
            uint256(fee) * COMPOUND_SAFETY_BPS,
            uint256(LPFeeLibrary.MAX_LP_FEE - fee) * BPS
        );
        if (cap > capacity) return capacity;
        return cap.toUint128();
    }

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
        )
    {
        VaultContext memory context = _loadContext();
        (uint256 freeTarget, uint256 freeCounter) = _freeBalances(context, 0, 0);
        (uint256 pendingTarget, uint256 pendingCounter) = _pendingFees(context);
        (uint256 launchTarget, uint256 launchCounter) = _pendingLaunchFees(context);
        freeTarget += pendingTarget + launchTarget;
        freeCounter += pendingCounter + launchCounter;

        uint128 currentLiquidity = _positionLiquidity(context);
        uint128 capacity = _liquidityCapacity(context, currentLiquidity);
        (uint160 sqrtPriceX96,,,) = _poolManager.getSlot0(context.poolId);
        availableLiquidity = _liquidityForAmountsUpToAtPrice(
            context, sqrtPriceX96, freeTarget, freeCounter, capacity
        );
        liquidityCap = _compoundLiquidityCap(context, capacity);
        availableAt = compoundAvailableAt();
        if (block.timestamp < availableAt) {
            return (0, 0, availableLiquidity, liquidityCap, 0, availableAt);
        }

        executableLiquidity = availableLiquidity < liquidityCap ? availableLiquidity : liquidityCap;
        (uint256 used0, uint256 used1) = _amountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(context.tickLower),
            TickMath.getSqrtPriceAtTick(context.tickUpper),
            executableLiquidity,
            true
        );
        (targetToDeploy, counterToDeploy) =
            _toTargetCounter(context.targetIsCurrency0, used0, used1);
    }

    function pendingFees() public view returns (uint256 targetFees, uint256 counterFees) {
        return _pendingFees(_loadContext());
    }

    function idleBalances() public view returns (uint256 targetIdle, uint256 counterIdle) {
        return _rawBalances(_loadContext());
    }

    function positionLiquidity() public view returns (uint128 liquidity) {
        return _positionLiquidity(_loadContext());
    }

    function positionPrincipal()
        external
        view
        returns (uint256 targetPrincipal, uint256 counterPrincipal)
    {
        return _positionPrincipal(_loadContext());
    }

    function positionTicks() external view returns (int24 lower, int24 upper) {
        return (_tickLower, _tickUpper);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory result) {
        IPoolManager manager = _poolManager;
        if (msg.sender != address(manager)) revert OnlyPoolManager();
        ImmutableArgs memory args = _immutableArgs();
        int24 lower = _tickLower;
        int24 upper = _tickUpper;
        int256 liquidityDelta = abi.decode(data, (int256));
        (BalanceDelta delta, BalanceDelta feesAccrued) = manager.modifyLiquidity(
            _poolKey(args),
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: liquidityDelta,
                salt: POSITION_SALT
            }),
            bytes("")
        );
        CurrencyTransfer.settleDelta(manager, args.currency0, args.currency1, delta);
        return abi.encode(delta, feesAccrued);
    }

    function _collectPositionFees(VaultContext memory context) private {
        (, BalanceDelta feesAccrued) = _modifyLiquidity(0);
        _reportPositionFees(context, feesAccrued);
    }

    /// @dev Full-range position fees have no performance cut. PoolManager settlement
    /// leaves every collected asset in this vault as holder NAV.
    function _reportPositionFees(VaultContext memory context, BalanceDelta feesAccrued) private {
        (uint256 fees0, uint256 fees1) = _positiveAmounts(feesAccrued);
        (uint256 feesTarget, uint256 feesCounter) =
            _toTargetCounter(context.targetIsCurrency0, fees0, fees1);
        if (feesTarget != 0 || feesCounter != 0) {
            emit PositionFeesCollected(feesTarget, feesCounter, totalSupply());
        }
    }

    /// @dev Adds the maximum liquidity fundable by exactly `targetAmount` and
    /// `counterAmount` at the current pool price. Never reads free balances, so callers
    /// control precisely which assets a given flow may deploy.
    function _deployCapped(VaultContext memory context, uint256 targetAmount, uint256 counterAmount)
        private
        returns (uint128 liquidityAdded)
    {
        liquidityAdded = _liquidityForAmounts(context, targetAmount, counterAmount);
        _deployLiquidity(context, liquidityAdded);
    }

    function _deployLiquidity(VaultContext memory context, uint128 liquidity) private {
        if (liquidity == 0) return;
        (, BalanceDelta feesAccrued) = _modifyLiquidity(uint256(liquidity).toInt256());
        _reportPositionFees(context, feesAccrued);
    }

    function _liquidityForAmounts(
        VaultContext memory context,
        uint256 targetAmount,
        uint256 counterAmount
    ) private view returns (uint128 liquidity) {
        (uint160 sqrtPriceX96,,,) = _poolManager.getSlot0(context.poolId);
        return _liquidityForAmountsAtPrice(context, sqrtPriceX96, targetAmount, counterAmount);
    }

    function _liquidityForAmountsAtPrice(
        VaultContext memory context,
        uint160 sqrtPriceX96,
        uint256 targetAmount,
        uint256 counterAmount
    ) private pure returns (uint128 liquidity) {
        (uint256 amount0, uint256 amount1) =
            _toSorted(context.targetIsCurrency0, targetAmount, counterAmount);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(context.tickLower),
            TickMath.getSqrtPriceAtTick(context.tickUpper),
            amount0,
            amount1
        );
    }

    /// @dev Returns fundable liquidity up to `limit` without allowing oversized donated
    /// balances to overflow LiquidityAmounts' uint128 result or PoolManager's int128 deltas.
    function _liquidityForAmountsUpTo(
        VaultContext memory context,
        uint256 targetAmount,
        uint256 counterAmount,
        uint128 limit
    ) private view returns (uint128 liquidity) {
        (uint160 sqrtPriceX96,,,) = _poolManager.getSlot0(context.poolId);
        return _liquidityForAmountsUpToAtPrice(
            context, sqrtPriceX96, targetAmount, counterAmount, limit
        );
    }

    function _liquidityForAmountsUpToAtPrice(
        VaultContext memory context,
        uint160 sqrtPriceX96,
        uint256 targetAmount,
        uint256 counterAmount,
        uint128 limit
    ) private pure returns (uint128 liquidity) {
        if (limit == 0) return 0;

        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(context.tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(context.tickUpper);
        (uint256 amount0, uint256 amount1) =
            _toSorted(context.targetIsCurrency0, targetAmount, counterAmount);
        uint256 maximumPoolDelta = uint256(uint128(type(int128).max));
        if (amount0 > maximumPoolDelta) amount0 = maximumPoolDelta;
        if (amount1 > maximumPoolDelta) amount1 = maximumPoolDelta;

        (uint256 required0, uint256 required1) =
            _amountsForLiquidity(sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, limit, true);
        if (amount0 >= required0 && amount1 >= required1) return limit;

        if (sqrtPriceX96 <= sqrtPriceLowerX96) {
            return LiquidityAmounts.getLiquidityForAmount0(
                sqrtPriceLowerX96, sqrtPriceUpperX96, amount0
            );
        }
        if (sqrtPriceX96 >= sqrtPriceUpperX96) {
            return LiquidityAmounts.getLiquidityForAmount1(
                sqrtPriceLowerX96, sqrtPriceUpperX96, amount1
            );
        }

        uint128 liquidity0 = amount0 >= required0
            ? limit
            : LiquidityAmounts.getLiquidityForAmount0(sqrtPriceX96, sqrtPriceUpperX96, amount0);
        uint128 liquidity1 = amount1 >= required1
            ? limit
            : LiquidityAmounts.getLiquidityForAmount1(sqrtPriceLowerX96, sqrtPriceX96, amount1);
        liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
    }

    /// @dev Clamps additions to the position, call-delta, and shared boundary-tick limits
    /// enforced by PoolManager.
    function _liquidityCapacity(VaultContext memory context, uint128 currentLiquidity)
        private
        view
        returns (uint128 capacity)
    {
        capacity = type(uint128).max - currentLiquidity;
        uint128 maximumDelta = uint128(type(int128).max);
        if (capacity > maximumDelta) capacity = maximumDelta;

        uint128 maximumPerTick = Pool.tickSpacingToMaxLiquidityPerTick(context.tickSpacing);
        (uint128 lowerLiquidityGross,) =
            _poolManager.getTickLiquidity(context.poolId, context.tickLower);
        (uint128 upperLiquidityGross,) =
            _poolManager.getTickLiquidity(context.poolId, context.tickUpper);

        uint128 lowerHeadroom = maximumPerTick - lowerLiquidityGross;
        uint128 upperHeadroom = maximumPerTick - upperLiquidityGross;
        if (capacity > lowerHeadroom) capacity = lowerHeadroom;
        if (capacity > upperHeadroom) capacity = upperHeadroom;
    }

    function _previewMintPair(
        VaultContext memory context,
        uint256 maxTarget,
        uint256 maxCounter,
        uint256 targetExcluded,
        uint256 counterExcluded
    )
        private
        view
        returns (
            uint256 shares,
            uint256 grossShares,
            uint256 targetUsed,
            uint256 counterUsed,
            uint128 liquidityAdded
        )
    {
        uint256 supply = totalSupply();
        if (supply == 0) return (0, 0, 0, 0, 0);
        PortfolioSnapshot memory portfolio =
            _portfolioSnapshot(context, targetExcluded, counterExcluded);
        if (portfolio.targetAssets == 0 || portfolio.counterAssets == 0) {
            return (0, 0, 0, 0, 0);
        }

        uint256 targetShares = FullMath.mulDiv(maxTarget, supply, portfolio.targetAssets);
        uint256 counterShares = FullMath.mulDiv(maxCounter, supply, portfolio.counterAssets);
        grossShares = targetShares < counterShares ? targetShares : counterShares;
        uint128 currentLiquidity = portfolio.liquidity;
        if (currentLiquidity == 0) return (0, 0, 0, 0, 0);

        uint128 capacity = _liquidityCapacity(context, currentLiquidity);
        uint256 capacityShares = FullMath.mulDiv(capacity, supply, currentLiquidity);
        if (grossShares > capacityShares) grossShares = capacityShares;
        if (grossShares < MIN_FEEABLE_SHARES) return (0, grossShares, 0, 0, 0);

        // The asset-ratio quote is exact in real arithmetic. Integer liquidity and token
        // deltas can round up independently, so reduce the candidate only when those exact
        // backing requirements exceed a caller's maximum.
        for (uint256 i; i < 4; ++i) {
            (targetUsed, counterUsed, liquidityAdded) = _mintBackingForShares(
                context,
                portfolio.sqrtPriceX96,
                currentLiquidity,
                portfolio.idleTarget,
                portfolio.idleCounter,
                supply,
                grossShares
            );
            if (targetUsed <= maxTarget && counterUsed <= maxCounter) break;

            uint256 targetFit = targetUsed > maxTarget
                ? FullMath.mulDiv(grossShares, maxTarget, targetUsed)
                : grossShares;
            uint256 counterFit = counterUsed > maxCounter
                ? FullMath.mulDiv(grossShares, maxCounter, counterUsed)
                : grossShares;
            uint256 nextGrossShares = targetFit < counterFit ? targetFit : counterFit;
            if (nextGrossShares >= grossShares) nextGrossShares = grossShares - 1;
            grossShares = nextGrossShares;
            if (grossShares < MIN_FEEABLE_SHARES) return (0, grossShares, 0, 0, 0);
        }
        if (targetUsed > maxTarget || counterUsed > maxCounter) {
            return (0, grossShares, 0, 0, 0);
        }

        shares = grossShares - _shareFee(grossShares);
    }

    function _portfolioSnapshot(
        VaultContext memory context,
        uint256 targetExcluded,
        uint256 counterExcluded
    ) private view returns (PortfolioSnapshot memory snapshot) {
        (snapshot.sqrtPriceX96,,,) = _poolManager.getSlot0(context.poolId);
        uint256 last0;
        uint256 last1;
        (snapshot.liquidity, last0, last1) = _poolManager.getPositionInfo(
            context.poolId, address(this), context.tickLower, context.tickUpper, POSITION_SALT
        );
        if (snapshot.liquidity == 0) return snapshot;

        (uint256 principal0, uint256 principal1) = _amountsForLiquidity(
            snapshot.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(context.tickLower),
            TickMath.getSqrtPriceAtTick(context.tickUpper),
            snapshot.liquidity,
            false
        );
        (uint256 principalTarget, uint256 principalCounter) =
            _toTargetCounter(context.targetIsCurrency0, principal0, principal1);

        (uint256 pending0, uint256 pending1) =
            _pendingFeesSorted(context, snapshot.liquidity, last0, last1);
        (uint256 pendingTarget, uint256 pendingCounter) =
            _toTargetCounter(context.targetIsCurrency0, pending0, pending1);
        (uint256 launchTarget, uint256 launchCounter) = _pendingLaunchFees(context);
        (uint256 freeTarget, uint256 freeCounter) =
            _freeBalances(context, targetExcluded, counterExcluded);

        snapshot.idleTarget = freeTarget + pendingTarget + launchTarget;
        snapshot.idleCounter = freeCounter + pendingCounter + launchCounter;
        snapshot.targetAssets = principalTarget + snapshot.idleTarget;
        snapshot.counterAssets = principalCounter + snapshot.idleCounter;
    }

    function _mintBackingForShares(
        VaultContext memory context,
        uint160 sqrtPriceX96,
        uint128 currentLiquidity,
        uint256 idleTarget,
        uint256 idleCounter,
        uint256 supply,
        uint256 grossShares
    )
        private
        pure
        returns (uint256 targetRequired, uint256 counterRequired, uint128 liquidityAdded)
    {
        liquidityAdded = FullMath.mulDivRoundingUp(currentLiquidity, grossShares, supply)
            .toUint128();
        (uint256 amount0, uint256 amount1) = _amountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(context.tickLower),
            TickMath.getSqrtPriceAtTick(context.tickUpper),
            liquidityAdded,
            true
        );
        (uint256 positionTarget, uint256 positionCounter) =
            _toTargetCounter(context.targetIsCurrency0, amount0, amount1);
        targetRequired = positionTarget + FullMath.mulDivRoundingUp(idleTarget, grossShares, supply);
        counterRequired =
            positionCounter + FullMath.mulDivRoundingUp(idleCounter, grossShares, supply);
    }

    function _totalAssets(
        VaultContext memory context,
        uint256 targetExcluded,
        uint256 counterExcluded
    ) private view returns (uint256 targetAssets, uint256 counterAssets) {
        (uint256 principalTarget, uint256 principalCounter) = _positionPrincipal(context);
        (uint256 pendingTarget, uint256 pendingCounter) = _pendingFees(context);
        (uint256 launchTarget, uint256 launchCounter) = _pendingLaunchFees(context);
        (uint256 freeTarget, uint256 freeCounter) =
            _freeBalances(context, targetExcluded, counterExcluded);
        targetAssets = principalTarget + freeTarget + pendingTarget + launchTarget;
        counterAssets = principalCounter + freeCounter + pendingCounter + launchCounter;
    }

    function _positionPrincipal(VaultContext memory context)
        private
        view
        returns (uint256 targetPrincipal, uint256 counterPrincipal)
    {
        (uint160 sqrtPriceX96,,,) = _poolManager.getSlot0(context.poolId);
        (uint128 liquidity,,) = _poolManager.getPositionInfo(
            context.poolId, address(this), context.tickLower, context.tickUpper, POSITION_SALT
        );
        (uint256 amount0, uint256 amount1) = _amountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(context.tickLower),
            TickMath.getSqrtPriceAtTick(context.tickUpper),
            liquidity,
            false
        );
        return _toTargetCounter(context.targetIsCurrency0, amount0, amount1);
    }

    function _positionLiquidity(VaultContext memory context)
        private
        view
        returns (uint128 liquidity)
    {
        (liquidity,,) = _poolManager.getPositionInfo(
            context.poolId, address(this), context.tickLower, context.tickUpper, POSITION_SALT
        );
    }

    function _amountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceLowerX96,
        uint160 sqrtPriceUpperX96,
        uint128 liquidity,
        bool roundUp
    ) private pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceX96 <= sqrtPriceLowerX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(
                sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity, roundUp
            );
        } else if (sqrtPriceX96 < sqrtPriceUpperX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(
                sqrtPriceX96, sqrtPriceUpperX96, liquidity, roundUp
            );
            amount1 = SqrtPriceMath.getAmount1Delta(
                sqrtPriceLowerX96, sqrtPriceX96, liquidity, roundUp
            );
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(
                sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity, roundUp
            );
        }
    }

    function _pendingFees(VaultContext memory context)
        private
        view
        returns (uint256 targetFees, uint256 counterFees)
    {
        (uint256 amount0, uint256 amount1) = _pendingFeesSorted(context);
        return _toTargetCounter(context.targetIsCurrency0, amount0, amount1);
    }

    function _pendingFeesSorted(VaultContext memory context)
        private
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint128 liquidity, uint256 last0, uint256 last1) = _poolManager.getPositionInfo(
            context.poolId, address(this), context.tickLower, context.tickUpper, POSITION_SALT
        );
        if (liquidity == 0) return (0, 0);
        return _pendingFeesSorted(context, liquidity, last0, last1);
    }

    function _pendingFeesSorted(
        VaultContext memory context,
        uint128 liquidity,
        uint256 last0,
        uint256 last1
    ) private view returns (uint256 amount0, uint256 amount1) {
        (uint256 current0, uint256 current1) =
            _poolManager.getFeeGrowthInside(context.poolId, context.tickLower, context.tickUpper);
        unchecked {
            amount0 = FullMath.mulDiv(current0 - last0, liquidity, FixedPoint128.Q128);
            amount1 = FullMath.mulDiv(current1 - last1, liquidity, FixedPoint128.Q128);
        }
    }

    /// @dev Balances the vault may freely spend or pay out, excluding deposits in flight.
    /// Excluding both deposited legs lets mintPair
    /// collect fees and reprice safely after arbitrary ERC-20 transfer callbacks.
    function _freeBalances(
        VaultContext memory context,
        uint256 targetExcluded,
        uint256 counterExcluded
    ) private view returns (uint256 freeTarget, uint256 freeCounter) {
        (uint256 targetBalance, uint256 counterBalance) = _rawBalances(context);
        freeTarget = targetBalance - targetExcluded;
        freeCounter = counterBalance - counterExcluded;
    }

    /// @notice Launch-position fees currently receivable by this vault as holder NAV.
    function pendingLaunchFees() public view returns (uint256 targetFees, uint256 counterFees) {
        return _pendingLaunchFees(_loadContext());
    }

    function _pendingLaunchFees(VaultContext memory context)
        private
        view
        returns (uint256 targetFees, uint256 counterFees)
    {
        address source = context.launchFeeSource;
        if (source == address(0)) return (0, 0);
        (, ILaunchFeeSource.FeeAmounts memory nav,) =
            ILaunchFeeSource(source).pendingFees(Currency.unwrap(context.targetCurrency));
        return (nav.target, nav.counter);
    }

    function _syncLaunchFees(VaultContext memory context) private {
        address source = context.launchFeeSource;
        if (source != address(0)) {
            ILaunchFeeSource(source).distributeFees(Currency.unwrap(context.targetCurrency));
        }
    }

    function _rawBalances(VaultContext memory context)
        private
        view
        returns (uint256 targetBalance, uint256 counterBalance)
    {
        targetBalance = context.targetCurrency.balanceOfSelf();
        counterBalance = context.counterCurrency.balanceOfSelf();
    }

    function _receiveCounterExact(
        VaultContext memory context,
        address payer,
        uint256 amount,
        uint256 expectedMsgValue
    ) private {
        if (context.counterCurrency.isAddressZero()) {
            if (msg.value != expectedMsgValue) {
                revert InvalidMsgValue(msg.value, expectedMsgValue);
            }
        } else {
            if (msg.value != 0) revert InvalidMsgValue(msg.value, 0);
            CurrencyTransfer.pullExact(Currency.unwrap(context.counterCurrency), payer, amount);
        }
    }

    function _modifyLiquidity(int256 liquidityDelta)
        private
        returns (BalanceDelta delta, BalanceDelta feesAccrued)
    {
        return abi.decode(
            _poolManager.unlock(abi.encode(liquidityDelta)), (BalanceDelta, BalanceDelta)
        );
    }

    function _toTargetCounter(bool isTargetCurrency0, uint256 amount0, uint256 amount1)
        private
        pure
        returns (uint256 targetAmount, uint256 counterAmount)
    {
        return isTargetCurrency0 ? (amount0, amount1) : (amount1, amount0);
    }

    function _toSorted(bool isTargetCurrency0, uint256 targetAmount, uint256 counterAmount)
        private
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        return isTargetCurrency0 ? (targetAmount, counterAmount) : (counterAmount, targetAmount);
    }

    function _positiveAmounts(BalanceDelta delta)
        private
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();
        amount0 = delta0 > 0 ? int256(delta0).toUint256() : 0;
        amount1 = delta1 > 0 ? int256(delta1).toUint256() : 0;
    }

    function _shareFee(uint256 shares) private pure returns (uint256) {
        // Round in Treasury's favor so splitting one operation across calls cannot reduce
        // the aggregate fee. The excess is always less than one raw lpTOKEN share per call.
        return FullMath.mulDivRoundingUp(shares, SHARE_FEE_BPS, BPS);
    }

    function _checkDeadline(uint256 deadline) private view {
        if (block.timestamp > deadline) revert DeadlineExpired();
    }

    function _immutableArgs() private view returns (ImmutableArgs memory args) {
        args = abi.decode(Clones.fetchCloneArgs(address(this)), (ImmutableArgs));
    }

    function _loadContext() private view returns (VaultContext memory context) {
        ImmutableArgs memory args = _immutableArgs();
        context.targetCurrency = _targetCurrency(args);
        context.counterCurrency = _counterCurrency(args);
        context.poolId = _poolKey(args).toId();
        context.launchFeeSource = args.launchFeeSource;
        context.fee = args.fee;
        context.tickSpacing = args.tickSpacing;
        context.tickLower = _tickLower;
        context.tickUpper = _tickUpper;
        context.targetIsCurrency0 = args.targetIsCurrency0;
    }

    function _targetCurrency(ImmutableArgs memory args) private pure returns (Currency) {
        return args.targetIsCurrency0 ? args.currency0 : args.currency1;
    }

    function _counterCurrency(ImmutableArgs memory args) private pure returns (Currency) {
        return args.targetIsCurrency0 ? args.currency1 : args.currency0;
    }

    function _poolKey(ImmutableArgs memory args) private pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: args.currency0,
            currency1: args.currency1,
            fee: args.fee,
            tickSpacing: args.tickSpacing,
            hooks: args.hooks
        });
    }
}
