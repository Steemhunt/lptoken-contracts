// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import { LaunchLiquidityVault } from "../src/LaunchLiquidityVault.sol";
import { LpTokenVault } from "../src/LpTokenVault.sol";
import { TokenLaunchpad } from "../src/TokenLaunchpad.sol";
import { ILaunchFeeSource } from "../src/interfaces/ILaunchFeeSource.sol";
import { LpTokenTestBase } from "./utils/LpTokenTestBase.sol";

/// @notice Launch creator that runs a permissionless `PoolManager.sync` inside its launch-fee
/// payout callback, and can optionally burn storage gas to model an expensive smart wallet.
contract HostileCreator {
    IPoolManager public immutable poolManager;
    address public immutable poison;
    uint256 public immutable coldWrites;
    bool public poisonArmed;
    bool public handoverArmed;
    LaunchLiquidityVault public handoverVault;
    address public handoverToken;
    address public handoverRecipient;
    uint256 public payouts;
    mapping(uint256 => uint256) private _slots;

    constructor(IPoolManager poolManager_, address poison_, uint256 coldWrites_) {
        poolManager = poolManager_;
        poison = poison_;
        coldWrites = coldWrites_;
    }

    function armPoison(bool value) external {
        poisonArmed = value;
    }

    function armHandover(LaunchLiquidityVault launchVault, address token, address newCreator)
        external
    {
        handoverVault = launchVault;
        handoverToken = token;
        handoverRecipient = newCreator;
        handoverArmed = true;
    }

    function transferCreator(LaunchLiquidityVault launchVault, address token, address newCreator)
        external
    {
        launchVault.transferCreator(token, newCreator);
    }

    function createToken(
        TokenLaunchpad launchpad,
        TokenLaunchpad.TokenMetadata calldata metadata,
        bytes32 salt
    ) external payable returns (address token, address vault, uint256 targetOut) {
        return launchpad.createToken{ value: msg.value }(
            metadata,
            salt,
            0,
            TickMath.MIN_SQRT_PRICE + 1,
            launchpad.startTick(),
            launchpad.initialLpQuote(),
            block.timestamp
        );
    }

    receive() external payable {
        if (poisonArmed) poolManager.sync(Currency.wrap(poison));
        if (handoverArmed) {
            handoverArmed = false;
            handoverVault.transferCreator(handoverToken, handoverRecipient);
        }
        for (uint256 i; i < coldWrites; ++i) {
            _slots[i] = block.number + i + 1;
        }
        // Written last so a stipend-exhausting wallet records nothing, exactly like a
        // real wallet whose bookkeeping reverts.
        payouts += 1;
    }
}

