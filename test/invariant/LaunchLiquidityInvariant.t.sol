// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import { LaunchLiquidityVault } from "../../src/LaunchLiquidityVault.sol";
import { LpTokenFactory } from "../../src/LpTokenFactory.sol";
import { LpTokenVault } from "../../src/LpTokenVault.sol";
import { TokenLaunchpad } from "../../src/TokenLaunchpad.sol";
import { ILaunchFeeSource } from "../../src/interfaces/ILaunchFeeSource.sol";
import { LaunchPoolConfig } from "../../src/libraries/LaunchPoolConfig.sol";
import { LpTokenTestBase } from "../utils/LpTokenTestBase.sol";

/// @notice Launches through the launchpad but cannot receive native currency, so its counter
/// fee claims accumulate as retry liabilities instead of being paid out. Its target claims
/// still settle, because an ERC-20 transfer never hands control to the recipient.
contract RejectingCreator {
    function launch(TokenLaunchpad launchpad, bytes32 salt)
        external
        payable
        returns (address token)
    {
        // Sending exactly the quote leaves no initial buy and therefore no native refund,
        // which is the only leg of `createToken` this contract could not accept.
        (token,,) = launchpad.createToken{ value: msg.value }(
            TokenLaunchpad.TokenMetadata("Reject Cat", "RCAT", "", "", "", ""),
            salt,
            0,
            TickMath.MIN_SQRT_PRICE + 1,
            launchpad.startTick(),
            launchpad.initialLpQuote(),
            block.timestamp
        );
    }
}

contract LaunchLiquidityInvariantHandler is Test {
    LaunchLiquidityInvariantTest public immutable base;

    constructor(LaunchLiquidityInvariantTest base_, address tokenA, address tokenB) {
        base = base_;
        IERC20(tokenA).approve(address(base_.vaultOf(true)), type(uint256).max);
        IERC20(tokenB).approve(address(base_.vaultOf(false)), type(uint256).max);
    }

    /// @dev Mint refunds, redeem proceeds, and swap output all arrive as native currency.
    receive() external payable { }

    function buy(bool useA, uint96 rawAmount) external {
        base.buyForHandler(useA, bound(uint256(rawAmount), 1e12, 5 ether));
    }

    function sell(bool useA, uint96 rawAmount) external {
        uint256 held = IERC20(base.tokenOf(useA)).balanceOf(address(this));
        if (held < 1e12) return;
        base.sellForHandler(useA, bound(uint256(rawAmount), 1e12, held));
    }

    /// @dev Distributes both positions, then checks the accounting identity. Both must be
    /// current for the identity to be exact: `pendingFees` folds prospective allocations from
    /// uncollected pool fees into its result, and those are not in the contract's balance yet.
    function distribute(bool withGas, uint32 rawGas) external {
        base.distributeBothForHandler(withGas ? bound(uint256(rawGas), 30_000, 500_000) : 0);
    }

    function mintPair(bool useA, uint96 rawTarget) external {
        LpTokenVault vault = base.vaultOf(useA);
        IERC20 token = IERC20(base.tokenOf(useA));
        (uint256 targetAssets, uint256 counterAssets) = vault.totalAssets();
        if (targetAssets == 0 || counterAssets == 0) return;

        uint256 targetAmount = bound(uint256(rawTarget), 1e15, 1e24);
        if (token.balanceOf(address(this)) < targetAmount) return;
        // Fund the counter leg above parity so the target leg binds and the quote is exact.
        uint256 counterAmount = FullMath.mulDiv(targetAmount, counterAssets, targetAssets) + 1;
        if (counterAmount > 100 ether) return;

        (uint256 previewShares,,) = vault.previewMintPair(targetAmount, counterAmount);
        // Syncing launch fees inside the call raises total assets and therefore lowers the
        // authoritative share count. Keep an order of magnitude of headroom over the floor so
        // a live quote can never fall through it between the preview and the mint.
        if (previewShares < 10 * vault.MIN_FEEABLE_SHARES()) return;

        vm.deal(address(this), address(this).balance + counterAmount);
        vault.mintPair{ value: counterAmount }(
            targetAmount, counterAmount, 0, address(this), block.timestamp
        );
    }

    function redeem(bool useA, uint256 seed) external {
        LpTokenVault vault = base.vaultOf(useA);
        uint256 balance = vault.balanceOf(address(this));
        uint256 minimum = vault.MIN_FEEABLE_SHARES();
        if (balance < minimum) return;
        vault.redeem(bound(seed, minimum, balance), 0, 0, address(this), block.timestamp);
    }

    function compound(bool useA) external {
        LpTokenVault vault = base.vaultOf(useA);
        uint64 availableAt = vault.compoundAvailableAt();
        if (block.timestamp < availableAt) vm.warp(availableAt);
        try vault.compound(0, block.timestamp) returns (uint128) { } catch { }
    }
}

