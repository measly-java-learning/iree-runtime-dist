#!/usr/bin/env bash
# Emit manifest.json + BUILDINFO. Build config comes from effective_cmake_flags,
# so recorded provenance cannot diverge from the build that produced it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/variants.sh"
. "$HERE/lib/cmakeflags.sh"

PREFIX="${1:?usage: gen-manifest.sh <prefix> <variant> <platform> <iree-src> <iree-version> <compiler-version>}"
VARIANT="${2:?variant required}"
PLATFORM="${3:?platform required}"
IREE_SRC="${4:?iree-src required}"
IREE_VERSION="${5:?iree-version required}"
COMPILER_VERSION="${6:?compiler-version required}"

OUT_DIR="$PREFIX/share/iree-runtime-dist"
mkdir -p "$OUT_DIR"

RUNTIME_COMMIT="$(git -C "$IREE_SRC" rev-parse HEAD)"

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
# Optimizing Compiler Version X.Y.Z.W ..." to stderr even with no args, and
# exits non-zero) rather than trusting an assumed value. Every stage is
# tolerant of failure (`|| true`) since a missing `cl` or an unexpected banner
# format exiting non-zero under `set -euo pipefail` would otherwise abort the
# whole script -- and an explicit "unknown" beats a silent empty string. On a
# non-Windows host `cl` will not be on PATH at all, and "unknown" is the
# correct recorded value in that case.
MSVC_TOOLSET="$(cl 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
[ -n "$MSVC_TOOLSET" ] || MSVC_TOOLSET="unknown"

# crt is derived from the same effective_cmake_flags output that fed the
# build -- never hardcoded -- so the manifest cannot claim a CRT the build
# didn't actually use (CLAUDE.md: recorded provenance cannot diverge from the
# build that produced it). Only meaningful on windows-*; a missing or
# unrecognized value there is a loud failure, not a guessed default.
CRT=""
case "$PLATFORM" in
  windows-*)
    _crt_flag="$(effective_cmake_flags "$VARIANT" "$PLATFORM" | grep -E '^-DCMAKE_MSVC_RUNTIME_LIBRARY=' || true)"
    _crt_value="${_crt_flag#*=}"
    case "$_crt_value" in
      MultiThreaded)    CRT="MT" ;;
      MultiThreadedDLL) CRT="MD" ;;
      *)
        echo "error: windows platform requires -DCMAKE_MSVC_RUNTIME_LIBRARY to be MultiThreaded or MultiThreadedDLL in effective_cmake_flags output (got '${_crt_value:-<absent>}')" >&2
        exit 1
        ;;
    esac
    ;;
esac

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

# build_config comes from the same function the build used.
BUILD_CONFIG_JSON="$(
  effective_cmake_flags "$VARIANT" "$PLATFORM" | python3 -c '
import json, sys
cfg = {}
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("-D") or "=" not in line:
        continue
    k, v = line[2:].split("=", 1)
    cfg[k] = v
print(json.dumps(cfg, indent=4, sort_keys=True))
'
)"

SANITIZER="$(variant_sanitizer "$VARIANT")"

# Pass every value as argv rather than interpolating into the heredoc's Python
# source directly -- interpolation would let a value containing a quote or
# backslash (e.g. an unusual IREE_SRC path) break the heredoc's Python syntax or
# smuggle content into the JSON. Reading from sys.argv keeps each value an opaque
# string as far as the Python parser is concerned.
python3 - "$OUT_DIR/manifest.json" "$VARIANT" "$PLATFORM" "$IREE_VERSION" \
  "$RUNTIME_COMMIT" "$COMPILER_VERSION" "$GLIBC_BUILD" "$BUILD_CONFIG_JSON" \
  "$VM_BYTECODE_VERSION" "$SANITIZER" "$MSVC_TOOLSET" "$CRT" <<'EOF'
import json, sys

(_, out_path, variant, platform, iree_version, runtime_commit,
 compiler_version, glibc_build, build_config_json,
 vm_bytecode_version, sanitizer, msvc_toolset, crt) = sys.argv

