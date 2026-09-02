// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import { LaunchLiquidityVault } from "../src/LaunchLiquidityVault.sol";
import { LpTokenVault } from "../src/LpTokenVault.sol";
import { TokenLaunchpad } from "../src/TokenLaunchpad.sol";
import { LpTokenTestBase } from "./utils/LpTokenTestBase.sol";

/// @notice Replays 43 days of real Robinhood-chain memecoin volume through a platform
/// launch to see whether compound absorbs launch-fee inflow, and at which calling cadence.
///
/// Volume comes from the CASHCAT/WETH main pool series (GeckoTerminal hourly OHLCV, pool
/// 0xa70fc67c9f69da90b63a0e4c05d229954574e313, fetched 2026-08-12). Each entry below is
/// that day's pool volume as parts-per-million of the pool's marked TVL, which is the
/// scale-free form: both fee inflow and the compound cap scale with liquidity, so only
/// volume relative to depth matters. Over the window it totals 151x TVL traded, averaging
/// 3.5x per day and peaking at 29.5x on the launch-pump day.
contract CompoundThroughputSimTest is LpTokenTestBase {
    using StateLibrary for IPoolManager;

    uint32[43] internal DAILY_VOLUME_PPM = [
        uint32(1_020_907),
        605_867,
        308_531,
        241_982,
        233_729,
        268_331,
        685_423,
        29_483_269,
        8_644_140,
        9_658_476,
        7_537_669,
        7_289_759,
        4_920_148,
        7_793_682,
        9_201_051,
        9_586_719,
        6_671_450,
        1_654_502,
        1_555_097,
        1_281_959,
        1_286_244,
        1_187_432,
        1_662_185,
        795_550,
        346_491,
        731_111,
        1_159_819,
        1_418_175,
        4_498_292,
        1_506_582,
        638_165,
        286_729,
        273_289,
        1_753_489,
        2_018_949,
        4_199_601,
        12_602_361,
        1_488_058,
        1_229_700,
        1_785_330,
        1_207_477,
        594_995,
        195_470
    ];

    /// Round trips per simulated day, so each day's volume moves the price and comes back
    /// rather than trending in one direction forever.
    uint256 internal constant SWAPS_PER_DAY = 4;

    TokenLaunchpad internal launchpad;
    LaunchLiquidityVault internal launchVault;
    address internal token;
    LpTokenVault internal vault;
    PoolKey internal key;
    address internal trader = makeAddr("trader");

    function setUp() public override {
        super.setUp();
        launchpad = _deployLaunchpad(manager, factory, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE);
        launchVault = launchpad.liquidityVault();
        vm.prank(owner);
        factory.bindLaunchpad(address(launchpad));

        TokenLaunchpad.TokenMetadata memory metadata = TokenLaunchpad.TokenMetadata({
            name: "Sim Cat",
            symbol: "SCAT",
            imageUrl: "ipfs://sim",
            websiteUrl: "https://example.com",
            twitterHandle: "sim_cat",
            telegramHandle: "sim_cat_chat"
        });
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        address vaultAddress;
        (token, vaultAddress,) = launchpad.createToken{ value: 0.02 ether }(
            metadata,
            keccak256("sim"),
            0,
            0,
            LAUNCH_START_TICK,
            LAUNCH_INITIAL_LP_QUOTE,
            block.timestamp
        );
        vault = LpTokenVault(payable(vaultAddress));
        key = launchpad.poolKey(token);
    }

    /// Pool depth marked in the counter currency, used to scale each day's volume.
    function _poolCounterDepth() private view returns (uint256) {
        return address(manager).balance;
    }

    function _buy(uint256 ethIn) private {
        if (ethIn == 0) return;
        vm.deal(trader, trader.balance + ethIn);
        vm.prank(trader);
        swapRouter.swap{ value: ethIn }(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
    }

    function _sell(uint256 tokenIn) private {
        if (tokenIn == 0) return;
        vm.startPrank(trader);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(tokenIn),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
        vm.stopPrank();
    }

    uint256 internal deployed;
    uint256 internal successes;
    uint256 internal failures;
    uint256 internal idleShareBps;
    uint256 internal cooldownFailures;
    uint256 internal dryFailures;

    /// @param callsPerDay how often anyone bothers to call compound. 144 is the cooldown
    /// limit of one call every 10 minutes.
    function _simulateDay(uint256 dayIndex, uint256 callsPerDay) private {
        uint256 perSwap =
            (_poolCounterDepth() * DAILY_VOLUME_PPM[dayIndex]) / 1_000_000 / (SWAPS_PER_DAY * 2);
        uint256 callsDone;

        for (uint256 slice; slice < SWAPS_PER_DAY; ++slice) {
            _buy(perSwap);
            _sell(IERC20(token).balanceOf(trader));
            vm.warp(vm.getBlockTimestamp() + (1 days / SWAPS_PER_DAY));

            uint256 target = (callsPerDay * (slice + 1)) / SWAPS_PER_DAY;
            while (callsDone < target) {
                callsDone += 1;
                vm.warp(vm.getBlockTimestamp() + 10 minutes);
                try vault.compound(1, vm.getBlockTimestamp()) returns (uint128 added) {
                    deployed += added;
                    successes += 1;
                } catch (bytes memory reason) {
                    failures += 1;
                    if (bytes4(reason) == LpTokenVault.CompoundCooldown.selector) {
                        cooldownFailures += 1;
                    } else if (bytes4(reason) == LpTokenVault.InsufficientLiquidityAdded.selector) {
                        dryFailures += 1;
                    }
                }
            }
        }
    }

    function _run(uint256 callsPerDay) private {
        deployed = 0;
        successes = 0;
        failures = 0;
        cooldownFailures = 0;
        dryFailures = 0;
        for (uint256 day; day < DAILY_VOLUME_PPM.length; ++day) {
            _simulateDay(day, callsPerDay);
        }

        // Fold in whatever is still owed before measuring.
        launchVault.distributeFees(token);
        (uint256 idleTarget, uint256 idleCounter) = vault.idleBalances();
        (uint256 totalTarget, uint256 totalCounter) = vault.totalAssets();
        // Mark both legs in the counter currency at the final price so the shares compare.
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        uint256 priceQ96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 96;
        uint256 idleValue = idleCounter + ((idleTarget * priceQ96) >> 96);
        uint256 totalValue = totalCounter + ((totalTarget * priceQ96) >> 96);
        idleShareBps = totalValue == 0 ? 0 : (idleValue * 10_000) / totalValue;
    }

    function _report(string memory label, uint256 callsPerDay) private {
        uint256 snap = vm.snapshotState();
        _run(callsPerDay);
        (uint256 idleTarget, uint256 idleCounter) = vault.idleBalances();
        (,, uint128 available, uint128 cap, uint128 executable,) = vault.previewCompound();

        emit log_string(label);
        emit log_named_uint("  idle share of NAV (bps)", idleShareBps);
        emit log_named_uint("  compound calls that deployed", successes);
        emit log_named_uint("  compound calls that reverted", failures);
        emit log_named_uint("    of which cooldown", cooldownFailures);
        emit log_named_uint("    of which nothing to deploy", dryFailures);
        emit log_named_uint("  liquidity deployed in total", deployed);
        emit log_named_uint("  final vault position liquidity", vault.positionLiquidity());
        emit log_named_uint("  idle target", idleTarget);
        emit log_named_uint("  idle counter", idleCounter);
        // Which constraint actually binds at the end of the window.
        emit log_named_uint("  matched liquidity available", available);
        emit log_named_uint("  compound cap", cap);
        emit log_named_uint("  executable now", executable);
        vm.revertToState(snap);
    }

    function _launchLiquidity() private view returns (uint128 liquidity) {
        (,, liquidity,) = launchVault.positions(token);
    }

    function testThroughputByCallingCadence() public {
        emit log_named_uint("bootstrap position liquidity", vault.positionLiquidity());
        emit log_named_uint("launch position liquidity", _launchLiquidity());
        _report("never compounded", 0);
        _report("once per day", 1);
        _report("every 6 hours", 4);
        _report("hourly", 24);
        _report("every 10 minutes (cooldown limit)", 144);
    }

    /// Calling compound more often stops helping well below the cooldown limit, because
    /// the cap is not what binds.
    function testCadenceSaturatesFarBelowTheCooldownLimit() public {
        uint256 snap = vm.snapshotState();
        _run(4);
        uint256 sixHourlyDeployed = deployed;
        uint256 sixHourlyFailures = failures;
        vm.revertToState(snap);

        snap = vm.snapshotState();
        _run(144);
        uint256 tenMinutelyDeployed = deployed;
        uint256 tenMinutelyFailures = failures;
        vm.revertToState(snap);

        assertEq(tenMinutelyDeployed, sixHourlyDeployed, "extra calls deployed extra liquidity");
        assertGt(tenMinutelyFailures, sixHourlyFailures, "extra calls should find nothing");
    }

    /// The cap set in `compoundBase` never binds under real volume: what runs out is the
    /// counter leg. Launch fees give the vault 60% of the target side but only 20% of the
    /// counter side, so the pairing that compound needs is starved long before the cap.
    function testCounterLegIsTheBindingConstraintNotTheCap() public {
        _run(144);
        // _run ends with a distributeFees, so drain whatever that just credited before
        // reading the steady state.
        vm.warp(uint256(vault.compoundAvailableAt()));
        try vault.compound(1, vm.getBlockTimestamp()) { } catch { }

        (uint256 idleTarget, uint256 idleCounter) = vault.idleBalances();
        (,, uint128 available, uint128 cap,,) = vault.previewCompound();

        assertEq(available, 0, "matched liquidity remained");
        assertLt(available, cap, "the cap was the binding constraint");
        assertGt(idleTarget, 0, "target idle was fully deployable");
        // The stranded target leg dwarfs anything the counter leg could pair with.
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        uint256 priceQ96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 96;
        uint256 strandedValue = (idleTarget * priceQ96) >> 96;
        assertGt(strandedValue, idleCounter * 100, "target surplus is not structural");
        emit log_named_uint("stranded target value in counter terms", strandedValue);
        emit log_named_uint("idle counter left", idleCounter);

        // Supplying the missing counter leg is what unlocks the rest, not a larger cap.
        vm.deal(address(vault), 100 ether);
        (,, uint128 availableAfter,,,) = vault.previewCompound();
        assertGt(availableAfter, 0, "counter leg was not the constraint");
        emit log_named_uint("matched liquidity unlocked by counter top-up", availableAfter);
        emit log_named_uint("compound cap", cap);
    }
}
