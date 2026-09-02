#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
FORK_SUITE="test/LpTokenFork*.t.sol"

cd "${CONTRACTS_DIR}"
export FOUNDRY_PROFILE=default

forge build --offline
forge test --offline --no-match-path "${FORK_SUITE}"

printf 'All non-fork contract tests passed; the fork suites (%s) require test/test-fork.sh.\n' "${FORK_SUITE}"
