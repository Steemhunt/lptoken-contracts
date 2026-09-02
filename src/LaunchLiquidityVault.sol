// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { FixedPoint128 } from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { ILaunchFeeSource } from "./interfaces/ILaunchFeeSource.sol";
import { ILpTokenFactory } from "./interfaces/ILpTokenFactory.sol";
import { ITokenLaunchpad } from "./interfaces/ITokenLaunchpad.sol";
import { CurrencyTransfer } from "./libraries/CurrencyTransfer.sol";
import { LaunchPoolConfig } from "./libraries/LaunchPoolConfig.sol";

/// @notice Shared custody for every permanent one-sided launch position. Principal can
/// never be withdrawn. Anyone can distribute fees under the immutable launch policy.
contract LaunchLiquidityVault is ILaunchFeeSource, IUnlockCallback, ReentrancyGuardTransient {
    using SafeCast for int256;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    bytes32 public constant POSITION_SALT = bytes32(0);
    /// @notice Native payout allowance used when a vault operation synchronizes launch
    /// fees. It bounds what a hostile recipient can burn inside an unrelated caller's
    /// mint, redeem, or compound.
    uint256 public constant NATIVE_PAYOUT_GAS = 30_000;

    IPoolManager public immutable override poolManager;
    address public immutable override launchpad;
    address public immutable override factory;

    struct Position {
        address creator;
        address lpTokenVault;
        uint128 liquidity;
        // The launch range this position was opened at, pinned so a later change to the
        // launchpad's terms cannot move where an existing position is read or modified.
        // Packs into the slot alongside `liquidity`, so recording it costs no extra storage.
        int24 startTick;
        // Raw unallocated fee units, each strictly less than the common denominator five.
        uint8 targetSplitRemainder;
        uint8 counterSplitRemainder;
        uint256 creatorTargetClaim;
        uint256 creatorCounterClaim;
        uint256 protocolCounterClaim;
    }

    enum CallbackAction {
        AddLiquidity,
        CollectFees
    }

    struct CallbackData {
        CallbackAction action;
        address token;
    }

    enum FeeRecipient {
        Creator,
        Protocol
    }

    mapping(address token => Position position) private _positions;

    event PositionLocked(
        address indexed token,
        address indexed creator,
        bytes32 indexed poolId,
        address lpTokenVault,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 tokenDustSentToDead
    );
    /// @notice Emitted when a creator hands its launch-fee claim to another address. The
    /// position, its range, and the fee split are unchanged; only the payee moves.
    event CreatorTransferred(
        address indexed token, address indexed previousCreator, address indexed newCreator
    );
    /// @dev Allocated values contain only complete five-unit buckets and therefore equal
    /// the recipient sums. The two remainder values are retained, unallocated raw balances.
    event LaunchFeesAllocated(
        address indexed token,
        address indexed lpTokenVault,
        address indexed creator,
        uint256 allocatedTarget,
        uint256 allocatedCounter,
        uint256 creatorTarget,
        uint256 creatorCounter,
        uint256 navTarget,
        uint256 navCounter,
        uint256 protocolCounter,
        uint8 targetRemainder,
        uint8 counterRemainder
    );
    event LaunchFeePayout(
        address indexed token,
        address indexed receiver,
        FeeRecipient indexed recipient,
        uint256 targetAmount,
        uint256 counterAmount,
        bool targetSuccess,
        bool counterSuccess
    );

    error AlreadyRegistered();
    error InvalidAddress();
    error InvalidInitialBalance(uint256 actual, uint256 expected);
    error OnlyCreator();
    error OnlyLaunchpad();
    error OnlyPoolManager();
    error PositionNotFound();
    error UnexpectedDelta();
    error ZeroLiquidity();

    constructor(IPoolManager poolManager_, address launchpad_, address factory_) {
        if (
            address(poolManager_) == address(0) || launchpad_ == address(0)
                || factory_ == address(0)
        ) {
            revert InvalidAddress();
        }
        poolManager = poolManager_;
        launchpad = launchpad_;
        factory = factory_;
    }

    function treasury() public view override returns (address) {
        return ILpTokenFactory(factory).treasury();
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
    }

    function addPosition(address token, address creator, address lpTokenVault, uint256 tokenAmount)
        external
        nonReentrant
        returns (uint128 liquidity, uint256 dust)
    {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (token == address(0) || creator == address(0) || lpTokenVault == address(0)) {
            revert InvalidAddress();
        }
        if (_positions[token].creator != address(0)) revert AlreadyRegistered();

        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        if (tokenBalance != tokenAmount) {
            revert InvalidInitialBalance(tokenBalance, tokenAmount);
        }

        int24 startTick = ITokenLaunchpad(launchpad).startTick();
        (int24 tickLower, int24 tickUpper) = LaunchPoolConfig.launchTicks(startTick);
        liquidity = LaunchPoolConfig.launchLiquidity(startTick, tokenAmount);
        if (liquidity == 0) revert ZeroLiquidity();

        Position storage position = _positions[token];
        position.creator = creator;
        position.lpTokenVault = lpTokenVault;
        position.liquidity = liquidity;
        position.startTick = startTick;

        BalanceDelta delta = _modifyLiquidity(token, CallbackAction.AddLiquidity);
        if (delta.amount0() != 0 || delta.amount1() >= 0) revert UnexpectedDelta();

        dust = IERC20(token).balanceOf(address(this));
        if (dust != 0) {
            CurrencyTransfer.transfer(Currency.wrap(token), LaunchPoolConfig.DEAD, dust);
        }

        emit PositionLocked(
            token,
            creator,
            PoolId.unwrap(_poolKey(token).toId()),
            lpTokenVault,
            tickLower,
            tickUpper,
            liquidity,
            dust
        );
    }

    /// @notice Hands this launch position's creator fee claim to another address.
    /// @dev Only the current creator may hand it over, and only to a non-zero address, which
    /// also keeps `creator` usable as the position's existence marker. Claims recorded by a
    /// failed payout live on the position rather than on the creator, so they follow the new
    /// address; that is what makes this the recovery path for a creator that cannot receive
    /// its own payouts. A creator that would rather settle first can call `distributeFees`
    /// before handing over. Nothing else moves: the permanent position, its range, the fee
    /// split, and the vault's NAV share are untouched, and the launchpad's own record of who
    /// created the token stays as it was.
    function transferCreator(address token, address newCreator) external {
        Position storage position = _position(token);
        address currentCreator = position.creator;
        if (msg.sender != currentCreator) revert OnlyCreator();
        if (newCreator == address(0)) revert InvalidAddress();

        position.creator = newCreator;
        emit CreatorTransferred(token, currentCreator, newCreator);
    }

    /// @notice Permissionlessly collects and distributes all currently accrued launch fees:
    /// target 40% creator / 60% NAV; counter 40% creator / 20% NAV / 40% protocol.
    /// Failed creator or treasury payouts remain retryable; canonical NAV transfers revert.
    /// Native retries use bounded gas, so a permanently rejecting recipient adds a bounded
    /// surcharge to this call and to vault operations that synchronize launch fees.
    function distributeFees(address token) external nonReentrant {
        _distributeFees(token, NATIVE_PAYOUT_GAS);
    }

    /// @notice Same distribution with a caller-funded native payout allowance. A recipient
    /// whose `receive` costs more than the default stipend can settle its own claim here
    /// without raising what it may burn inside anyone else's vault operation. The
    /// allowance is a cap, so an honest recipient still consumes only what it uses, and it
    /// never lets the caller choose who is paid.
    function distributeFeesWithGas(address token, uint256 nativeGas) external nonReentrant {
        _distributeFees(token, nativeGas);
    }

    function _distributeFees(address token, uint256 nativeGas) private {
        Position storage position = _position(token);
        (uint256 grossTarget, uint256 grossCounter) = _collectPositionFees(token);
        if (grossTarget != 0 || grossCounter != 0) {
            _allocateFees(token, position, grossTarget, grossCounter);
        }
        _payLiabilities(token, position, nativeGas);
    }

    /// @notice Returns retry liabilities plus currently claimable prospective allocations
    /// in one RPC. Raw sub-five-unit remainders remain unallocated and are not NAV.
    function pendingFees(address token)
        external
        view
        returns (FeeAmounts memory creator, FeeAmounts memory nav, FeeAmounts memory protocol)
    {
        Position storage position = _positions[token];
        if (position.creator == address(0)) return (creator, nav, protocol);
        (uint256 pendingTarget, uint256 pendingCounter) = _pendingPositionFees(token);
        (FeeAmounts memory newCreator, FeeAmounts memory newNav, FeeAmounts memory newProtocol,,) = _previewAllocation(
            pendingTarget,
            pendingCounter,
            position.targetSplitRemainder,
            position.counterSplitRemainder
        );
        creator = FeeAmounts({
            target: position.creatorTargetClaim + newCreator.target,
            counter: position.creatorCounterClaim + newCreator.counter
        });
        nav = newNav;
        protocol =
            FeeAmounts({ target: 0, counter: position.protocolCounterClaim + newProtocol.counter });
    }

    function _pendingPositionFees(address token)
        private
        view
        returns (uint256 targetAmount, uint256 counterAmount)
    {
        Position storage position = _positions[token];
        if (position.creator == address(0) || position.liquidity == 0) return (0, 0);

        (int24 tickLower, int24 tickUpper) = LaunchPoolConfig.launchTicks(position.startTick);
        PoolId id = _poolKey(token).toId();
        (, uint256 last0, uint256 last1) =
            poolManager.getPositionInfo(id, address(this), tickLower, tickUpper, POSITION_SALT);
        (uint256 current0, uint256 current1) =
            poolManager.getFeeGrowthInside(id, tickLower, tickUpper);
        unchecked {
            counterAmount =
                FullMath.mulDiv(current0 - last0, position.liquidity, FixedPoint128.Q128);
            targetAmount = FullMath.mulDiv(current1 - last1, position.liquidity, FixedPoint128.Q128);
        }
    }

    function positions(address token)
        external
        view
        returns (address creator, address lpTokenVault, uint128 liquidity, int24 startTick)
    {
        Position storage position = _positions[token];
        return (position.creator, position.lpTokenVault, position.liquidity, position.startTick);
    }

    /// @notice Launch-position liquidity that is actually active at the pool's current
    /// tick and belongs to `lpTokenVault`, or zero otherwise. The permanent launch range
    /// ends at the start tick, so at or above it this position backs nothing even though
    /// its nominal liquidity is unchanged. Callers sizing economic limits must use this
    /// rather than the nominal amount.
    function activeLiquidity(address token, address lpTokenVault)
        external
        view
        override
        returns (uint128)
    {
        Position storage position = _positions[token];
        if (position.creator == address(0) || position.lpTokenVault != lpTokenVault) return 0;

        (int24 tickLower, int24 tickUpper) = LaunchPoolConfig.launchTicks(position.startTick);
        (, int24 tick,,) = poolManager.getSlot0(_poolKey(token).toId());
        if (tick < tickLower || tick >= tickUpper) return 0;
        return position.liquidity;
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        Position storage position = _positions[data.token];
        if (position.creator == address(0)) revert PositionNotFound();

        (int24 tickLower, int24 tickUpper) = LaunchPoolConfig.launchTicks(position.startTick);
        int256 liquidityDelta = data.action == CallbackAction.AddLiquidity
            ? int256(uint256(position.liquidity))
            : int256(0);
        PoolKey memory key = _poolKey(data.token);
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: POSITION_SALT
            }),
            bytes("")
        );
        CurrencyTransfer.settleDelta(poolManager, key.currency0, key.currency1, delta);
        return abi.encode(delta);
    }

    function _collectPositionFees(address token)
        private
        returns (uint256 grossTarget, uint256 grossCounter)
    {
        (uint256 pendingTarget, uint256 pendingCounter) = _pendingPositionFees(token);
        if (pendingTarget == 0 && pendingCounter == 0) return (0, 0);
        BalanceDelta delta = _modifyLiquidity(token, CallbackAction.CollectFees);
        if (delta.amount0() < 0 || delta.amount1() < 0) revert UnexpectedDelta();
        grossCounter = int256(delta.amount0()).toUint256();
        grossTarget = int256(delta.amount1()).toUint256();
    }

    function _allocateFees(
        address token,
        Position storage position,
        uint256 grossTarget,
        uint256 grossCounter
    ) private {
        (
            FeeAmounts memory creator,
            FeeAmounts memory nav,
            FeeAmounts memory protocol,
            uint8 nextTargetRemainder,
            uint8 nextCounterRemainder
        ) = _previewAllocation(
            grossTarget, grossCounter, position.targetSplitRemainder, position.counterSplitRemainder
        );
        position.targetSplitRemainder = nextTargetRemainder;
        position.counterSplitRemainder = nextCounterRemainder;
        position.creatorTargetClaim += creator.target;
        position.creatorCounterClaim += creator.counter;
        position.protocolCounterClaim += protocol.counter;

        // NAV is part of immediately redeemable lpTOKEN backing. Unlike peripheral payouts,
        // failure must revert collection so no off-vault receivable can distort share value.
        CurrencyTransfer.transfer(Currency.wrap(token), position.lpTokenVault, nav.target);
        CurrencyTransfer.transfer(Currency.wrap(address(0)), position.lpTokenVault, nav.counter);
        emit LaunchFeesAllocated(
            token,
            position.lpTokenVault,
            position.creator,
            creator.target + nav.target,
            creator.counter + nav.counter + protocol.counter,
            creator.target,
            creator.counter,
            nav.target,
            nav.counter,
            protocol.counter,
            nextTargetRemainder,
            nextCounterRemainder
        );
    }

    function _payLiabilities(address token, Position storage position, uint256 nativeGas) private {
        // A creator may hand over during its native payout callback. This payout still belongs
        // to the address selected when distribution began; the successor receives later fees.
        address creator = position.creator;
        uint256 creatorTarget = position.creatorTargetClaim;
        uint256 creatorCounter = position.creatorCounterClaim;
        position.creatorTargetClaim = 0;
        position.creatorCounterClaim = 0;
        // Clear before each external call and restore only the failed leg. This keeps creator
        // and protocol delivery independent without exposing a reentrant double payout.
        bool creatorTargetSuccess =
            CurrencyTransfer.tryTransfer(Currency.wrap(token), creator, creatorTarget, nativeGas);
        bool creatorCounterSuccess = CurrencyTransfer.tryTransfer(
            Currency.wrap(address(0)), creator, creatorCounter, nativeGas
        );
        if (!creatorTargetSuccess) position.creatorTargetClaim = creatorTarget;
        if (!creatorCounterSuccess) position.creatorCounterClaim = creatorCounter;
        if (creatorTarget != 0 || creatorCounter != 0) {
            emit LaunchFeePayout(
                token,
                creator,
                FeeRecipient.Creator,
                creatorTargetSuccess ? creatorTarget : 0,
                creatorCounterSuccess ? creatorCounter : 0,
                creatorTargetSuccess,
                creatorCounterSuccess
            );
        }

        uint256 protocolCounter = position.protocolCounterClaim;
        if (protocolCounter == 0) return;
        position.protocolCounterClaim = 0;
        address treasury_ = treasury();
        bool protocolCounterSuccess = CurrencyTransfer.tryTransfer(
            Currency.wrap(address(0)), treasury_, protocolCounter, nativeGas
        );
        if (!protocolCounterSuccess) position.protocolCounterClaim = protocolCounter;
        emit LaunchFeePayout(
            token,
            treasury_,
            FeeRecipient.Protocol,
            0,
            protocolCounterSuccess ? protocolCounter : 0,
            true,
            protocolCounterSuccess
        );
    }

    function _previewAllocation(
        uint256 grossTarget,
        uint256 grossCounter,
        uint8 targetRemainder,
        uint8 counterRemainder
    )
        internal
        pure
        returns (
            FeeAmounts memory creator,
            FeeAmounts memory nav,
            FeeAmounts memory protocol,
            uint8 nextTargetRemainder,
            uint8 nextCounterRemainder
        )
    {
        // Carrying raw units before splitting makes the result independent of how callers
        // partition the same collected amount across distribution transactions.
        uint256 distributableTarget = grossTarget + targetRemainder;
        uint256 targetUnits = distributableTarget / 5;
        creator.target = targetUnits * 2;
        nav.target = targetUnits * 3;
        nextTargetRemainder = (distributableTarget % 5).toUint8();

        uint256 distributableCounter = grossCounter + counterRemainder;
        uint256 counterUnits = distributableCounter / 5;
        creator.counter = counterUnits * 2;
        nav.counter = counterUnits;
        protocol.counter = counterUnits * 2;
        nextCounterRemainder = (distributableCounter % 5).toUint8();
    }

    function _modifyLiquidity(address token, CallbackAction action)
        private
        returns (BalanceDelta delta)
    {
        delta = abi.decode(
            poolManager.unlock(abi.encode(CallbackData({ action: action, token: token }))),
            (BalanceDelta)
        );
    }

    function _position(address token) private view returns (Position storage position) {
        position = _positions[token];
        if (position.creator == address(0)) revert PositionNotFound();
    }

    function _poolKey(address token) private view returns (PoolKey memory) {
        return LaunchPoolConfig.poolKey(token, IHooks(launchpad));
    }
}
