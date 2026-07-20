#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"

out="$(bash "$here/../build-runtime.sh" --print-flags --variant default)"
assert_contains "$out" "-DIREE_BUILD_COMPILER=OFF"       "print-flags shows compiler off"
assert_contains "$out" "-DIREE_HAL_DRIVER_LOCAL_TASK=ON" "print-flags shows variant flags"

# --print-flags must not need a source tree or a container.
if bash "$here/../build-runtime.sh" --print-flags --variant default >/dev/null 2>&1; then
  echo "ok: print-flags works with no --iree-src"
else echo "FAIL: print-flags must not require --iree-src" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
exit "$ASSERT_FAILS"
