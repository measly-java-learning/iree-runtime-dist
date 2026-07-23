#!/usr/bin/env bash
# Usage: cmake_additions.test.sh <prefix>. Skips when no prefix given.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"

# Hermetic: render the template with sed exactly as build-runtime.sh does, no
# build required. Runs even when no prefix is given (test/run.sh).
render() { sed -e "s|@IREE_VERSION@|3.11.0|g" -e "s|@COMPILER_VERSION@|3.11.0|g" \
  -e "s|@VARIANT@|$1|g" -e "s|@PLATFORM@|linux-x86_64|g" -e "s|@RUNTIME_COMMIT@|abc|g" \
  "$here/../cmake/IreeRuntimeDist.cmake.in"; }
d="$(render default)"; t="$(render tsan)"
case "$t" in *"-fsanitize=thread"*) echo "ok: tsan config propagates sanitizer";; *) echo "FAIL: tsan missing INTERFACE sanitizer" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1));; esac
# NOTE: the tsan-only flag lives inside a static
# `if(IREE_RUNTIME_DIST_VARIANT STREQUAL "tsan")` block in the shared template.
# sed substitution cannot strip dead CMake conditional branches (only real CMake
# evaluation can, which needs find_package(IREERuntime REQUIRED ...) to resolve
# against an actual built prefix -- not available hermetically). So the literal
# "-fsanitize=thread" text is present in BOTH renders; what must differ, and does,
# is the value fed into the guard that controls whether it ever fires. Assert that
# instead. Real gating (default binaries carry no tsan instrumentation) is proven
# at Task 9's consumer acceptance test via absence of __tsan_ symbols.
case "$d" in *'IREE_RUNTIME_DIST_VARIANT          "tsan"'*) echo "FAIL: default must not render as tsan variant" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1));; *) echo "ok: default variant guard does not select tsan";; esac
assert_contains "$t" "IREE_RUNTIME_DIST_TSAN_SUPPRESSIONS" "tsan exposes suppressions discovery var"
assert_contains "$t" "IREE_RUNTIME_DIST_SANITIZER" "tsan exposes sanitizer var"

prefix="${1:-}"
if [ -z "$prefix" ]; then echo "skip: cmake_additions.test.sh prefix checks (hermetic render checks ran)"; exit "$ASSERT_FAILS"; fi

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
