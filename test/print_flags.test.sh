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

out_default="$(bash "$here/../build-runtime.sh" --print-flags --variant default)"
assert_contains "$out_default" "compiler_flags:" "print-flags reports compiler flags"
case "$out_default" in *"-fsanitize=thread"*) echo "FAIL: default must not be instrumented" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1));; *) echo "ok: default not instrumented";; esac

out_tsan="$(bash "$here/../build-runtime.sh" --print-flags --variant tsan)"
assert_contains "$out_tsan" "-fsanitize=thread" "tsan print-flags shows the sanitizer"
assert_contains "$out_tsan" "-ffile-prefix-map=" "tsan still carries the relocatability prefix-map"

exit "$ASSERT_FAILS"
