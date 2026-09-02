// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IProtocolFees } from "@uniswap/v4-core/src/interfaces/IProtocolFees.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { Pool } from "@uniswap/v4-core/src/libraries/Pool.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolModifyLiquidityTest } from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import { IV4Router } from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import { IV4Quoter } from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import { IWETH9 } from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import { LaunchLiquidityVault } from "../src/LaunchLiquidityVault.sol";
import { LaunchToken } from "../src/LaunchToken.sol";
import { LpTokenFactory } from "../src/LpTokenFactory.sol";
import { LpTokenVault } from "../src/LpTokenVault.sol";
import { TokenLaunchpad } from "../src/TokenLaunchpad.sol";
import { ILpTokenFactory } from "../src/interfaces/ILpTokenFactory.sol";
import { ILaunchFeeSource } from "../src/interfaces/ILaunchFeeSource.sol";
import { ILpTokenVault } from "../src/interfaces/ILpTokenVault.sol";
import { DeploymentBase } from "../script/DeploymentBase.s.sol";
import { DeployLpToken } from "../script/DeployLpToken.s.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { LpTokenLens } from "../src/periphery/LpTokenLens.sol";
import { ZapRouter } from "../src/periphery/ZapRouter.sol";
import { LaunchpadTestDeployer } from "./utils/LaunchpadTestDeployer.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable;
}

interface IAllowanceTransfer {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;

    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

/// @notice Mainnet-fork dry runs against the production PoolManager deployment on the
/// Robinhood chain. Skipped unless FORK_RPC_URL is set. FORK_BLOCK_NUMBER optionally
/// pins an archive block. Fresh pools are created on the fork so the run exercises real
/// bytecode and state without touching existing markets.
contract LpTokenForkDryRunTest is Test, LaunchpadTestDeployer {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    bytes32 internal constant POOL_MANAGER_CODEHASH =
        0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626;
    address internal constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    bytes32 internal constant UNIVERSAL_ROUTER_CODEHASH =
        0x2ce6aaaf9f4151f5e1cbf774668772f17f532ae11b15e9284fd0a072a8b0fbde;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    bytes32 internal constant PERMIT2_CODEHASH =
        0x5208783f52488f7d3493e5e38311ab707c1d75457fe472a19b0b4d57d66a7fca;
    address internal constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    bytes32 internal constant V4_QUOTER_CODEHASH =
        0xd707b1da8cb165e5ea35a3b4450d971eb562ec171e23492aa117036b78a868f6;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    bytes32 internal constant USDG_CODEHASH =
        0x864cc9ad53b338b82da1f7cab85ab0b3d5c8861acb422b6fec63cf36234f36a6;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    bytes32 internal constant WETH_CODEHASH =
        0x5706be52f64875fee65a2cec0d80e47a23d8793cbe85d214b48445e2d05f5353;
    bytes32 internal constant WETH_USDG_POOL_ID =
        0x77c25b9386d47de62e0155c393696e9f43f7e6d036c6ca52f66735ccbb8808a7;
    bytes1 internal constant SWEEP_COMMAND = 0x04;
    bytes1 internal constant V4_SWAP_COMMAND = 0x10;

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal liquidityRouter;
    LpTokenFactory internal factory;

    address internal owner = makeAddr("fork owner");
    address internal treasury = makeAddr("fork treasury");

    receive() external payable { }

    function setUp() public {
        string memory rpcUrl = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;
        uint256 forkBlock = vm.envOr("FORK_BLOCK_NUMBER", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpcUrl);
        else vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, 4663);
        assertEq(POOL_MANAGER.codehash, POOL_MANAGER_CODEHASH);
        assertEq(UNIVERSAL_ROUTER.codehash, UNIVERSAL_ROUTER_CODEHASH);
        assertEq(PERMIT2.codehash, PERMIT2_CODEHASH);
        assertEq(V4_QUOTER.codehash, V4_QUOTER_CODEHASH);
        assertEq(USDG.codehash, USDG_CODEHASH);
        assertEq(WETH.codehash, WETH_CODEHASH);

        manager = IPoolManager(POOL_MANAGER);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        factory = new LpTokenFactory(manager, treasury, owner);
    }

    modifier onlyForked() {
        if (address(manager) == address(0)) {
            vm.skip(true);
        }
        _;
    }

    function testForkDryRunErc20CounterLifecycle() public onlyForked {
        MockERC20 target = new MockERC20("Fork Target", "FORKT", 18);
        MockERC20 counter = new MockERC20("Fork Counter", "FORKC", 6);
        PoolKey memory key = _sortedKey(address(target), address(counter));
        _createLivePool(key);

        LpTokenVault vault = _launch(address(target), key, 1_000e18, 1_000e18);
        _lifecycle(vault, key, address(target));
    }

    function testForkDryRunNativeCounterLifecycle() public onlyForked {
        MockERC20 target = new MockERC20("Fork Native Target", "FORKN", 18);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(target)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        _createLivePool(key);

        LpTokenVault vault = _launch(address(target), key, 1_000e18, 1_000e18);
        assertTrue(vault.counterIsNative());
        _lifecycle(vault, key, address(target));
    }

