// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { stdJson } from "forge-std/StdJson.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { Pool } from "@uniswap/v4-core/src/libraries/Pool.sol";
import { SqrtPriceMath } from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { LpTokenVault } from "../src/LpTokenVault.sol";
import { TokenLaunchpad } from "../src/TokenLaunchpad.sol";
import { LaunchPoolConfig } from "../src/libraries/LaunchPoolConfig.sol";
import { VaultRange } from "../src/libraries/VaultRange.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { LpTokenTestBase } from "./utils/LpTokenTestBase.sol";

/// @notice Adds a position paying whichever single leg it owes, settling straight against the
/// PoolManager. The canonical test router quotes both legs, so it cannot express the one-sided
/// position this attack uses.
contract OneSidedProvider is IUnlockCallback {
    IPoolManager private immutable _manager;

    constructor(IPoolManager manager_) {
        _manager = manager_;
    }

    receive() external payable { }

    function add(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        payable
        returns (uint256 paid0, uint256 paid1)
    {
        return abi.decode(
            _manager.unlock(abi.encode(key, tickLower, tickUpper, liquidity)), (uint256, uint256)
        );
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        (PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity) =
            abi.decode(raw, (PoolKey, int24, int24, uint128));
        (BalanceDelta delta,) = _manager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            bytes("")
        );
        return abi.encode(
            _settle(key.currency0, delta.amount0()), _settle(key.currency1, delta.amount1())
        );
    }

    function _settle(Currency currency, int128 amount) private returns (uint256 owed) {
        if (amount >= 0) return 0;
        owed = uint256(uint128(-amount));
        _manager.sync(currency);
        if (currency.isAddressZero()) {
            _manager.settle{ value: owed }();
        } else {
            IERC20(Currency.unwrap(currency)).transfer(address(_manager), owed);
            _manager.settle();
        }
    }
}

/// @notice Reaches the library through a call so a rejected pool can be observed as a revert.
contract VaultRangeHarness {
    function ticks(int24 tickSpacing, uint256 budget0, uint256 budget1)
        external
        pure
        returns (int24, int24)
    {
        return VaultRange.ticks(tickSpacing, budget0, budget1);
    }
}