manifest = {
    "schema_version": 2,
    "variant": variant,
    "platform": platform,
    "iree_version": iree_version,
    "iree_tag": "v" + iree_version,
    "runtime_commit": runtime_commit,
    "iree_compile_version": compiler_version,
    "vm_bytecode_version": vm_bytecode_version,
    "build_config": json.loads(build_config_json),
    "notes": {
        "compiler": (
            "The IREE compiler is out of contract: built with "
            "IREE_BUILD_COMPILER=OFF and never shipped. Install "
            "iree-base-compiler==" + compiler_version + " to produce loadable "
            ".vmfb files."
        ),
        "pip_runtime_wheel": (
            "The pip iree-base-runtime wheel is NOT linkable at any version -- "
            "no headers, no static libs. Only a from-source build or this dist "
            "yields a linkable runtime."
        ),
        "vm_bytecode_version": (
            "IREE_VM_BYTECODE_VERSION_MAJOR.MINOR from the shipped runtime's "
            "own iree/vm/bytecode/utils/isa.h -- the value the VM bytecode "
            "verifier checks a loaded .vmfb against. A .vmfb compiled by a "
            "mismatched compiler version fails to load with a VM import "
            "signature mismatch; compare this field before loading one built "
            "elsewhere."
        ),
    },
}

if sanitizer:
    manifest["sanitizer"] = sanitizer
    manifest["notes"]["sanitizer"] = (
        "This variant is built with -fsanitize=" + sanitizer + ". The umbrella "
        "target propagates the sanitizer flag as an INTERFACE option, so linking "
        "it instruments the whole consumer program. See share/iree-runtime-dist/"
        "TSAN.md for how to run it (ASLR/mmap_rnd_bits) and any suppressions."
    )

# Provenance keys are platform-conditional: a Windows artifact has no glibc,
# and a container-built Linux artifact has no MSVC toolset/CRT. Absence of
# the inapplicable key is the honest encoding -- a "n/a" sentinel would invite
# reading it as "no glibc requirement" rather than "wrong provenance model".
if platform.startswith("linux-"):
    manifest["glibc_build"] = glibc_build
    manifest["notes"]["glibc_build"] = (
        "glibc_build is the glibc version of the container these static "
        "archives were compiled against, NOT a detected minimum/floor -- "
        "static archives carry unversioned undefined libc symbols, so the "
        "consumer's own final link is what actually resolves glibc symbol "
        "versions. Do not read this as a guarantee of compatibility with "
        "any glibc older than the value recorded here."
    )
elif platform.startswith("windows-"):
    manifest["msvc_toolset"] = msvc_toolset
    manifest["crt"] = crt
    manifest["notes"]["msvc_toolset"] = (
        "msvc_toolset is the cl.exe version these archives were compiled "
        "with, on a PINNED runner image (windows-2022). It is provenance, "
        "not a compatibility claim."
    )
    manifest["notes"]["crt"] = (
        "crt is the C runtime model these archives were compiled with (MT = "
        "static). The archives carry only /DEFAULTLIB:LIBCMT directives; the "
        "CRT itself is resolved at the consumer's final link, not embedded "
        "here. This is NOT a compatibility floor -- it is the CRT a consumer "
        "must match to avoid a mixed-CRT link."
    )

with open(out_path, "w") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
EOF

cat > "$PREFIX/BUILDINFO" <<EOF
iree-runtime-dist
variant=$VARIANT
platform=$PLATFORM
iree_version=$IREE_VERSION
runtime_commit=$RUNTIME_COMMIT
iree_compile_version=$COMPILER_VERSION
vm_bytecode_version=$VM_BYTECODE_VERSION
cmake_flags=$(effective_cmake_flags "$VARIANT" "$PLATFORM" | tr '\n' ' ')
EOF

# Provenance keys are platform-conditional here too, mirroring manifest.json:
# glibc_build only means something for a container-built Linux artifact;
# msvc_toolset/crt only mean something for a Windows one.
case "$PLATFORM" in
  linux-*)   echo "glibc_build=$GLIBC_BUILD" >> "$PREFIX/BUILDINFO" ;;
  windows-*) { echo "msvc_toolset=$MSVC_TOOLSET"; echo "crt=$CRT"; } >> "$PREFIX/BUILDINFO" ;;
esac

if [ -n "$SANITIZER" ]; then echo "sanitizer=$SANITIZER" >> "$PREFIX/BUILDINFO"; fi

echo "==> generated manifest.json and BUILDINFO"