    function testForkProductionUniversalRouterErc20ExactOutput() public onlyForked {
        MockERC20 target = new MockERC20("Fork Exact Output Target", "FORKXO", 18);
        MockERC20 counter = new MockERC20("Fork Exact Output Counter", "FORKXC", 18);
        PoolKey memory key = _sortedKey(address(target), address(counter));
        _createLivePool(key);

        bool zeroForOne = Currency.unwrap(key.currency0) == address(counter);
        uint256 targetAmount = 1 ether;
        uint256 quotedInput = _quoteExactOutput(key, zeroForOne, targetAmount);
        uint256 maximumInput = (quotedInput * 101 + 99) / 100;
        uint48 expiration = uint48(block.timestamp + 1 hours);

        counter.mint(address(this), maximumInput);
        counter.approve(PERMIT2, maximumInput);
        IAllowanceTransfer(PERMIT2)
            .approve(address(counter), UNIVERSAL_ROUTER, maximumInput.toUint160(), expiration);
        (uint160 permittedBefore, uint48 storedExpiration,) =
            IAllowanceTransfer(PERMIT2).allowance(address(this), address(counter), UNIVERSAL_ROUTER);
        assertEq(uint256(permittedBefore), maximumInput);
        assertEq(storedExpiration, expiration);

        vm.expectRevert();
        _universalExactOutputSwap(key, zeroForOne, targetAmount, quotedInput - 1, expiration);

        uint256 nativeBefore = address(this).balance;
        uint256 counterBefore = counter.balanceOf(address(this));
        uint256 targetBefore = target.balanceOf(address(this));
        _universalExactOutputSwap(key, zeroForOne, targetAmount, maximumInput, expiration);
        uint256 counterSpent = counterBefore - counter.balanceOf(address(this));

        assertEq(target.balanceOf(address(this)) - targetBefore, targetAmount);
        assertEq(counterSpent, quotedInput);
        assertLe(counterSpent, maximumInput);
        assertEq(address(this).balance, nativeBefore);
        assertEq(counter.balanceOf(UNIVERSAL_ROUTER), 0);
        assertEq(target.balanceOf(UNIVERSAL_ROUTER), 0);

        (uint160 permittedAfter, uint48 expirationAfter,) =
            IAllowanceTransfer(PERMIT2).allowance(address(this), address(counter), UNIVERSAL_ROUTER);
        assertEq(uint256(permittedAfter), maximumInput - counterSpent);
        assertEq(expirationAfter, expiration);

        vm.warp(uint256(expiration) + 1);
        uint256 secondTargetAmount = targetAmount / 1_000;
        uint256 secondQuotedInput = _quoteExactOutput(key, zeroForOne, secondTargetAmount);
        assertLt(secondQuotedInput, uint256(permittedAfter));
        vm.expectRevert(abi.encodeWithSignature("AllowanceExpired(uint256)", uint256(expiration)));
        _universalExactOutputSwap(
            key, zeroForOne, secondTargetAmount, secondQuotedInput, block.timestamp
        );
    }

    function testForkProductionUniversalRouterNativeExactOutputRefundsMaximum() public onlyForked {
        MockERC20 target = new MockERC20("Fork Native Exact Output", "FORKNXO", 18);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(target)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        _createLivePool(key);

        uint256 targetAmount = 1 ether;
        uint256 quotedInput = _quoteExactOutput(key, true, targetAmount);
        uint256 maximumInput = (quotedInput * 101 + 99) / 100;
        vm.deal(address(this), maximumInput + 1 ether);

        uint256 nativeBefore = address(this).balance;
        uint256 targetBefore = target.balanceOf(address(this));
        uint256 routerNativeBefore = UNIVERSAL_ROUTER.balance;
        _universalExactOutputSwap(key, true, targetAmount, maximumInput, block.timestamp);
        uint256 nativeSpent = nativeBefore - address(this).balance;

        assertEq(target.balanceOf(address(this)) - targetBefore, targetAmount);
        assertEq(nativeSpent, quotedInput);
        assertLe(nativeSpent, maximumInput);
        assertLt(nativeSpent, maximumInput);
        assertEq(UNIVERSAL_ROUTER.balance, routerNativeBefore);
        assertEq(target.balanceOf(UNIVERSAL_ROUTER), 0);
    }

    function testForkTokenLaunchpadWithoutInitialBuy() public onlyForked {
        TokenLaunchpad launchpad = _deployLaunchpad();
        address creator = makeAddr("fork no-buy creator");
        uint256 bootstrapQuote = launchpad.initialLpQuote();
        int24 expectedStartTick = launchpad.startTick();
        vm.deal(creator, bootstrapQuote);

        vm.prank(creator);
        (address token, address vaultAddress, uint256 targetOut) = launchpad.createToken{
            value: bootstrapQuote
        }(
            _launchMetadata(),
            keccak256("fork launch without buy"),
            0,
            0,
            expectedStartTick,
            bootstrapQuote,
            block.timestamp
        );

        LpTokenVault vault = LpTokenVault(payable(vaultAddress));
        PoolKey memory key = launchpad.poolKey(token);
        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        assertEq(targetOut, 0);
        assertEq(IERC20(token).balanceOf(creator), 0);
        assertEq(currentTick, launchpad.startTick());
        assertEq(vault.totalSupply(), vault.balanceOf(vault.DEAD_SHARE_RECEIVER()));
        assertGt(vault.positionLiquidity(), 0);
    }

