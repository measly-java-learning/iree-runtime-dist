#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/naming.sh"
assert_eq "$(asset_stem 3.11.0 default linux-x86_64)"   "iree-runtime-3.11.0-default-linux-x86_64"           "asset_stem"
assert_eq "$(tarball_name 3.11.0 default linux-x86_64)" "iree-runtime-3.11.0-default-linux-x86_64.tar.gz"    "tarball_name"
assert_eq "$(sha_name 3.11.0 default linux-x86_64)"     "iree-runtime-3.11.0-default-linux-x86_64.tar.gz.sha256" "sha_name"

assert_eq "$(asset_stem 3.11.0 default linux-aarch64)"   "iree-runtime-3.11.0-default-linux-aarch64"           "asset_stem"
assert_eq "$(tarball_name 3.11.0 default linux-aarch64)" "iree-runtime-3.11.0-default-linux-aarch64.tar.gz"    "tarball_name"
assert_eq "$(sha_name 3.11.0 default linux-aarch64)"     "iree-runtime-3.11.0-default-linux-aarch64.tar.gz.sha256" "sha_name"

assert_eq "$(asset_stem 3.11.0 default windows-x86_64)"   "iree-runtime-3.11.0-default-windows-x86_64"        "asset_stem windows"
assert_eq "$(tarball_name 3.11.0 default windows-x86_64)" "iree-runtime-3.11.0-default-windows-x86_64.tar.gz" "tarball_name windows stays .tar.gz"

# The full-list functions must stay unchanged -- release.yml still needs the
# complete platform list, since windows-x86_64 IS a release platform even
# though it is not a build-image platform.
assert_eq "$(known_platforms | tr '\n' ' ' | sed 's/ $//')" "linux-x86_64 linux-aarch64 windows-x86_64" \
  "known_platforms still lists all platforms including windows-x86_64"

# parse_asset -- the inverse of asset_stem, shared by gen-pin.sh and the
# release-notes renderer. Accepts tarball and sha basenames.
assert_eq "$(parse_asset iree-runtime-3.11.0-default-linux-x86_64.tar.gz)"        "3.11.0 default linux-x86_64"   "parse_asset tarball"
assert_eq "$(parse_asset iree-runtime-3.11.0-default-linux-x86_64.tar.gz.sha256)"  "3.11.0 default linux-x86_64"   "parse_asset sha"
assert_eq "$(parse_asset iree-runtime-3.11.0-tsan-linux-aarch64.tar.gz)"           "3.11.0 tsan linux-aarch64"     "parse_asset tsan"
assert_eq "$(parse_asset iree-runtime-3.11.0-default-windows-x86_64.tar.gz)"       "3.11.0 default windows-x86_64" "parse_asset windows"

if parse_asset iree-runtime-3.11.0-10-default-linux-x86_64.tar.gz >/dev/null 2>&1; then
  printf 'FAIL: parse_asset should reject a pkgrev-in-name (variant token with a dash)\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok: parse_asset rejects a dash in the variant token\n'
fi
if parse_asset bogus.tar.gz >/dev/null 2>&1; then
  printf 'FAIL: parse_asset should reject a non-round-tripping name\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok: parse_asset rejects a non-round-tripping name\n'
fi

exit "$ASSERT_FAILS"
