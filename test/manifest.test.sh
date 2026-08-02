#!/usr/bin/env bash
# Usage: manifest.test.sh <prefix>. The <prefix>-based assertions below skip
# when no prefix given; the platform-conditional-provenance fixtures further
# down are self-contained (call gen-manifest.sh against a synthetic prefix +
# synthetic git repo) and always run, so they exercise real behavior even on
# a host with no built prefix and no Windows machine.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"

# get(): read a bracket-style accessor expression, e.g. get "$m" "['schema_version']".
get() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d$2)" "$1"; }
# getd(): get() cannot express "key absent -> default" (it splices its second
# arg directly after a bare `d`, so a `.get(...)` call needs the leading dot
# get() doesn't supply). Sibling helper for exactly that one shape, added here
# rather than in assert.sh since it's specific to this file's JSON reads.
getd() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2], sys.argv[3]))" "$1" "$2" "$3"; }

# A fake build tree for gen-manifest.sh's new <build-dir> argument: a
# CMakeCache.txt carrying the declared-key registry and every key it names,
# exactly as a real configure records them. The registry line is DERIVED from
# the file's own KEY: lines (minus the cache-version entries), so the registry
# and the entries cannot drift -- the same registry gen-manifest.sh reads for
# real. This is what lets the observed-provenance assertions below run
# hermetically instead of only against a 40-minute real build.
fake_cache() { # <dir> <platform> <iree-src> [<iree-src-native>]
	mkdir -p "$1"
	{
		echo 'IREE_BUILD_COMPILER:BOOL=OFF'
		echo 'IREE_BUILD_TESTS:BOOL=OFF'
		echo 'IREE_BUILD_SAMPLES:BOOL=OFF'
		echo 'IREE_BUILD_BINDINGS_TFLITE:BOOL=OFF'
		echo 'IREE_BUILD_BINDINGS_TFLITE_JAVA:BOOL=OFF'
		echo 'IREE_BUILD_PYTHON_BINDINGS:BOOL=OFF'
		echo 'BUILD_SHARED_LIBS:BOOL=OFF'
		echo 'CMAKE_BUILD_TYPE:STRING=Release'
		echo 'CMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON'
		echo 'IREE_ALLOCATOR_SYSTEM:STRING=libc'
		echo 'IREE_ENABLE_THREADING:BOOL=ON'
		echo 'IREE_HAL_DRIVER_DEFAULTS:BOOL=OFF'
		echo 'IREE_HAL_DRIVER_LOCAL_SYNC:BOOL=ON'
		echo 'IREE_HAL_DRIVER_LOCAL_TASK:BOOL=ON'
		echo 'IREE_HAL_EXECUTABLE_LOADER_DEFAULTS:BOOL=OFF'
		echo 'IREE_HAL_EXECUTABLE_LOADER_EMBEDDED_ELF:BOOL=ON'
		echo 'IREE_HAL_EXECUTABLE_LOADER_SYSTEM_LIBRARY:BOOL=ON'
		echo 'IREE_ENABLE_RUNTIME_TRACING:BOOL=OFF'
		echo 'CMAKE_INSTALL_LIBDIR:STRING=lib'
		echo 'CMAKE_C_COMPILER:STRING=clang'
		echo 'CMAKE_CXX_COMPILER:STRING=clang++'
		# The flag values embed the source root EXACTLY as the cmake -C files
		# compose them from $ENV{IREE_SRC} / $ENV{IREE_SRC_NATIVE} -- the fixture's
		# own paths, so the emitter's normalization actually fires on the fixture
		# instead of silently passing on a path that never matches. This is what
		# makes the absolute-path scan and token assertions below real checks
		# rather than tautologies.
		if [ "$2" = windows-x86_64 ]; then
			# -d1trimfile: takes the native spelling with ONE trailing backslash, per
			# cmake/windows-x86_64.cmake's comments (verified on cl 19.44.35228).
			echo "CMAKE_C_FLAGS:STRING=-DWIN32 -D_WINDOWS -d1trimfile:${4}\\"
			echo "CMAKE_CXX_FLAGS:STRING=-DWIN32 -D_WINDOWS -GR -EHsc -d1trimfile:${4}\\"
			echo 'CMAKE_MSVC_RUNTIME_LIBRARY:STRING=MultiThreaded'
		else
			echo "CMAKE_C_FLAGS:STRING=-ffile-prefix-map=${3}=iree"
			echo "CMAKE_CXX_FLAGS:STRING=-ffile-prefix-map=${3}=iree"
		fi
		echo 'CMAKE_CACHE_MAJOR_VERSION:INTERNAL=3'
		echo 'CMAKE_CACHE_MINOR_VERSION:INTERNAL=29'
		echo 'CMAKE_CACHE_PATCH_VERSION:INTERNAL=6'
	} >"$1/CMakeCache.txt"
	keys="$(grep -oE '^[A-Z0-9_]+:' "$1/CMakeCache.txt" | sed 's/:$//' | grep -v '^CMAKE_CACHE_' | paste -sd';' -)"
	echo "IREE_DIST_DECLARED_KEYS:INTERNAL=${keys}" >>"$1/CMakeCache.txt"
}

