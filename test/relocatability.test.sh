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
assert_flagged     "-iquote flag abs src"    'target_compile_options(t -iquote/iree/runtime/src)'
assert_flagged     "-isysroot flag abs src"  'target_compile_options(t -isysroot/iree)'
assert_not_flagged "relative include"    '#include "iree/base/api.h"'
assert_not_flagged "relative __FILE__"   'static const char f[] = "iree/vm/context.c";'
assert_not_flagged "nested src path"     'runtime/src/iree/async/foo.c'
assert_not_flagged "upstream URL"        '// see https://github.com/iree-org/iree/blob/main/x.md'

# --- flatcc schema target -I leak (Task 5b) ---------------------------------
# flatcc's *_c_fbs schema targets embedded the build container's source mount
# as raw "-I/abs/path" tokens in INTERFACE_COMPILE_OPTIONS, which the
# ${PACKAGE_PREFIX_DIR} rewrite above never touches (it only rewrites the
# staged prefix path, and it operates on paths, not compiler-flag strings).
# Fresh single-file prefix, per case, so this can't be confounded by any
# other case's content living in the same tree.
flatcc_tmp="$(mktemp -d)"
mkdir -p "$flatcc_tmp/lib/cmake/IREE"
cat > "$flatcc_tmp/lib/cmake/IREE/IREETargets-Runtime.cmake" <<'EOF'
# Create imported target iree_schemas_webgpu_executable_def_c_fbs
add_library(iree_schemas_webgpu_executable_def_c_fbs INTERFACE IMPORTED)

set_target_properties(iree_schemas_webgpu_executable_def_c_fbs PROPERTIES
  INTERFACE_COMPILE_OPTIONS "-I/iree/third_party/flatcc/include/;-I/iree/third_party/flatcc/include/flatcc/reflection/"
  INTERFACE_INCLUDE_DIRECTORIES "${_IMPORT_PREFIX}/include"
  INTERFACE_LINK_LIBRARIES "-lm"
  iree_ALIAS_TO "iree::schemas::webgpu_executable_def_c_fbs"
)
EOF

relocatability_repair "$flatcc_tmp"
got_flatcc="$(cat "$flatcc_tmp/lib/cmake/IREE/IREETargets-Runtime.cmake")"

case "$got_flatcc" in
  *"/iree/third_party/flatcc"*)
    echo "FAIL: leaked flatcc -I path should be stripped" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) echo "ok: leaked flatcc -I path stripped" ;;
esac
# Option B (strip, not relocate): the flags were dead weight, not a real
# compile requirement, so no ${PACKAGE_PREFIX_DIR}-relative replacement is
# expected here -- unlike the absolute-install-prefix case above.
case "$got_flatcc" in
  *'INTERFACE_COMPILE_OPTIONS'*)
    echo "FAIL: emptied INTERFACE_COMPILE_OPTIONS line should be dropped" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) echo "ok: emptied INTERFACE_COMPILE_OPTIONS line dropped" ;;
esac
assert_contains "$got_flatcc" '-lm' "sibling INTERFACE_LINK_LIBRARIES property untouched"
assert_contains "$got_flatcc" 'iree_schemas_webgpu_executable_def_c_fbs' "target definition untouched"

