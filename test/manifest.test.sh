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

# Fake installed VM bytecode header, one copy per fixture prefix.
for p in linux-prefix windows-prefix; do
  mkdir -p "$fx/$p/include/iree/vm/bytecode/utils"
  cat > "$fx/$p/include/iree/vm/bytecode/utils/isa.h" <<'EOF'
#define IREE_VM_BYTECODE_VERSION_MAJOR 17
#define IREE_VM_BYTECODE_VERSION_MINOR 0
EOF
done

# Fake `cl` on PATH so the windows fixture exercises the real cl.exe-banner
# detection path in gen-manifest.sh instead of falling back to "unknown" (this
# host has no MSVC). The banner format matches a real cl.exe invocation with
# no args: version printed to stderr, non-zero exit.
mkdir -p "$fx/fakebin"
cat > "$fx/fakebin/cl" <<'EOF'
#!/bin/sh
echo "Microsoft (R) C/C++ Optimizing Compiler Version 19.44.35228.0 for x64" >&2
exit 2
EOF
chmod +x "$fx/fakebin/cl"

bash "$here/../scripts/gen-manifest.sh" "$fx/linux-prefix" default linux-x86_64 \
  "$fx/iree-src" 3.11.0 3.11.0 >/dev/null
PATH="$fx/fakebin:$PATH" bash "$here/../scripts/gen-manifest.sh" "$fx/windows-prefix" default windows-x86_64 \
  "$fx/iree-src" 3.11.0 3.11.0 >/dev/null

m="$fx/linux-prefix/share/iree-runtime-dist/manifest.json"
mw="$fx/windows-prefix/share/iree-runtime-dist/manifest.json"

# Provenance keys are platform-conditional, following the existing conditional
# `sanitizer` idiom. schema_version stays 2 -- the change is purely additive.
assert_eq "$(get "$mw" "['schema_version']")" "2"             "windows manifest stays schema 2"
assert_eq "$(get "$mw" "['msvc_toolset']")"   "19.44.35228.0" "windows records msvc_toolset"
assert_eq "$(get "$mw" "['crt']")"            "MT"            "windows records the static CRT"

# Mutual absence is the assertion that stops the two provenance models silently
# merging later. A Windows manifest must not carry a glibc value, and a Linux
# manifest must not carry MSVC keys.
assert_eq "$(getd "$mw" "glibc_build"  "ABSENT")" "ABSENT" "windows omits glibc_build"
assert_eq "$(getd "$m"  "msvc_toolset" "ABSENT")" "ABSENT" "linux omits msvc_toolset"
assert_eq "$(getd "$m"  "crt"          "ABSENT")" "ABSENT" "linux omits crt"

# The crt note must carry the same honesty caveat glibc_build has: with /MT the
# archives emit only /DEFAULTLIB:LIBCMT directives, so the CRT is resolved at the
# consumer's final link. It is NOT a compatibility floor.
assert_contains "$(get "$mw" "['notes']['crt']")" "final link" "crt note states where the CRT resolves"

# --- <prefix>-based structural checks (skip when no prefix given) ----------
prefix="${1:-}"
if [ -z "$prefix" ]; then echo "skip: remaining manifest.test.sh checks need a built prefix"; exit "$ASSERT_FAILS"; fi

m="$prefix/share/iree-runtime-dist/manifest.json"
if [ -e "$m" ]; then echo "ok: manifest.json present"
else echo "FAIL: manifest.json missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); exit "$ASSERT_FAILS"; fi

assert_eq "$(get "$m" "['schema_version']")"       "2"        "schema_version"
assert_eq "$(get "$m" "['iree_version']")"         "3.11.0"   "iree_version"
assert_eq "$(get "$m" "['iree_tag']")"             "v3.11.0"  "iree_tag"
assert_eq "$(get "$m" "['iree_compile_version']")" "3.11.0"   "paired compiler version"

# vm_bytecode_version (design lines 119, 214): the HAL/VM module ABI version
# the shipped runtime expects, read from its own installed header -- must
# look like a real MAJOR.MINOR pair, never absent or a placeholder.
vbv="$(get "$m" "['vm_bytecode_version']")"
if printf '%s' "$vbv" | grep -qE '^[0-9]+\.[0-9]+$'; then
  echo "ok: vm_bytecode_version looks like MAJOR.MINOR ($vbv)"
else
  echo "FAIL: vm_bytecode_version '$vbv' is not a MAJOR.MINOR version" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

# runtime_commit must be a real 40-char sha, not a placeholder.
c="$(get "$m" "['runtime_commit']")"
if printf '%s' "$c" | grep -qE '^[0-9a-f]{40}$'; then echo "ok: runtime_commit is a full sha"
else echo "FAIL: runtime_commit '$c' is not a 40-char sha" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

# Build-config attestation (wishlist #7).
assert_eq "$(get "$m" "['build_config']['IREE_BUILD_COMPILER']")"    "OFF" "compiler off attested"
assert_eq "$(get "$m" "['build_config']['BUILD_SHARED_LIBS']")"      "OFF" "static attested"
assert_eq "$(get "$m" "['build_config']['CMAKE_BUILD_TYPE']")"       "Release" "release attested"
assert_eq "$(get "$m" "['build_config']['IREE_HAL_DRIVER_LOCAL_TASK']")" "ON" "local-task attested"

if [ -e "$prefix/BUILDINFO" ]; then echo "ok: BUILDINFO present"
else echo "FAIL: BUILDINFO missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

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
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

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
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

exit "$ASSERT_FAILS"