# --- Platform-conditional provenance fixtures (Task 6) ---------------------
# Build two synthetic manifests via the real gen-manifest.sh: one linux-x86_64,
# one windows-x86_64. Neither depends on an actual build tree or a Windows
# machine -- gen-manifest.sh only needs a prefix with the installed VM
# bytecode header and a git repo to read a commit sha from, both faked here.
fx="$(mktemp -d)"
trap 'rm -rf "$fx"' EXIT

# Fake IREE_SRC: any git repo with a commit satisfies `git rev-parse HEAD`.
# -c user.* avoids touching real git config (global or repo).
mkdir -p "$fx/iree-src"
git -C "$fx/iree-src" init -q
git -C "$fx/iree-src" -c user.email=test@example.com -c user.name=test \
	commit -q --allow-empty -m "fixture commit"
# gen-manifest.sh OBSERVES iree_tag via git describe, so the fixture repo needs
# a tag for the observation to succeed.
git -C "$fx/iree-src" tag v3.11.0

# Fake build trees (gen-manifest.sh's new <build-dir> argument). The windows
# tree embeds the native-spelled source root in its -d1trimfile: flag, and the
# gen-manifest.sh calls below export IREE_SRC_NATIVE so the normalizer's
# backslash needle (and its forward-slash twin) is exercised hermetically.
fake_cache "$fx/linux-build" linux-x86_64 "$fx/iree-src"
fake_cache "$fx/windows-build" windows-x86_64 "$fx/iree-src" 'C:\work\iree'

# Fake installed VM bytecode header, one copy per fixture prefix.
for p in linux-prefix windows-prefix; do
	mkdir -p "$fx/$p/include/iree/vm/bytecode/utils"
	cat >"$fx/$p/include/iree/vm/bytecode/utils/isa.h" <<'EOF'
#define IREE_VM_BYTECODE_VERSION_MAJOR 17
#define IREE_VM_BYTECODE_VERSION_MINOR 0
EOF
done

# Fake `cl` on PATH so the windows fixture exercises the real cl.exe-banner
# detection path in gen-manifest.sh instead of falling back to "unknown" (this
# host has no MSVC). The banner format matches a real cl.exe invocation with
# no args: version printed to stderr, non-zero exit. The version is THREE
# dot-separated components on a real banner (verified against an actual
# windows-2022 CI run and, separately, VS2026 on winbox: "19.44.35228 for
# x64" / "19.51.36248 for x64") -- not four. An earlier four-component fixture
# here matched no real banner and, combined with a four-component-only regex
# in gen-manifest.sh, made msvc_toolset silently record "unknown" on every
# real host including CI. Keep the fixture honest to what cl.exe actually
# prints.
mkdir -p "$fx/fakebin"
cat >"$fx/fakebin/cl" <<'EOF'
#!/bin/sh
echo "Microsoft (R) C/C++ Optimizing Compiler Version 19.44.35228 for x64" >&2
exit 2
EOF
chmod +x "$fx/fakebin/cl"

bash "$here/../scripts/gen-manifest.sh" "$fx/linux-prefix" default linux-x86_64 \
	"$fx/iree-src" 3.11.0 3.11.0 "$fx/linux-build" >/dev/null
PATH="$fx/fakebin:$PATH" IREE_SRC_NATIVE='C:\work\iree' bash "$here/../scripts/gen-manifest.sh" "$fx/windows-prefix" default windows-x86_64 \
	"$fx/iree-src" 3.11.0 3.11.0 "$fx/windows-build" >/dev/null

m="$fx/linux-prefix/share/iree-runtime-dist/manifest.json"
mw="$fx/windows-prefix/share/iree-runtime-dist/manifest.json"

