#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
d="$here/../scripts/derive-version.sh"

out="$(bash "$d" v3.11.0-1)"
assert_contains "$out" "IREE_VERSION=3.11.0"      "derives IREE version"
assert_contains "$out" "IREE_TAG=v3.11.0"          "derives IREE tag"
assert_contains "$out" "COMPILER_VERSION=3.11.0"   "compiler version matches runtime version"

# pkgrev only re-rolls the same version; it must not leak into the version itself.
out2="$(bash "$d" v3.11.0-7)"
assert_contains "$out2" "IREE_VERSION=3.11.0"      "pkgrev does not change version"

# Malformed tags must fail loudly, not silently produce garbage.
if bash "$d" 3.11.0 >/dev/null 2>&1; then
  echo "FAIL: tag without v prefix should be rejected" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else echo "ok: rejects tag without v prefix"; fi
if bash "$d" v3.11.0 >/dev/null 2>&1; then
  echo "FAIL: tag without pkgrev should be rejected" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else echo "ok: rejects tag without pkgrev"; fi
exit "$ASSERT_FAILS"