    function testForkTokenLaunchpadAtomicLaunchAndLifecycle() public onlyForked {
        TokenLaunchpad launchpad = _deployLaunchpad();
        LaunchLiquidityVault launchLiquidityVault = launchpad.liquidityVault();
        address creator = makeAddr("fork launch creator");
        uint256 initialBuy = 0.01 ether;
        uint256 bootstrapQuote = launchpad.initialLpQuote();
        int24 expectedStartTick = launchpad.startTick();
        vm.deal(creator, bootstrapQuote + initialBuy);
        vm.prank(creator);
        (address token, address vaultAddress, uint256 targetOut) = launchpad.createToken{
            value: bootstrapQuote + initialBuy
        }(
            _launchMetadata(),
            keccak256("fork atomic launch"),
            1,
            TickMath.MIN_SQRT_PRICE + 1,
            expectedStartTick,
            bootstrapQuote,
            block.timestamp
        );

        LpTokenVault vault = LpTokenVault(payable(vaultAddress));
        PoolKey memory key = launchpad.poolKey(token);
        assertEq(vault.poolId(), PoolId.unwrap(key.toId()));
        assertEq(vault.launchFeeSource(), address(launchpad.liquidityVault()));
        assertEq(vault.totalSupply(), vault.balanceOf(vault.DEAD_SHARE_RECEIVER()));
        assertEq(vault.balanceOf(creator), 0);
        assertGt(targetOut, 0);
        assertEq(MockERC20(token).balanceOf(creator), targetOut);

        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        assertLt(currentTick, launchpad.startTick());
        (uint128 launchLiquidity,,) = manager.getPositionInfo(
            key.toId(),
            address(launchpad.liquidityVault()),
            TickMath.minUsableTick(launchpad.TICK_SPACING()),
            launchpad.startTick(),
            bytes32(0)
        );
        assertGt(launchLiquidity, 0);
        assertGt(vault.positionLiquidity(), 0);
        assertEq(manager.getLiquidity(key.toId()), launchLiquidity + vault.positionLiquidity());

        // Exercise the exact production route used by the web app in both directions.
        uint256 bought = _universalSwap(key, true, 0.005 ether);
        uint256 sold = bought / 3;
        assertGt(_universalSwap(key, false, sold), 0);

        // Launch-position fees are permissionlessly distributed to creator, NAV, and
        // protocol under the immutable per-leg policy.
        uint256 vaultTargetBefore = IERC20(token).balanceOf(address(vault));
        uint256 vaultQuoteBefore = address(vault).balance;
        uint256 creatorTargetBefore = IERC20(token).balanceOf(creator);
        uint256 creatorQuoteBefore = creator.balance;
        uint256 treasuryQuoteBefore = treasury.balance;
        (
            ILaunchFeeSource.FeeAmounts memory creatorFees,
            ILaunchFeeSource.FeeAmounts memory navFees,
            ILaunchFeeSource.FeeAmounts memory protocolFees
        ) = launchLiquidityVault.pendingFees(token);
        assertGt(creatorFees.target, 0);
        assertGt(creatorFees.counter, 0);
        assertGt(navFees.target, 0);
        assertGt(navFees.counter, 0);
        assertEq(protocolFees.target, 0);
        assertGt(protocolFees.counter, 0);

        vm.prank(makeAddr("fork launch fee distributor"));
        launchLiquidityVault.distributeFees(token);
        assertEq(IERC20(token).balanceOf(address(vault)) - vaultTargetBefore, navFees.target);
        assertEq(address(vault).balance - vaultQuoteBefore, navFees.counter);
        assertEq(IERC20(token).balanceOf(creator) - creatorTargetBefore, creatorFees.target);
        assertEq(creator.balance - creatorQuoteBefore, creatorFees.counter);
        assertEq(treasury.balance - treasuryQuoteBefore, protocolFees.counter);

        // Full-range fees remain entirely in NAV and compounding never mints protocol shares.
        (uint256 vaultFeesTarget, uint256 vaultFeesCounter) = vault.pendingFees();
        assertGt(vaultFeesTarget, 0);
        assertGt(vaultFeesCounter, 0);
        uint256 treasurySharesBeforeCompound = vault.balanceOf(treasury);
        uint256 supplyBeforeCompound = vault.totalSupply();
        vm.warp(vault.compoundAvailableAt());
        assertGt(vault.compound(1, block.timestamp), 0);
        assertEq(vault.balanceOf(treasury), treasurySharesBeforeCompound);
        assertEq(vault.totalSupply(), supplyBeforeCompound);

        // A public holder can mint and burn lpTOKEN shares after the platform launch.
        uint256 maxTarget = IERC20(token).balanceOf(address(this)) / 2;
        uint256 maxCounter = 0.002 ether;
        IERC20(token).approve(address(vault), maxTarget);
        uint256 supplyBeforeMint = vault.totalSupply();
        uint256 treasurySharesBeforeMint = vault.balanceOf(treasury);
        (uint256 shares, uint256 targetUsed, uint256 counterUsed) = vault.mintPair{
            value: maxCounter
        }(
            maxTarget, maxCounter, 1, address(this), block.timestamp
        );
        assertGt(shares, 0);
        assertGt(targetUsed, 0);
        assertGt(counterUsed, 0);
        uint256 grossShares = vault.totalSupply() - supplyBeforeMint;
        uint256 mintFeeShares = grossShares - shares;
        assertEq(
            mintFeeShares,
            FullMath.mulDivRoundingUp(grossShares, vault.SHARE_FEE_BPS(), vault.BPS())
        );
        assertEq(vault.balanceOf(treasury) - treasurySharesBeforeMint, mintFeeShares);

        uint256 redeemFeeShares =
            FullMath.mulDivRoundingUp(shares, vault.SHARE_FEE_BPS(), vault.BPS());
        uint256 treasurySharesBeforeRedeem = vault.balanceOf(treasury);
        uint256 supplyBeforeRedeem = vault.totalSupply();
        (uint256 redeemedTarget, uint256 redeemedCounter) =
            vault.redeem(shares, 1, 1, address(this), block.timestamp);
        assertGt(redeemedTarget, 0);
        assertGt(redeemedCounter, 0);
        assertEq(vault.balanceOf(treasury) - treasurySharesBeforeRedeem, redeemFeeShares);
        assertEq(supplyBeforeRedeem - vault.totalSupply(), shares - redeemFeeShares);
    }

    function testForkRoutedStableZapIntoNativeLaunchVaultAndStrictExit() public onlyForked {
        TokenLaunchpad launchpad = _deployLaunchpad();
        address creator = makeAddr("fork routed launch creator");
        uint256 bootstrapQuote = launchpad.initialLpQuote();
        int24 expectedStartTick = launchpad.startTick();
        vm.deal(creator, bootstrapQuote);
        vm.prank(creator);
        (, address vaultAddress,) = launchpad.createToken{ value: bootstrapQuote }(
            _launchMetadata(),
            keccak256("fork routed zap"),
            0,
            0,
            expectedStartTick,
            bootstrapQuote,
            block.timestamp
        );
        LpTokenVault vault = LpTokenVault(payable(vaultAddress));
        assertTrue(vault.counterIsNative());

        PoolKey memory bridge = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDG),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        (uint160 bridgePrice,,,) = manager.getSlot0(bridge.toId());
        assertGt(bridgePrice, 0);

