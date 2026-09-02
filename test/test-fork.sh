#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
POOL_MANAGER="0x8366a39cc670b4001a1121b8f6a443a643e40951"
STATE_VIEW="0xf3334192d15450cdd385c8b70e03f9a6bd9e673b"
V4_QUOTER="0x8dc178efb8111bb0973dd9d722ebeff267c98f94"
UNIVERSAL_ROUTER="0x8876789976dEcBfCbBbe364623C63652db8C0904"
PERMIT2="0x000000000022D473030F116dDEE9F6B43aC78BA3"
USDG="0x5fc5360d0400a0fd4f2af552add042d716f1d168"
WETH="0x0bd7d308f8e1639fab988df18a8011f41eacad73"
WETH_USDG_POOL_ID="0x77c25b9386d47de62e0155c393696e9f43f7e6d036c6ca52f66735ccbb8808a7"
EXPECTED_CHAIN_ID="4663"

default_labels=("PublicNode" "NodeFlare" "Pocket Network" "Robinhood official")
default_urls=(
    "https://robinhood-rpc.publicnode.com"
    "https://rpc.nodeflare.app/robinhood/public"
    "https://robinhood.api.pocket.network"
    "https://rpc.mainnet.chain.robinhood.com"
)

if [[ -n "${FORK_BLOCK_NUMBER:-}" ]] \
    && [[ ! "${FORK_BLOCK_NUMBER}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'FORK_BLOCK_NUMBER must be a positive decimal block number.\n' >&2
    exit 1
fi

if [[ -n "${FORK_BLOCK_NUMBER:-}" && -z "${FORK_RPC_URL:-}" ]]; then
    printf 'FORK_BLOCK_NUMBER requires an explicit archive-capable FORK_RPC_URL.\n' >&2
    exit 1
fi

if [[ -n "${FORK_RPC_URL:-}" ]]; then
    labels=("configured FORK_RPC_URL")
    urls=("${FORK_RPC_URL}")
else
    labels=("${default_labels[@]}")
    urls=("${default_urls[@]}")
fi

probe_rpc() {
    local rpc_url="$1"
    local chain_id
    local code
    local block="${FORK_BLOCK_NUMBER:-latest}"
    local address

    chain_id="$(cast chain-id --rpc-url "${rpc_url}" --rpc-timeout 10 2>/dev/null)" || return 1
    [[ "${chain_id}" == "${EXPECTED_CHAIN_ID}" ]] || return 1

    for address in \
        "${POOL_MANAGER}" \
        "${STATE_VIEW}" \
        "${V4_QUOTER}" \
        "${UNIVERSAL_ROUTER}" \
        "${PERMIT2}" \
        "${USDG}" \
        "${WETH}"; do
        code="$(cast code "${address}" --block "${block}" --rpc-url "${rpc_url}" \
            --rpc-timeout 15 2>/dev/null)" || return 1
        [[ -n "${code}" && "${code}" != "0x" ]] || return 1
    done

    cast call "${STATE_VIEW}" "getSlot0(bytes32)(uint160,int24,uint24,uint24)" \
        "${WETH_USDG_POOL_ID}" --block "${block}" --rpc-url "${rpc_url}" \
        --rpc-timeout 15 >/dev/null 2>&1 || return 1

    if [[ -n "${FORK_BLOCK_NUMBER:-}" ]]; then
        cast block "${block}" --rpc-url "${rpc_url}" --rpc-timeout 15 \
            >/dev/null 2>&1 || return 1
        cast storage "${POOL_MANAGER}" 0 --block "${block}" --rpc-url "${rpc_url}" \
            --rpc-timeout 15 >/dev/null 2>&1 || return 1
        cast call "${POOL_MANAGER}" "protocolFeeController()(address)" --block "${block}" \
            --rpc-url "${rpc_url}" --rpc-timeout 15 >/dev/null 2>&1 || return 1
    fi
}

cd "${CONTRACTS_DIR}"
# Every fork suite: the deployment dry run and the compound regressions.
FORK_SUITE_PATTERN="test/LpTokenFork*.t.sol"
forge_args=(test --offline --match-path "${FORK_SUITE_PATTERN}")
if [[ -n "${FORK_BLOCK_NUMBER:-}" ]]; then
    forge_args+=(--no-storage-caching)
fi

selected_url=""
selected_label=""
for index in "${!urls[@]}"; do
    if probe_rpc "${urls[${index}]}"; then
        selected_url="${urls[${index}]}"
        selected_label="${labels[${index}]}"
        break
    fi
done

if [[ -z "${selected_url}" ]]; then
    if [[ -n "${FORK_BLOCK_NUMBER:-}" ]]; then
        printf 'The configured RPC cannot serve the required state at block %s.\n' \
            "${FORK_BLOCK_NUMBER}" >&2
        exit 1
    fi
    printf 'No Robinhood RPC passed the chain and protocol-state probes.\n' >&2
    exit 1
fi

printf 'Running Robinhood fork tests through %s at block %s.\n' \
    "${selected_label}" "${FORK_BLOCK_NUMBER:-latest}"
FOUNDRY_PROFILE=default FORK_RPC_URL="${selected_url}" forge "${forge_args[@]}"
