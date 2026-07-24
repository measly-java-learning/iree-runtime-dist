#!/usr/bin/env bash
# Usage: manifest.test.sh <prefix>. Skips when no prefix given.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
prefix="${1:-}"
if [ -z "$prefix" ]; then echo "skip: manifest.test.sh needs a built prefix"; exit 0; fi

m="$prefix/share/iree-runtime-dist/manifest.json"
if [ -e "$m" ]; then echo "ok: manifest.json present"
else echo "FAIL: manifest.json missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); exit "$ASSERT_FAILS"; fi

get() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d$2)" "$m"; }

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