# Same leak, Windows form. This is not hypothetical: the first real Windows
# artifact (run 30284606833) shipped
#   -ID:/a/iree-runtime-dist/iree-runtime-dist/iree/third_party/flatcc/include/
# in IREETargets-Runtime.cmake, because the repair's pattern required the
# character after -I to be "/" and a Windows absolute path starts with a drive
# letter. relocatability_assert did not catch it either: on Windows it is
# invoked with POSIX-form needles (/d/a/...) while everything cmake and cl bake
# in is Windows-form.
flatcc_win="$(mktemp -d)"
mkdir -p "$flatcc_win/lib/cmake/IREE"
cat > "$flatcc_win/lib/cmake/IREE/IREETargets-Runtime.cmake" <<'EOF'
set_target_properties(iree_schemas_webgpu_executable_def_c_fbs PROPERTIES
  INTERFACE_COMPILE_OPTIONS "-ID:/a/iree-runtime-dist/iree-runtime-dist/iree/third_party/flatcc/include/;-ID:/a/iree-runtime-dist/iree-runtime-dist/iree/third_party/flatcc/include/flatcc/reflection/"
  INTERFACE_LINK_LIBRARIES "-pdbpagesize:32768"
)
EOF
relocatability_repair "$flatcc_win"
got_flatcc_win="$(cat "$flatcc_win/lib/cmake/IREE/IREETargets-Runtime.cmake")"
case "$got_flatcc_win" in
  *'D:/a/'*|*'D:\a\'*)
    echo "FAIL: windows-form flatcc -I path should be stripped" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) echo "ok: windows-form flatcc -I path stripped" ;;
esac
assert_contains "$got_flatcc_win" '-pdbpagesize:32768' "windows sibling link property untouched"

# A RELATIVE -I is not a build-machine path and must survive: the broadened
# pattern must not turn into "strip every -I".
flatcc_rel="$(mktemp -d)"
mkdir -p "$flatcc_rel/lib/cmake/IREE"
cat > "$flatcc_rel/lib/cmake/IREE/IREETargets-Runtime.cmake" <<'EOF'
set_target_properties(t PROPERTIES
  INTERFACE_COMPILE_OPTIONS "-Iinclude/flatcc"
)
EOF
relocatability_repair "$flatcc_rel"
assert_contains "$(cat "$flatcc_rel/lib/cmake/IREE/IREETargets-Runtime.cmake")" \
  '-Iinclude/flatcc' "relative -I option left untouched"

if relocatability_assert "$flatcc_tmp" "/work/iree-build-default" "/iree" >/dev/null 2>&1; then
  echo "ok: flatcc-leak prefix passes assertion after repair"
else echo "FAIL: flatcc-leak prefix should pass assertion after repair" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

# Idempotency: a second repair pass must not error and must not change output.
before_flatcc="$got_flatcc"
relocatability_repair "$flatcc_tmp"
after_flatcc="$(cat "$flatcc_tmp/lib/cmake/IREE/IREETargets-Runtime.cmake")"
if [ "$before_flatcc" = "$after_flatcc" ]; then
  echo "ok: flatcc repair is idempotent"
else echo "FAIL: second repair pass changed output" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

rm -rf "$flatcc_tmp"

# --- Metacharacter-path repair (Finding A regression) -----------------------
# $abs (the prefix's own absolute path) was previously used unescaped both as
# a grep pattern and as a sed s/// LHS with "|" as delimiter. A prefix path
# containing regex metacharacters (".") over-matches; one containing "|"
# breaks the sed delimiter outright. Use a fresh, hermetic, single-file
# prefix whose path contains both, named literally so the on-disk directory
# is the thing under test (not a symlink or a synthetic string).
meta_tmp="$(mktemp -d "/tmp/relocatability-test-pre.fix-v1.0|part.XXXXXX")"
mkdir -p "$meta_tmp/lib/cmake/IREE"
meta_abs="$(cd "$meta_tmp" && pwd)"
cat > "$meta_tmp/lib/cmake/IREE/IREETargets-Runtime.cmake" <<EOF
set_target_properties(iree_base_base PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES "$meta_abs/include"
)
EOF

relocatability_repair "$meta_tmp"
got_meta="$(cat "$meta_tmp/lib/cmake/IREE/IREETargets-Runtime.cmake")"

assert_contains "$got_meta" '${PACKAGE_PREFIX_DIR}/include' "metacharacter-path prefix rewritten correctly"
case "$got_meta" in
  *"$meta_abs"*)
    echo "FAIL: metacharacter path leak survived repair" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) echo "ok: metacharacter path fully rewritten, no leak survives" ;;
