// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { IWETH9 } from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import { ILpTokenFactory } from "../interfaces/ILpTokenFactory.sol";
import { ILpTokenVault } from "../interfaces/ILpTokenVault.sol";
import { CurrencyTransfer } from "../libraries/CurrencyTransfer.sol";

/// @notice Restricted V4 zap periphery for canonical lpTOKEN vaults. Single-leg target and
/// counter zaps use the vault pool directly. Routed zaps accept only native currency or the
/// configured canonical stablecoin and a client-supplied sequence of hookless, static-fee V4
/// pools. Every exact-input hop must spend its full input before the vault pool is used to form
/// the target/counter pair. Caller minima enforce accounting and slippage, but the router does
/// not discover route quality, establish fair value, or provide MEV protection.
/// @dev Arc-specific fork of ZapRouter at repository commit
/// 9ed92f2d61edf9b37c292e3232ac7162d83fae0d. The deployed-chain source stays unchanged.
/// Native USDC and ERC-20 USDC share one balance with 18 and 6 decimals respectively.
/// The wrappedNative getter identifies the ERC-20 interface, not a WETH9 contract.
/// Conversion changes accounting units only; no deposit/withdraw call is made.
/// @custom:version 2.0-arc
contract ZapRouterArc is ReentrancyGuardTransient, IUnlockCallback {
    using SafeERC20 for IERC20;
    using SafeCast for int256;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    address public constant USDC = 0x3600000000000000000000000000000000000000;
    uint256 private constant NATIVE_SCALE = 1e12;

    uint256 public constant MAX_ROUTE_HOPS = 3;

    ILpTokenFactory public immutable factory;
    IPoolManager public immutable poolManager;
    address public immutable canonicalStable;
    IWETH9 public immutable wrappedNative;

    struct SwapCallbackData {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
    }

    /// @notice EIP-2612 approval carried alongside a zap so the token it spends needs no
    /// separate approval transaction. A zero `deadline` means no approval was carried.
    struct PermitSignature {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @dev The routed zap's inputs, grouped so the shared implementation stays within the
    /// stack. `counterRoute` and the carried approval travel beside it.
    struct RoutedZapParams {
        ILpTokenVault vault;
        Currency inputCurrency;
        uint256 inputAmount;
        uint256 minRouteCounterOut;
        uint256 swapCounterAmount;
        uint256 minSwapTargetOut;
        uint256 minShares;
        address receiver;
        uint256 deadline;
    }

    struct VaultContext {
        PoolKey key;
        Currency target;
        Currency counter;
        bool targetIsCurrency0;
    }

    error AliasedPoolCurrencies();
    error InvalidAddress();
    error InvalidAmount();
    error DeadlineExpired();
    error OnlyPoolManager();
    error UnregisteredVault(address vault);
    error HookedPoolNotSupported(address hooks);
    error DynamicFeePoolNotSupported();
    error InvalidPoolFee(uint24 fee);
    error InvalidRoutePool(uint256 hop);
    error InvalidRouteLength(uint256 length);
    error RouteCurrencyMismatch(uint256 hop, address currency);
    error RouteOutputMismatch(address output, address counter);
    error UnsupportedInput(address input);
    error MinimumSharesRequired();
    error InvalidSwapDelta();
    error IncompleteSwapInput(uint256 spent, uint256 expected);
    error InexactSwapInput(uint256 expected, uint256 spent);
    error InsufficientSwapOutput(uint256 amount, uint256 minimum);
    error InsufficientCounterOutput(uint256 amount, uint256 minimum);
    error InsufficientTargetOutput(uint256 amount, uint256 minimum);
    error InvalidMsgValue(uint256 provided, uint256 expected);
    error UnexpectedBalance(address currency, uint256 actual, uint256 expected);
    error InexactSwapOutput(uint256 reported, uint256 received);
    error InexactWrap(uint256 expected, uint256 received);
    error UnauthorizedNativeSender(address sender);
    error CarriedApprovalNotGranted(address token);

    /// @notice Canonical record of a zap in, emitted by both the direct and the routed path.
    /// On the routed path `counterIn` is the counter the route produced, which is the amount
    /// this contract actually splits and pair-mints, so an indexer that follows only this
    /// event still measures every zap in correctly.
    event ZappedIn(
        address indexed sender,
        address indexed vault,
        address indexed receiver,
        uint256 counterIn,
        uint256 counterSwapped,
        uint256 targetBought,
        uint256 shares
    );
    /// @notice Canonical record of a target-only zap in. `targetUsed` returned by the call is
    /// `targetSwapped` plus the target deposited into the vault; any unused target or counter
    /// produced by the swap is returned to `sender`.
    event TargetZappedIn(
        address indexed sender,
        address indexed vault,
        address indexed receiver,
        uint256 targetIn,
        uint256 targetSwapped,
        uint256 counterBought,
        uint256 shares
    );
    /// @notice Routing detail for `zapInRouted`, emitted alongside `ZappedIn` rather than
    /// instead of it. Every field this shares with `ZappedIn` carries the same value
    /// (`counterRouted` is its `counterIn`); only `inputCurrency` and `inputAmount` are new.
    /// The two events therefore describe one operation and must not be summed together.
    event RoutedZappedIn(
        address indexed sender,
        address indexed vault,
        address indexed receiver,
        address inputCurrency,
        uint256 inputAmount,
        uint256 counterRouted,
        uint256 counterSwapped,
        uint256 targetBought,
        uint256 shares
    );
    event ZappedOut(
        address indexed sender,
        address indexed vault,
        address indexed receiver,
        uint256 shares,
        uint256 targetSwapped,
        uint256 counterOut
    );
    event TargetZappedOut(
        address indexed sender,
        address indexed vault,
        address indexed receiver,
        uint256 shares,
        uint256 counterSwapped,
        uint256 targetOut
    );
    /// @notice A pair mint paid through this contract. The vault's own `PairMinted` records
    /// this contract as the minter, so the paying account is recorded here — as the zap
    /// events record it for theirs — with what the vault took from each leg; whatever it
    /// declined went back to `sender`.
    event RoutedPairMinted(
        address indexed sender,
        address indexed vault,
        address indexed receiver,
        uint256 targetUsed,
        uint256 counterUsed,
        uint256 shares
    );

    constructor(ILpTokenFactory factory_) {
        address factoryAddress = address(factory_);
        if (
            factoryAddress == address(0) || factoryAddress.code.length == 0 || USDC.code.length == 0
        ) {
            revert InvalidAddress();
        }
        IPoolManager manager = factory_.poolManager();
        if (address(manager) == address(0) || address(manager).code.length == 0) {
            revert InvalidAddress();
        }
        if (IERC20Metadata(USDC).decimals() != 6) revert InvalidAddress();
        factory = factory_;
        poolManager = manager;
        canonicalStable = USDC;
        wrappedNative = IWETH9(USDC);
    }

    /// @notice Returns the ZapRouter version.
    function version() external pure returns (string memory) {
        return "2.0-arc";
    }

    receive() external payable {
        if (
            msg.sender != address(poolManager) && msg.sender != address(wrappedNative)
                && !factory.isVault(msg.sender)
        ) revert UnauthorizedNativeSender(msg.sender);
    }

    /// @notice Deposits the vault counter, swaps the explicit portion into target through
    /// the vault pool, then pair-mints. The client computes the split from live quotes and
    /// the vault preview; this function never assumes a 50% raw-unit split.
    function zapIn(
        ILpTokenVault vault,
        uint256 counterAmount,
        uint256 swapCounterAmount,
        uint256 minSwapTargetOut,
        uint256 minShares,
        address receiver,
        uint256 deadline
    )
        external
        payable
        nonReentrant
        returns (uint256 shares, uint256 targetUsed, uint256 counterUsed)
    {
        return _zapIn(
            vault,
            counterAmount,
            swapCounterAmount,
            minSwapTargetOut,
            minShares,
            receiver,
            deadline,
            _noPermit()
        );
    }

    /// @notice `zapIn`, paying the counter under a carried EIP-2612 approval.
    function zapInWithPermit(
        ILpTokenVault vault,
        uint256 counterAmount,
        uint256 swapCounterAmount,
        uint256 minSwapTargetOut,
        uint256 minShares,
        address receiver,
        uint256 deadline,
        PermitSignature calldata permitSignature
    )
        external
        payable
        nonReentrant
        returns (uint256 shares, uint256 targetUsed, uint256 counterUsed)
    {
        return _zapIn(
            vault,
            counterAmount,
            swapCounterAmount,
            minSwapTargetOut,
            minShares,
            receiver,
            deadline,
            permitSignature
        );
    }

    function _zapIn(
        ILpTokenVault vault,
        uint256 counterAmount,
        uint256 swapCounterAmount,
        uint256 minSwapTargetOut,
        uint256 minShares,
        address receiver,
        uint256 deadline,
        PermitSignature memory permitSignature
    ) private returns (uint256 shares, uint256 targetUsed, uint256 counterUsed) {
        _check(deadline, receiver);
        VaultContext memory context = _validatedVault(vault);
        uint256 nativeBaseline = address(this).balance - msg.value;
        uint256 targetBaseline = _balanceAtStart(context.target, nativeBaseline);
        uint256 counterBaseline = _balanceAtStart(context.counter, nativeBaseline);
        uint256 sharesBaseline = IERC20(address(vault)).balanceOf(address(this));

        _receiveInput(context.counter, counterAmount, permitSignature);
        (shares, targetUsed, counterUsed,,) = _zapCounter(
            vault,
            context,
            counterAmount,
            swapCounterAmount,
            minSwapTargetOut,
            minShares,
            receiver,
            deadline
        );

        _requireBalance(context.target, targetBaseline);
        _requireBalance(context.counter, counterBaseline);
        _requireTokenBalance(address(vault), sharesBaseline);
    }

    /// @notice Deposits the vault target, swaps the explicit portion into counter through the
    /// vault pool, then pair-mints. The client computes the split from live quotes and the vault
    /// preview; this function never assumes a 50% raw-unit split.
    function zapInTarget(
        ILpTokenVault vault,
        uint256 targetAmount,
        uint256 swapTargetAmount,
        uint256 minSwapCounterOut,
        uint256 minShares,
        address receiver,
        uint256 deadline
    ) external nonReentrant returns (uint256 shares, uint256 targetUsed, uint256 counterUsed) {
        return _zapInTarget(
            vault,
            targetAmount,
            swapTargetAmount,
            minSwapCounterOut,
            minShares,
            receiver,
            deadline,
            _noPermit()
        );
    }

    /// @notice `zapInTarget`, paying the target under a carried EIP-2612 approval.
    function zapInTargetWithPermit(
        ILpTokenVault vault,
        uint256 targetAmount,
        uint256 swapTargetAmount,
        uint256 minSwapCounterOut,
        uint256 minShares,
        address receiver,
        uint256 deadline,
        PermitSignature calldata permitSignature
    ) external nonReentrant returns (uint256 shares, uint256 targetUsed, uint256 counterUsed) {
        return _zapInTarget(
            vault,
            targetAmount,
            swapTargetAmount,
            minSwapCounterOut,
            minShares,
            receiver,
            deadline,
            permitSignature
        );
    }

    function _zapInTarget(
        ILpTokenVault vault,
        uint256 targetAmount,
        uint256 swapTargetAmount,
        uint256 minSwapCounterOut,
        uint256 minShares,
        address receiver,
        uint256 deadline,
        PermitSignature memory permitSignature
    ) private returns (uint256 shares, uint256 targetUsed, uint256 counterUsed) {
        _check(deadline, receiver);
        VaultContext memory context = _validatedVault(vault);
        uint256 nativeBaseline = address(this).balance;
        uint256 targetBaseline = _balanceAtStart(context.target, nativeBaseline);
        uint256 counterBaseline = _balanceAtStart(context.counter, nativeBaseline);
        uint256 sharesBaseline = IERC20(address(vault)).balanceOf(address(this));

        _receiveInput(context.target, targetAmount, permitSignature);
        uint256 targetSwapped;
        uint256 counterBought;
        (shares, targetUsed, counterUsed, targetSwapped, counterBought) = _zapTarget(
            vault,
            context,
            targetAmount,
            swapTargetAmount,
            minSwapCounterOut,
            minShares,
            receiver,
            deadline
        );
        emit TargetZappedIn(
            msg.sender, address(vault), receiver, targetAmount, targetSwapped, counterBought, shares
        );

        _requireBalance(context.target, targetBaseline);
        _requireBalance(context.counter, counterBaseline);
        _requireTokenBalance(address(vault), sharesBaseline);
    }

    /// @notice Converts native currency or the configured canonical stablecoin through a
    /// contiguous client-supplied V4 route into the vault counter, then performs the same
    /// counter-to-target split and pair mint as `zapIn`. Native and wrapped native are
    /// interchangeable at the first and last route boundaries.
    function zapInRouted(
        ILpTokenVault vault,
        Currency inputCurrency,
        uint256 inputAmount,
        PoolKey[] calldata counterRoute,
        uint256 minRouteCounterOut,
        uint256 swapCounterAmount,
        uint256 minSwapTargetOut,
        uint256 minShares,
        address receiver,
        uint256 deadline
    )
        external
        payable
        nonReentrant
        returns (uint256 shares, uint256 targetUsed, uint256 counterUsed)
    {
        return _zapInRouted(
            RoutedZapParams(
                vault,
                inputCurrency,
                inputAmount,
                minRouteCounterOut,
                swapCounterAmount,
                minSwapTargetOut,
                minShares,
                receiver,
                deadline
            ),
            counterRoute,
            _noPermit()
        );
    }

    /// @notice `zapInRouted`, paying the input under a carried EIP-2612 approval.
    function zapInRoutedWithPermit(
        ILpTokenVault vault,
        Currency inputCurrency,
        uint256 inputAmount,
        PoolKey[] calldata counterRoute,
        uint256 minRouteCounterOut,
        uint256 swapCounterAmount,
        uint256 minSwapTargetOut,
        uint256 minShares,
        address receiver,
        uint256 deadline,
        PermitSignature calldata permitSignature
    )
        external
        payable
        nonReentrant
        returns (uint256 shares, uint256 targetUsed, uint256 counterUsed)
    {
        return _zapInRouted(
            RoutedZapParams(
                vault,
                inputCurrency,
                inputAmount,
                minRouteCounterOut,
                swapCounterAmount,
                minSwapTargetOut,
                minShares,
                receiver,
                deadline
            ),
            counterRoute,
            permitSignature
        );
    }

    function _zapInRouted(
        RoutedZapParams memory params,
        PoolKey[] calldata counterRoute,
        PermitSignature memory permitSignature
    ) private returns (uint256 shares, uint256 targetUsed, uint256 counterUsed) {
        _check(params.deadline, params.receiver);
        _validateInput(params.inputCurrency);
        VaultContext memory context = _validatedVault(params.vault);
        uint256 nativeBaseline = address(this).balance - msg.value;
        uint256 inputBaseline = _balanceAtStart(params.inputCurrency, nativeBaseline);
        uint256 targetBaseline = _balanceAtStart(context.target, nativeBaseline);
        uint256 counterBaseline = _balanceAtStart(context.counter, nativeBaseline);
        uint256 sharesBaseline = IERC20(address(params.vault)).balanceOf(address(this));

        _validateRoute(params.inputCurrency, counterRoute, context.counter);
        _receiveInput(params.inputCurrency, params.inputAmount, permitSignature);
        uint256 counterRouted = _routeToCounter(
            params.inputCurrency, params.inputAmount, counterRoute, context.counter
        );
        if (counterRouted < params.minRouteCounterOut) {
            revert InsufficientCounterOutput(counterRouted, params.minRouteCounterOut);
        }

        uint256 counterSwapped;
        uint256 targetBought;
        (shares, targetUsed, counterUsed, counterSwapped, targetBought) = _zapCounter(
            params.vault,
            context,
            counterRouted,
            params.swapCounterAmount,
            params.minSwapTargetOut,
            params.minShares,
            params.receiver,
            params.deadline
        );
        emit RoutedZappedIn(
            msg.sender,
            address(params.vault),
            params.receiver,
            Currency.unwrap(params.inputCurrency),
            params.inputAmount,
            counterRouted,
            counterSwapped,
            targetBought,
            shares
        );

        _requireBalance(params.inputCurrency, inputBaseline);
        _requireBalance(context.target, targetBaseline);
        _requireBalance(context.counter, counterBaseline);
        _requireTokenBalance(address(params.vault), sharesBaseline);
    }

    /// @notice Redeems both legs and atomically converts the complete target leg into the
    /// vault counter through the vault pool. Any partial exact-input fill reverts.
    function zapOut(
        ILpTokenVault vault,
        uint256 shares,
        uint256 minCounterOut,
        address receiver,
        uint256 deadline
    ) external nonReentrant returns (uint256 counterOut) {
        return _zapOut(vault, shares, minCounterOut, receiver, deadline, false, _noPermit());
    }

    /// @notice `zapOut`, spending the submitted shares under a carried EIP-2612 approval.
    function zapOutWithPermit(
        ILpTokenVault vault,
        uint256 shares,
        uint256 minCounterOut,
        address receiver,
        uint256 deadline,
        PermitSignature calldata permitSignature
    ) external nonReentrant returns (uint256 counterOut) {
        return _zapOut(vault, shares, minCounterOut, receiver, deadline, false, permitSignature);
    }

    /// @notice Redeems both legs and atomically converts the complete counter leg into the
    /// vault target through the vault pool. Any partial exact-input fill reverts.
    function zapOutTarget(
        ILpTokenVault vault,
        uint256 shares,
        uint256 minTargetOut,
        address receiver,
        uint256 deadline
    ) external nonReentrant returns (uint256 targetOut) {
        return _zapOut(vault, shares, minTargetOut, receiver, deadline, true, _noPermit());
    }

    /// @notice `zapOutTarget`, spending the submitted shares under a carried EIP-2612 approval.
    function zapOutTargetWithPermit(
        ILpTokenVault vault,
        uint256 shares,
        uint256 minTargetOut,
        address receiver,
        uint256 deadline,
        PermitSignature calldata permitSignature
    ) external nonReentrant returns (uint256 targetOut) {
        return _zapOut(vault, shares, minTargetOut, receiver, deadline, true, permitSignature);
    }

    function _zapOut(
        ILpTokenVault vault,
        uint256 shares,
        uint256 minOutput,
        address receiver,
        uint256 deadline,
        bool outputTarget,
        PermitSignature memory permitSignature
    ) private returns (uint256 amountOut) {
        _check(deadline, receiver);
        if (shares == 0) revert InvalidAmount();

        VaultContext memory context = _validatedVault(vault);
        uint256 nativeBaseline = address(this).balance;
        uint256 targetBaseline = _balanceAtStart(context.target, nativeBaseline);
        uint256 counterBaseline = _balanceAtStart(context.counter, nativeBaseline);
        uint256 sharesBaseline = IERC20(address(vault)).balanceOf(address(this));

        _permit(address(vault), shares, permitSignature);
        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), shares);
        (uint256 targetFromRedeem, uint256 counterFromRedeem) =
            vault.redeem(shares, 0, 0, address(this), deadline);

        if (outputTarget) {
            uint256 targetFromSwap;
            if (counterFromRedeem != 0) {
                targetFromSwap =
                    _swapExactInput(context.key, !context.targetIsCurrency0, counterFromRedeem);
            }
            amountOut = targetFromRedeem + targetFromSwap;
            if (amountOut < minOutput) {
                revert InsufficientTargetOutput(amountOut, minOutput);
            }
            CurrencyTransfer.transfer(context.target, receiver, amountOut);
            emit TargetZappedOut(
                msg.sender, address(vault), receiver, shares, counterFromRedeem, amountOut
            );
        } else {
            uint256 counterFromSwap;
            if (targetFromRedeem != 0) {
                counterFromSwap =
                    _swapExactInput(context.key, context.targetIsCurrency0, targetFromRedeem);
            }
            amountOut = counterFromRedeem + counterFromSwap;
            if (amountOut < minOutput) {
                revert InsufficientCounterOutput(amountOut, minOutput);
            }
            CurrencyTransfer.transfer(context.counter, receiver, amountOut);
            emit ZappedOut(
                msg.sender, address(vault), receiver, shares, targetFromRedeem, amountOut
            );
        }

        _requireBalance(context.target, targetBaseline);
        _requireBalance(context.counter, counterBaseline);
        uint256 shareBalance = IERC20(address(vault)).balanceOf(address(this));
        if (shareBalance != sharesBaseline) {
            revert UnexpectedBalance(address(vault), shareBalance, sharesBaseline);
        }
    }

    /// @notice Deposits a proportional pair into a vault, paying each leg under a carried
    /// EIP-2612 approval, so a pair mint needs no approval transaction of its own.
    /// @dev The vault's own `mintPair` stays the direct route and is unchanged; this exists so
    /// the approvals can be signatures. Each leg's approval is optional, which covers a pair
    /// whose counter is native or whose counter cannot sign. Shares are minted straight to
    /// `receiver`, and whatever the mint declines comes back to the caller.
    function mintPairWithPermit(
        ILpTokenVault vault,
        uint256 maxTarget,
        uint256 maxCounter,
        uint256 minShares,
        address receiver,
        uint256 deadline,
        PermitSignature calldata targetPermit,
        PermitSignature calldata counterPermit
    )
        external
        payable
        nonReentrant
        returns (uint256 shares, uint256 targetUsed, uint256 counterUsed)
    {
        _check(deadline, receiver);
        if (maxTarget == 0 || maxCounter == 0) revert InvalidAmount();
        if (minShares == 0) revert MinimumSharesRequired();

        VaultContext memory context = _validatedVault(vault);
        uint256 nativeBaseline = address(this).balance - msg.value;
        uint256 targetBaseline = _balanceAtStart(context.target, nativeBaseline);
        uint256 counterBaseline = _balanceAtStart(context.counter, nativeBaseline);
        uint256 sharesBaseline = IERC20(address(vault)).balanceOf(address(this));

        // The counter carries the message value when it is native; the target never can.
        _receiveInput(context.counter, maxCounter, counterPermit);
        address target = Currency.unwrap(context.target);
        _permit(target, maxTarget, targetPermit);
        CurrencyTransfer.pullExact(target, msg.sender, maxTarget);

        (shares, targetUsed, counterUsed) =
            _depositPair(vault, context, maxTarget, maxCounter, minShares, receiver, deadline);
        emit RoutedPairMinted(msg.sender, address(vault), receiver, targetUsed, counterUsed, shares);

        _requireBalance(context.target, targetBaseline);
        _requireBalance(context.counter, counterBaseline);
        _requireTokenBalance(address(vault), sharesBaseline);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        SwapCallbackData memory params = abi.decode(data, (SwapCallbackData));
        BalanceDelta delta = poolManager.swap(
            params.key,
            SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: -params.amountIn.toInt256(),
                sqrtPriceLimitX96: params.zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );

        int128 inputDelta = params.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = params.zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0) revert InvalidSwapDelta();
        uint256 spent = (-int256(inputDelta)).toUint256();
        if (spent != params.amountIn) revert IncompleteSwapInput(spent, params.amountIn);

        CurrencyTransfer.settleDelta(poolManager, params.key.currency0, params.key.currency1, delta);
        return abi.encode(delta);
    }

    function _zapCounter(
        ILpTokenVault vault,
        VaultContext memory context,
        uint256 counterAmount,
        uint256 swapCounterAmount,
        uint256 minSwapTargetOut,
        uint256 minShares,
        address receiver,
        uint256 deadline
    )
        private
        returns (
            uint256 shares,
            uint256 targetUsed,
            uint256 counterUsed,
            uint256 counterSwapped,
            uint256 targetBought
        )
    {
        if (counterAmount == 0 || swapCounterAmount > counterAmount) {
            revert InvalidAmount();
        }
        if (minShares == 0) revert MinimumSharesRequired();

        if (swapCounterAmount != 0) {
            counterSwapped = swapCounterAmount;
            targetBought =
                _swapExactInput(context.key, !context.targetIsCurrency0, swapCounterAmount);
        }
        if (targetBought < minSwapTargetOut) {
            revert InsufficientSwapOutput(targetBought, minSwapTargetOut);
        }

        uint256 counterRemaining = counterAmount - counterSwapped;
        uint256 counterUsedByMint;
        (shares, targetUsed, counterUsedByMint) = _depositPair(
            vault, context, targetBought, counterRemaining, minShares, receiver, deadline
        );
        counterUsed = counterSwapped + counterUsedByMint;
        emit ZappedIn(
            msg.sender,
            address(vault),
            receiver,
            counterAmount,
            counterSwapped,
            targetBought,
            shares
        );
    }

    function _zapTarget(
        ILpTokenVault vault,
        VaultContext memory context,
        uint256 targetAmount,
        uint256 swapTargetAmount,
        uint256 minSwapCounterOut,
        uint256 minShares,
        address receiver,
        uint256 deadline
    )
        private
        returns (
            uint256 shares,
            uint256 targetUsed,
            uint256 counterUsed,
            uint256 targetSwapped,
            uint256 counterBought
        )
    {
        if (targetAmount == 0 || swapTargetAmount == 0 || swapTargetAmount >= targetAmount) {
            revert InvalidAmount();
        }
        if (minShares == 0) revert MinimumSharesRequired();

        targetSwapped = swapTargetAmount;
        counterBought = _swapExactInput(context.key, context.targetIsCurrency0, swapTargetAmount);
        if (counterBought < minSwapCounterOut) {
            revert InsufficientSwapOutput(counterBought, minSwapCounterOut);
        }

        uint256 targetRemaining = targetAmount - targetSwapped;
        uint256 targetUsedByMint;
        (shares, targetUsedByMint, counterUsed) = _depositPair(
            vault, context, targetRemaining, counterBought, minShares, receiver, deadline
        );
        targetUsed = targetSwapped + targetUsedByMint;
    }

    function _routeToCounter(
        Currency inputCurrency,
        uint256 inputAmount,
        PoolKey[] calldata route,
        Currency counterCurrency
    ) private returns (uint256 amountOut) {
        Currency current = inputCurrency;
        amountOut = inputAmount;

        if (route.length != 0) {
            Currency routeInput = _routeInputCurrency(current, route[0]);
            amountOut = _convertCurrency(current, routeInput, amountOut);
            current = routeInput;

            for (uint256 i; i < route.length; ++i) {
                PoolKey memory key = route[i];
                bool zeroForOne;
                if (current == key.currency0) {
                    zeroForOne = true;
                    current = key.currency1;
                } else if (current == key.currency1) {
                    zeroForOne = false;
                    current = key.currency0;
                } else {
                    revert RouteCurrencyMismatch(i, Currency.unwrap(current));
                }
                amountOut = _swapExactInput(key, zeroForOne, amountOut);
            }
        }

        return _convertCurrency(current, counterCurrency, amountOut);
    }

    function _convertCurrency(Currency current, Currency output, uint256 amount)
        private
        returns (uint256)
    {
        if (current == output) return amount;
        Currency wrappedCurrency = Currency.wrap(address(wrappedNative));
        if (current.isAddressZero() && output == wrappedCurrency) {
            return _wrap(amount);
        }
        if (current == wrappedCurrency && output.isAddressZero()) {
            return _unwrap(amount);
        }
        revert RouteOutputMismatch(Currency.unwrap(current), Currency.unwrap(output));
    }

    function _swapExactInput(PoolKey memory key, bool zeroForOne, uint256 amountIn)
        private
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert InvalidAmount();
        uint128 exactAmountIn = amountIn.toUint128();
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
        uint256 inputBefore = _currencyBalance(inputCurrency);
        uint256 outputBefore = _currencyBalance(outputCurrency);
        BalanceDelta delta = abi.decode(
            poolManager.unlock(
                abi.encode(
                    SwapCallbackData({
                        key: key, zeroForOne: zeroForOne, amountIn: uint256(exactAmountIn)
                    })
                )
            ),
            (BalanceDelta)
        );
        uint256 inputAfter = _currencyBalance(inputCurrency);
        uint256 inputSpent = inputAfter <= inputBefore ? inputBefore - inputAfter : 0;
        if (inputSpent != amountIn) revert InexactSwapInput(amountIn, inputSpent);
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        amountOut = int256(outputDelta).toUint256();
        uint256 outputReceived = _currencyBalance(outputCurrency) - outputBefore;
        if (outputReceived != amountOut) revert InexactSwapOutput(amountOut, outputReceived);
    }

    function _validatedVault(ILpTokenVault vault)
        private
        view
        returns (VaultContext memory context)
    {
        if (!factory.isVault(address(vault))) {
            revert UnregisteredVault(address(vault));
        }
        if (vault.factory() != address(factory)) revert UnregisteredVault(address(vault));
        context.key = vault.poolKey();
        context.target = Currency.wrap(vault.target());
        if (context.target == context.key.currency0) {
            context.targetIsCurrency0 = true;
            context.counter = context.key.currency1;
        } else if (context.target == context.key.currency1) {
            context.counter = context.key.currency0;
        } else {
            revert UnregisteredVault(address(vault));
        }
        _requireIndependentLegs(context.key);
    }

    function _validateRoutePool(PoolKey memory key, uint256 hop) private pure {
        if (address(key.hooks) != address(0)) {
            revert HookedPoolNotSupported(address(key.hooks));
        }
        if (LPFeeLibrary.isDynamicFee(key.fee)) revert DynamicFeePoolNotSupported();
        if (!LPFeeLibrary.isValid(key.fee) || key.fee == LPFeeLibrary.MAX_LP_FEE) {
            revert InvalidPoolFee(key.fee);
        }
        if (
            Currency.unwrap(key.currency0) >= Currency.unwrap(key.currency1)
                || key.tickSpacing < TickMath.MIN_TICK_SPACING
                || key.tickSpacing > TickMath.MAX_TICK_SPACING
        ) revert InvalidRoutePool(hop);
        _requireIndependentLegs(key);
    }

    function _validateRoute(
        Currency inputCurrency,
        PoolKey[] calldata route,
        Currency counterCurrency
    ) private view {
        if (route.length > MAX_ROUTE_HOPS) {
            revert InvalidRouteLength(route.length);
        }
        Currency current = inputCurrency;
        if (route.length != 0) current = _routeInputCurrency(current, route[0]);

        for (uint256 i; i < route.length; ++i) {
            PoolKey memory key = route[i];
            _validateRoutePool(key, i);
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
            if (sqrtPriceX96 == 0) revert InvalidRoutePool(i);
            if (current == key.currency0) current = key.currency1;
            else if (current == key.currency1) current = key.currency0;
            else revert RouteCurrencyMismatch(i, Currency.unwrap(current));
        }

        Currency wrappedCurrency = Currency.wrap(address(wrappedNative));
        if (
            !(current == counterCurrency)
                && !(current.isAddressZero() && counterCurrency == wrappedCurrency)
                && !(current == wrappedCurrency && counterCurrency.isAddressZero())
        ) revert RouteOutputMismatch(Currency.unwrap(current), Currency.unwrap(counterCurrency));
    }

    /// @dev Shared by route validation and execution so they infer the same first currency.
    function _routeInputCurrency(Currency current, PoolKey calldata first)
        private
        view
        returns (Currency)
    {
        if (_contains(first, current)) return current;
        if (current.isAddressZero()) {
            Currency erc20Usdc = Currency.wrap(USDC);
            if (_contains(first, erc20Usdc)) return erc20Usdc;
        } else if (Currency.unwrap(current) == USDC && first.currency0.isAddressZero()) {
            return first.currency0;
        }
        return current;
    }

    function _validateInput(Currency inputCurrency) private view {
        address input = Currency.unwrap(inputCurrency);
        if (input != address(0) && input != canonicalStable) revert UnsupportedInput(input);
    }

    function _receiveInput(
        Currency inputCurrency,
        uint256 amount,
        PermitSignature memory permitSignature
    ) private {
        if (amount == 0) revert InvalidAmount();
        bool nativeInput = inputCurrency.isAddressZero();
        uint256 expectedValue = nativeInput ? amount : 0;
        if (msg.value != expectedValue) revert InvalidMsgValue(msg.value, expectedValue);
        if (!nativeInput) {
            address input = Currency.unwrap(inputCurrency);
            _permit(input, amount, permitSignature);
            CurrencyTransfer.pullExact(input, msg.sender, amount);
        }
    }

    /// @dev Deposits target and counter this contract already holds, resets the approvals the
    /// vault needed, and returns whatever the mint declined to `msg.sender`. Shares go straight
    /// to `receiver`, so they never rest here.
    function _depositPair(
        ILpTokenVault vault,
        VaultContext memory context,
        uint256 targetAmount,
        uint256 counterAmount,
        uint256 minShares,
        address receiver,
        uint256 deadline
    ) private returns (uint256 shares, uint256 targetUsed, uint256 counterUsed) {
        address target = Currency.unwrap(context.target);
        Currency counterCurrency = context.counter;
        bool counterIsNative = counterCurrency.isAddressZero();

        IERC20(target).forceApprove(address(vault), targetAmount);
        if (!counterIsNative) {
            IERC20(Currency.unwrap(counterCurrency)).forceApprove(address(vault), counterAmount);
        }
        (shares, targetUsed, counterUsed) = vault.mintPair{
            value: counterIsNative ? counterAmount : 0
        }(
            targetAmount, counterAmount, minShares, receiver, deadline
        );
        IERC20(target).forceApprove(address(vault), 0);
        if (!counterIsNative) {
            IERC20(Currency.unwrap(counterCurrency)).forceApprove(address(vault), 0);
        }

        if (targetAmount > targetUsed) {
            IERC20(target).safeTransfer(msg.sender, targetAmount - targetUsed);
        }
        if (counterAmount > counterUsed) {
            CurrencyTransfer.transfer(counterCurrency, msg.sender, counterAmount - counterUsed);
        }
    }

    /// @dev Absent approval, which the entry points without one carry.
    function _noPermit() private pure returns (PermitSignature memory permitSignature) { }

    /// @dev Runs a carried EIP-2612 approval before the pull that consumes it, then requires
    /// the allowance it was to grant. Anyone may relay a permit signature, so a front-runner
    /// can spend its nonce and leave the permit call reverting over an approval that already
    /// landed; the call is therefore attempted, not required, and the allowance is what is
    /// checked. A carried approval that left the allowance short — a consumed or unusable
    /// signature, or a token whose permit verifies one and grants nothing — is reported as
    /// its own failure, so a client can tell it from every other reason the call might fail
    /// and answer it, and only it, with an ordinary approval. Plain calls carry nothing and
    /// are untouched.
    function _permit(address token, uint256 amount, PermitSignature memory permitSignature)
        private
    {
        if (permitSignature.deadline == 0) return;
        try IERC20Permit(token)
            .permit(
                msg.sender,
                address(this),
                permitSignature.value,
                permitSignature.deadline,
                permitSignature.v,
                permitSignature.r,
                permitSignature.s
            ) { }
            catch { }
        if (IERC20(token).allowance(msg.sender, address(this)) < amount) {
            revert CarriedApprovalNotGranted(token);
        }
    }

    function _contains(PoolKey calldata key, Currency currency) private pure returns (bool) {
        return key.currency0 == currency || key.currency1 == currency;
    }

    function _wrap(uint256 amount) private returns (uint256 erc20Amount) {
        erc20Amount = amount / NATIVE_SCALE;
        if (erc20Amount == 0) revert InvalidAmount();
        // Convert only this route's funds. Pre-existing native dust belongs to its depositor.
        CurrencyTransfer.transfer(Currency.wrap(address(0)), msg.sender, amount % NATIVE_SCALE);
    }

    function _unwrap(uint256 amount) private pure returns (uint256) {
        return amount * NATIVE_SCALE;
    }

    function _currencyBalance(Currency currency) private view returns (uint256) {
        return currency.balanceOfSelf();
    }

    function _balanceAtStart(Currency currency, uint256 nativeBaseline)
        private
        view
        returns (uint256)
    {
        // Both USDC views already include msg.value. Preserve the full pre-call native
        // reserve, including dust hidden by six-decimal ERC-20 balanceOf.
        return _isUsdc(currency) ? nativeBaseline : currency.balanceOfSelf();
    }

    function _requireBalance(Currency currency, uint256 expected) private view {
        // Shared-reserve baselines use native units for both USDC representations.
        if (_isUsdc(currency)) currency = Currency.wrap(address(0));
        uint256 actual = _currencyBalance(currency);
        if (actual != expected) {
            revert UnexpectedBalance(Currency.unwrap(currency), actual, expected);
        }
    }

    function _requireTokenBalance(address token, uint256 expected) private view {
        uint256 actual = IERC20(token).balanceOf(address(this));
        if (actual != expected) revert UnexpectedBalance(token, actual, expected);
    }

    function _check(uint256 deadline, address receiver) private view {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (receiver == address(0) || receiver == address(this)) revert InvalidAddress();
    }

    function _requireIndependentLegs(PoolKey memory key) private pure {
        if (_isUsdc(key.currency0) && _isUsdc(key.currency1)) revert AliasedPoolCurrencies();
    }

    function _isUsdc(Currency currency) private pure returns (bool) {
        return currency.isAddressZero() || Currency.unwrap(currency) == USDC;
    }
}
