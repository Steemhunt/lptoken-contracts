#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)

OPENZEPPELIN_COMMIT="5fd1781b1454fd1ef8e722282f86f9293cacf256"
V4_CORE_COMMIT="59d3ecf53afa9264a16bba0e38f4c5d2231f80bc"
V4_PERIPHERY_COMMIT="545a5d2a87228167edde48f3b9eda122d1e3c4d6"

fail() {
  printf 'Source pin verification failed: %s\n' "$1" >&2
  exit 1
}

verify_pin() {
  local path=$1
  local expected=$2
  local recorded
  local actual

  [ -d "$REPOSITORY_ROOT/$path" ] || fail "$path is not initialized"
  recorded=$(git -C "$REPOSITORY_ROOT" ls-files --stage -- "$path" | awk '$1 == "160000" { print $2 }')
  actual=$(git -C "$REPOSITORY_ROOT/$path" rev-parse HEAD)
  [ "$recorded" = "$expected" ] || fail "$path gitlink is ${recorded:-missing}, expected $expected"
  [ "$actual" = "$expected" ] || fail "$path worktree is $actual, expected $expected"
}

verify_pin "lib/openzeppelin-contracts" "$OPENZEPPELIN_COMMIT"
verify_pin "lib/v4-core" "$V4_CORE_COMMIT"
verify_pin "lib/v4-periphery" "$V4_PERIPHERY_COMMIT"

while IFS= read -r line; do
  [ -n "$line" ] || continue
  [ "${line:0:1}" = " " ] || fail "submodule gitlink is not clean: $line"

  path=$(printf '%s\n' "${line:1}" | awk '{ print $2 }')
  dirty=$(
    git -C "$REPOSITORY_ROOT/$path" status \
      --porcelain \
      --untracked-files=all \
      --ignore-submodules=dirty
  )
  [ -z "$dirty" ] || fail "$path worktree is dirty"
done <<< "$(git -C "$REPOSITORY_ROOT" submodule status --recursive)"

printf 'Verified pinned and clean Solidity dependencies.\n'
