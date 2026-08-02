#!/usr/bin/env bash
# Emit manifest.json + BUILDINFO. Build configuration is OBSERVED from the build
# tree's own CMakeCache.txt -- filtered by the IREE_DIST_DECLARED_KEYS registry
# the cmake -C files populate -- rather than reconstructed from the arguments
# that drove the build, so recorded provenance cannot diverge from the build
# that produced it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

PREFIX="${1:?usage: gen-manifest.sh <prefix> <variant> <platform> <iree-src> <iree-version> <iree-compiler-version> <build-dir>}"
VARIANT="${2:?variant required}"
PLATFORM="${3:?platform required}"
IREE_SRC="${4:?iree-src required}"
IREE_VERSION="${5:?iree-version required}"
IREE_COMPILER_VERSION="${6:?iree-compiler-version required}"
# The build tree is now a required input: build_config, crt, sanitizer, and
# cmake_version are all read from its CMakeCache.txt rather than reconstructed
# from the arguments that drove the build. Consequence to accept: a manifest can
# no longer be regenerated from an installed prefix alone. That is the point of
# observing rather than reconstructing, not a regression.
BUILD_DIR="${7:?build-dir required}"
[ -f "$BUILD_DIR/CMakeCache.txt" ] ||
	{
		echo "error: no CMakeCache.txt in '$BUILD_DIR'" >&2
		exit 1
	}

OUT_DIR="$PREFIX/share/iree-runtime-dist"
mkdir -p "$OUT_DIR"

RUNTIME_COMMIT="$(git -C "$IREE_SRC" rev-parse HEAD)"

# iree_tag is OBSERVED beside runtime_commit rather than reconstructed as
# "v" + iree_version. Same checkout, same git, one path to the fact.
IREE_TAG="$(git -C "$IREE_SRC" describe --tags --abbrev=0)" ||
	{
		echo "error: could not read a tag from '$IREE_SRC'" >&2
		exit 1
	}

# Which version of THIS recipe produced the artifact -- recorded nowhere until
# now, even though every repair and all the packaging come from here.
# --always so a shallow/tagless clone still yields a hash; --dirty so a hand
# build from an uncommitted tree says so. CI is always clean.
#
# safe.directory for our own repo, for the same reason build-runtime.sh declares
# it for $IREE_SRC: this repo is a bind mount owned by the invoking user while
# the container runs as root, so git refuses it as "dubious ownership" and the
# call fails inside the container but not on a bare host run -- exactly the
# divergence CI trips over. The inline env assignments apply to THIS git command
# only; build-runtime.sh's inherited GIT_CONFIG_* for $IREE_SRC still covers the
# git calls above.
_dist_repo="$(cd "$HERE/.." && pwd)"
RUNTIME_DIST_COMMIT="$(
	GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="$_dist_repo" \
		git -C "$_dist_repo" describe --always --dirty
)" || {
	echo "error: could not describe the iree-runtime-dist repo at '$_dist_repo'" >&2
	exit 1
}

# NOTE: static archives carry unversioned undefined libc symbols (glibc symbol
# versioning is resolved at final link against the shared libc, never recorded
# in a .a). Scanning the archives for GLIBC_x.y symbol-version strings therefore
# cannot answer "what glibc does this need" -- it always yields nothing, and
# reporting that as a floor of "none" would misleadingly imply no constraint.
#
# What we CAN honestly attest is the glibc of the environment these archives
# were compiled in (this script must run inside that same environment --
# build-runtime.sh's Phase 3 call happens inside the manylinux container, and
# a standalone regen must be invoked the same way, e.g. via `docker run`).
# Prefer getconf; fall back to parsing `ldd --version`. Every stage is
# tolerant of failure (`|| true`) since `grep`/`getconf` exiting non-zero
# under `set -euo pipefail` would otherwise abort the whole script -- and an
# explicit "unknown" beats a silent empty string or an assumed value.
GLIBC_BUILD="$(getconf GNU_LIBC_VERSION 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
if [ -z "$GLIBC_BUILD" ]; then
	GLIBC_BUILD="$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | tail -1 || true)"
fi
[ -n "$GLIBC_BUILD" ] || GLIBC_BUILD="unknown"

# MSVC toolset provenance, mirroring the glibc_build pattern above exactly:
# detect from cl.exe's own version banner (cl prints "Microsoft (R) C/C++
# Optimizing Compiler Version X.Y.Z ..." to stderr even with no args, and
# exits non-zero) rather than trusting an assumed value. Every stage is
# tolerant of failure (`|| true`) since a missing `cl` or an unexpected banner
# format exiting non-zero under `set -euo pipefail` would otherwise abort the
# whole script -- and an explicit "unknown" beats a silent empty string. On a
# non-Windows host `cl` will not be on PATH at all, and "unknown" is the
# correct recorded value in that case.
#
# The banner's version is three dot-separated components on real cl.exe
# (verified on a windows-2022 CI runner: "19.44.35228 for x64", and on VS2026:
# "19.51.36248 for x64") -- NOT four. A four-component pattern matches nothing
# against a real banner and silently falls back to "unknown" on every host,
# including CI, making the manifest's own msvc_toolset provenance claim
# vacuous. CMake's own compiler-identification strings do sometimes carry a
# fourth (MSC_VER-style) component elsewhere, so accept an optional trailing
# ".W" rather than assuming one fixed shape is the only one that can appear.
MSVC_TOOLSET="$(cl 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
[ -n "$MSVC_TOOLSET" ] || MSVC_TOOLSET="unknown"