contract LaunchFeePayoutHardeningTest is LpTokenTestBase {
    TokenLaunchpad internal launchpad;
    LaunchLiquidityVault internal launchVault;

    function setUp() public override {
        super.setUp();
        launchpad = _deployLaunchpad(manager, factory, LAUNCH_START_TICK, LAUNCH_INITIAL_LP_QUOTE);
        launchVault = launchpad.liquidityVault();
        vm.prank(owner);
        factory.bindLaunchpad(address(launchpad));
    }

    function _launch(HostileCreator creator, bytes32 salt)
        private
        returns (address token, LpTokenVault vault, PoolKey memory key)
    {
        vm.deal(address(creator), 10 ether);
        TokenLaunchpad.TokenMetadata memory metadata = TokenLaunchpad.TokenMetadata({
            name: "Hostile Cat",
            symbol: "HCAT",
            imageUrl: "ipfs://hostile",
            websiteUrl: "https://example.com",
            twitterHandle: "hostile_cat",
            telegramHandle: "hostile_cat_chat"
        });
        address vaultAddress;
        (token, vaultAddress,) = creator.createToken{ value: 0.01 ether }(launchpad, metadata, salt);
        vault = LpTokenVault(payable(vaultAddress));
        key = launchpad.poolKey(token);
    }

    function _buy(PoolKey memory key, uint256 ethIn) private {
        vm.deal(address(this), address(this).balance + ethIn);
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

    function _sell(PoolKey memory key, address token, uint256 amountIn) private {
        if (amountIn == 0) return;
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
    }

    /// Both fee legs must accrue, otherwise compound has nothing matched to deploy.
    function _accrueBothLegs(PoolKey memory key, address token) private {
        for (uint256 i; i < 3; ++i) {
            _buy(key, 1 ether);
            _sell(key, token, IERC20(token).balanceOf(address(this)) / 2);
        }
    }

    function _mint(address token, LpTokenVault vault, PoolKey memory key)
        private
        returns (uint256 shares)
    {
        _buy(key, 1 ether);
        uint256 targetAmount = IERC20(token).balanceOf(address(this));
        IERC20(token).approve(address(vault), type(uint256).max);
        (shares,,) = vault.mintPair{ value: 0.05 ether }(
            targetAmount, 0.05 ether, 1, address(this), block.timestamp + 1
        );
    }

    // --- A poisoned synced-currency slot must not block native settlement -------------

    function testHostileCreatorCannotBlockMintPair() public {
        (address token, LpTokenVault vault, PoolKey memory key) =
            _launch(new HostileCreator(manager, address(usdg), 0), keccak256("mint"));
        _accrueBothLegs(key, token);

        HostileCreator creator = HostileCreator(payable(_creatorOf(token)));
        creator.armPoison(true);

        assertGt(_mint(token, vault, key), 0, "mint blocked by a poisoned sync slot");
        assertGt(creator.payouts(), 0, "creator payout callback never fired");
    }

    function testHostileCreatorCannotBlockCompound() public {
        (address token, LpTokenVault vault, PoolKey memory key) =
            _launch(new HostileCreator(manager, address(usdg), 0), keccak256("compound"));
        _accrueBothLegs(key, token);

        HostileCreator(payable(_creatorOf(token))).armPoison(true);
        vm.warp(vault.compoundAvailableAt());
        assertGt(vault.compound(0, block.timestamp + 1), 0, "compound blocked");
    }

    /// Redemption never settled native, so it must keep working either way.
    function testRedeemUnaffectedByPoisonedSyncSlot() public {
        (address token, LpTokenVault vault, PoolKey memory key) =
            _launch(new HostileCreator(manager, address(usdg), 0), keccak256("redeem"));
        _accrueBothLegs(key, token);
        uint256 shares = _mint(token, vault, key);

        HostileCreator(payable(_creatorOf(token))).armPoison(true);
        (uint256 targetOut, uint256 counterOut) =
            vault.redeem(shares, 0, 0, address(this), block.timestamp + 1);
        assertGt(targetOut, 0);
        assertGt(counterOut, 0);
    }

    /// A third party poisoning the slot before the call must not matter either. The poison
    /// is applied immediately before the vault call so it targets our settlement path
    /// rather than the v4 test router's.
    function testExternalSyncBeforeMintIsHarmless() public {
        (address token, LpTokenVault vault, PoolKey memory key) =
            _launch(new HostileCreator(manager, address(usdg), 0), keccak256("external"));
        _accrueBothLegs(key, token);

        _buy(key, 1 ether);
        uint256 targetAmount = IERC20(token).balanceOf(address(this));
        IERC20(token).approve(address(vault), type(uint256).max);

        manager.sync(Currency.wrap(address(usdg)));
        (uint256 shares,,) = vault.mintPair{ value: 0.05 ether }(
            targetAmount, 0.05 ether, 1, address(this), block.timestamp + 1
        );
        assertGt(shares, 0, "mint blocked by an external sync");
    }

    // --- Caller-funded payout allowance ----------------------------------------------

    function testDefaultStipendLeavesExpensiveWalletUnpaid() public {
        (address token,, PoolKey memory key) =
            _launch(new HostileCreator(manager, address(usdg), 3), keccak256("expensive"));
        _accrueBothLegs(key, token);

        launchVault.distributeFees(token);
        (ILaunchFeeSource.FeeAmounts memory creator,,) = launchVault.pendingFees(token);
        assertGt(creator.counter, 0, "expensive wallet unexpectedly paid by the stipend");
        assertEq(HostileCreator(payable(_creatorOf(token))).payouts(), 0);
    }

    function testCallerFundedAllowancePaysExpensiveWallet() public {
        (address token,, PoolKey memory key) =
            _launch(new HostileCreator(manager, address(usdg), 3), keccak256("expensive-retry"));
        _accrueBothLegs(key, token);

        launchVault.distributeFees(token);
        address creatorAddress = _creatorOf(token);
        uint256 before = creatorAddress.balance;

        launchVault.distributeFeesWithGas(token, 500_000);

        (ILaunchFeeSource.FeeAmounts memory creator,,) = launchVault.pendingFees(token);
        assertEq(creator.counter, 0, "claim still unpaid after a funded retry");
        assertGt(creatorAddress.balance, before, "creator received nothing");
        assertGt(HostileCreator(payable(creatorAddress)).payouts(), 0);
    }

    /// The default path must keep its tight bound so one market cannot tax its LPs more.
    function testDefaultStipendConstantIsUnchanged() public view {
        assertEq(launchVault.NATIVE_PAYOUT_GAS(), 30_000);
    }

    // --- Creator handover -------------------------------------------------------------

    /// The reason the handover exists: a wallet the stipend cannot pay leaves its claim
    /// stranded, and pointing the position at a payable address settles it.
    function testHandoverPaysAClaimTheOldCreatorCouldNotReceive() public {
        (address token,, PoolKey memory key) =
            _launch(new HostileCreator(manager, address(usdg), 3), keccak256("handover"));
        _accrueBothLegs(key, token);

        launchVault.distributeFees(token);
        (ILaunchFeeSource.FeeAmounts memory stranded,,) = launchVault.pendingFees(token);
        assertEq(stranded.target, 0, "standard target payout should not strand");
        assertGt(stranded.counter, 0, "expected an unpaid claim to hand over");

        HostileCreator oldCreator = HostileCreator(payable(_creatorOf(token)));
        address newCreator = makeAddr("new-creator");
        vm.expectEmit(true, true, true, false, address(launchVault));
        emit LaunchLiquidityVault.CreatorTransferred(token, address(oldCreator), newCreator);
        oldCreator.transferCreator(launchVault, token, newCreator);

        assertEq(_creatorOf(token), newCreator, "creator not moved");
        launchVault.distributeFees(token);

        (ILaunchFeeSource.FeeAmounts memory afterHandover,,) = launchVault.pendingFees(token);
        assertEq(afterHandover.counter, 0, "stranded claim survived the handover");
        assertEq(newCreator.balance, stranded.counter, "new creator was not paid the claim");
        assertEq(IERC20(token).balanceOf(newCreator), 0, "handover created a target claim");
        assertEq(oldCreator.payouts(), 0, "old creator was paid after handing over");
    }

    /// Fees that accrue later follow the new creator too, so the handover is permanent.
    function testLaterFeesAccrueToTheNewCreator() public {
        (address token,, PoolKey memory key) =
            _launch(new HostileCreator(manager, address(usdg), 0), keccak256("handover-later"));
        HostileCreator oldCreator = HostileCreator(payable(_creatorOf(token)));
        address newCreator = makeAddr("later-creator");
        oldCreator.transferCreator(launchVault, token, newCreator);

        _accrueBothLegs(key, token);
        uint256 oldCreatorBalance = address(oldCreator).balance;
        uint256 oldCreatorTarget = IERC20(token).balanceOf(address(oldCreator));
        launchVault.distributeFees(token);

        assertGt(newCreator.balance, 0, "new creator received no later fees");
        assertGt(IERC20(token).balanceOf(newCreator), 0, "new creator received no target fees");
        assertEq(address(oldCreator).balance, oldCreatorBalance, "old creator still paid");
        assertEq(
            IERC20(token).balanceOf(address(oldCreator)),
            oldCreatorTarget,
            "old creator still received target fees"
        );
    }

    /// A handover during the native callback affects only future payouts. The current payout
    /// and its event retain the creator selected when distribution began.
    function testCallbackHandoverKeepsCurrentPayoutReceiverConsistent() public {
        (address token,, PoolKey memory key) =
            _launch(new HostileCreator(manager, address(usdg), 3), keccak256("handover-callback"));
        _accrueBothLegs(key, token);

        launchVault.distributeFees(token);
        (ILaunchFeeSource.FeeAmounts memory stranded,,) = launchVault.pendingFees(token);
        assertGt(stranded.counter, 0, "expected a retryable native claim");

        HostileCreator oldCreator = HostileCreator(payable(_creatorOf(token)));
        address newCreator = makeAddr("callback-creator");
        oldCreator.armHandover(launchVault, token, newCreator);
        uint256 oldCreatorBefore = address(oldCreator).balance;

        vm.expectEmit(true, true, true, false, address(launchVault));
        emit LaunchLiquidityVault.LaunchFeePayout(
            token,
            address(oldCreator),
            LaunchLiquidityVault.FeeRecipient.Creator,
            0,
            0,
            false,
            false
        );
        launchVault.distributeFeesWithGas(token, 500_000);

        assertEq(_creatorOf(token), newCreator, "callback handover did not persist");
        assertEq(
            address(oldCreator).balance,
            oldCreatorBefore + stranded.counter,
            "current claim did not pay the old creator"
        );
        assertEq(newCreator.balance, 0, "successor received the current claim");

        _accrueBothLegs(key, token);
        launchVault.distributeFees(token);
        assertGt(newCreator.balance, 0, "successor received no later fees");
    }

    function testOnlyTheCurrentCreatorCanHandOver() public {
        (address token,,) =
            _launch(new HostileCreator(manager, address(usdg), 0), keccak256("handover-auth"));
        HostileCreator originalCreator = HostileCreator(payable(_creatorOf(token)));
        address newCreator = makeAddr("auth-creator");

        vm.expectRevert(LaunchLiquidityVault.OnlyCreator.selector);
        launchVault.transferCreator(token, newCreator);

        originalCreator.transferCreator(launchVault, token, newCreator);

        // The outgoing creator loses the right along with the claim.
        vm.expectRevert(LaunchLiquidityVault.OnlyCreator.selector);
        originalCreator.transferCreator(launchVault, token, address(originalCreator));

        vm.prank(newCreator);
        launchVault.transferCreator(token, address(originalCreator));
        assertEq(_creatorOf(token), address(originalCreator), "new creator cannot hand back");
    }

    /// Zero would erase the position, since `creator` is also its existence marker.
    function testHandoverRejectsTheZeroAddress() public {
        (address token,,) =
            _launch(new HostileCreator(manager, address(usdg), 0), keccak256("handover-zero"));
        HostileCreator creator = HostileCreator(payable(_creatorOf(token)));

        vm.expectRevert(LaunchLiquidityVault.InvalidAddress.selector);
        creator.transferCreator(launchVault, token, address(0));
    }

    function testHandoverRequiresAKnownPosition() public {
        vm.expectRevert(LaunchLiquidityVault.PositionNotFound.selector);
        launchVault.transferCreator(address(cashcat), makeAddr("unknown-creator"));
    }

    function _creatorOf(address token) private view returns (address creator) {
        (creator,,,) = launchVault.positions(token);
    }
}
