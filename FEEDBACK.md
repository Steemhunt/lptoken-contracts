# Uniswap v4 developer feedback

Notes from building lpTOKEN on Uniswap v4 and bringing the same contracts to Arc mainnet
during ETHOnline 2026. Each point says what we ran into and where it shows up in this
repository. Facts about external docs were checked on September 11, 2026.

## 1. Native currency is not always ETH

On Arc, `Currency.wrap(address(0))` is USDC with 18 decimals. The USDC ERC-20 at
`0x3600000000000000000000000000000000000000` is the same balance with 6 decimals. It is
an interface on that balance, not a WETH style wrapper.

What this meant for us:

- `ZapRouter` expects a WETH9 style `deposit` and `withdraw`. On Arc we shipped a
  separate [`ZapRouterArc`](src/periphery/ZapRouterArc.sol) that converts between the
  two units instead. The shared core contracts stayed unchanged.
- The guidance we found disagrees on which USDC a pool should use. Arc's general AMM
  guidance points to the ERC-20. Uniswap's Arc Instant Launch builds native USDC pools.
  We went with native USDC, partly because 6 decimals round badly on very small amounts.

A recommendation for v4 pools on chains like this, and native currency metadata per chain
in the SDK, would help integrators.

## 2. The hook self-call exemption

[`TokenLaunchpad`](src/TokenLaunchpad.sol) is an initializer-only hook. Its
`beforeInitialize` always reverts, and the launchpad can still open its own pools, because
v4 skips a hook's callbacks when the hook itself is the caller. Our whole initialization
gate depends on that rule.

We found the rule only as a one-line comment on the `noSelfCall` modifier in `Hooks.sol`
and in an archived library reference page. The hooks concepts page does not mention it. A
sentence there would help anyone building a similar gate.

## 3. Deployment blocks on the deployments page

Reproducible fork runs in this repository pin `FORK_BLOCK_NUMBER` on an archive node, and
that block has to come after PoolManager, Universal Router and Permit2 exist on the chain.
The v4 deployments page lists addresses only, so those blocks have to be found elsewhere. A
deployment block column would help. Arc is not on the page yet either.
