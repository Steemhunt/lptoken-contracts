# Deployments

Deployment manifests are written only after receipt and runtime-wiring
validation. No production manifest exists until the replacement deployment has
been broadcast and reviewed. A production manifest must contain
chain ID, transaction hashes,
confirmed addresses, deployment blocks, constructor arguments, source commits,
runtime code hashes, and every immutable protocol constant. The confirmed
address set is `LpTokenFactory`, its vault implementation, `TokenLaunchpad`,
the shared `LaunchLiquidityVault`, `ZapRouter`, and `LpTokenLens`.
The manifest must also record the deployment signer, requested final Factory
owner, ownership-transfer transaction, and confirmed `factory.owner()` value.

Receipt validation must also confirm the initial Factory treasury and empty
pending treasury, the one-time Factory-to-Launchpad binding,
the Launchpad's Factory, PoolManager, and shared-vault immutables, the shared
vault's Launchpad, PoolManager, and Factory-derived treasury, and ZapRouter's
Factory, PoolManager, canonical stablecoin, and wrapped-native immutables. Web and
indexer configuration must use the corresponding receipt-backed addresses and
runtime hashes; guessed or zero values are not deployment manifests.

Schema version 2 keeps `contracts` as the current canonical address set and
records replaced deployments under `contractHistory`. A replacement contract
entry records its own source commit and dependency pins when they differ from
the initial deployment's top-level provenance. `receiptSummary` continues to
describe the initial protocol deployment; each replacement's confirmed receipt
is recorded on its current contract entry, while the retired entry retains its
original receipt.

The checked-in mainnet configs pin the approved initial treasury and reviewed chain
dependencies. Each deployment must produce a chain-specific manifest from its confirmed
receipts.

## Arc mainnet

[`arc-mainnet.json`](arc-mainnet.json) records the September 9, 2026 deployment on
chain 5042. Its periphery is `ZapRouterArc`; `wrappedNative()` identifies the
six-decimal USDC ERC-20 interface for ABI compatibility and does not identify a
WETH9 wrapper. Native transfers, launch seeds, and receipt fees use 18-decimal USDC.

This public record retains confirmed addresses, transaction hashes, receipts,
constructor parameters, dependency pins, source hashes, and observed wiring.
Provider credentials, local paths, unsigned execution plans, and internal
application activation notes are not part of this snapshot. Getter observations
are pinned to `verification.block` and are not a claim about current chain state.

Arc-specific source files were uncommitted when deployed. Their `sourceCommit`
remains null; `sourceSha256` identifies the exact included source. Commit IDs refer
to the originating repository and need not exist in this public clone. The
preparation hashes identify the included config and Solidity deployment script.
Explorer source verification and a mainnet token-trading round trip are not
established by the recorded receipt and runtime checks.
