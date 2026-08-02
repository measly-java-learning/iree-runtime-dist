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

exit "$ASSERT_FAILS"
