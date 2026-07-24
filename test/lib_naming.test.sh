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

# Build-image identity is keyed off the same platform token as the assets, so the
# image tag, its Dockerfile, and the artifact platform can never drift apart.
assert_eq "$(build_image_tag linux-x86_64)"  "iree-runtime-dist-build:linux-x86_64" "build_image_tag"
assert_eq "$(build_dockerfile linux-x86_64)" "docker/linux-x86_64.Dockerfile"       "build_dockerfile"

assert_eq "$(build_image_tag linux-aarch64)"  "iree-runtime-dist-build:linux-aarch64" "build_image_tag"
assert_eq "$(build_dockerfile linux-aarch64)" "docker/linux-aarch64.Dockerfile"       "build_dockerfile"

# The Dockerfile every known platform names must actually exist on disk -- otherwise
# a future platform added to PLATFORMS would fail only at CI image-build time.
for p in $(known_platforms); do
  df="$(cd "$here/.." && pwd)/$(build_dockerfile "$p")"
  assert_eq "$([ -f "$df" ] && echo yes || echo NO)" "yes" "dockerfile exists for $p"
done
exit "$ASSERT_FAILS"