/// @notice Fuzzes the platform-launch path, which the curated campaign in `LpTokenInvariant`
/// cannot reach: that vault has no launch-fee source, so `_syncLaunchFees` is a no-op there and
/// none of `LaunchLiquidityVault`'s accounting runs. Two tokens share one launch vault here, so
/// the campaign also covers the part that only exists on this path -- one contract holding
/// pooled native currency against per-token liabilities.
contract LaunchLiquidityInvariantTest is StdInvariant, LpTokenTestBase {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    LpTokenFactory internal platformFactory;
    TokenLaunchpad internal launchpad;
    LaunchLiquidityVault internal launchVault;
    LaunchLiquidityInvariantHandler internal handler;

    address internal tokenA;
    address internal tokenB;
    LpTokenVault internal vaultA;
    LpTokenVault internal vaultB;
    address internal creatorA;
    address internal creatorB;
    uint128 internal launchLiquidityA;
    uint128 internal launchLiquidityB;

    function setUp() public override {
        super.setUp();

        platformFactory = new LpTokenFactory(manager, treasury, owner);
        launchpad = _deployLaunchpad(
            manager, platformFactory, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE
        );
        vm.prank(owner);
        platformFactory.bindLaunchpad(address(launchpad));
        launchVault = launchpad.liquidityVault();

        // One ordinary creator, and one that can never accept native currency, so unpaid
        // counter claims accumulate and the retry path is exercised rather than assumed.
        creatorA = alice;
        vm.deal(creatorA, LAUNCH_INITIAL_LP_QUOTE);
        vm.prank(creatorA);
        address vaultAAddress;
        (tokenA, vaultAAddress,) = launchpad.createToken{ value: LAUNCH_INITIAL_LP_QUOTE }(
            TokenLaunchpad.TokenMetadata("Invariant Cat", "ICAT", "", "", "", ""),
            keccak256("invariant paying creator"),
            0,
            TickMath.MIN_SQRT_PRICE + 1,
            LAUNCH_START_TICK,
            LAUNCH_INITIAL_LP_QUOTE,
            block.timestamp
        );

        RejectingCreator rejecting = new RejectingCreator();
        creatorB = address(rejecting);
        vm.deal(creatorB, LAUNCH_INITIAL_LP_QUOTE);
        tokenB = rejecting.launch{ value: LAUNCH_INITIAL_LP_QUOTE }(
            launchpad, keccak256("invariant rejecting creator")
        );

        vaultA = LpTokenVault(payable(vaultAAddress));
        vaultB = LpTokenVault(payable(launchpad.getTokenInfo(tokenB).vault));
        (,, launchLiquidityA,) = launchVault.positions(tokenA);
        (,, launchLiquidityB,) = launchVault.positions(tokenB);

        handler = new LaunchLiquidityInvariantHandler(this, tokenA, tokenB);
        targetContract(address(handler));
    }

    function tokenOf(bool useA) public view returns (address) {
        return useA ? tokenA : tokenB;
    }

    function vaultOf(bool useA) public view returns (LpTokenVault) {
        return useA ? vaultA : vaultB;
    }

    function keyOf(bool useA) public view returns (PoolKey memory) {
        return launchpad.poolKey(tokenOf(useA));
    }

    /// @dev The native leg is exactly what the base helper already funds and pranks, so this
    /// buys through it rather than restating the same swap.
    function buyForHandler(bool useA, uint256 amountIn) external {
        _swap(keyOf(useA), address(handler), true, amountIn);
    }

    /// @dev The launch token has no mint function, so unlike the curated base helper this sells
    /// only what the handler already bought.
    function sellForHandler(bool useA, uint256 amountIn) external {
        // Resolve the key before pranking: `keyOf` calls the launchpad, and an external call in
        // the argument list would consume the prank and credit the swap to this contract.
        PoolKey memory key = keyOf(useA);
        address token = tokenOf(useA);
        vm.prank(address(handler));
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        vm.prank(address(handler));
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -amountIn.toInt256(),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
    }

    function distributeBothForHandler(uint256 nativeGas) external {
        if (nativeGas == 0) {
            launchVault.distributeFees(tokenA);
            launchVault.distributeFees(tokenB);
        } else {
            launchVault.distributeFeesWithGas(tokenA, nativeGas);
            launchVault.distributeFeesWithGas(tokenB, nativeGas);
        }
        _assertLaunchVaultBacksItsLiabilities();
    }

    /// @dev Checked immediately after both positions are distributed, so no uncollected pool
    /// fees are folded into `pendingFees` and the reported claims are exactly the stored unpaid
    /// ones. What the launch vault holds must then be those claims plus the raw per-leg
    /// remainder, which the split carries forward and never lets reach five.
    ///
    /// This is the property that makes shared custody safe: liabilities are tracked per token
    /// while the native balance is pooled across every token, so one token's claims must never
    /// be payable out of another's funds.
    function _assertLaunchVaultBacksItsLiabilities() private view {
        uint256 unpaidCounter;
        address[2] memory tokens = [tokenA, tokenB];
        for (uint256 i; i < tokens.length; ++i) {
            (
                ILaunchFeeSource.FeeAmounts memory creator,,
                ILaunchFeeSource.FeeAmounts memory protocol
            ) = launchVault.pendingFees(tokens[i]);
            unpaidCounter += creator.counter + protocol.counter;

            uint256 targetHeld = IERC20(tokens[i]).balanceOf(address(launchVault));
            assertGe(targetHeld, creator.target, "target leg cannot cover its unpaid claim");
            assertLt(targetHeld - creator.target, 5, "target leg holds more than the raw remainder");
        }

        uint256 nativeHeld = address(launchVault).balance;
        assertGe(nativeHeld, unpaidCounter, "native leg cannot cover its unpaid claims");
        assertLt(
            nativeHeld - unpaidCounter,
            5 * tokens.length,
            "native leg holds more than the raw remainders"
        );
    }

    /// @dev The permanent position must never move: not its liquidity, not the range it was
    /// opened at, and not the on-chain position those two describe. A launch-terms change or a
    /// fee collection that moved any of them would orphan the liquidity and its fee claim.
    function invariantLaunchPositionsStayPinned() public view {
        _assertPositionPinned(true, creatorA, launchLiquidityA);
        _assertPositionPinned(false, creatorB, launchLiquidityB);
    }

    function _assertPositionPinned(bool useA, address creator, uint128 liquidityAtCreation)
        private
        view
    {
        (address recordedCreator, address recordedVault, uint128 liquidity, int24 pinnedTick) =
            launchVault.positions(tokenOf(useA));
        assertEq(recordedCreator, creator, "creator changed");
        assertEq(recordedVault, address(vaultOf(useA)), "lpTOKEN vault changed");
        assertEq(liquidity, liquidityAtCreation, "launch liquidity changed");
        assertEq(pinnedTick, LAUNCH_START_TICK, "pinned launch range moved");

        (int24 lower, int24 upper) = LaunchPoolConfig.launchTicks(pinnedTick);
        (uint128 onChain,,) = manager.getPositionInfo(
            keyOf(useA).toId(), address(launchVault), lower, upper, bytes32(0)
        );
        assertEq(onChain, liquidityAtCreation, "on-chain launch position diverged");
    }

    /// @dev The launch range ends at the start tick, so above it the position backs nothing even
    /// though its nominal liquidity is unchanged. Callers sizing the compound cap depend on
    /// exactly this, so it must hold at every reachable price.
    function invariantActiveLaunchLiquidityFollowsTheRange() public view {
        _assertActiveLiquidityFollowsRange(true);
        _assertActiveLiquidityFollowsRange(false);
    }

    function _assertActiveLiquidityFollowsRange(bool useA) private view {
        address token = tokenOf(useA);
        (,, uint128 liquidity, int24 pinnedTick) = launchVault.positions(token);
        (int24 lower, int24 upper) = LaunchPoolConfig.launchTicks(pinnedTick);
        (, int24 tick,,) = manager.getSlot0(keyOf(useA).toId());

        uint128 active = launchVault.activeLiquidity(token, address(vaultOf(useA)));
        if (tick >= lower && tick < upper) {
            assertEq(active, liquidity, "in-range launch position reported inactive");
        } else {
            assertEq(active, 0, "out-of-range launch position reported active");
        }
        assertEq(
            launchVault.activeLiquidity(token, address(vaultOf(!useA))),
            0,
            "launch position reported active for the other token's vault"
        );
    }

    /// @dev The compound cap is derived from protocol-owned liquidity that is live right now.
    /// Once the base exceeds what the pool actually has active, the fee-cost argument behind
    /// the cap no longer holds, so the clamp is load-bearing rather than defensive.
    function invariantCompoundBaseStaysWithinPoolActiveLiquidity() public view {
        assertLe(vaultA.compoundBase(), manager.getLiquidity(keyOf(true).toId()));
        assertLe(vaultB.compoundBase(), manager.getLiquidity(keyOf(false).toId()));
    }

    /// @dev Every entry point collects position fees unconditionally, and v4 rejects a
    /// zero-delta update on an empty position, so an emptied vault position would brick mint,
    /// redeem, and compound together. The dead shares are what keeps it non-empty.
    function invariantVaultPositionNeverEmpties() public view {
        assertGt(vaultA.positionLiquidity(), 0, "vault A position emptied");
        assertGt(vaultB.positionLiquidity(), 0, "vault B position emptied");
    }

    function invariantFullSupplyClaimsExactlyNetAssets() public view {
        _assertFullSupplyClaim(vaultA);
        _assertFullSupplyClaim(vaultB);
    }

    function _assertFullSupplyClaim(LpTokenVault vault) private view {
        (uint256 targetAssets, uint256 counterAssets) = vault.totalAssets();
        (uint256 targetClaim, uint256 counterClaim) = vault.claimForShares(vault.totalSupply());
        assertEq(targetClaim, targetAssets);
        assertEq(counterClaim, counterAssets);
    }

    function invariantDeadSharesPermanent() public view {
        _assertDeadSharesPermanent(vaultA);
        _assertDeadSharesPermanent(vaultB);
    }

    function _assertDeadSharesPermanent(LpTokenVault vault) private view {
        assertGe(
            vault.balanceOf(vault.DEAD_SHARE_RECEIVER()),
            vault.DEAD_SHARES(),
            "dead shares were reduced"
        );
        assertGe(vault.totalSupply(), vault.DEAD_SHARES());
    }
}