esac

rm -rf "$meta_tmp"

# --- RELOC_ALLOW_DEBUG_PATHS must exempt ONLY debug-section paths ------------
# Sanitizer variants build with -g, whose DWARF embeds the build dir. The flag
# lets the assertion ignore build paths that live only in an object's debug
# sections -- but a leak in a text/config file is never debug info and must
# still fail, flag or not. (The binary/debug-only exemption itself is validated
# in-container by the real tsan build, because host grep matches binary content
# differently; here we lock down the teeth that ARE host-reliable: a .cmake leak
# is always caught.)
dbg_tmp="$(mktemp -d)"
mkdir -p "$dbg_tmp/lib/cmake/IreeRuntimeDist"
printf 'set(LEAK "/work/iree-build-tsan/x")\n' > "$dbg_tmp/lib/cmake/IreeRuntimeDist/Config.cmake"

if RELOC_ALLOW_DEBUG_PATHS=1 relocatability_assert "$dbg_tmp" /work/iree-build-tsan /nonexistent-src >/dev/null 2>&1; then
  echo "FAIL: RELOC_ALLOW_DEBUG_PATHS wrongly exempted a leak in a .cmake text file" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok: debug-path exemption still catches a non-debug (.cmake) leak"
fi

# And a clean prefix must pass with the flag on (no false positive).
clean_tmp="$(mktemp -d)"; mkdir -p "$clean_tmp/lib"
printf 'relative/path/only\n' > "$clean_tmp/lib/ok.cmake"
if RELOC_ALLOW_DEBUG_PATHS=1 relocatability_assert "$clean_tmp" /work/iree-build-tsan /nonexistent-src >/dev/null 2>&1; then
  echo "ok: clean prefix passes with the flag on"
else
  echo "FAIL: flag produced a false positive on a clean prefix" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi
rm -rf "$dbg_tmp" "$clean_tmp"

# --- COFF (.lib/.obj) awareness ---------------------------------------------
# A leaked path in a Windows .lib must be caught. The existing case pattern is
# *.a|*.o|*.so|*.so.*, so a .lib falls through to the "always real" branch --
# correct by accident today, asserted deliberately here.
win_tmp="$(mktemp -d)"; mkdir -p "$win_tmp/lib"
printf 'C:\\Users\\builder\\workspace\\iree-build\\junk\n' > "$win_tmp/lib/leaky.lib"
if relocatability_assert "$win_tmp" 'C:\Users\builder\workspace\iree-build' 'C:\Users\builder\workspace\iree' >/dev/null 2>&1; then
  echo "FAIL: a leaked build path in a .lib was not caught" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok: leaked build path in a .lib is caught"
fi
rm -rf "$win_tmp"

# The debug-path exemption must NOT rescue a .lib, even when enabled: the paths
# it would need to exempt are __FILE__ string constants, not debug sections.
win2="$(mktemp -d)"; mkdir -p "$win2/lib"
printf 'C:\\Users\\builder\\workspace\\iree\\runtime\\src\\iree\\base\\allocator.c\n' > "$win2/lib/file.lib"
if RELOC_ALLOW_DEBUG_PATHS=1 relocatability_assert "$win2" 'C:\Users\builder\workspace\iree-build' 'C:\Users\builder\workspace\iree' >/dev/null 2>&1; then
  echo "FAIL: RELOC_ALLOW_DEBUG_PATHS wrongly exempted a __FILE__ leak in a .lib" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok: exemption does not rescue a __FILE__ leak in a .lib"
fi
rm -rf "$win2"

