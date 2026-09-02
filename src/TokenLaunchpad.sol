// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { FixedPoint96 } from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { LaunchLiquidityVault } from "./LaunchLiquidityVault.sol";
import { LaunchToken } from "./LaunchToken.sol";
import { LpTokenFactory } from "./LpTokenFactory.sol";
import { LpTokenVault } from "./LpTokenVault.sol";
import { CurrencyTransfer } from "./libraries/CurrencyTransfer.sol";
import { LaunchPoolConfig } from "./libraries/LaunchPoolConfig.sol";

/// @notice Permissionless fixed-supply token launcher. Every token receives one permanent
/// one-sided position and one permanently locked lpTOKEN vault seed in the same
/// native-currency Uniswap V4 pool. Supply, fee, and tick spacing are product constants;
/// the Factory owner may update the native-denominated start tick and bootstrap quote for
/// future launches, while existing positions retain the terms they launched under.
contract TokenLaunchpad is IUnlockCallback, ReentrancyGuardTransient {
    using SafeCast for int256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant TOKEN_SUPPLY = LaunchPoolConfig.TOKEN_SUPPLY;
    uint24 public constant LP_FEE = LaunchPoolConfig.LP_FEE;
    int24 public constant TICK_SPACING = LaunchPoolConfig.TICK_SPACING;

    IPoolManager public immutable poolManager;
    LpTokenFactory public immutable factory;
    LaunchLiquidityVault public immutable liquidityVault;

    uint160 private _initialSqrtPriceX96;
    /// @notice Initial pool tick, and the permanent launch range's upper bound. Governs
    /// launches made from now on; every existing token keeps the terms it launched under.
    int24 public startTick;
    /// @notice Native contribution the launchpad seeds into the lpTOKEN vault.
    uint256 public initialLpQuote;
    uint256 private _bootstrapTargetAmount;

    struct TokenMetadata {
        string name;
        string symbol;
        string imageUrl;
        string websiteUrl;
        string twitterHandle;
        string telegramHandle;
    }

    struct TokenInfo {
        address token;
        address creator;
        address vault;
        bytes32 poolId;
        uint128 launchLiquidity;
        uint64 createdAt;
    }

    struct TokenRecord {
        address token;
        address creator;
        address vault;
        uint128 launchLiquidity;
        uint64 createdAt;
    }

    struct SwapCallbackData {
        address token;
        uint256 amountIn;
        uint160 sqrtPriceLimitX96;
    }

    TokenRecord[] private _tokens;
    mapping(address token => uint256 oneBasedIndex) public tokenIndex;

    event TokenCreated(
        address indexed token,
        address indexed creator,
        bytes32 indexed poolId,
        address vault,
        bytes32 userSalt,
        string name,
        string symbol,
        uint160 initialSqrtPriceX96,
        int24 startTick,
        uint128 launchLiquidity,
        uint256 bootstrapTarget,
        uint256 bootstrapQuote,
        uint256 tokenDustSentToDead
    );
    event LaunchTermsUpdated(
        int24 startTick, uint256 initialLpQuote, uint256 bootstrapTarget, uint256 initialFdvNative
    );
    event CreatorInitialBuy(
        address indexed token,
        address indexed creator,
        uint256 quoteSpent,
        uint256 targetOut,
        uint256 quoteRefunded
    );

    error DeadlineExpired();
    error InsufficientInitialBuyOutput(uint256 amount, uint256 minimum);
    error InvalidAddress();
    error InvalidMsgValue(uint256 provided, uint256 minimum);
    error InvalidLaunchTerms();
    error LaunchTermsChanged(
        int24 expectedStartTick,
        int24 actualStartTick,
        uint256 expectedInitialLpQuote,
        uint256 actualInitialLpQuote
    );
    error OnlyFactoryOwner();
    error OnlySelfInitialization();
    error InvalidRange();
    error InvalidSwapDelta();
    error OnlyPoolManager();
    error PredictedVaultMismatch(address predicted, address deployed);
    error SwapInputExceeded(uint256 spent, uint256 maximum);
    error TokenNotFound();

    /// @param startTick_ Launch price as a tick. Must be a multiple of the fixed tick spacing
    /// and leave a usable one-sided range below it, so the permanent launch position is not
    /// degenerate. Native-denominated economics differ per chain, which is why this and
    /// `initialLpQuote_` are deployment parameters rather than compiled-in constants.
    /// @param initialLpQuote_ Native contribution seeded into the lpTOKEN vault.
    constructor(
        IPoolManager poolManager_,
        LpTokenFactory factory_,
        int24 startTick_,
        uint256 initialLpQuote_
    ) {
        if (address(poolManager_) == address(0) || address(factory_) == address(0)) {
            revert InvalidAddress();
        }
        if (address(poolManager_).code.length == 0 || address(factory_).code.length == 0) {
            revert InvalidAddress();
        }
        if (address(factory_.poolManager()) != address(poolManager_)) revert InvalidAddress();

        Hooks.Permissions memory permissions;
        permissions.beforeInitialize = true;
        Hooks.validateHookPermissions(IHooks(address(this)), permissions);

        poolManager = poolManager_;
        factory = factory_;
        _setLaunchTerms(factory_, startTick_, initialLpQuote_);
        liquidityVault = new LaunchLiquidityVault(poolManager_, address(this), address(factory_));
    }

    /// @notice Replaces the launch terms for future tokens. Native-denominated economics move
    /// with the market, so this is the same class of authority as curating a new pool: it
    /// governs what may be launched next and reaches nothing already launched. Every existing
    /// token keeps its pool, its price, and — because `LaunchLiquidityVault` pins each
    /// position's range at creation — its permanent launch position and fee claim.
    /// @dev Authority follows the Factory owner, so the platform keeps one admin identity.
    function setLaunchTerms(int24 startTick_, uint256 initialLpQuote_) external nonReentrant {
        LpTokenFactory factory_ = factory;
        if (msg.sender != factory_.owner()) revert OnlyFactoryOwner();
        _setLaunchTerms(factory_, startTick_, initialLpQuote_);
    }

    /// @dev Takes the Factory explicitly so the constructor can validate before the immutable
    /// is readable from a called function.
    function _setLaunchTerms(LpTokenFactory factory_, int24 startTick_, uint256 initialLpQuote_)
        private
    {
        (int24 minimumTick, int24 maximumTick) = LaunchPoolConfig.vaultTicks();
        if (
            startTick_ % TICK_SPACING != 0 || startTick_ <= minimumTick || startTick_ >= maximumTick
        ) revert InvalidLaunchTerms();
        if (initialLpQuote_ == 0) revert InvalidLaunchTerms();

        uint256 bootstrapTarget =
            LaunchPoolConfig.bootstrapTargetAmount(startTick_, initialLpQuote_);
        // A launch must fund its vault seed and still leave one-sided launch liquidity.
        if (bootstrapTarget == 0 || bootstrapTarget >= TOKEN_SUPPLY) revert InvalidLaunchTerms();
        if (LaunchPoolConfig.launchLiquidity(startTick_, TOKEN_SUPPLY - bootstrapTarget) == 0) {
            revert InvalidLaunchTerms();
        }
        // The vault mints the dead-share floor out of the bootstrap seed before the receiver's
        // share, so a seed that does not clear that floor reverts inside `bootstrap` instead.
        // Checking it here keeps every launch-viability failure at the operator. The floor is
        // read from the implementation the Factory will clone rather than restated here, so the
        // two cannot drift.
        uint256 deadShareFloor = LpTokenVault(payable(factory_.vaultImplementation())).DEAD_SHARES();
        if (
            LaunchPoolConfig.bootstrapLiquidity(startTick_, initialLpQuote_, bootstrapTarget)
                <= deadShareFloor
        ) revert InvalidLaunchTerms();

        startTick = startTick_;
        initialLpQuote = initialLpQuote_;
        _initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(startTick_);
        _bootstrapTargetAmount = bootstrapTarget;
        emit LaunchTermsUpdated(startTick_, initialLpQuote_, bootstrapTarget, initialFdvNative());
    }

    /// @notice Fully diluted value of the supply at the current start price, in native units.
    /// Derived from `startTick`, so it cannot disagree with the price actually set.
    function initialFdvNative() public view returns (uint256) {
        // The token is currency1, so one token is (Q96 / sqrtPrice)^2 of the native leg.
        uint160 sqrtPriceX96 = _initialSqrtPriceX96;
        uint256 supplyPerSqrtPrice = FullMath.mulDiv(TOKEN_SUPPLY, FixedPoint96.Q96, sqrtPriceX96);
        return FullMath.mulDiv(supplyPerSqrtPrice, FixedPoint96.Q96, sqrtPriceX96);
    }

    /// @notice Atomically creates the fixed token, initializes its protected pool, and
    /// bootstraps both permanent liquidity positions before an optional creator buy.
    /// @dev The launchpad is the PoolKey's initializer-only hook. Uniswap V4 skips the
    /// callback when the hook itself calls `initialize`, while every external initializer
    /// reaches `beforeInitialize` and reverts. The expected terms bind the creator's
    /// transaction to the economics they reviewed.
    function createToken(
        TokenMetadata calldata metadata,
        bytes32 userSalt,
        uint256 minInitialBuyOut,
        uint160 sqrtPriceLimitX96,
        int24 expectedStartTick,
        uint256 expectedInitialLpQuote,
        uint256 deadline
    )
        external
        payable
        nonReentrant
        returns (address token, address vault, uint256 initialBuyTargetOut)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        int24 launchStartTick = startTick;
        uint256 quote = initialLpQuote;
        if (launchStartTick != expectedStartTick || quote != expectedInitialLpQuote) {
            revert LaunchTermsChanged(
                expectedStartTick, launchStartTick, expectedInitialLpQuote, quote
            );
        }
        if (msg.value < quote) {
            revert InvalidMsgValue(msg.value, quote);
        }

        address creator = msg.sender;
        token = _deployToken(metadata, creator, userSalt);
        PoolKey memory key = _poolKey(token);
        uint160 sqrtPriceX96 = _initialSqrtPriceX96;
        poolManager.initialize(key, sqrtPriceX96);

        uint256 bootstrapTarget = _bootstrapTargetAmount;
        uint256 launchTarget = TOKEN_SUPPLY - bootstrapTarget;
        address predictedVault = factory.predictLaunchpadVault(token);
        IERC20(token).safeTransfer(address(liquidityVault), launchTarget);
        (uint128 launchLiquidity, uint256 dust) =
            liquidityVault.addPosition(token, creator, predictedVault, launchTarget);

        // The Factory validates this registration during the nested launch call, so both
        // halves of the registry must land before it: writing them together keeps
        // `isToken`, `getTokenCount`, and `getTokenInfo` mutually consistent for the whole
        // window rather than relying on nothing in the launch path reading them back. The
        // record stores the predicted vault, which the check below pins to the deployed
        // clone. Any later failure reverts the registration together with the entire launch.
        tokenIndex[token] = _tokens.length + 1;
        _tokens.push(
            TokenRecord({
                token: token,
                creator: creator,
                vault: predictedVault,
                launchLiquidity: launchLiquidity,
                createdAt: uint64(block.timestamp)
            })
        );

        IERC20(token).forceApprove(predictedVault, bootstrapTarget);
        (vault,,) = factory.launchFromLaunchpad{ value: quote }(token, bootstrapTarget);
        IERC20(token).forceApprove(predictedVault, 0);
        if (vault != predictedVault) revert PredictedVaultMismatch(predictedVault, vault);

        emit TokenCreated(
            token,
            creator,
            PoolId.unwrap(key.toId()),
            vault,
            userSalt,
            metadata.name,
            metadata.symbol,
            sqrtPriceX96,
            launchStartTick,
            launchLiquidity,
            bootstrapTarget,
            quote,
            dust
        );

        uint256 maximumInitialBuy = msg.value - quote;
        uint256 quoteSpent;
        if (maximumInitialBuy != 0) {
            (quoteSpent, initialBuyTargetOut) =
                _swapNativeForTarget(key, maximumInitialBuy, sqrtPriceLimitX96);
        }
        if (initialBuyTargetOut < minInitialBuyOut) {
            revert InsufficientInitialBuyOutput(initialBuyTargetOut, minInitialBuyOut);
        }
        if (initialBuyTargetOut != 0) IERC20(token).safeTransfer(creator, initialBuyTargetOut);

        uint256 quoteRefunded = maximumInitialBuy - quoteSpent;
        CurrencyTransfer.transfer(Currency.wrap(address(0)), creator, quoteRefunded);
        if (maximumInitialBuy != 0) {
            emit CreatorInitialBuy(token, creator, quoteSpent, initialBuyTargetOut, quoteRefunded);
        }
    }

    function predictTokenAddress(address creator, TokenMetadata calldata metadata, bytes32 userSalt)
        external
        view
        returns (address predicted)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(LaunchToken).creationCode,
                abi.encode(
                    metadata.name,
                    metadata.symbol,
                    metadata.imageUrl,
                    metadata.websiteUrl,
                    metadata.twitterHandle,
                    metadata.telegramHandle,
                    creator,
                    address(this)
                )
            )
        );
        predicted = Create2.computeAddress(_deploymentSalt(creator, userSalt), initCodeHash);
    }

    function isToken(address token) external view returns (bool) {
        return tokenIndex[token] != 0;
    }

    function getTokenCount() external view returns (uint256) {
        return _tokens.length;
    }

    function getTokenInfo(address token) external view returns (TokenInfo memory) {
        uint256 index = tokenIndex[token];
        if (index == 0) revert TokenNotFound();
        return _tokenInfo(_tokens[index - 1]);
    }

    function tokens(uint256 index) external view returns (TokenInfo memory) {
        return _tokenInfo(_tokens[index]);
    }

    function getTokens(uint256 startIndex, uint256 endIndex)
        external
        view
        returns (TokenInfo[] memory result)
    {
        if (startIndex > endIndex) revert InvalidRange();
        uint256 count = _tokens.length;
        if (startIndex >= count) return new TokenInfo[](0);
        if (endIndex > count) endIndex = count;

        result = new TokenInfo[](endIndex - startIndex);
        for (uint256 i; i < result.length; ++i) {
            result[i] = _tokenInfo(_tokens[startIndex + i]);
        }
    }

    function poolKey(address token) external view returns (PoolKey memory) {
        return _poolKey(token);
    }

    /// @notice Rejects every external attempt to initialize a launch pool.
    /// @dev V4 does not call this function when `sender == key.hooks`, so the launchpad's
    /// own atomic initialization is the only path that can succeed.
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert OnlySelfInitialization();
    }

    function poolTicks()
        external
        view
        returns (int24 launchStartTick, int24 tickLower, int24 tickUpper)
    {
        launchStartTick = startTick;
        (tickLower, tickUpper) = LaunchPoolConfig.launchTicks(launchStartTick);
    }

    function initialSqrtPriceX96() external view returns (uint160) {
        return _initialSqrtPriceX96;
    }

    function bootstrapTargetAmount() external view returns (uint256) {
        return _bootstrapTargetAmount;
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        SwapCallbackData memory data = abi.decode(rawData, (SwapCallbackData));
        PoolKey memory key = _poolKey(data.token);
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -data.amountIn.toInt256(),
                sqrtPriceLimitX96: data.sqrtPriceLimitX96
            }),
            bytes("")
        );
        if (delta.amount0() > 0 || delta.amount1() < 0) revert InvalidSwapDelta();
        uint256 spent = delta.amount0() < 0 ? (-int256(delta.amount0())).toUint256() : 0;
        if (spent > data.amountIn) revert SwapInputExceeded(spent, data.amountIn);

        CurrencyTransfer.settleDelta(poolManager, key.currency0, key.currency1, delta);
        return abi.encode(delta);
    }

    function _deployToken(TokenMetadata calldata metadata, address creator, bytes32 userSalt)
        private
        returns (address token)
    {
        token = address(
            new LaunchToken{ salt: _deploymentSalt(creator, userSalt) }(
                metadata.name,
                metadata.symbol,
                metadata.imageUrl,
                metadata.websiteUrl,
                metadata.twitterHandle,
                metadata.telegramHandle,
                creator,
                address(this)
            )
        );
    }

    function _swapNativeForTarget(PoolKey memory key, uint256 amountIn, uint160 sqrtPriceLimitX96)
        private
        returns (uint256 amountSpent, uint256 amountOut)
    {
        uint160 limit = sqrtPriceLimitX96 == 0 ? TickMath.MIN_SQRT_PRICE + 1 : sqrtPriceLimitX96;
        BalanceDelta delta = abi.decode(
            poolManager.unlock(
                abi.encode(
                    SwapCallbackData({
                        token: Currency.unwrap(key.currency1),
                        amountIn: amountIn,
                        sqrtPriceLimitX96: limit
                    })
                )
            ),
            (BalanceDelta)
        );
        amountSpent = delta.amount0() < 0 ? (-int256(delta.amount0())).toUint256() : 0;
        amountOut = delta.amount1() > 0 ? int256(delta.amount1()).toUint256() : 0;
    }

    function _tokenInfo(TokenRecord memory record) private view returns (TokenInfo memory info) {
        info = TokenInfo({
            token: record.token,
            creator: record.creator,
            vault: record.vault,
            poolId: PoolId.unwrap(_poolKey(record.token).toId()),
            launchLiquidity: record.launchLiquidity,
            createdAt: record.createdAt
        });
    }

    function _poolKey(address token) private view returns (PoolKey memory) {
        return LaunchPoolConfig.poolKey(token, IHooks(address(this)));
    }

    function _deploymentSalt(address creator, bytes32 userSalt) private pure returns (bytes32) {
        return keccak256(abi.encode(creator, userSalt));
    }
}