# Provenance keys are platform-conditional, following the existing conditional
# `sanitizer` idiom. schema_version stays 2 -- the change is purely additive.
assert_eq "$(get "$mw" "['schema_version']")" "2" "windows manifest stays schema 2"
assert_eq "$(get "$mw" "['msvc_toolset']")" "19.44.35228" "windows records msvc_toolset"
assert_eq "$(get "$mw" "['crt']")" "MT" "windows records the static CRT"

# Mutual absence is the assertion that stops the two provenance models silently
# merging later. A Windows manifest must not carry a glibc value, and a Linux
# manifest must not carry MSVC keys.
assert_eq "$(getd "$mw" "glibc_build" "ABSENT")" "ABSENT" "windows omits glibc_build"
assert_eq "$(getd "$m" "msvc_toolset" "ABSENT")" "ABSENT" "linux omits msvc_toolset"
assert_eq "$(getd "$m" "crt" "ABSENT")" "ABSENT" "linux omits crt"

# The crt note must carry the same honesty caveat glibc_build has: with /MT the
# archives emit only /DEFAULTLIB:LIBCMT directives, so the CRT is resolved at the
# consumer's final link. It is NOT a compatibility floor.
assert_contains "$(get "$mw" "['notes']['crt']")" "final link" "crt note states where the CRT resolves"

# The detection regex must also accept a four-component banner (some CMake
# compiler-identification strings carry one) without regressing the
# three-component real-world case above -- both shapes, not a swap of one
# rigid assumption for another.
fx4="$(mktemp -d)"
trap 'rm -rf "$fx" "$fx4"' EXIT
mkdir -p "$fx4/fakebin4"
cat >"$fx4/fakebin4/cl" <<'EOF'
#!/bin/sh
echo "Microsoft (R) C/C++ Optimizing Compiler Version 19.44.35228.1 for x64" >&2
exit 2
EOF
chmod +x "$fx4/fakebin4/cl"
mkdir -p "$fx4/windows-prefix4/include/iree/vm/bytecode/utils"
cat >"$fx4/windows-prefix4/include/iree/vm/bytecode/utils/isa.h" <<'EOF'
#define IREE_VM_BYTECODE_VERSION_MAJOR 17
#define IREE_VM_BYTECODE_VERSION_MINOR 0
EOF
fake_cache "$fx4/windows-build4" windows-x86_64 "$fx/iree-src" 'C:\work\iree'
PATH="$fx4/fakebin4:$PATH" IREE_SRC_NATIVE='C:\work\iree' bash "$here/../scripts/gen-manifest.sh" "$fx4/windows-prefix4" default windows-x86_64 \
	"$fx/iree-src" 3.11.0 3.11.0 "$fx4/windows-build4" >/dev/null
mw4="$fx4/windows-prefix4/share/iree-runtime-dist/manifest.json"
assert_eq "$(get "$mw4" "['msvc_toolset']")" "19.44.35228.1" "four-component banner also parses"

# --- observed provenance (spec: 2026-07-29-declared-configuration-and-observed-provenance) ---
# These assertions run against the synthetic fixtures above (which now feed
# gen-manifest.sh a fake build tree), so they exercise real observation
# hermetically instead of only against a real built prefix.
#
# schema_version stays 2: every new field is additive and breaks no consumer,
# the same criterion under which glibc_build/msvc_toolset/crt were added. The
# published iree_compile_version key is deliberately NOT renamed, despite the
# internal COMPILER_VERSION -> IREE_COMPILER_VERSION change.
assert_eq "$(get "$m" "['schema_version']")" "2" "schema_version still 2"
assert_eq "$(get "$m" "['iree_compile_version']")" "3.11.0" "iree_compile_version not renamed"

# iree_tag is OBSERVED from the checkout, not reconstructed as "v" + version.
assert_eq "$(get "$m" "['iree_tag']")" "v3.11.0" "iree_tag observed from git describe"

# cmake_version: the configure-time CMake, read from CMakeCache.txt's own
# CMAKE_CACHE_*_VERSION entries. CMake is deliberately unpinned (the pin is
# unavailable on the Windows runner, and a container-only half-pin would hide
# risk rather than reduce it), so recording it is the mitigation.
cmv="$(get "$m" "['cmake_version']")"
case "$cmv" in
[0-9]*.[0-9]*.[0-9]*) printf 'ok: cmake_version looks like a version (%s)\n' "$cmv" ;;
*)
	printf 'FAIL: cmake_version is not a dotted version: [%s]\n' "$cmv" >&2
	ASSERT_FAILS=$((ASSERT_FAILS + 1))
	;;