# A missing/failing strip tool must NOT cause an exemption -- and this must
# be proven deterministically, not merely observed on whatever the current
# host happens to have installed. A host WITH llvm-objcopy present is
# exactly the environment where the fail-open risk is live, so relying on
# "this host happens to lack it" would silently skip the regression on the
# hosts that matter most. Force both scenarios with a PATH shim containing
# only the external commands relocatability_assert's exemption path needs
# (sed, grep, mktemp, rm) -- llvm-objcopy is deliberately absent from it,
# or present-but-failing, regardless of what the real host provides.
shim_dir="$(mktemp -d)"
for _tool in sed grep mktemp rm; do
  ln -s "$(command -v "$_tool")" "$shim_dir/$_tool"
done
old_path="$PATH"

# Case A: no llvm-objcopy resolves at all (not on PATH under any name).
# The `&&` short-circuit on the failed `command -v`/exec inside
# relocatability_assert's coff_strip_tool resolution should leave
# coff_strip_tool empty, and the .lib branch should treat the hit as real --
# never fail open. This is the direct regression test for that failure mode:
# if a future refactor drops the `-n "$coff_strip_tool"` guard or the `&&`
# short-circuit, this is what would start silently exempting real leaks.
missing_tool_tmp="$(mktemp -d)"; mkdir -p "$missing_tool_tmp/lib"
printf 'C:\\Users\\builder\\workspace\\iree-build\\junk\n' > "$missing_tool_tmp/lib/leaky.obj"
PATH="$shim_dir"
if RELOC_ALLOW_DEBUG_PATHS=1 relocatability_assert "$missing_tool_tmp" 'C:\Users\builder\workspace\iree-build' 'C:\Users\builder\workspace\iree' >/dev/null 2>&1; then
  echo "FAIL: no COFF strip tool on PATH caused the leak to be silently exempted" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok: no COFF strip tool on PATH does not fail open -- leak still caught"
fi
PATH="$old_path"
rm -rf "$missing_tool_tmp"

# Case B: llvm-objcopy exists on PATH but fails -- the more realistic
# failure mode (a tool that's present but can't parse the input) -- must
# also not cause an exemption.
cat > "$shim_dir/llvm-objcopy" <<'SHIM'
#!/bin/sh
exit 1
SHIM
chmod +x "$shim_dir/llvm-objcopy"
failing_tool_tmp="$(mktemp -d)"; mkdir -p "$failing_tool_tmp/lib"
printf 'C:\\Users\\builder\\workspace\\iree-build\\junk\n' > "$failing_tool_tmp/lib/leaky.obj"
PATH="$shim_dir"
if RELOC_ALLOW_DEBUG_PATHS=1 relocatability_assert "$failing_tool_tmp" 'C:\Users\builder\workspace\iree-build' 'C:\Users\builder\workspace\iree' >/dev/null 2>&1; then
  echo "FAIL: a present-but-failing llvm-objcopy caused the leak to be silently exempted" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok: a present-but-failing llvm-objcopy does not fail open -- leak still caught"
fi
PATH="$old_path"
rm -rf "$failing_tool_tmp" "$shim_dir"

# --- -natvis: absolute path repair (Task 9) ----------------------------------
# -natvis: carries an absolute SOURCE path into INTERFACE_LINK_LIBRARIES, so a
# consumer on any other machine gets a dangling flag on their link line. A .cmake
# file is a text file and is never exempt from the assertion.
nat="$(mktemp -d)"; mkdir -p "$nat/lib/cmake/IREE"
cat > "$nat/lib/cmake/IREE/IREETargets-Runtime.cmake" <<'X'
set_target_properties(iree_runtime_impl PROPERTIES
  INTERFACE_LINK_LIBRARIES "flatcc_parsing;-natvis:C:/Users/builder/workspace/iree/runtime/iree.natvis;-pdbpagesize:32768"
)
X
relocatability_repair "$nat" 'C:\Users\builder\workspace\iree-build' 'C:/Users/builder/workspace/iree'
if grep -q 'natvis:C:' "$nat/lib/cmake/IREE/IREETargets-Runtime.cmake"; then
  echo "FAIL: -natvis: absolute path survived the repair" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok: -natvis: absolute path repaired"
