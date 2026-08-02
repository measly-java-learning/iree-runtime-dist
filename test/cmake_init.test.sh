#!/usr/bin/env bash
# Hermetic checks on the cmake -C cache-init layer. No cmake invocation, no
# build: this asserts the files EXIST for every platform/variant the recipe
# knows about, and that the MSVC platform defaults are present.
#
# Why assert on the content of a static file at all: the -EHsc restatement
# below is not a value that might be wrong, it is a line that must not be
# DELETED. Its absence clobbers Windows-MSVC.cmake's CXX default, and every
# C++ translation unit touching <ostream> then fails C4530, which IREE's -WX
# turns into an error. That is an observed failure, not a hypothetical: run
# 30281540210 died 322 objects in, on third_party/benchmark, for exactly this.
# A 40-minute Windows build is the only other thing that catches it.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/assert.sh"
. "$root/scripts/lib/naming.sh"
. "$root/scripts/lib/variants.sh"

# These files are mostly comment, and the comments quote the very strings the
# assertions below search for -- "never RelWithDebInfo", "losing /EHsc fails
# C4530". Matching raw file text therefore matches the prose, so the test would
# keep passing after the declaration that prose describes was deleted: the exact
# regression it exists to catch. Every content assertion runs against code only.
#
# No cache-init file puts a literal `#` inside a string argument; if one ever
# does, this strip is too crude and the assertion is what will break, loudly.
cmake_code() { # <file>  -> file contents with comments and blank lines removed
  sed -e 's/#.*$//' "$1" | grep -v '^[[:space:]]*$' || true
}

# 1. Every platform has a cache-init file, and every variant that platform
#    builds has one too. Catches "added a platform, forgot the file" -- a
#    failure mode that did not exist before this layer.
for p in $(known_platforms); do
  [ -f "$root/cmake/$p.cmake" ] \
    && printf 'ok: cmake/%s.cmake exists\n' "$p" \
    || { printf 'FAIL: cmake/%s.cmake missing\n' "$p" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
  for v in $(known_variants "$p"); do
    [ -f "$root/cmake/variant-$v.cmake" ] \
      && printf 'ok: cmake/variant-%s.cmake exists (for %s)\n' "$v" "$p" \
      || { printf 'FAIL: cmake/variant-%s.cmake missing (needed by %s)\n' "$v" "$p" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
  done
done

[ -f "$root/cmake/common.cmake" ] \
  && printf 'ok: cmake/common.cmake exists\n' \
  || { printf 'FAIL: cmake/common.cmake missing\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
[ -f "$root/cmake/dist-set.cmake" ] \
  && printf 'ok: cmake/dist-set.cmake exists\n' \
  || { printf 'FAIL: cmake/dist-set.cmake missing\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# 2. Whether every -C file can reach dist_set() is NOT checked here. A macro
#    does not persist between -C scripts, so each file needs the include
#    directly or through one -- cmake/linux-{x86_64,aarch64}.cmake are thin
#    wrappers that reach it through gnu-toolchain.cmake. Deciding that from
#    file text means reimplementing CMake's include resolution in shell, and a
#    direct-text check would instead demand a redundant include in the
#    wrappers, which proves nothing about whether the real chain works.
#    Configure output settles it exactly: a file that cannot reach the macro
#    dies with "Unknown CMake command \"dist_set\"", and IREE_DIST_DECLARED_KEYS
#    in CMakeCache.txt names every file's contribution. That is the Step 10
#    probe's job, and from Task 5 on it is what gen-manifest.sh reads.

# 3. The Windows MSVC platform defaults. -EHsc and -GR are C++-only; -EHsc in
#    the C flags would be an unknown-option warning on cl, and IREE's -WX
#    would escalate it.
w="$(cmake_code "$root/cmake/windows-x86_64.cmake")"
assert_contains "$w" '-EHsc' 'windows cache-init restates -EHsc'
assert_contains "$w" '-GR'   'windows cache-init restates -GR'
assert_contains "$w" '-DWIN32' 'windows cache-init restates -DWIN32'
assert_contains "$w" '_WINDOWS' 'windows cache-init restates -D_WINDOWS'

# The C-flags line must NOT carry -EHsc. Isolate the CMAKE_C_FLAGS
# declaration: the line naming CMAKE_C_FLAGS, excluding CMAKE_CXX_FLAGS.
c_line="$(cmake_code "$root/cmake/windows-x86_64.cmake" \
  | grep 'CMAKE_C_FLAGS' | grep -v 'CMAKE_CXX_FLAGS' || true)"
[ -n "$c_line" ] \
  && printf 'ok: found a CMAKE_C_FLAGS declaration to check\n' \
  || { printf 'FAIL: no CMAKE_C_FLAGS declaration found in cmake/windows-x86_64.cmake\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
case "$c_line" in
  *-EHsc*) printf 'FAIL: -EHsc must not appear in the C flags (C++-only)\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) printf 'ok: -EHsc absent from the C flags\n' ;;
esac

# 4. CMAKE_BUILD_TYPE is Release, and no cache-init file DECLARES
#    RelWithDebInfo. Switching tsan to RelWithDebInfo renames the exported
#    config (IMPORTED_LOCATION_RELEASE -> _RELWITHDEBINFO) and silently breaks
#    the Release-hardcoded libbacktrace and relocatability repairs. Both
#    common.cmake and variant-tsan.cmake explain that in prose, so this scans
#    code only -- a raw scan fails on the very comments warning against it.
assert_contains "$(cmake_code "$root/cmake/common.cmake")" 'CMAKE_BUILD_TYPE                Release' \
  'common.cmake sets CMAKE_BUILD_TYPE Release'
reldbg=0
for f in "$root"/cmake/*.cmake; do
  case "$(cmake_code "$f")" in
    *RelWithDebInfo*) printf 'FAIL: %s declares RelWithDebInfo\n' "$(basename "$f")" >&2
                      ASSERT_FAILS=$((ASSERT_FAILS+1)); reldbg=1 ;;
  esac
done
[ "$reldbg" -eq 0 ] && printf 'ok: no cache-init file declares RelWithDebInfo\n'

[ "$ASSERT_FAILS" -eq 0 ] || exit 1
echo "cmake_init: all assertions passed"
