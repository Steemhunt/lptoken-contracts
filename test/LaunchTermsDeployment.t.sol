// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { FixedPoint96 } from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { DeployLpToken } from "../script/DeployLpToken.s.sol";
import { LaunchLiquidityVault } from "../src/LaunchLiquidityVault.sol";
import { ILaunchFeeSource } from "../src/interfaces/ILaunchFeeSource.sol";
import { LaunchPoolConfig } from "../src/libraries/LaunchPoolConfig.sol";
import { LpTokenFactory } from "../src/LpTokenFactory.sol";
import { LpTokenVault } from "../src/LpTokenVault.sol";
import { TokenLaunchpad } from "../src/TokenLaunchpad.sol";

import { LpTokenTestBase } from "./utils/LpTokenTestBase.sol";

contract DeployLpTokenHarness is DeployLpToken {
    function readLaunchStartTick(string memory config) external pure returns (int24) {
        return _readLaunchStartTick(config);
    }
}

/// @notice The start tick and bootstrap quote are native-denominated economics, so they are
/// seeded as deployment parameters and owner-updatable for future launches. A chain whose native
/// currency is worth much more or much less than ETH uses the same bytecode with different terms.
contract LaunchTermsDeploymentTest is LpTokenTestBase {
    using stdJson for string;
    using StateLibrary for IPoolManager;

    function _deployPlatform(int24 startTick, uint256 initialLpQuote)
        private
        returns (LpTokenFactory localFactory, TokenLaunchpad launchpad)
    {
        localFactory = new LpTokenFactory(manager, treasury, owner);
        launchpad = _deployLaunchpad(manager, localFactory, startTick, initialLpQuote);
        vm.prank(owner);
        localFactory.bindLaunchpad(address(launchpad));
    }

    function _create(TokenLaunchpad launchpad, address creator, bytes32 salt)
        private
        returns (address token, address vault)
    {
        uint256 value = launchpad.initialLpQuote();
        int24 expectedStartTick = launchpad.startTick();
        vm.deal(creator, value);
        vm.prank(creator);
        (token, vault,) = launchpad.createToken{ value: value }(
            TokenLaunchpad.TokenMetadata("Terms Cat", "TCAT", "", "", "", ""),
            salt,
            0,
            TickMath.MIN_SQRT_PRICE + 1,
            expectedStartTick,
            value,
            block.timestamp
        );
    }

    /// @dev A deployment with a different native denomination completes a real launch and
    /// lands at exactly the tick it was configured for, using unchanged bytecode.
    function testAlternativeNativeTermsLaunchEndToEnd() public {
        // A chain whose native unit is worth far less than ETH: cheaper token in native
        // terms, so a lower start tick, and a proportionally larger bootstrap quote.
        int24 startTick = 120_000;
        uint256 initialLpQuote = 5 ether;
        (LpTokenFactory localFactory, TokenLaunchpad launchpad) =
            _deployPlatform(startTick, initialLpQuote);

        assertEq(launchpad.startTick(), startTick);
        assertEq(launchpad.initialLpQuote(), initialLpQuote);
        assertGt(launchpad.bootstrapTargetAmount(), 0);
        assertLt(launchpad.bootstrapTargetAmount(), launchpad.TOKEN_SUPPLY());

        (address token, address vaultAddress) = _create(launchpad, alice, keccak256("alt terms"));
        LpTokenVault vault = LpTokenVault(payable(vaultAddress));
        PoolKey memory key = launchpad.poolKey(token);

        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(key.toId());
        assertEq(tick, startTick, "pool did not initialize at the configured tick");
        assertEq(sqrtPriceX96, launchpad.initialSqrtPriceX96());
        assertEq(localFactory.vaultOfPoolId(key.toId()), vaultAddress);
        assertEq(vault.totalSupply(), vault.balanceOf(vault.DEAD_SHARE_RECEIVER()));

        // The permanent launch range tracks the configured tick, not a compiled-in one.
        (, int24 launchLower, int24 launchUpper) = launchpad.poolTicks();
        assertEq(launchUpper, startTick);
        assertEq(launchLower, TickMath.minUsableTick(launchpad.TICK_SPACING()));
        (,, uint128 launchLiquidity,) = launchpad.liquidityVault().positions(token);
        assertGt(launchLiquidity, 0);

        // And the market is live: a buy moves into the launch range and accrues fees.
        address trader = makeAddr("alt trader");
        _buyNative(key, trader, 1 ether);
        (, int24 tickAfter,,) = manager.getSlot0(key.toId());
        assertLt(tickAfter, startTick);
        launchpad.liquidityVault().distributeFees(token);
        (uint256 navTarget, uint256 navCounter) = vault.totalAssets();
        assertTrue(navTarget > 0 || navCounter > 0);
    }

    /// @dev Two deployments with different terms coexist on the same PoolManager and neither
    /// borrows the other's economics.
    function testDeploymentsWithDifferentTermsAreIndependent() public {
        (, TokenLaunchpad cheap) = _deployPlatform(120_000, 5 ether);
        (, TokenLaunchpad rich) = _deployPlatform(198_000, 0.001 ether);

        assertEq(cheap.startTick(), 120_000);
        assertEq(rich.startTick(), 198_000);
        assertTrue(cheap.bootstrapTargetAmount() != rich.bootstrapTargetAmount());
        assertTrue(cheap.initialFdvNative() != rich.initialFdvNative());

        (address cheapToken,) = _create(cheap, alice, keccak256("cheap"));
        (address richToken,) = _create(rich, bob, keccak256("rich"));

        (, int24 cheapTick,,) = manager.getSlot0(cheap.poolKey(cheapToken).toId());
        (, int24 richTick,,) = manager.getSlot0(rich.poolKey(richToken).toId());
        assertEq(cheapTick, 120_000);
        assertEq(richTick, 198_000);
    }

    /// @dev The canonical Robinhood terms still produce exactly the values that were
    /// previously compiled in, so this refactor changes no live economics.
    function testCanonicalTermsMatchThePreviousConstants() public {
        (, TokenLaunchpad launchpad) = _deployPlatform(198_000, 0.001 ether);

        assertEq(launchpad.startTick(), 198_000);
        assertEq(launchpad.initialLpQuote(), 0.001 ether);
        assertEq(launchpad.initialSqrtPriceX96(), TickMath.getSqrtPriceAtTick(198_000));
        // 2.5 ETH FDV, as the previous INITIAL_FDV_NATIVE constant asserted.
        assertApproxEqRel(launchpad.initialFdvNative(), 2.5 ether, 0.01e18);
    }

    /// @dev Terms that cannot produce a viable launch are rejected at deployment, where the
    /// operator sees them, rather than at the first creator's transaction.
    function testInvalidTermsAreRejectedAtDeployment() public {
        LpTokenFactory localFactory = new LpTokenFactory(manager, treasury, owner);

        vm.expectRevert(TokenLaunchpad.InvalidLaunchTerms.selector);
        _deployLaunchpad(manager, localFactory, 198_001, 0.001 ether);

        vm.expectRevert(TokenLaunchpad.InvalidLaunchTerms.selector);
        _deployLaunchpad(manager, localFactory, 198_000, 0);

        int24 maximumTick = TickMath.maxUsableTick(200);
        vm.expectRevert(TokenLaunchpad.InvalidLaunchTerms.selector);
        _deployLaunchpad(manager, localFactory, maximumTick, 0.001 ether);

        // A quote so large that the matched target exceeds the fixed supply cannot launch.
        vm.expectRevert(TokenLaunchpad.InvalidLaunchTerms.selector);
        _deployLaunchpad(manager, localFactory, 198_000, 1_000_000 ether);

        // Near the vault's upper boundary, a large quote implies liquidity beyond `uint128`.
        // That is the same invalid-terms rejection, not a `SafeCastOverflow` — or, further
        // out, a bare `FullMath` revert — escaping the liquidity math. The tick itself still
        // matches every quote up to the exact representability boundary.
        int24 overflowTick = 393_600;
        uint256 overflowQuote = 1e29;
        uint160 overflowSqrtPrice = TickMath.getSqrtPriceAtTick(overflowTick);
        uint256 maximumQuote = FullMath.mulDivRoundingUp(
            uint256(type(uint128).max) + 1,
            LaunchPoolConfig.VAULT_SQRT_PRICE_UPPER - overflowSqrtPrice,
            FullMath.mulDiv(
                overflowSqrtPrice, LaunchPoolConfig.VAULT_SQRT_PRICE_UPPER, FixedPoint96.Q96
            )
        ) - 1;
        assertGt(LaunchPoolConfig.bootstrapTargetAmount(overflowTick, 0.001 ether), 0);
        assertGt(LaunchPoolConfig.bootstrapTargetAmount(overflowTick, maximumQuote), 0);
        assertEq(LaunchPoolConfig.bootstrapTargetAmount(overflowTick, maximumQuote + 1), 0);
        assertEq(LaunchPoolConfig.bootstrapTargetAmount(overflowTick, overflowQuote), 0);
        assertEq(LaunchPoolConfig.bootstrapTargetAmount(overflowTick, type(uint256).max), 0);
        vm.expectRevert(TokenLaunchpad.InvalidLaunchTerms.selector);
        _deployLaunchpad(manager, localFactory, overflowTick, overflowQuote);
        vm.expectRevert(TokenLaunchpad.InvalidLaunchTerms.selector);
        _deployLaunchpad(manager, localFactory, overflowTick, type(uint256).max);

        // A nonzero token residual can still round down to zero launch liquidity.
        int24 zeroLiquidityTick = 200;
        uint256 zeroLiquidityQuote = 980_225_339_904_033_380_318_888_671;
        uint256 residual = LaunchPoolConfig.TOKEN_SUPPLY
            - LaunchPoolConfig.bootstrapTargetAmount(zeroLiquidityTick, zeroLiquidityQuote);
        assertEq(residual, 1);
        assertEq(LaunchPoolConfig.launchLiquidity(zeroLiquidityTick, residual), 0);
        vm.expectRevert(TokenLaunchpad.InvalidLaunchTerms.selector);
        _deployLaunchpad(manager, localFactory, zeroLiquidityTick, zeroLiquidityQuote);

        // And a seed that clears every check above can still fall short of the vault's
        // dead-share floor, which `bootstrap` requires the whole seed to exceed.
        (int24 thinTick, uint256 thinQuote) = _thinSeedTerms();
        vm.expectRevert(TokenLaunchpad.InvalidLaunchTerms.selector);
        _deployLaunchpad(manager, localFactory, thinTick, thinQuote);
    }

    /// @dev Pins the terms used above as genuinely reachable: viable by every other rule, and
    /// unviable only because the seed does not clear `DEAD_SHARES`. Without that assertion the
    /// revert could come from any of the earlier checks and prove nothing about this one.
    function _thinSeedTerms() private returns (int24 startTick, uint256 initialLpQuote) {
        startTick = -210_000;
        initialLpQuote = 1e10;

        assertEq(startTick % 200, 0, "tick is not spacing-aligned");
        (int24 minimumTick, int24 maximumTick) = LaunchPoolConfig.vaultTicks();
        assertGt(startTick, minimumTick);
        assertLt(startTick, maximumTick);

        uint256 target = LaunchPoolConfig.bootstrapTargetAmount(startTick, initialLpQuote);
        assertGt(target, 0, "matched target is zero");
        assertLt(target, LaunchPoolConfig.TOKEN_SUPPLY, "matched target consumes the supply");
        assertGt(
            LaunchPoolConfig.launchLiquidity(startTick, LaunchPoolConfig.TOKEN_SUPPLY - target),
            0,
            "residual leaves no launch liquidity"
        );

        uint256 seed = LaunchPoolConfig.bootstrapLiquidity(startTick, initialLpQuote, target);
        assertGt(seed, 0, "seed is zero, so this proves the wrong rule");
        uint256 deadShareFloor = LpTokenVault(payable(factory.vaultImplementation())).DEAD_SHARES();
        assertLe(seed, deadShareFloor, "seed already clears the dead-share floor");
    }

    /// @dev The deployment config must actually parse into the constructor arguments. This
    /// is an offline check because a malformed `launchTerms` block would otherwise only
    /// surface during a live broadcast.
    function testDeploymentConfigParsesIntoValidTerms() public {
        DeployLpTokenHarness deployer = new DeployLpTokenHarness();
        string[3] memory paths = [
            "config/robinhood-mainnet.json",
            "config/base-mainnet.json",
            "test/fixtures/robinhood-fork-deployment.json"
        ];
        for (uint256 i; i < paths.length; ++i) {
            string memory config = vm.readFile(paths[i]);
            int24 startTick = deployer.readLaunchStartTick(config);
            uint256 initialLpQuote =
                vm.parseUint(config.readString(".launchTerms.initialLpQuoteWei"));

            LpTokenFactory localFactory = new LpTokenFactory(manager, treasury, owner);
            TokenLaunchpad launchpad =
                _deployLaunchpad(manager, localFactory, startTick, initialLpQuote);
            assertEq(launchpad.startTick(), startTick);
            assertEq(launchpad.initialLpQuote(), initialLpQuote);
            assertGt(launchpad.bootstrapTargetAmount(), 0);
        }
    }

    /// @dev The tokens hand a hardcoded Permit2 unlimited `transferFrom`, so a config naming a
    /// different address would pin reviewed code for something nothing trusts, and the
    /// deployment's own check would then fail on live state rather than here.
    function testDeploymentConfigNamesThePermit2TheTokensTrust() public {
        LpTokenFactory localFactory = new LpTokenFactory(manager, treasury, owner);
        address trusted = LpTokenVault(payable(localFactory.vaultImplementation())).PERMIT2();

        string[3] memory paths = [
            "config/robinhood-mainnet.json",
            "config/base-mainnet.json",
            "test/fixtures/robinhood-fork-deployment.json"
        ];
        for (uint256 i; i < paths.length; ++i) {
            string memory config = vm.readFile(paths[i]);
            assertEq(config.readAddress(".addresses.permit2"), trusted, paths[i]);
            assertTrue(config.readBytes32(".runtimeCodeHashes.permit2") != bytes32(0), paths[i]);
        }
    }

    function testDeploymentConfigRejectsOutOfRangeStartTick() public {
        DeployLpTokenHarness deployer = new DeployLpTokenHarness();
        int256 aboveMaximum = int256(type(int24).max) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeCast.SafeCastOverflowedIntDowncast.selector, 24, aboveMaximum
            )
        );
        deployer.readLaunchStartTick('{"launchTerms":{"startTick":8388608}}');

        int256 belowMinimum = int256(type(int24).min) - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeCast.SafeCastOverflowedIntDowncast.selector, 24, belowMinimum
            )
        );
        deployer.readLaunchStartTick('{"launchTerms":{"startTick":-8388609}}');
    }

    function testLaunchRevertsWhenOwnerChangesCommittedTerms() public {
        (, TokenLaunchpad launchpad) = _deployPlatform(198_000, 0.001 ether);
        int24 expectedStartTick = launchpad.startTick();
        uint256 expectedInitialLpQuote = launchpad.initialLpQuote();

        vm.prank(owner);
        launchpad.setLaunchTerms(120_000, 5 ether);

        vm.deal(alice, 5 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenLaunchpad.LaunchTermsChanged.selector,
                expectedStartTick,
                int24(120_000),
                expectedInitialLpQuote,
                5 ether
            )
        );
        launchpad.createToken{ value: 5 ether }(
            TokenLaunchpad.TokenMetadata("Committed Cat", "CCAT", "", "", "", ""),
            keccak256("stale launch terms"),
            0,
            0,
            expectedStartTick,
            expectedInitialLpQuote,
            block.timestamp
        );

        assertEq(launchpad.getTokenCount(), 0);
        assertEq(address(launchpad).balance, 0);
    }

    /// @dev The whole premise of making the terms mutable: they govern what launches next and
    /// reach nothing already launched. A token created under the old terms must keep its
    /// price, its permanent launch range, and — critically — a working fee claim, because
    /// `LaunchLiquidityVault` reads each position at the range it was opened at.
    function testUpdatingTermsLeavesExistingLaunchesIntact() public {
        (LpTokenFactory localFactory, TokenLaunchpad launchpad) =
            _deployPlatform(198_000, 0.001 ether);
        LaunchLiquidityVault launchVault = launchpad.liquidityVault();

        (address oldToken, address oldVaultAddress) =
            _create(launchpad, alice, keccak256("before terms change"));
        LpTokenVault oldVault = LpTokenVault(payable(oldVaultAddress));
        PoolKey memory oldKey = launchpad.poolKey(oldToken);
        (,, uint128 oldLiquidity, int24 oldPinnedTick) = launchVault.positions(oldToken);
        assertEq(oldPinnedTick, 198_000);

        // Trade so the old token has real fees outstanding across the change.
        _swap(oldKey, makeAddr("old trader"), true, 3 ether);

        vm.prank(owner);
        launchpad.setLaunchTerms(120_000, 5 ether);
        assertEq(launchpad.startTick(), 120_000);
        assertEq(launchpad.initialLpQuote(), 5 ether);

        // The existing position is untouched: same pinned range, same liquidity.
        (,, uint128 liquidityAfter, int24 pinnedAfter) = launchVault.positions(oldToken);
        assertEq(pinnedAfter, oldPinnedTick, "an existing position's range moved");
        assertEq(liquidityAfter, oldLiquidity);
        (, int24 tickAfter,,) = manager.getSlot0(oldKey.toId());
        assertLt(tickAfter, int24(198_000));

        // And its fees are still reachable. `totalAssets` already counts them while pending,
        // so the proof is that the position still reports them and that distributing actually
        // delivers them into the vault's idle balances.
        (, ILaunchFeeSource.FeeAmounts memory pendingNav,) = launchVault.pendingFees(oldToken);
        assertTrue(
            pendingNav.target > 0 || pendingNav.counter > 0,
            "existing position reported no fees after a terms change"
        );
        (uint256 idleTargetBefore, uint256 idleCounterBefore) = oldVault.idleBalances();
        launchVault.distributeFees(oldToken);
        (uint256 idleTargetAfter, uint256 idleCounterAfter) = oldVault.idleBalances();
        assertTrue(
            idleTargetAfter > idleTargetBefore || idleCounterAfter > idleCounterBefore,
            "existing launch fees became unreachable after a terms change"
        );

        // A new launch uses the new terms, at its own price, without disturbing the old one.
        (address newToken, address newVault) =
            _create(launchpad, bob, keccak256("after terms change"));
        (,,, int24 newPinnedTick) = launchVault.positions(newToken);
        assertEq(newPinnedTick, 120_000);
        (, int24 newTick,,) = manager.getSlot0(launchpad.poolKey(newToken).toId());
        assertEq(newTick, 120_000);
        assertEq(localFactory.vaultOfPoolId(launchpad.poolKey(newToken).toId()), newVault);
    }

    /// @dev Only the Factory owner may move the terms, and invalid terms are rejected on
    /// update exactly as they are at deployment.
    function testOnlyFactoryOwnerMovesTermsAndInvalidOnesAreRejected() public {
        (, TokenLaunchpad launchpad) = _deployPlatform(198_000, 0.001 ether);

        vm.expectRevert(TokenLaunchpad.OnlyFactoryOwner.selector);
        vm.prank(alice);
        launchpad.setLaunchTerms(120_000, 5 ether);

        vm.prank(owner);
        vm.expectRevert(TokenLaunchpad.InvalidLaunchTerms.selector);
        launchpad.setLaunchTerms(120_001, 5 ether);

        vm.prank(owner);
        vm.expectRevert(TokenLaunchpad.InvalidLaunchTerms.selector);
        launchpad.setLaunchTerms(120_000, 0);

        // The setter shares the constructor's validation path, so a seed below the dead-share
        // floor cannot be introduced by an update either. This is the case that would
        // otherwise leave a live launchpad rejecting every creator.
        (int24 thinTick, uint256 thinQuote) = _thinSeedTerms();
        vm.prank(owner);
        vm.expectRevert(TokenLaunchpad.InvalidLaunchTerms.selector);
        launchpad.setLaunchTerms(thinTick, thinQuote);

        // Terms unchanged after every rejected attempt.
        assertEq(launchpad.startTick(), 198_000);
        assertEq(launchpad.initialLpQuote(), 0.001 ether);
    }

    function _buyNative(PoolKey memory key, address who, uint256 amountIn) private {
        _swap(key, who, true, amountIn);
    }
}
