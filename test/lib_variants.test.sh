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

# --- dedup override: genuinely exercise effective_cmake_flags's collision path ---
# variant_flags/default and common_flags share zero real flag names today, so
# without a synthetic collision the "variant wins" merge in effective_cmake_flags
# is never actually exercised -- concatenating both lists unconditionally would
# pass every assertion above. Stub both functions inside a subshell (stubs never
# leak to the parent shell; the real functions above are untouched) and force a
# name collision to prove the real effective_cmake_flags dedupes and picks the
# variant's value.
(
  ASSERT_FAILS=0
  variant_flags() { printf '%s\n' '-DCOLLIDE=variant-value' '-DVARIANT_ONLY=ON'; }
  common_flags()  { printf '%s\n' '-DCOLLIDE=common-value' '-DCOMMON_ONLY=ON'; }

  out="$(effective_cmake_flags default)"

  count="$(printf '%s\n' "$out" | grep -c '^-DCOLLIDE=' || true)"
  assert_eq "$count" "1" "colliding flag name appears exactly once"

  assert_contains "$out" "-DCOLLIDE=variant-value" "variant's value wins on collision"
  case "$out" in
    *"-DCOLLIDE=common-value"*)
      echo "FAIL: common value leaked through despite variant collision" >&2
      ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
    *) echo "ok: common's colliding value is suppressed" ;;
  esac

  # A filter that over-suppresses (e.g. drops everything, or drops by prefix
  # instead of exact name) would also fail these two.
  assert_contains "$out" "-DVARIANT_ONLY=ON" "non-colliding variant flag still survives"
  assert_contains "$out" "-DCOMMON_ONLY=ON"  "non-colliding common flag still survives"

  exit "$ASSERT_FAILS"
)
collision_fails=$?
ASSERT_FAILS=$((ASSERT_FAILS + collision_fails))

# --- prefix safety: -DFOO=OFF must not suppress -DFOO_EXTRA=ON ---
# The dedup match is `grep -q "^${name}="`, which requires the literal '=' right
# after the flag name. Guard this so a future refactor (e.g. switching to a
# substring or prefix match) can't silently start suppressing distinctly-named
# flags that merely share a prefix.
(
  ASSERT_FAILS=0
  variant_flags() { printf '%s\n' '-DIREE_BUILD_TESTS_EXTRA=ON'; }
  common_flags()  { printf '%s\n' '-DIREE_BUILD_TESTS=OFF'; }

  out="$(effective_cmake_flags default)"

  assert_contains "$out" "-DIREE_BUILD_TESTS_EXTRA=ON" "prefix-only match does not suppress variant flag"
  assert_contains "$out" "-DIREE_BUILD_TESTS=OFF"       "unrelated common flag with shared prefix survives"

  exit "$ASSERT_FAILS"
)
prefix_fails=$?
ASSERT_FAILS=$((ASSERT_FAILS + prefix_fails))

exit "$ASSERT_FAILS"
