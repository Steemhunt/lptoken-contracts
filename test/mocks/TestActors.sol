// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { TransientStateLibrary } from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Standard-balance ERC-20 whose transferFrom can invoke a configured callback.
/// Used to model ERC-777-style or otherwise callback-capable curated assets.
contract CallbackERC20 is ERC20 {
    uint8 private immutable _tokenDecimals;
    address public callbackRecipient;
    address public callbackTarget;
    bytes public callbackData;
    uint256 public callbackCount;
    bool private _callbackActive;

    error CallbackFailed();

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    receive() external payable { }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configureTransferFromCallback(address recipient, address target, bytes calldata data)
        external
    {
        callbackRecipient = recipient;
        callbackTarget = target;
        callbackData = data;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        bool success = super.transferFrom(from, to, value);
        if (!_callbackActive && to == callbackRecipient && callbackTarget != address(0)) {
            _callbackActive = true;
            ++callbackCount;
            (bool callbackSuccess,) = callbackTarget.call(callbackData);
            if (!callbackSuccess) revert CallbackFailed();
            _callbackActive = false;
        }
        return success;
    }
}

/// @notice Fee-on-transfer token used to prove the vault fails closed outside its
/// documented standard-ERC20 support boundary.
contract TaxedERC20 is ERC20 {
    uint256 public constant TAX_BPS = 100;

    constructor() ERC20("Taxed", "TAX") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        uint256 tax = from == address(0) || to == address(0) ? 0 : value * TAX_BPS / 10_000;
        if (tax != 0) super._update(from, address(0xdead), tax);
        super._update(from, to, value - tax);
    }
}

/// @notice Force-sends native currency via selfdestruct, bypassing receive() gates.
contract ForceSender {
    constructor() payable { }

    function force(address payable to) external {
        selfdestruct(to);
    }
}

/// @notice Receiver that rejects all native transfers.
contract NativeRejector { }

/// @notice Minimal unlock router able to provide full-range liquidity for fee-on-transfer
/// tokens by grossing up transfers so the PoolManager still receives its exact owed
/// amount. Exists only so tests can build a live taxed pool the vault must then reject.
contract TaxedLiquidityProvider is IUnlockCallback {
    using SafeCast for int256;
    using SafeCast for uint256;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    function provide(PoolKey memory key, int256 liquidityDelta) external {
        poolManager.unlock(abi.encode(key, liquidityDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "only manager");
        (PoolKey memory key, int256 liquidityDelta) = abi.decode(data, (PoolKey, int256));
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            bytes("")
        );
        _settleGross(key.currency0, delta.amount0());
        _settleGross(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settleGross(Currency currency, int128 delta) private {
        IERC20 token = IERC20(Currency.unwrap(currency));
        if (delta < 0) {
            uint256 owed = (-int256(delta)).toUint256();
            poolManager.sync(currency);
            // Overshoot the transfer so the manager nets at least `owed` after any
            // transfer tax, then reclaim whatever surplus was credited.
            uint256 gross = owed * 2;
            token.transfer(address(poolManager), gross);
            poolManager.settle();
            int256 remaining = poolManager.currencyDelta(address(this), currency);
            if (remaining > 0) poolManager.take(currency, address(this), uint256(remaining));
        } else if (delta > 0) {
            poolManager.take(currency, address(this), int256(delta).toUint256());
        }
    }
}
