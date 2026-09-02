// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.36;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { LpTokenVault } from "../src/LpTokenVault.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { LpTokenTestBase } from "./utils/LpTokenTestBase.sol";

/// @notice State-changing vault flows pass one decoded immutable context through their helper
/// graph. These tests pin the observable identity and per-clone isolation of that context.
contract VaultContextTest is LpTokenTestBase {
    PoolKey internal keyA;
    PoolKey internal keyB;
    LpTokenVault internal vaultA;
    LpTokenVault internal vaultB;

    function setUp() public override {
        super.setUp();
        keyA = _erc20Key(address(cashcat), address(usdg));
        _initLivePool(keyA, 0);
        vaultA = _launch(address(cashcat), keyA, 1_000e18, 1_000e18);

        // A second vault with a different orientation, counter, and fee makes any accidental
        // reuse of the first vault's context observable.
        keyB = _erc20Key(address(tok8), address(weth), 3_000, 60);
        _initLivePool(keyB, 0);
        vaultB = _launch(address(tok8), keyB, 1_000e8, 1_000e18);
    }

    function _snapshotIdentity(LpTokenVault vault) private view returns (bytes memory identity) {
        return abi.encode(
            vault.target(),
            vault.counter(),
            vault.currency0(),
            vault.currency1(),
            vault.lpFee(),
            vault.tickSpacing(),
            vault.targetIsCurrency0(),
            vault.counterIsNative(),
            vault.launchFeeSource(),
            address(vault.poolKey().hooks),
            vault.poolId()
        );
    }

    /// @dev A real state-changing flow must preserve every argument-derived view.
    function testContextPreservesEveryDerivedGetter() public {
        bytes memory before = _snapshotIdentity(vaultA);

        MockERC20(address(cashcat)).mint(address(this), 100e18);
        MockERC20(address(usdg)).mint(address(this), 100e18);
        cashcat.approve(address(vaultA), type(uint256).max);
        usdg.approve(address(vaultA), type(uint256).max);
        vaultA.mintPair(100e18, 100e18, 0, address(this), block.timestamp);

        assertEq(
            keccak256(_snapshotIdentity(vaultA)),
            keccak256(before),
            "an argument-derived view changed after the context was used"
        );
    }

    /// @dev Two vaults exercised in one transaction must each use their own clone arguments.
    function testContextUsesEachClonesImmutableArgs() public {
        bytes memory identityA = _snapshotIdentity(vaultA);
        bytes memory identityB = _snapshotIdentity(vaultB);
        assertTrue(keccak256(identityA) != keccak256(identityB), "vaults are not distinct");

        // Exercise A, then confirm B still reports itself, not A.
        MockERC20(address(cashcat)).mint(address(this), 100e18);
        MockERC20(address(usdg)).mint(address(this), 100e18);
        cashcat.approve(address(vaultA), type(uint256).max);
        usdg.approve(address(vaultA), type(uint256).max);
        vaultA.mintPair(100e18, 100e18, 0, address(this), block.timestamp);
        assertEq(keccak256(_snapshotIdentity(vaultB)), keccak256(identityB), "B used A's context");

        // Exercise B in the same transaction and confirm A is still A.
        MockERC20(address(tok8)).mint(address(this), 100e8);
        MockERC20(address(weth)).mint(address(this), 100e18);
        tok8.approve(address(vaultB), type(uint256).max);
        weth.approve(address(vaultB), type(uint256).max);
        vaultB.mintPair(100e8, 100e18, 0, address(this), block.timestamp);
        assertEq(keccak256(_snapshotIdentity(vaultA)), keccak256(identityA), "A used B's context");
    }
}
