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

assert_eq "$(get "$m" "['schema_version']")"       "1"        "schema_version"
assert_eq "$(get "$m" "['variant']")"              "default"  "variant"
assert_eq "$(get "$m" "['platform']")"             "linux-x86_64" "platform"
assert_eq "$(get "$m" "['iree_version']")"         "3.11.0"   "iree_version"
assert_eq "$(get "$m" "['iree_tag']")"             "v3.11.0"  "iree_tag"
assert_eq "$(get "$m" "['iree_compile_version']")" "3.11.0"   "paired compiler version"

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

exit "$ASSERT_FAILS"
