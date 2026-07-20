#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/submodules.sh"

EXPECTED="third_party/benchmark third_party/flatcc third_party/googletest third_party/hip-build-deps third_party/hsa-runtime-headers third_party/musl third_party/printf third_party/spirv_cross third_party/tracy third_party/vulkan_headers third_party/webgpu-headers"

assert_eq "$IREE_REQUIRED_SUBMODULES" "$EXPECTED" "required submodule set"
assert_eq "$(required_submodules)" "$EXPECTED" "required_submodules prints the set"

# llvm-project is 2.6 GB and unnecessary with IREE_BUILD_COMPILER=OFF.
# This assertion is the whole point of the allowlist -- do not relax it.
case "$IREE_REQUIRED_SUBMODULES" in
  *llvm-project*) echo "FAIL: llvm-project must not be required" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) echo "ok: llvm-project excluded" ;;
esac
exit "$ASSERT_FAILS"
