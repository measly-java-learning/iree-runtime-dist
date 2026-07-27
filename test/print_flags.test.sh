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

# Windows needs a static CRT (/MT) because the consumer is a JNI shim linking
# into a DLL; a dynamic CRT would push a VC++ redistributable requirement onto
# every downstream user. /d1trimfile: is MSVC's -ffile-prefix-map analog and is
# what keeps absolute __FILE__ paths out of the shipped archives.
# NOTE: platform comes from the --platform FLAG, not an environment variable.
# build-runtime.sh:17 sets PLATFORM="" unconditionally and only assigns it from
# --platform (:52) or host-arch detection (:90-92), so `PLATFORM=... bash ...`
# would silently test the host platform's flags and never pass.
# Assert the REAL cache variable, not a "/MT" substring. `/MT` does not appear
# in `-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded`, and an assertion looking for
# it invites adding a cosmetic echo line to --print-flags just to satisfy the
# test. --print-flags must emit cmake arguments and nothing else: its output
# feeds BUILDINFO/manifest.json provenance, and the next task derives `crt`
# from it.
wf="$(bash "$here/../build-runtime.sh" --print-flags --variant default --platform windows-x86_64 --iree-src /tmp/x)"
assert_contains "$wf" "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded" "windows uses the static CRT"
assert_contains "$wf" "d1trimfile"   "windows trims __FILE__ paths"
# The trim prefix must be a real path, never empty -- `/d1trimfile:` with no
# prefix trims nothing and silently leaves absolute __FILE__ paths in every
# archive, which is the exact leak this flag exists to prevent.
case "$wf" in
  *"d1trimfile:"[[:space:]]*|*"d1trimfile:\\"*|*"d1trimfile:"$'\n'*)
    echo "FAIL: /d1trimfile: has an empty prefix" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) echo "ok: /d1trimfile: carries a non-empty prefix" ;;
esac

# Passing -DCMAKE_<LANG>_FLAGS on the cmake command line REPLACES the value
# CMake's platform module initialised rather than adding to it. On MSVC that
# default carries /EHsc (and /GR), so clobbering it makes every C++ TU that
# includes <ostream> fail C4530, which IREE's -WX escalates to an error --
# observed for real in run 30281540210, 322 objects into a 40-minute build, on
# third_party/benchmark. build-runtime.sh restates those defaults; assert they
# are actually there, per language, so a future edit that drops them fails here
# in a second instead of in CI.
cxx="$(printf '%s\n' "$wf" | grep '^compiler_flags_cxx: ' || true)"
cc="$(printf '%s\n' "$wf" | grep '^compiler_flags: ' || true)"
assert_contains "$cxx" "-EHsc" "windows C++ flags keep the /EHsc default cmake would have set"
assert_contains "$cxx" "-GR"   "windows C++ flags keep the /GR default cmake would have set"
assert_contains "$cxx" "d1trimfile" "windows C++ flags still trim __FILE__"
assert_contains "$cc"  "d1trimfile" "windows C flags still trim __FILE__"
# -EHsc is a C++-only option; cl warns on it for a C translation unit.
case "$cc" in *-EHsc*) echo "FAIL: -EHsc leaked into the C flags" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1));; *) echo "ok: no -EHsc in C flags";; esac

lf="$(bash "$here/../build-runtime.sh" --print-flags --variant default --platform linux-x86_64)"
assert_contains "$lf" "-ffile-prefix-map" "linux keeps its own prefix map"
case "$lf" in *d1trimfile*) echo "FAIL: MSVC-only flag leaked into linux flags" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1));; *) echo "ok: no MSVC flag on linux";; esac

exit "$ASSERT_FAILS"