esac

# runtime_dist_commit: which version of THIS recipe produced the tarball. Was
# recorded nowhere before. --dirty so a hand build from uncommitted changes says
# so; CI is always clean, so the marker only ever annotates local builds.
rdc="$(get "$m" "['runtime_dist_commit']")"
[ -n "$rdc" ] &&
	printf 'ok: runtime_dist_commit present (%s)\n' "$rdc" ||
	{
		printf 'FAIL: runtime_dist_commit missing\n' >&2
		ASSERT_FAILS=$((ASSERT_FAILS + 1))
	}

# build_config is filtered to the keys the cache-init files declared -- by key
# NAME, never by entry type, because a command-line -D override resets the type
# to UNINITIALIZED. It must contain our keys and NOT contain IREE's hundreds of
# unrelated ones.
assert_eq "$(get "$m" "['build_config']['IREE_BUILD_COMPILER']")" "OFF" "build_config carries a declared key"
assert_eq "$(get "$m" "['build_config']['CMAKE_BUILD_TYPE']")" "Release" "build_config carries CMAKE_BUILD_TYPE"
bc_n="$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))['build_config']))" "$m")"
if [ "$bc_n" -lt 40 ]; then
	printf 'ok: build_config is filtered, not the whole cache (%s keys)\n' "$bc_n"
else
	printf 'FAIL: build_config has %s keys -- the declared-key filter is not being applied\n' "$bc_n" >&2
	ASSERT_FAILS=$((ASSERT_FAILS + 1))
fi

# No build-machine path may survive in a build_config VALUE. The compiler-flag
# entries are path-dependent by construction (-ffile-prefix-map / -d1trimfile
# embed the source root), and manifest.json ships inside the prefix, so an
# un-normalized value is a real relocatability leak -- caught by the Phase 4
# relocatability_assert, but 40 minutes into a build. This catches it here.
#
# Values only, never keys: CMAKE_C_COMPILER's VALUE is legitimately an absolute
# path to the toolchain (/usr/bin/clang, or the resolved cl.exe on windows) and
# is provenance we want -- it names the compiler on the BUILD IMAGE, not a path
# inside the artifact, and no consumer resolves it. The rule is about the source
# and build roots, which is what the normalization rewrites.
for _f in "$m" "$mw"; do
	python3 - "$_f" <<'PY' || ASSERT_FAILS=$((ASSERT_FAILS + 1))
import json, re, sys
cfg = json.load(open(sys.argv[1]))["build_config"]
bad = []
for k, v in cfg.items():
    if k in ("CMAKE_C_COMPILER", "CMAKE_CXX_COMPILER"):
        continue
    # An absolute POSIX path, or a windows drive-letter path in either slash
    # style. -I/-L style flags concatenate directly onto their argument, so a
    # leading path character is not required.
    if re.search(r"(^|[^A-Za-z0-9_.])(/[A-Za-z0-9_.]|[A-Za-z]:[\\/])", v):
        bad.append("%s=%s" % (k, v))
if bad:
    print("FAIL: %s: build_config value carries an absolute path:" % sys.argv[1], file=sys.stderr)
    for b in bad:
        print("  " + b, file=sys.stderr)
    sys.exit(1)
print("ok: %s: no build_config value carries a build-machine path" % sys.argv[1])
PY
done

# The normalization is a rewrite, not a deletion: the flag keeps its shape and
# says where the path was. Asserting the token is present is what distinguishes
# "normalized" from "the flag was dropped/never applied" -- the latter would
# pass the absolute-path scan above while silently shipping build paths in every
# __FILE__ string in the archives. The windows fixture proves the native
# (backslash) spelling normalizes too, via -d1trimfile:.
assert_contains "$(get "$m" "['build_config']['CMAKE_C_FLAGS']")" '@IREE_SOURCE_ROOT@' \
	"CMAKE_C_FLAGS records the source root as a token"
assert_contains "$(get "$m" "['build_config']['CMAKE_CXX_FLAGS']")" '@IREE_SOURCE_ROOT@' \
	"CMAKE_CXX_FLAGS records the source root as a token"
assert_contains "$(get "$mw" "['build_config']['CMAKE_C_FLAGS']")" '@IREE_SOURCE_ROOT@' \
	"windows CMAKE_C_FLAGS records the native source root as a token"