# clang provenance, mirroring the MSVC_TOOLSET pattern exactly: from the
# compiler's own banner, tolerant of failure (grep exiting non-zero under
# set -euo pipefail would abort the script), "unknown" rather than a silent
# empty string or an assumed value. Only meaningful on linux-*, where clang is
# the compiler the Dockerfile pins; on windows it is never on PATH and the
# manifest omits the key entirely.
CLANG_VERSION="$(clang --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
[ -n "$CLANG_VERSION" ] || CLANG_VERSION="unknown"

# The HAL/VM module ABI version the runtime expects (design lines 119, 214):
# so a consumer can fail fast with a clear message instead of a cryptic VM
# import signature mismatch when a .vmfb was produced by an incompatible
# compiler. Read straight from the just-installed runtime header rather than
# fabricated -- iree/vm/bytecode/verifier.c rejects a module whose bytecode
# version doesn't match IREE_VM_BYTECODE_VERSION_{MAJOR,MINOR} from this same
# header, so this is the actual value the shipped runtime enforces.
_isa_header="$PREFIX/include/iree/vm/bytecode/utils/isa.h"
VM_BYTECODE_VERSION_MAJOR="$(grep -oE '#define[[:space:]]+IREE_VM_BYTECODE_VERSION_MAJOR[[:space:]]+[0-9]+' "$_isa_header" 2>/dev/null | grep -oE '[0-9]+$' || true)"
VM_BYTECODE_VERSION_MINOR="$(grep -oE '#define[[:space:]]+IREE_VM_BYTECODE_VERSION_MINOR[[:space:]]+[0-9]+' "$_isa_header" 2>/dev/null | grep -oE '[0-9]+$' || true)"
if [ -z "$VM_BYTECODE_VERSION_MAJOR" ] || [ -z "$VM_BYTECODE_VERSION_MINOR" ]; then
	echo "error: could not read IREE_VM_BYTECODE_VERSION_MAJOR/MINOR from $_isa_header -- has IREE's bytecode versioning scheme changed?" >&2
	exit 1
fi
VM_BYTECODE_VERSION="${VM_BYTECODE_VERSION_MAJOR}.${VM_BYTECODE_VERSION_MINOR}"

# build_config, crt, sanitizer, and cmake_version are all read from the build
# tree's CMakeCache.txt by emit-manifest.py. Every value is passed as argv,
# never interpolated into Python source -- see the docstring in emit-manifest.py
# for why.
python3 "$HERE/emit-manifest.py" "$OUT_DIR/manifest.json" "$VARIANT" "$PLATFORM" \
	"$IREE_VERSION" "$IREE_TAG" "$RUNTIME_COMMIT" "$RUNTIME_DIST_COMMIT" \
	"$IREE_COMPILER_VERSION" "$GLIBC_BUILD" "$CLANG_VERSION" \
	"$VM_BYTECODE_VERSION" "$MSVC_TOOLSET" "$BUILD_DIR" \
	"$IREE_SRC" "${IREE_SRC_NATIVE:-}"

# IREE_SRC is passed as-is (not resolved with cd && pwd) so the needle is
# spelled exactly as cmake/gnu-toolchain.cmake interpolated it through
# $ENV{IREE_SRC} -- a resolved-vs-unresolved mismatch would leave the flag
# string untouched and the build-machine path in the shipped manifest.
# IREE_SRC_NATIVE is exported by build-runtime.sh only on windows-*, hence the
# `:-` default; on Linux the empty needle is skipped by the normalizer.

# cmake_flags is read back out of the manifest just written, rather than
# recomputed: one authority, and the two files cannot disagree.
_cmake_flags="$(python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))["build_config"]
print(" ".join("-D%s=%s" % (k, v) for k, v in sorted(cfg.items())))
' "$OUT_DIR/manifest.json")"

cat >"$PREFIX/BUILDINFO" <<EOF
iree-runtime-dist
variant=$VARIANT
platform=$PLATFORM
iree_version=$IREE_VERSION
iree_tag=$IREE_TAG
runtime_commit=$RUNTIME_COMMIT
runtime_dist_commit=$RUNTIME_DIST_COMMIT
iree_compile_version=$IREE_COMPILER_VERSION
vm_bytecode_version=$VM_BYTECODE_VERSION
cmake_version=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["cmake_version"])' "$OUT_DIR/manifest.json")
cmake_flags=$_cmake_flags
EOF

# Provenance keys are platform-conditional here too, mirroring manifest.json:
# glibc_build/clang_version only mean something for a container-built Linux
# artifact; msvc_toolset/crt only mean something for a Windows one. The crt
# value is read back out of the manifest (which observed it from the cache)
# so BUILDINFO cannot disagree with manifest.json.
case "$PLATFORM" in
linux-*) {
	echo "glibc_build=$GLIBC_BUILD"
	echo "clang_version=$CLANG_VERSION"
} >>"$PREFIX/BUILDINFO" ;;
windows-*) {
	echo "msvc_toolset=$MSVC_TOOLSET"
	python3 -c 'import json,sys;print("crt="+json.load(open(sys.argv[1]))["crt"])' "$OUT_DIR/manifest.json"
} >>"$PREFIX/BUILDINFO" ;;
esac

# sanitizer likewise read back out of the manifest: it is observed from the
# build's own CMAKE_C_FLAGS, not reconstructed from the variant argument.
_san="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("sanitizer",""))' "$OUT_DIR/manifest.json")"
if [ -n "$_san" ]; then echo "sanitizer=$_san" >>"$PREFIX/BUILDINFO"; fi

echo "==> generated manifest.json and BUILDINFO"
