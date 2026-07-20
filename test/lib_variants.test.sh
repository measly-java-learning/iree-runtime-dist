#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/variants.sh"
. "$here/../scripts/lib/cmakeflags.sh"

df="$(variant_flags default)"
assert_contains "$df" "-DIREE_HAL_DRIVER_LOCAL_SYNC=ON"  "default has local-sync"
assert_contains "$df" "-DIREE_HAL_DRIVER_LOCAL_TASK=ON"  "default has local-task"
assert_contains "$df" "-DIREE_ENABLE_RUNTIME_TRACING=OFF" "default has tracing off"

cf="$(common_flags)"
assert_contains "$cf" "-DIREE_BUILD_COMPILER=OFF"        "compiler is out of contract"
assert_contains "$cf" "-DBUILD_SHARED_LIBS=OFF"          "static only"
assert_contains "$cf" "-DCMAKE_BUILD_TYPE=Release"       "release build"
assert_contains "$cf" "-DCMAKE_POSITION_INDEPENDENT_CODE=ON" "PIC on"
assert_contains "$cf" "-DIREE_ALLOCATOR_SYSTEM=libc"     "libc allocator"

ef="$(effective_cmake_flags default)"
assert_contains "$ef" "-DIREE_BUILD_COMPILER=OFF"        "effective includes common"
assert_contains "$ef" "-DIREE_HAL_DRIVER_LOCAL_TASK=ON"  "effective includes variant"

# No flag may appear twice -- a duplicate means common and variant disagree silently.
dupes="$(printf '%s\n' "$ef" | sed 's/=.*//' | sort | uniq -d)"
assert_eq "$dupes" "" "no duplicate flag names in effective set"

if variant_flags nonesuch >/dev/null 2>&1; then
  echo "FAIL: unknown variant should be rejected" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else echo "ok: rejects unknown variant"; fi
exit "$ASSERT_FAILS"