/// @notice Uniswap V4 caps `liquidityGross` per tick and shares that cap across every position
/// using the tick as a boundary, so a vault that keeps adding liquidity at two fixed ticks can
/// be stopped by whoever fills them first. At the extreme usable ticks that costs dust, which is
/// why `VaultRange` places the boundaries where filling them costs more than the leg can supply.
contract VaultRangeTest is LpTokenTestBase {
    using StateLibrary for IPoolManager;
    using stdJson for string;

    /// @dev Shared with the web application's TypeScript port of this library.
    string internal constant FIXTURE_PATH = "test/fixtures/vault-range-cases.json";

    TokenLaunchpad private launchpad;
    OneSidedProvider private provider;
    VaultRangeHarness private harness;
    address private creator = makeAddr("range-creator");
    address private attacker = makeAddr("range-attacker");

    function setUp() public override {
        super.setUp();
        launchpad = _deployLaunchpad(manager, factory, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE);
        vm.prank(owner);
        factory.bindLaunchpad(address(launchpad));
        provider = new OneSidedProvider(manager);
        harness = new VaultRangeHarness();
        vm.deal(creator, 10 ether);
        vm.deal(attacker, 100 ether);
        vm.deal(address(provider), 100 ether);
    }

    // -------------------------------------------------------------------
    // The rule
    // -------------------------------------------------------------------

    /// The launch constants must stay the values the rule derives, since the launchpad sizes
    /// every bootstrap against them while the Factory pins the vault position from the rule.
    function testLaunchConstantsMatchTheRule() public view {
        (int24 lower, int24 upper) = LaunchPoolConfig.vaultTicks();
        (int24 ruleLower, int24 ruleUpper) = VaultRange.ticks(
            LaunchPoolConfig.TICK_SPACING,
            VaultRange.NATIVE_BUDGET,
            VaultRange.SUPPLY_MULTIPLE * LaunchPoolConfig.TOKEN_SUPPLY
        );
        assertEq(lower, ruleLower);
        assertEq(upper, ruleUpper);
        assertEq(
            uint256(TickMath.getSqrtPriceAtTick(lower)),
            uint256(LaunchPoolConfig.VAULT_SQRT_PRICE_LOWER)
        );
        assertEq(
            uint256(TickMath.getSqrtPriceAtTick(upper)),
            uint256(LaunchPoolConfig.VAULT_SQRT_PRICE_UPPER)
        );
    }

    /// The launch planner runs the same rule off-chain to size a curated seed, so a shared
    /// fixture pins what both must produce. Any drift between them would let an operator review
    /// one range while the Factory pins another.
    function testPortedRuleMatchesTheSharedFixture() public {
        string memory fixtureJson = vm.readFile(FIXTURE_PATH);
        int256[] memory spacings = fixtureJson.readIntArray(".tickSpacing");
        uint256[] memory budgets0 = fixtureJson.readUintArray(".budget0");
        uint256[] memory budgets1 = fixtureJson.readUintArray(".budget1");
        int256[] memory lowers = fixtureJson.readIntArray(".tickLower");
        int256[] memory uppers = fixtureJson.readIntArray(".tickUpper");
        assertEq(spacings.length, 9, "fixture case count changed");

        for (uint256 i; i < spacings.length; ++i) {
            (int24 lower, int24 upper) =
                VaultRange.ticks(int24(spacings[i]), budgets0[i], budgets1[i]);
            assertEq(int256(lower), lowers[i], "fixture lower");
            assertEq(int256(upper), uppers[i], "fixture upper");
        }

        int256[] memory rejectedSpacings = fixtureJson.readIntArray(".unprotectableTickSpacing");
        uint256[] memory rejected0 = fixtureJson.readUintArray(".unprotectableBudget0");
        uint256[] memory rejected1 = fixtureJson.readUintArray(".unprotectableBudget1");
        for (uint256 i; i < rejectedSpacings.length; ++i) {
            vm.expectPartialRevert(VaultRange.UnprotectablePool.selector);
            harness.ticks(int24(rejectedSpacings[i]), rejected0[i], rejected1[i]);
        }
    }

    /// Both boundaries are tick-spacing multiples inside the usable range, and each one costs
    /// at least its side's budget to saturate — the property everything else rests on. These
    /// budgets are all far from the usable ticks, so no boundary here is clamped.
    function testBoundariesCostTheirBudgetToSaturate() public pure {
        int24[3] memory spacings = [int24(10), int24(60), int24(200)];
        uint256[3] memory supplies = [uint256(1e15), 1e27, 1e33];
        for (uint256 i; i < spacings.length; ++i) {
            for (uint256 j; j < supplies.length; ++j) {
                int24 spacing = spacings[i];
                uint256 budget1 = VaultRange.SUPPLY_MULTIPLE * supplies[j];
                (int24 lower, int24 upper) =
                    VaultRange.ticks(spacing, VaultRange.NATIVE_BUDGET, budget1);

                assertEq(lower % spacing, 0);
                assertEq(upper % spacing, 0);
                assertGe(lower, TickMath.minUsableTick(spacing));
                assertLe(upper, TickMath.maxUsableTick(spacing));
                assertLt(lower, upper);
                assertGe(_saturationCost1(spacing, lower), budget1);
                assertGe(_saturationCost0(spacing, upper), VaultRange.NATIVE_BUDGET);
            }
        }
    }

    /// The same property over the whole input space rather than a sample. A boundary clamped to
    /// the usable tick is excluded: there is no tick further out to place it at, so its cost is
    /// whatever the extreme is worth, which is the case `UnprotectablePool` and the unminted-leg
    /// rule already describe.
    /// forge-config: default.fuzz.runs = 2000
    function testFuzzEveryPlacedBoundaryCostsItsBudget(
        uint256 budget0,
        uint256 budget1,
        uint8 spacingSeed
    ) public view {
        int24 spacing = int24(uint24(bound(spacingSeed, 1, 255)));
        budget0 = bound(budget0, 1, 1e40);
        budget1 = bound(budget1, 1, 1e40);

        (bool derived, int24 lower, int24 upper) = _tryTicks(spacing, budget0, budget1);
        if (!derived) return;
        if (lower > TickMath.minUsableTick(spacing)) {
            assertGe(_saturationCost1(spacing, lower), budget1, "lower is cheaper than its budget");
        }
        if (upper < TickMath.maxUsableTick(spacing)) {
            assertGe(_saturationCost0(spacing, upper), budget0, "upper is cheaper than its budget");
        }
    }

    /// The boundaries only move inward as far as the budgets demand: one spacing further out,
    /// saturation is already affordable. Without this the rule could pass by being arbitrarily
    /// narrow rather than by being exactly wide enough.
    function testBoundariesAreTheWidestThatSatisfyTheBudgets() public pure {
        int24 spacing = LaunchPoolConfig.TICK_SPACING;
        uint256 budget1 = VaultRange.SUPPLY_MULTIPLE * LaunchPoolConfig.TOKEN_SUPPLY;
        (int24 lower, int24 upper) = VaultRange.ticks(spacing, VaultRange.NATIVE_BUDGET, budget1);

        assertLt(_saturationCost1(spacing, lower - spacing), budget1);
        assertLt(_saturationCost0(spacing, upper + spacing), VaultRange.NATIVE_BUDGET);
    }

    /// A pool whose legs are both large enough that no placement prices out both boundaries
    /// cannot host a vault, and says so instead of reverting somewhere inside Uniswap.
    function testPoolWithNoProtectableRangeIsRejected() public {
        vm.expectRevert(
            abi.encodeWithSelector(VaultRange.UnprotectablePool.selector, 46_910, -46_910)
        );
        harness.ticks(10, 1e31, 1e31);
    }

    /// A leg nobody has minted yet bounds nothing, so its boundary stays at the usable tick
    /// rather than dividing by zero in a view a client may call before the token exists.
    function testLegWithoutSupplyKeepsTheUsableBoundary() public {
        MockERC20 unminted = new MockERC20("Unminted", "UNMINT", 18);
        PoolKey memory key = _nativeKey(address(unminted));

        assertEq(VaultRange.budget(Currency.wrap(address(unminted))), 1);
        (int24 lower,) = VaultRange.ticks(key);
        assertEq(lower, TickMath.minUsableTick(key.tickSpacing));
    }

    // -------------------------------------------------------------------
    // What the rule buys
    // -------------------------------------------------------------------

    /// Saturating a boundary tick of a launched vault is what the range exists to price out:
    /// at the usable ticks it costs dust, and at the vault's own boundaries it costs more than
    /// the whole token supply — while a third party may still provide liquidity anywhere.
    function testSaturatingTheVaultBoundariesCostsMoreThanTheSupplyOrTheChain() public {
        (address token,) = _launchToken(keccak256("saturation"));
        PoolKey memory key = launchpad.poolKey(token);
        LpTokenVault vault = LpTokenVault(payable(factory.vaultOfPoolId(key.toId())));
        (int24 lower, int24 upper) = vault.positionTicks();
        int24 spacing = key.tickSpacing;

        // Dust at the usable ticks, and the vault is untouched because it is not there.
        uint128 fill = Pool.tickSpacingToMaxLiquidityPerTick(spacing);
        vm.prank(attacker);
        (uint256 nativeAtUsable,) = provider.add(
            key, TickMath.maxUsableTick(spacing) - spacing, TickMath.maxUsableTick(spacing), fill
        );
        assertLt(nativeAtUsable, 0.0001 ether);
        assertGt(_mintInto(vault, token, 0.01 ether), 0);

        // The same fill at the vault's own boundary is unaffordable on either side.
        assertGt(_saturationCost0(spacing, upper), 1_000_000 ether);
        assertGt(_saturationCost1(spacing, lower), LaunchPoolConfig.TOKEN_SUPPLY);
    }

    /// The remaining reach of a saturated boundary: a third party can still stop a vault whose
    /// boundary they can afford, which is the whole reason the boundary is placed out of reach.
    function testASaturatedBoundaryStopsMintAndCompoundButNotRedeem() public {
        (address token,) = _launchToken(keccak256("saturated-boundary"));
        PoolKey memory key = launchpad.poolKey(token);
        LpTokenVault vault = LpTokenVault(payable(factory.vaultOfPoolId(key.toId())));
        (, int24 upper) = vault.positionTicks();
        uint256 shares = _mintInto(vault, token, 0.01 ether);
        assertGt(shares, 0);

        (uint128 gross,) = manager.getTickLiquidity(key.toId(), upper);
        vm.deal(address(provider), 1e30);
        vm.prank(attacker);
        (uint256 nativePaid,) = provider.add(
            key,
            upper,
            upper + key.tickSpacing,
            Pool.tickSpacingToMaxLiquidityPerTick(key.tickSpacing) - gross
        );
        assertGt(nativePaid, VaultRange.NATIVE_BUDGET);

        (uint256 quoted,,) = vault.previewMintPair(type(uint128).max, 1 ether);
        assertEq(quoted, 0);
        vm.warp(vault.compoundAvailableAt());
        vm.expectRevert(
            abi.encodeWithSelector(LpTokenVault.InsufficientLiquidityAdded.selector, 0, 1)
        );
        vault.compound(1, block.timestamp);

        vm.prank(creator);
        (uint256 targetOut, uint256 counterOut) =
            vault.redeem(shares, 0, 0, creator, block.timestamp);
        assertGt(targetOut, 0);
        assertGt(counterOut, 0);
    }

    /// The range is pinned when the vault bootstraps, so a leg minting afterwards cannot move
    /// the permanent position, and the address a client predicted stays the address deployed.
    function testRangeAndAddressSurviveASupplyChange() public {
        MockERC20 token = new MockERC20("Mintable", "MINT", 18);
        PoolKey memory key = _erc20Key(address(token), address(usdg));
        _initLivePool(key, 0);

        address predicted = factory.predictVault(address(token), key);
        LpTokenVault vault = _launch(address(token), key, 1_000e18, 1_000e6);
        (int24 lower, int24 upper) = vault.positionTicks();
        assertEq(address(vault), predicted);

        token.mint(address(this), 1e33);
        (int24 lowerAfter, int24 upperAfter) = vault.positionTicks();
        assertEq(lowerAfter, lower);
        assertEq(upperAfter, upper);
        assertEq(factory.predictVault(address(token), key), address(vault));
    }

    // -------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------

    /// @dev A pool with no protectable range is a valid outcome the fuzz run skips rather than
    /// a failure, and reaching the library through a call is what makes it observable.
    function _tryTicks(int24 spacing, uint256 budget0, uint256 budget1)
        private
        view
        returns (bool derived, int24 lower, int24 upper)
    {
        try harness.ticks(spacing, budget0, budget1) returns (int24 low, int24 high) {
            return (true, low, high);
        } catch {
            return (false, 0, 0);
        }
    }

    /// @dev Currency1 a tick-spacing-wide position below the price owes to fill `tick`'s cap.
    function _saturationCost1(int24 spacing, int24 tick) private pure returns (uint256) {
        return SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(tick - spacing),
            TickMath.getSqrtPriceAtTick(tick),
            Pool.tickSpacingToMaxLiquidityPerTick(spacing),
            false
        );
    }

    /// @dev Currency0 a tick-spacing-wide position above the price owes to fill `tick`'s cap.
    function _saturationCost0(int24 spacing, int24 tick) private pure returns (uint256) {
        return SqrtPriceMath.getAmount0Delta(
            TickMath.getSqrtPriceAtTick(tick),
            TickMath.getSqrtPriceAtTick(tick + spacing),
            Pool.tickSpacingToMaxLiquidityPerTick(spacing),
            false
        );
    }

    function _launchToken(bytes32 salt) private returns (address token, address vault) {
        vm.prank(creator);
        (token, vault,) = launchpad.createToken{ value: LAUNCH_INITIAL_LP_QUOTE }(
            TokenLaunchpad.TokenMetadata({
                name: "Range Cat",
                symbol: "RCAT",
                imageUrl: "ipfs://range",
                websiteUrl: "https://example.com",
                twitterHandle: "range_cat",
                telegramHandle: "range_cat"
            }),
            salt,
            0,
            0,
            LAUNCH_START_TICK,
            LAUNCH_INITIAL_LP_QUOTE,
            block.timestamp
        );
    }

    function _mintInto(LpTokenVault vault, address token, uint256 nativeAmount)
        private
        returns (uint256 shares)
    {
        PoolKey memory key = launchpad.poolKey(token);
        _swap(key, creator, true, nativeAmount);
        uint256 balance = IERC20(token).balanceOf(creator);
        vm.deal(creator, creator.balance + nativeAmount);
        vm.startPrank(creator);
        IERC20(token).approve(address(vault), balance);
        (shares,,) = vault.mintPair{ value: nativeAmount }(
            balance, nativeAmount, 1, creator, block.timestamp
        );
        vm.stopPrank();
    }
}
