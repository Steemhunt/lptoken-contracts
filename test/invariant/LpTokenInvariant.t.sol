// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { LpTokenVault } from "../../src/LpTokenVault.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { LpTokenTestBase } from "../utils/LpTokenTestBase.sol";

contract LpTokenInvariantHandler is Test {
    LpTokenInvariantTest public immutable base;
    LpTokenVault public immutable vault;
    MockERC20 public immutable target;
    MockERC20 public immutable counterToken;

    constructor(
        LpTokenInvariantTest base_,
        LpTokenVault vault_,
        MockERC20 target_,
        MockERC20 counterToken_
    ) {
        base = base_;
        vault = vault_;
        target = target_;
        counterToken = counterToken_;
        target_.approve(address(vault_), type(uint256).max);
        counterToken_.approve(address(vault_), type(uint256).max);
    }

    function mintPair(uint96 rawAmount) external {
        uint256 amount = bound(uint256(rawAmount), 1e6, 100e18);
        (uint256 previewShares,,) = vault.previewMintPair(amount, amount);
        if (previewShares == 0) return;
        target.mint(address(this), amount);
        counterToken.mint(address(this), amount);
        vault.mintPair(amount, amount, 0, address(this), block.timestamp);
    }

    function redeem(uint256 seed) external {
        uint256 balance = vault.balanceOf(address(this));
        uint256 minimum = vault.MIN_FEEABLE_SHARES();
        if (balance < minimum) return;
        uint256 shares = bound(seed, minimum, balance);
        vault.redeem(shares, 0, 0, address(this), block.timestamp);
    }

    function swap(uint96 rawAmount, bool zeroForOne) external {
        base.swapForHandler(zeroForOne, bound(uint256(rawAmount), 1e6, 50e18));
    }

    function donate(uint64 raw0, uint64 raw1) external {
        base.donateForHandler(bound(uint256(raw0), 1, 1e18), bound(uint256(raw1), 1, 1e18));
    }

    function compound() external {
        uint64 availableAt = vault.compoundAvailableAt();
        if (block.timestamp < availableAt) vm.warp(availableAt);
        try vault.compound(0, block.timestamp) returns (uint128) { } catch { }
    }

    function externalLiquidity(uint96 rawAmount, bool add) external {
        int256 amount = int256(bound(uint256(rawAmount), 1e9, 1e18));
        base.externalLiquidityForHandler(add ? amount : -amount);
    }
}

contract LpTokenInvariantTest is StdInvariant, LpTokenTestBase {
    using StateLibrary for IPoolManager;

    PoolKey internal poolKey;
    LpTokenVault internal vault;
    LpTokenInvariantHandler internal handler;
    uint256 internal externalLiquiditySalt;
    uint256 internal initialSupply;
    uint128 internal initialPositionLiquidity;

    function setUp() public override {
        super.setUp();
        poolKey = _erc20Key(address(cashcat), address(usdg));
        _initLivePool(poolKey, 0);
        vault = _launch(address(cashcat), poolKey, 1_000e18, 1_000e18);
        initialSupply = vault.totalSupply();
        initialPositionLiquidity = vault.positionLiquidity();

        handler = new LpTokenInvariantHandler(this, vault, cashcat, usdg);
        targetContract(address(handler));
    }

    function swapForHandler(bool zeroForOne, uint256 amountIn) external {
        _swap(poolKey, makeAddr("invariant trader"), zeroForOne, amountIn);
    }

    function donateForHandler(uint256 amount0, uint256 amount1) external {
        _donate(poolKey, makeAddr("invariant donor"), amount0, amount1);
    }

    /// @dev Adds go into a fresh salted position each time: the canonical v4 test router
    /// asserts that adding liquidity nets a debt, which a fee-laden shared position can
    /// violate. Removals drain the setUp baseline position, whose fee credits are fine.
    function externalLiquidityForHandler(int256 liquidityDelta) external {
        if (liquidityDelta > 0) {
            _addRangeLiquidity(
                poolKey,
                makeAddr("invariant lp"),
                TickMath.minUsableTick(SPACING),
                TickMath.maxUsableTick(SPACING),
                liquidityDelta,
                bytes32(++externalLiquiditySalt)
            );
        } else {
            _addFullRangeLiquidity(poolKey, address(this), liquidityDelta);
        }
    }

    function invariantFullSupplyClaimsExactlyNetAssets() public view {
        (uint256 targetAssets, uint256 counterAssets) = vault.totalAssets();
        (uint256 targetClaim, uint256 counterClaim) = vault.claimForShares(vault.totalSupply());
        assertEq(targetClaim, targetAssets);
        assertEq(counterClaim, counterAssets);
    }

    function invariantDeadSharesPermanent() public view {
        assertEq(vault.balanceOf(vault.DEAD_SHARE_RECEIVER()), vault.DEAD_SHARES());
        assertGe(vault.totalSupply(), vault.DEAD_SHARES());
    }

    function invariantVaultOwnsOnlySaltZeroRangePosition() public view {
        (int24 lower, int24 upper) = vault.positionTicks();
        (uint128 liquidity,,) =
            manager.getPositionInfo(poolKey.toId(), address(vault), lower, upper, bytes32(0));
        assertEq(liquidity, vault.positionLiquidity());
        assertGt(liquidity, 0);
        assertGe(manager.getLiquidity(poolKey.toId()), liquidity);
    }

    function invariantCompoundBaseMatchesPositionLiquidity() public view {
        assertEq(vault.compoundBase(), vault.positionLiquidity());
    }

    function invariantPositionLiquidityPerShareNeverDecreases() public view {
        assertGe(
            uint256(vault.positionLiquidity()) * initialSupply,
            uint256(initialPositionLiquidity) * vault.totalSupply()
        );
    }

    function invariantRedeemPreviewNeverExceedsGrossClaim() public view {
        uint256 shares = vault.balanceOf(address(handler));
        (uint256 grossTarget, uint256 grossCounter) = vault.claimForShares(shares);
        (uint256 netTarget, uint256 netCounter) = vault.previewRedeem(shares);
        assertGe(grossTarget, netTarget);
        assertGe(grossCounter, netCounter);
    }
}