# Platform-conditional provenance, extended with clang_version. clang_version
# is present on linux-* (the Linux compiler was attested only indirectly, via
# Dockerfile NEVRAs) and ABSENT on windows-*, so the two provenance models
# cannot silently merge.
cv="$(get "$m" "['clang_version']")"
[ -n "$cv" ] && [ "$cv" != "None" ] &&
	printf 'ok: clang_version present on linux (%s)\n' "$cv" ||
	{
		printf 'FAIL: clang_version missing on a linux manifest\n' >&2
		ASSERT_FAILS=$((ASSERT_FAILS + 1))
	}
if python3 -c "import json,sys;sys.exit(0 if 'clang_version' not in json.load(open(sys.argv[1])) else 1)" "$mw"; then
	printf 'ok: clang_version absent on a windows manifest\n'
else
	printf 'FAIL: clang_version present on a windows manifest\n' >&2
	ASSERT_FAILS=$((ASSERT_FAILS + 1))
fi

# sanitizer is OBSERVED from the build's own CMAKE_C_FLAGS rather than
# reconstructed from the variant argument. The fixtures are both default, so
# this asserts the absent side hermetically; the tsan side is covered by the
# <prefix> gate below against a real tsan build tree.
case "$(get "$m" "['variant']")" in
tsan) assert_eq "$(get "$m" "['sanitizer']")" "thread" "sanitizer observed from the build's own flags" ;;
*) python3 -c "import json,sys;sys.exit(0 if 'sanitizer' not in json.load(open(sys.argv[1])) else 1)" "$m" &&
	printf 'ok: sanitizer absent on default\n' ||
	{
		printf 'FAIL: sanitizer present on a default manifest\n' >&2
		ASSERT_FAILS=$((ASSERT_FAILS + 1))
	} ;;
esac

# --- <prefix>-based structural checks (skip when no prefix given) ----------
prefix="${1:-}"
if [ -z "$prefix" ]; then
	echo "skip: remaining manifest.test.sh checks need a built prefix"
	exit "$ASSERT_FAILS"
fi

m="$prefix/share/iree-runtime-dist/manifest.json"
if [ -e "$m" ]; then
	echo "ok: manifest.json present"
else
	echo "FAIL: manifest.json missing" >&2
	ASSERT_FAILS=$((ASSERT_FAILS + 1))
	exit "$ASSERT_FAILS"
fi

assert_eq "$(get "$m" "['schema_version']")" "2" "schema_version"
assert_eq "$(get "$m" "['iree_version']")" "3.11.0" "iree_version"
assert_eq "$(get "$m" "['iree_tag']")" "v3.11.0" "iree_tag"
assert_eq "$(get "$m" "['iree_compile_version']")" "3.11.0" "paired compiler version"

# vm_bytecode_version (design lines 119, 214): the HAL/VM module ABI version
# the shipped runtime expects, read from its own installed header -- must
# look like a real MAJOR.MINOR pair, never absent or a placeholder.
vbv="$(get "$m" "['vm_bytecode_version']")"
if printf '%s' "$vbv" | grep -qE '^[0-9]+\.[0-9]+$'; then
	echo "ok: vm_bytecode_version looks like MAJOR.MINOR ($vbv)"
else
	echo "FAIL: vm_bytecode_version '$vbv' is not a MAJOR.MINOR version" >&2
	ASSERT_FAILS=$((ASSERT_FAILS + 1))
fi

# runtime_commit must be a real 40-char sha, not a placeholder.
c="$(get "$m" "['runtime_commit']")"
if printf '%s' "$c" | grep -qE '^[0-9a-f]{40}$'; then
	echo "ok: runtime_commit is a full sha"
else
	echo "FAIL: runtime_commit '$c' is not a 40-char sha" >&2
	ASSERT_FAILS=$((ASSERT_FAILS + 1))
fi

# Build-config attestation (wishlist #7).
assert_eq "$(get "$m" "['build_config']['IREE_BUILD_COMPILER']")" "OFF" "compiler off attested"
assert_eq "$(get "$m" "['build_config']['BUILD_SHARED_LIBS']")" "OFF" "static attested"
assert_eq "$(get "$m" "['build_config']['CMAKE_BUILD_TYPE']")" "Release" "release attested"
assert_eq "$(get "$m" "['build_config']['IREE_HAL_DRIVER_LOCAL_TASK']")" "ON" "local-task attested"

if [ -e "$prefix/BUILDINFO" ]; then
	echo "ok: BUILDINFO present"
else
	echo "FAIL: BUILDINFO missing" >&2
	ASSERT_FAILS=$((ASSERT_FAILS + 1))
fi