fi
# The repair must be surgical: sibling entries stay intact.
assert_contains "$(cat "$nat/lib/cmake/IREE/IREETargets-Runtime.cmake")" "flatcc_parsing"     "sibling link entry untouched"
assert_contains "$(cat "$nat/lib/cmake/IREE/IREETargets-Runtime.cmake")" "-pdbpagesize:32768" "sibling linker flag untouched"
# No empty list element (doubled ';;' or stray leading/trailing ';' next to
# the surrounding quotes) left behind.
got_nat="$(cat "$nat/lib/cmake/IREE/IREETargets-Runtime.cmake")"
if printf '%s' "$got_nat" | grep -Eq -- ';;|"[[:space:]]*;|;[[:space:]]*"'; then
  echo "FAIL: -natvis: repair left an empty list element" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok: -natvis: repair left no empty list element"
fi
assert_contains "$got_nat" 'INTERFACE_LINK_LIBRARIES "flatcc_parsing;-pdbpagesize:32768"' "-natvis: entry cleanly excised"

# Idempotency: a second repair pass on an already-repaired file is a no-op.
before_nat="$got_nat"
relocatability_repair "$nat"
after_nat="$(cat "$nat/lib/cmake/IREE/IREETargets-Runtime.cmake")"
if [ "$before_nat" = "$after_nat" ]; then
  echo "ok: -natvis: repair is idempotent"
else
  echo "FAIL: second -natvis: repair pass changed output" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
fi
rm -rf "$nat"

# Real leaks observed in the wild use forward slashes (CMake normalises export
# paths), but a raw backslash-separated Windows path must be caught too.
natbs="$(mktemp -d)"; mkdir -p "$natbs/lib/cmake/IREE"
printf 'set_target_properties(iree_runtime_impl PROPERTIES\n  INTERFACE_LINK_LIBRARIES "flatcc_parsing;-natvis:C:\\\\Users\\\\builder\\\\workspace\\\\iree\\\\runtime\\\\iree.natvis;-pdbpagesize:32768"\n)\n' \
  > "$natbs/lib/cmake/IREE/IREETargets-Runtime.cmake"
relocatability_repair "$natbs"
got_natbs="$(cat "$natbs/lib/cmake/IREE/IREETargets-Runtime.cmake")"
case "$got_natbs" in
  *'natvis:C:'*)
    echo "FAIL: backslash-style -natvis: absolute path survived the repair" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) echo "ok: backslash-style -natvis: absolute path repaired" ;;
esac
assert_contains "$got_natbs" "flatcc_parsing"     "backslash case: sibling link entry untouched"
assert_contains "$got_natbs" "-pdbpagesize:32768" "backslash case: sibling linker flag untouched"
rm -rf "$natbs"

# A fixture with no -natvis: entry at all must be left byte-identical.
clean_nat="$(mktemp -d)"; mkdir -p "$clean_nat/lib/cmake/IREE"
cat > "$clean_nat/lib/cmake/IREE/IREETargets-Runtime.cmake" <<'X'
set_target_properties(iree_runtime_impl PROPERTIES
  INTERFACE_LINK_LIBRARIES "flatcc_parsing;-pdbpagesize:32768"
)
X
sha_before="$(sha256sum "$clean_nat/lib/cmake/IREE/IREETargets-Runtime.cmake" | cut -d' ' -f1)"
relocatability_repair "$clean_nat"
sha_after="$(sha256sum "$clean_nat/lib/cmake/IREE/IREETargets-Runtime.cmake" | cut -d' ' -f1)"
if [ "$sha_before" = "$sha_after" ]; then
  echo "ok: fixture without -natvis: left byte-identical"
else
  echo "FAIL: fixture without -natvis: was modified" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
fi
rm -rf "$clean_nat"

exit "$ASSERT_FAILS"
