#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/relocatability.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/lib/cmake/IREE"

# A config leaking an absolute install prefix, as CMake sometimes emits.
cat > "$tmp/lib/cmake/IREE/IREETargets-Runtime.cmake" <<EOF
set_target_properties(iree_base_base PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES "$tmp/include"
  INTERFACE_LINK_LIBRARIES "/usr/lib64/libm.so;/usr/lib64/libdl.so"
)
EOF
# Build-tree metadata that must never ship.
touch "$tmp/CMakeCache.txt" "$tmp/compile_commands.json"

relocatability_repair "$tmp"

got="$(cat "$tmp/lib/cmake/IREE/IREETargets-Runtime.cmake")"
assert_contains "$got" '${PACKAGE_PREFIX_DIR}/include' "absolute prefix rewritten"
assert_contains "$got" "-lm"  "absolute libm normalized to -lm"
assert_contains "$got" "-ldl" "absolute libdl normalized to -ldl"

if [ -e "$tmp/CMakeCache.txt" ]; then
  echo "FAIL: CMakeCache.txt must be removed" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else echo "ok: CMakeCache.txt removed"; fi
if [ -e "$tmp/compile_commands.json" ]; then
  echo "FAIL: compile_commands.json must be removed" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else echo "ok: compile_commands.json removed"; fi

# A clean prefix passes the assertion.
if relocatability_assert "$tmp" "/nonexistent/build" "/nonexistent/src" >/dev/null 2>&1; then
  echo "ok: clean prefix passes assertion"
else echo "FAIL: clean prefix should pass" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

# A prefix with a leaked build path fails it.
mkdir -p "$tmp/lib/cmake/IREE"
echo 'set(X "/build/tree/here")' > "$tmp/lib/cmake/IREE/leak.cmake"
if relocatability_assert "$tmp" "/build/tree" "/nonexistent/src" >/dev/null 2>&1; then
  echo "FAIL: leaked build path should fail the assertion" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else echo "ok: leaked build path fails the assertion"; fi

# --- Matcher gap regression: build+src needle boundary rule -----------------
# Each case gets its own fresh single-file prefix so results can't be
# confounded by another case's content living in the same tree.
BUILD_NEEDLE="/work/iree-build-default"
SRC_NEEDLE="/iree"

# assert_flagged/assert_not_flagged <case-name> <file-content>
assert_flagged() {
  local name="$1" content="$2" d
  d="$(mktemp -d)"
  printf '%s\n' "$content" > "$d/sample.txt"
  if relocatability_assert "$d" "$BUILD_NEEDLE" "$SRC_NEEDLE" >/dev/null 2>&1; then
    echo "FAIL: $name should be flagged" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
  else echo "ok: $name flagged"; fi
  rm -rf "$d"
}
assert_not_flagged() {
  local name="$1" content="$2" d
  d="$(mktemp -d)"
  printf '%s\n' "$content" > "$d/sample.txt"
  if relocatability_assert "$d" "$BUILD_NEEDLE" "$SRC_NEEDLE" >/dev/null 2>&1; then
    echo "ok: $name not flagged"
  else echo "FAIL: $name should not be flagged" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
  rm -rf "$d"
}

assert_flagged     "quoted abs src"      'set(X "/iree/runtime/src")'
assert_flagged     "-I flag abs src"     'target_compile_options(t -I/iree/runtime/src)'
assert_flagged     "abs build dir"       'set(Y "/work/iree-build-default/lib")'
assert_flagged     "bare abs at BOL"     '/iree/runtime/src/foo.c'
assert_not_flagged "relative include"    '#include "iree/base/api.h"'
assert_not_flagged "relative __FILE__"   'static const char f[] = "iree/vm/context.c";'
assert_not_flagged "nested src path"     'runtime/src/iree/async/foo.c'
assert_not_flagged "upstream URL"        '// see https://github.com/iree-org/iree/blob/main/x.md'

exit "$ASSERT_FAILS"