        uint128 inputAmount = 10e6;
        (uint256 quotedCounter,) = IV4Quoter(V4_QUOTER)
            .quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: bridge,
                    zeroForOne: false,
                    exactAmount: inputAmount,
                    hookData: bytes("")
                })
            );
        uint256 minimumCounter = quotedCounter * 99 / 100;
        assertGt(minimumCounter, 1);

        ZapRouter router = new ZapRouter(factory, USDG, IWETH9(WETH));
        address holder = makeAddr("fork routed zap holder");
        deal(USDG, holder, inputAmount);
        vm.prank(holder);
        IERC20(USDG).approve(address(router), inputAmount);
        PoolKey[] memory route = new PoolKey[](1);
        route[0] = bridge;

        vm.prank(holder);
        (uint256 shares,,) = router.zapInRouted(
            ILpTokenVault(address(vault)),
            Currency.wrap(USDG),
            inputAmount,
            route,
            minimumCounter,
            minimumCounter / 2,
            1,
            1,
            holder,
            block.timestamp
        );
        assertGt(shares, 0);
        assertEq(vault.balanceOf(holder), shares);

        uint256 nativeBefore = holder.balance;
        vm.startPrank(holder);
        vault.approve(address(router), shares);
        uint256 counterOut =
            router.zapOut(ILpTokenVault(address(vault)), shares, 1, holder, block.timestamp);
        vm.stopPrank();
        assertGt(counterOut, 0);
        assertEq(holder.balance, nativeBefore + counterOut);
        assertEq(vault.balanceOf(holder), 0);

        // The same round trip paid by signature, against the live stablecoin's own EIP-712
        // domain and the vault share's, with no approval standing behind either.
        uint256 signerKey = 0x5161;
        address signer = vm.addr(signerKey);
        deal(USDG, signer, inputAmount);
        assertEq(IERC20(USDG).allowance(signer, address(router)), 0);

        // Signed before the prank: reading the token's nonce and domain would otherwise spend
        // it, and the zap would arrive from this contract rather than the signer.
        ZapRouter.PermitSignature memory inputPermit =
            _forkPermit(signerKey, USDG, address(router), inputAmount);
        vm.prank(signer);
        (uint256 permitShares,,) = router.zapInRoutedWithPermit(
            ILpTokenVault(address(vault)),
            Currency.wrap(USDG),
            inputAmount,
            route,
            minimumCounter,
            minimumCounter / 2,
            1,
            1,
            signer,
            block.timestamp,
            inputPermit
        );
        assertGt(permitShares, 0);
        assertEq(vault.balanceOf(signer), permitShares);

        assertEq(vault.allowance(signer, address(router)), 0);
        uint256 signerNativeBefore = signer.balance;
        ZapRouter.PermitSignature memory sharePermit =
            _forkPermit(signerKey, address(vault), address(router), permitShares);
        vm.prank(signer);
        uint256 permitCounterOut = router.zapOutWithPermit(
            ILpTokenVault(address(vault)), permitShares, 1, signer, block.timestamp, sharePermit
        );
        assertGt(permitCounterOut, 0);
        assertEq(signer.balance, signerNativeBefore + permitCounterOut);
        assertEq(vault.balanceOf(signer), 0);
        assertEq(IERC20(USDG).balanceOf(address(router)), 0);
    }

    /// @dev Signs against whatever domain the token reports, so a live token's own separator
    /// is what the signature is checked under rather than one reconstructed here.
    function _forkPermit(uint256 signerKey, address token, address spender, uint256 value)
        private
        view
        returns (ZapRouter.PermitSignature memory)
    {
        address owner = vm.addr(signerKey);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                owner,
                spender,
                value,
                IERC20Permit(token).nonces(owner),
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            signerKey,
            keccak256(
                abi.encodePacked("\x19\x01", IERC20Permit(token).DOMAIN_SEPARATOR(), structHash)
            )
        );
        return ZapRouter.PermitSignature(value, deadline, v, r, s);
    }

    function testForkExistingWethUsdgPoolDirectZapAndLens() public onlyForked {
        PoolKey memory key = _wethUsdgKey();
        assertEq(PoolId.unwrap(key.toId()), WETH_USDG_POOL_ID);
        (uint160 liveSqrtPrice, int24 liveTick,,) = manager.getSlot0(key.toId());
        assertGt(liveSqrtPrice, 0);
        assertGt(manager.getLiquidity(key.toId()), 0);

        LpTokenVault vault = _launchExistingWethUsdg(key);
        assertEq(vault.target(), WETH);
        assertEq(Currency.unwrap(vault.counter()), USDG);
        assertFalse(vault.counterIsNative());

        LpTokenLens lens = new LpTokenLens();
        LpTokenLens.VaultSnapshot memory snap = lens.snapshot(vault);
        assertEq(snap.vault, address(vault));
        assertEq(snap.target, WETH);
        assertEq(snap.counter, USDG);
        assertEq(snap.poolId, PoolId.unwrap(key.toId()));
        assertEq(snap.poolTick, liveTick);
        assertGt(snap.poolLiquidity, snap.positionLiquidity);
        assertGt(snap.positionLiquidity, 0);
        assertTrue(lens.isRegistered(factory, vault));
        LpTokenLens.VaultSnapshot[] memory snaps = lens.factorySnapshots(factory, 0, 2);
        assertEq(snaps.length, 1);
        assertEq(snaps[0].vault, address(vault));

        ZapRouter router = new ZapRouter(factory, USDG, IWETH9(WETH));
        address holder = makeAddr("fork direct zap holder");
        uint256 counterAmount = 40e6;
        uint256 swapCounterAmount = counterAmount / 2;
        deal(USDG, holder, counterAmount);
        vm.prank(holder);
        IERC20(USDG).approve(address(router), counterAmount);

        (uint256 quotedTarget,) = IV4Quoter(V4_QUOTER)
            .quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: key,
                    zeroForOne: false,
                    exactAmount: swapCounterAmount.toUint128(),
                    hookData: bytes("")
                })
            );
        assertGt(quotedTarget, 0);

        // A real PoolManager swap happens before the guard, so this proves the entire
        // direct zap (including pool price and transferred input) rolls back atomically.
        uint256 supplyBefore = vault.totalSupply();
        vm.prank(holder);
        vm.expectPartialRevert(ZapRouter.InsufficientSwapOutput.selector);
        router.zapIn(
            ILpTokenVault(address(vault)),
            counterAmount,
            swapCounterAmount,
            type(uint256).max,
            1,
            holder,
            block.timestamp
        );
        assertEq(IERC20(USDG).balanceOf(holder), counterAmount);
        assertEq(vault.totalSupply(), supplyBefore);
        (uint160 sqrtPriceAfterRevert, int24 tickAfterRevert,,) = manager.getSlot0(key.toId());
        assertEq(sqrtPriceAfterRevert, liveSqrtPrice);
        assertEq(tickAfterRevert, liveTick);
        _assertZapRouterEmpty(router, vault);

        vm.prank(holder);
        (uint256 shares, uint256 targetUsed, uint256 counterUsed) = router.zapIn(
            ILpTokenVault(address(vault)),
            counterAmount,
            swapCounterAmount,
            quotedTarget * 99 / 100,
            1,
            holder,
            block.timestamp
        );
        assertGt(shares, 0);
        assertGt(targetUsed, 0);
        assertGt(counterUsed, swapCounterAmount);
        assertEq(vault.balanceOf(holder), shares);
        (uint256 previewTarget, uint256 previewCounter) = lens.previewRedeem(vault, shares);
        assertGt(previewTarget, 0);
        assertGt(previewCounter, 0);

        // The strict exit also rolls back both the redemption and real pool swap when its
        // final counter-output guard is impossible, then succeeds with the same shares.
        uint256 counterBeforeExit = IERC20(USDG).balanceOf(holder);
        uint256 targetBeforeExit = IERC20(WETH).balanceOf(holder);
        (uint160 sqrtPriceBeforeExit, int24 tickBeforeExit,,) = manager.getSlot0(key.toId());
        vm.startPrank(holder);
        vault.approve(address(router), shares);
        vm.expectPartialRevert(ZapRouter.InsufficientCounterOutput.selector);
        router.zapOut(
            ILpTokenVault(address(vault)), shares, type(uint256).max, holder, block.timestamp
        );
        vm.stopPrank();
        assertEq(vault.balanceOf(holder), shares);
        assertEq(IERC20(USDG).balanceOf(holder), counterBeforeExit);
        assertEq(IERC20(WETH).balanceOf(holder), targetBeforeExit);
        (uint160 sqrtPriceAfterExitRevert, int24 tickAfterExitRevert,,) =
            manager.getSlot0(key.toId());
        assertEq(sqrtPriceAfterExitRevert, sqrtPriceBeforeExit);
        assertEq(tickAfterExitRevert, tickBeforeExit);
        _assertZapRouterEmpty(router, vault);

        vm.prank(holder);
        uint256 counterOut =
            router.zapOut(ILpTokenVault(address(vault)), shares, 1, holder, block.timestamp);
        assertGt(counterOut, 0);
        assertEq(IERC20(USDG).balanceOf(holder), counterBeforeExit + counterOut);
        assertEq(vault.balanceOf(holder), 0);
        _assertZapRouterEmpty(router, vault);
    }

    function testForkLaunchMetadataDirectoryAndLensViews() public onlyForked {
        TokenLaunchpad launchpad = _deployLaunchpad();
        address creator = makeAddr("fork metadata creator");
        uint256 bootstrapQuote = launchpad.initialLpQuote();
        int24 expectedStartTick = launchpad.startTick();
        vm.deal(creator, bootstrapQuote);
        vm.prank(creator);
        (address token, address vaultAddress,) = launchpad.createToken{ value: bootstrapQuote }(
            _launchMetadata(),
            keccak256("fork metadata views"),
            0,
            0,
            expectedStartTick,
            bootstrapQuote,
            block.timestamp
        );

        LaunchToken launchToken = LaunchToken(token);
        vm.prank(creator);
        launchToken.updateMetadata(
            "ipfs://fork-updated", "https://fork.example", "fork_updated", "fork_chat"
        );
        assertEq(launchToken.imageUrl(), "ipfs://fork-updated");
        assertEq(launchToken.websiteUrl(), "https://fork.example");
        assertEq(launchToken.twitterHandle(), "fork_updated");
        assertEq(launchToken.telegramHandle(), "fork_chat");

        assertEq(launchpad.getTokenCount(), 1);
        TokenLaunchpad.TokenInfo memory info = launchpad.getTokenInfo(token);
        assertEq(info.token, token);
        assertEq(info.creator, creator);
        assertEq(info.vault, vaultAddress);
        TokenLaunchpad.TokenInfo[] memory directory = launchpad.getTokens(0, 2);
        assertEq(directory.length, 1);
        assertEq(directory[0].token, token);

        LpTokenVault vault = LpTokenVault(payable(vaultAddress));
        LpTokenLens lens = new LpTokenLens();
        LpTokenLens.VaultSnapshot memory snap = lens.snapshot(vault);
        assertEq(snap.vault, vaultAddress);
        assertEq(snap.launchFeeSource, address(launchpad.liquidityVault()));
        assertTrue(snap.counterIsNative);
        assertEq(snap.totalSupply, vault.totalSupply());
        assertEq(snap.positionLiquidity, vault.positionLiquidity());
        assertTrue(lens.isRegistered(factory, vault));

        (uint256 previewShares, uint256 targetUsed, uint256 counterUsed) =
            lens.previewMintPair(vault, launchpad.bootstrapTargetAmount(), bootstrapQuote);
        assertGt(previewShares, 0);
        assertGt(targetUsed, 0);
        assertGt(counterUsed, 0);
        (uint256 targetOut, uint256 counterOut) =
            lens.previewRedeem(vault, vault.balanceOf(vault.DEAD_SHARE_RECEIVER()));
        assertGt(targetOut, 0);
        assertGt(counterOut, 0);
    }

    function testForkLaunchGuardsRollbackAllCreatedState() public onlyForked {
        TokenLaunchpad launchpad = _deployLaunchpad();
        address creator = makeAddr("fork rollback creator");
        TokenLaunchpad.TokenMetadata memory metadata = _launchMetadata();
        uint256 bootstrapQuote = launchpad.initialLpQuote();
        int24 expectedStartTick = launchpad.startTick();
        uint256 supplied = bootstrapQuote + 0.01 ether;
        vm.deal(creator, supplied);

        bytes32 minimumSalt = keccak256("fork minimum rollback");
        address minimumPredicted = launchpad.predictTokenAddress(creator, metadata, minimumSalt);
        vm.prank(creator);
        vm.expectPartialRevert(TokenLaunchpad.InsufficientInitialBuyOutput.selector);
        launchpad.createToken{ value: supplied }(
            metadata,
            minimumSalt,
            type(uint256).max,
            TickMath.MIN_SQRT_PRICE + 1,
            expectedStartTick,
            bootstrapQuote,
            block.timestamp
        );
        _assertLaunchRolledBack(launchpad, minimumPredicted, creator, supplied);

        bytes32 limitSalt = keccak256("fork price-limit rollback");
        address limitPredicted = launchpad.predictTokenAddress(creator, metadata, limitSalt);
        uint160 invalidLimit = launchpad.initialSqrtPriceX96();
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(
                Pool.PriceLimitAlreadyExceeded.selector, invalidLimit, invalidLimit
            )
        );
        launchpad.createToken{ value: supplied }(
            metadata, limitSalt, 0, invalidLimit, expectedStartTick, bootstrapQuote, block.timestamp
        );
        _assertLaunchRolledBack(launchpad, limitPredicted, creator, supplied);
    }

    function testForkProductionDeploymentScriptWiring() public onlyForked {
        uint256 deployerPrivateKey = uint256(keccak256("fork deployment script key"));
        address factoryOwnerTransferTarget = makeAddr("fork factory owner transfer target");
        vm.setEnv("DEPLOYMENT_CONFIG", "test/fixtures/robinhood-fork-deployment.json");
        vm.setEnv("PRIVATE_KEY", vm.toString(deployerPrivateKey));

        DeployLpToken script = new DeployLpToken();
        vm.setEnv("FACTORY_OWNER_TRANSFER_TARGET", vm.toString(address(0)));
        vm.expectRevert(DeploymentBase.InvalidAddress.selector);
        script.run();

        vm.setEnv("FACTORY_OWNER_TRANSFER_TARGET", vm.toString(factoryOwnerTransferTarget));
        (
            LpTokenFactory deployedFactory,
            TokenLaunchpad deployedLaunchpad,
            LaunchLiquidityVault deployedLaunchLiquidityVault,
            ZapRouter deployedZapRouter,
            LpTokenLens deployedLens
        ) = script.run();

        assertEq(address(deployedFactory.poolManager()), POOL_MANAGER);
        assertEq(deployedFactory.treasury(), address(0xBEEF));
        assertEq(deployedFactory.pendingTreasury(), address(0));
        assertEq(deployedFactory.owner(), factoryOwnerTransferTarget);
        assertGt(deployedFactory.vaultImplementation().code.length, 0);
        LpTokenVault deployedVaultImplementation =
            LpTokenVault(payable(deployedFactory.vaultImplementation()));
        assertEq(deployedVaultImplementation.factory(), address(deployedFactory));
        assertEq(address(deployedVaultImplementation.poolManager()), POOL_MANAGER);
        assertEq(deployedVaultImplementation.treasury(), address(0xBEEF));
        assertEq(deployedFactory.launchpad(), address(deployedLaunchpad));
        assertEq(address(deployedLaunchpad.poolManager()), POOL_MANAGER);
        assertEq(address(deployedLaunchpad.factory()), address(deployedFactory));
        assertEq(address(deployedLaunchpad.liquidityVault()), address(deployedLaunchLiquidityVault));
        assertEq(address(deployedLaunchLiquidityVault.poolManager()), POOL_MANAGER);
        assertEq(deployedLaunchLiquidityVault.launchpad(), address(deployedLaunchpad));
        assertEq(deployedLaunchLiquidityVault.factory(), address(deployedFactory));
        assertEq(deployedLaunchLiquidityVault.treasury(), address(0xBEEF));
        assertEq(address(deployedZapRouter.poolManager()), POOL_MANAGER);
        assertEq(address(deployedZapRouter.factory()), address(deployedFactory));
        assertEq(deployedZapRouter.canonicalStable(), USDG);
        assertEq(address(deployedZapRouter.wrappedNative()), WETH);
        assertGt(address(deployedLens).code.length, 0);

        address rotatedTreasury = makeAddr("fork rotated treasury");
        vm.prank(address(0xBEEF));
        deployedFactory.proposeTreasury(rotatedTreasury);
        assertEq(deployedVaultImplementation.treasury(), address(0xBEEF));
        assertEq(deployedLaunchLiquidityVault.treasury(), address(0xBEEF));
        vm.prank(rotatedTreasury);
        deployedFactory.acceptTreasury();
        assertEq(deployedVaultImplementation.treasury(), rotatedTreasury);
        assertEq(deployedLaunchLiquidityVault.treasury(), rotatedTreasury);
    }

    function _launchExistingWethUsdg(PoolKey memory key) private returns (LpTokenVault vault) {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        uint256 targetAmount = 0.02 ether;
        uint256 counterAmount = 50e6;
        ILpTokenFactory.LaunchParams memory params = ILpTokenFactory.LaunchParams({
            target: WETH,
            poolKey: key,
            targetAmount: targetAmount,
            counterAmount: counterAmount,
            expectedTick: tick,
            maxTickDeviation: 0,
            minExistingLiquidity: 1,
            minLiquidityAdded: 1,
            minShares: 1,
            receiver: owner,
            deadline: block.timestamp
        });
        address predicted = factory.predictVault(WETH, key);
        deal(WETH, owner, targetAmount);
        deal(USDG, owner, counterAmount);
        vm.startPrank(owner);
        IERC20(WETH).approve(predicted, targetAmount);
        IERC20(USDG).approve(predicted, counterAmount);
        (address vaultAddress, uint256 shares, uint128 liquidityAdded) = factory.launch(params);
        vm.stopPrank();
        assertGt(shares, 0);
        assertGt(liquidityAdded, 0);
        vault = LpTokenVault(payable(vaultAddress));
    }

    function _assertZapRouterEmpty(ZapRouter router, LpTokenVault vault) private view {
        assertEq(IERC20(WETH).balanceOf(address(router)), 0);
        assertEq(IERC20(USDG).balanceOf(address(router)), 0);
        assertEq(vault.balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);
    }

    function _assertLaunchRolledBack(
        TokenLaunchpad launchpad,
        address predictedToken,
        address creator,
        uint256 supplied
    ) private view {
        assertEq(predictedToken.code.length, 0);
        assertEq(creator.balance, supplied);
        assertEq(launchpad.getTokenCount(), 0);
        assertEq(factory.vaultCount(), 0);
        assertEq(address(launchpad).balance, 0);
        assertEq(address(launchpad.liquidityVault()).balance, 0);
    }

    function _lifecycle(LpTokenVault vault, PoolKey memory key, address target) private {
        // Mint.
        address minter = makeAddr("fork minter");
        MockERC20(target).mint(minter, 100e18);
        vm.prank(minter);
        MockERC20(target).approve(address(vault), type(uint256).max);
        uint256 value;
        if (vault.counterIsNative()) {
            vm.deal(minter, 100e18);
            value = 100e18;
        } else {
            MockERC20 counterToken = MockERC20(Currency.unwrap(vault.counter()));
            counterToken.mint(minter, 100e18);
            vm.prank(minter);
            counterToken.approve(address(vault), type(uint256).max);
        }
        uint256 supplyBeforeMint = vault.totalSupply();
        uint256 treasurySharesBeforeMint = vault.balanceOf(treasury);
        vm.prank(minter);
        (uint256 shares,,) =
            vault.mintPair{ value: value }(100e18, 100e18, 1, minter, block.timestamp);
        assertGt(shares, 0);
        uint256 grossShares = vault.totalSupply() - supplyBeforeMint;
        uint256 mintFeeShares = grossShares - shares;
        assertEq(
            mintFeeShares,
            FullMath.mulDivRoundingUp(grossShares, vault.SHARE_FEE_BPS(), vault.BPS())
        );
        assertEq(vault.balanceOf(treasury) - treasurySharesBeforeMint, mintFeeShares);

        // Exercise the deployed PoolManager's directional protocol-fee path rather than
        // limiting the fork lifecycle to its zero-fee initialization state.
        uint24 protocolFee = (uint24(500) << 12) | uint24(500);
        address protocolFeeController = manager.protocolFeeController();
        assertNotEq(protocolFeeController, address(0));
        vm.prank(protocolFeeController);
        IProtocolFees(address(manager)).setProtocolFee(key, protocolFee);
        (,, uint24 liveProtocolFee,) = manager.getSlot0(key.toId());
        assertEq(liveProtocolFee, protocolFee);

        uint256 currency0ProtocolFeesBefore =
            IProtocolFees(address(manager)).protocolFeesAccrued(key.currency0);
        uint256 currency1ProtocolFeesBefore =
            IProtocolFees(address(manager)).protocolFeesAccrued(key.currency1);

        // Trade through the deployed Universal Router + Permit2 to accrue both fee legs.
        _universalSwap(key, true, 10e18);
        _universalSwap(key, false, 10e18);
        assertGt(
            IProtocolFees(address(manager)).protocolFeesAccrued(key.currency0),
            currency0ProtocolFeesBefore
        );
        assertGt(
            IProtocolFees(address(manager)).protocolFeesAccrued(key.currency1),
            currency1ProtocolFeesBefore
        );
        (uint256 feesTarget, uint256 feesCounter) = vault.pendingFees();
        assertGt(feesTarget, 0);
        assertGt(feesCounter, 0);
        uint256 treasurySharesBeforeCompound = vault.balanceOf(treasury);
        uint256 supplyBeforeCompound = vault.totalSupply();
        vm.warp(vault.compoundAvailableAt());
        vm.prank(makeAddr("fork compound caller"));
        uint128 added = vault.compound(0, block.timestamp);
        assertGt(added, 0);
        assertEq(vault.balanceOf(treasury), treasurySharesBeforeCompound);
        assertEq(vault.totalSupply(), supplyBeforeCompound);

        // Redeem everything the minter holds.
        uint256 redeemFeeShares =
            FullMath.mulDivRoundingUp(shares, vault.SHARE_FEE_BPS(), vault.BPS());
        uint256 treasurySharesBeforeRedeem = vault.balanceOf(treasury);
        uint256 supplyBeforeRedeem = vault.totalSupply();
        vm.prank(minter);
        (uint256 targetOut, uint256 counterOut) =
            vault.redeem(shares, 1, 1, minter, block.timestamp);
        assertGt(targetOut, 0);
        assertGt(counterOut, 0);
        assertEq(vault.balanceOf(minter), 0);
        assertEq(vault.balanceOf(treasury) - treasurySharesBeforeRedeem, redeemFeeShares);
        assertEq(supplyBeforeRedeem - vault.totalSupply(), shares - redeemFeeShares);
    }

    function _launch(
        address target,
        PoolKey memory key,
        uint256 targetAmount,
        uint256 counterAmount
    ) private returns (LpTokenVault vault) {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        ILpTokenFactory.LaunchParams memory params = ILpTokenFactory.LaunchParams({
            target: target,
            poolKey: key,
            targetAmount: targetAmount,
            counterAmount: counterAmount,
            expectedTick: tick,
            maxTickDeviation: 100,
            minExistingLiquidity: 1,
            minLiquidityAdded: 1,
            minShares: 1,
            receiver: owner,
            deadline: block.timestamp
        });
        address predicted = factory.predictVault(target, key);
        MockERC20(target).mint(owner, targetAmount);
        vm.prank(owner);
        MockERC20(target).approve(predicted, type(uint256).max);
        bool nativeCounter = key.currency0.isAddressZero();
        uint256 value;
        if (nativeCounter) {
            vm.deal(owner, counterAmount);
            value = counterAmount;
        } else {
            Currency counterCurrency =
                Currency.unwrap(key.currency0) == target ? key.currency1 : key.currency0;
            MockERC20 counterToken = MockERC20(Currency.unwrap(counterCurrency));
            counterToken.mint(owner, counterAmount);
            vm.prank(owner);
            counterToken.approve(predicted, type(uint256).max);
        }
        vm.prank(owner);
        (address vaultAddress,,) = factory.launch{ value: value }(params);
        vault = LpTokenVault(payable(vaultAddress));
    }

    function _createLivePool(PoolKey memory key) private {
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        uint256 value;
        if (key.currency0.isAddressZero()) {
            vm.deal(address(this), address(this).balance + 1e22);
            value = 1e22;
        } else {
            MockERC20 token0 = MockERC20(Currency.unwrap(key.currency0));
            token0.mint(address(this), 1e30);
            token0.approve(address(liquidityRouter), type(uint256).max);
        }
        MockERC20 token1 = MockERC20(Currency.unwrap(key.currency1));
        token1.mint(address(this), 1e30);
        token1.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{ value: value }(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: 1e21,
                salt: bytes32(0)
            }),
            bytes("")
        );
    }

    function _universalSwap(PoolKey memory key, bool zeroForOne, uint256 amountIn)
        private
        returns (uint256 amountOut)
    {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        uint256 value;
        if (input.isAddressZero()) {
            vm.deal(address(this), address(this).balance + amountIn);
            value = amountIn;
        } else {
            address inputToken = Currency.unwrap(input);
            uint256 balance = IERC20(inputToken).balanceOf(address(this));
            if (balance < amountIn) MockERC20(inputToken).mint(address(this), amountIn - balance);
            // Mirrors the app: top up only when the standing allowance is short, which the
            // protocol's own tokens never are.
            if (IERC20(inputToken).allowance(address(this), PERMIT2) < amountIn) {
                IERC20(inputToken).approve(PERMIT2, type(uint256).max);
            }
            IAllowanceTransfer(PERMIT2)
                .approve(
                    inputToken,
                    UNIVERSAL_ROUTER,
                    amountIn.toUint160(),
                    uint48(block.timestamp + 1 days)
                );
        }

        uint256 outputBefore = _currencyBalance(output, address(this));
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn.toUint128(),
                amountOutMinimum: 1,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(input, amountIn);
        params[2] = abi.encode(output, uint256(1));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        IUniversalRouter(UNIVERSAL_ROUTER).execute{ value: value }(
            abi.encodePacked(V4_SWAP_COMMAND), inputs, block.timestamp
        );
        amountOut = _currencyBalance(output, address(this)) - outputBefore;
        assertGt(amountOut, 0);
    }

    function _universalExactOutputSwap(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountOut,
        uint256 maximumIn,
        uint256 deadline
    ) private {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountOut: amountOut.toUint128(),
                amountInMaximum: maximumIn.toUint128(),
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(input, maximumIn);
        params[2] = abi.encode(output, amountOut);

        bool nativeInput = input.isAddressZero();
        bytes[] memory inputs = new bytes[](nativeInput ? 2 : 1);
        inputs[0] = abi.encode(actions, params);
        bytes memory commands = abi.encodePacked(V4_SWAP_COMMAND);
        if (nativeInput) {
            commands = abi.encodePacked(V4_SWAP_COMMAND, SWEEP_COMMAND);
            inputs[1] = abi.encode(address(0), address(1), uint256(0));
        }
        IUniversalRouter(UNIVERSAL_ROUTER).execute{ value: nativeInput ? maximumIn : 0 }(
            commands, inputs, deadline
        );
    }

    function _quoteExactOutput(PoolKey memory key, bool zeroForOne, uint256 amountOut)
        private
        returns (uint256 amountIn)
    {
        (amountIn,) = IV4Quoter(V4_QUOTER)
            .quoteExactOutputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    exactAmount: amountOut.toUint128(),
                    hookData: bytes("")
                })
            );
    }

    function _currencyBalance(Currency currency, address account) private view returns (uint256) {
        if (currency.isAddressZero()) return account.balance;
        return IERC20(Currency.unwrap(currency)).balanceOf(account);
    }

    function _deployLaunchpad() private returns (TokenLaunchpad launchpad) {
        launchpad = _deployLaunchpad(manager, factory, 198_000, 0.001 ether);
        vm.prank(owner);
        factory.bindLaunchpad(address(launchpad));
    }

    function _launchMetadata() private pure returns (TokenLaunchpad.TokenMetadata memory metadata) {
        metadata = TokenLaunchpad.TokenMetadata({
            name: "Fork Launch",
            symbol: "FLAUNCH",
            imageUrl: "ipfs://fork-launch",
            websiteUrl: "https://example.com",
            twitterHandle: "fork_launch",
            telegramHandle: "fork_launch_chat"
        });
    }

    function _sortedKey(address a, address b) private pure returns (PoolKey memory key) {
        (address token0, address token1) = a < b ? (a, b) : (b, a);
        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function _wethUsdgKey() private pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDG),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }
}
