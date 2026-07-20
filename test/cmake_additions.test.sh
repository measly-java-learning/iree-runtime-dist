#!/usr/bin/env bash
# Usage: cmake_additions.test.sh <prefix>. Skips when no prefix given.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
prefix="${1:-}"
if [ -z "$prefix" ]; then echo "skip: cmake_additions.test.sh needs a built prefix"; exit 0; fi

v="$prefix/lib/cmake/IREE/IREERuntimeConfigVersion.cmake"
if [ -s "$v" ]; then echo "ok: version file present (upstream omits it)"
else echo "FAIL: IREERuntimeConfigVersion.cmake missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

d="$prefix/lib/cmake/IreeRuntimeDist/IreeRuntimeDistConfig.cmake"
if [ -s "$d" ]; then echo "ok: dist config present"
else echo "FAIL: IreeRuntimeDistConfig.cmake missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

got="$(cat "$d" 2>/dev/null || true)"
assert_contains "$got" "iree-runtime-dist::runtime"        "umbrella target defined"
assert_contains "$got" "IREE_RUNTIME_DIST_VERSION"          "version variable exposed"
assert_contains "$got" "IREE_RUNTIME_DIST_COMPILER_VERSION" "paired compiler variable exposed"
assert_contains "$got" "IREE_RUNTIME_DIST_ADD_VMFB"         "smoke artifact path exposed"

# Dist additions must live beside upstream's config, never be edited into it.
# NOTE: a bare "iree-runtime-dist" substring check would false-positive here --
# scripts/config-deps.sh's sanctioned Threads::Threads patch (see build-runtime.sh
# Phase 1) already leaves a comment containing that substring
# ("# --- iree-runtime-dist patch: re-find external deps ---"). Check for the
# umbrella target name this task actually adds, which the sanctioned patch never
# introduces.
up="$prefix/lib/cmake/IREE/IREERuntimeConfig.cmake"
if grep -q "iree-runtime-dist::runtime" "$up" 2>/dev/null; then
  echo "FAIL: upstream IREERuntimeConfig.cmake was modified" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else echo "ok: upstream config unmodified"; fi

exit "$ASSERT_FAILS"