# manifest.json's variant must match the prefix's own BUILDINFO variant= line
# rather than a hard-coded "default" -- this test runs against both default
# and tsan prefixes.
variant="$(grep -oE '^variant=.*' "$prefix/BUILDINFO" | cut -d= -f2)"
assert_eq "$(get "$m" "['variant']")" "$variant" "variant matches BUILDINFO"

# Likewise the platform: assert manifest.json matches the prefix's own BUILDINFO
# platform= line rather than a hard-coded token -- this test runs against every
# platform (linux-x86_64, linux-aarch64), and both fields derive from $PLATFORM in
# build-runtime.sh, so a mismatch means the two generated records drifted.
platform="$(grep -oE '^platform=.*' "$prefix/BUILDINFO" | cut -d= -f2)"
assert_eq "$(get "$m" "['platform']")" "$platform" "platform matches BUILDINFO"

# sanitizer field: absent for default, "thread" for tsan (Task 3).
san="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sanitizer",""))' "$m")"
if [ "$variant" = "tsan" ]; then
	assert_eq "$san" "thread" "tsan manifest records sanitizer=thread"
	assert_contains "$(cat "$prefix/BUILDINFO")" "sanitizer=thread" "tsan BUILDINFO records sanitizer"
else
	assert_eq "$san" "" "default manifest omits sanitizer"
fi

# Toolchain provenance is platform-conditional and MUTUALLY EXCLUSIVE: a
# container-built Linux artifact records glibc_build and no MSVC fields; a
# runner-built Windows artifact records msvc_toolset + crt and has no glibc at
# all. Asserting both directions (present here, ABSENT there) is the point --
# a manifest that carried glibc_build on Windows would be attesting to a libc
# that never touched the build. Keyed off the prefix's own BUILDINFO platform
# read above, never a hard-coded token.
case "$platform" in
windows-*)
	tk="$(getd "$m" msvc_toolset "")"
	if printf '%s' "$tk" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
		echo "ok: msvc_toolset looks like a cl version ($tk)"
	else
		echo "FAIL: msvc_toolset '$tk' is not a cl.exe version" >&2
		ASSERT_FAILS=$((ASSERT_FAILS + 1))
	fi
	crt="$(getd "$m" crt "")"
	if [ "$crt" = "MT" ] || [ "$crt" = "MD" ]; then
		echo "ok: crt recorded ($crt)"
	else
		echo "FAIL: crt '$crt' is neither MT nor MD" >&2
		ASSERT_FAILS=$((ASSERT_FAILS + 1))
	fi
	gb="$(getd "$m" glibc_build "<absent>")"
	if [ "$gb" = "<absent>" ]; then
		echo "ok: no glibc_build on a windows artifact"
	else
		echo "FAIL: windows manifest records glibc_build '$gb'" >&2
		ASSERT_FAILS=$((ASSERT_FAILS + 1))
	fi
	;;
*)
	# glibc_build must look like a real detected version (MAJOR.MINOR) or the
	# explicit "unknown" sentinel -- never a hard-coded/assumed value, and never
	# a silent empty string.
	gb="$(get "$m" "['glibc_build']")"
	if printf '%s' "$gb" | grep -qE '^[0-9]+\.[0-9]+$'; then
		echo "ok: glibc_build looks like a version ($gb)"
	elif [ "$gb" = "unknown" ]; then
		echo "ok: glibc_build is explicit 'unknown'"
	else
		echo "FAIL: glibc_build '$gb' is neither a MAJOR.MINOR version nor 'unknown'" >&2
		ASSERT_FAILS=$((ASSERT_FAILS + 1))
	fi
	for absent in msvc_toolset crt; do
		v="$(getd "$m" "$absent" "<absent>")"
		if [ "$v" = "<absent>" ]; then
			echo "ok: no $absent on a linux artifact"
		else
			echo "FAIL: linux manifest records $absent '$v'" >&2
			ASSERT_FAILS=$((ASSERT_FAILS + 1))
		fi
	done
	;;
esac

# The old glibc_floor field was misleading (implied a detected symbol-version
# floor that static archives cannot actually provide -- see gen-manifest.sh).
# Assert it cannot quietly reappear.
if python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if 'glibc_floor' not in d else 1)
" "$m"; then
	echo "ok: glibc_floor key is gone"
else
	echo "FAIL: misleading 'glibc_floor' key is still present" >&2
	ASSERT_FAILS=$((ASSERT_FAILS + 1))
fi

exit "$ASSERT_FAILS"
