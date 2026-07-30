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

assert_eq "$(build_dockerfile linux-x86_64)" "docker/linux-x86_64.Dockerfile"       "build_dockerfile"
assert_eq "$(build_dockerfile linux-aarch64)" "docker/linux-aarch64.Dockerfile"       "build_dockerfile"

# An unknown platform must be an error, not a silent default.
platform_toolchain bogus-platform >/dev/null 2>&1
assert_eq "$?" "2" "platform_toolchain rejects an unknown platform"

# Asking a runner platform for a build image is a programming error and must fail
# loudly -- a silent empty string would produce `docker build -f ''` at CI time.
build_dockerfile windows-x86_64 >/dev/null 2>&1
assert_eq "$?" "2" "build_dockerfile refuses a runner platform"
build_image_tag windows-x86_64 >/dev/null 2>&1
assert_eq "$?" "2" "build_image_tag refuses a runner platform"

assert_eq "$(asset_stem 3.11.0 default windows-x86_64)"   "iree-runtime-3.11.0-default-windows-x86_64"        "asset_stem windows"
assert_eq "$(tarball_name 3.11.0 default windows-x86_64)" "iree-runtime-3.11.0-default-windows-x86_64.tar.gz" "tarball_name windows stays .tar.gz"

# The Dockerfile every CONTAINER platform names must exist on disk -- otherwise a
# future platform added to PLATFORMS would fail only at CI image-build time.
# Runner platforms deliberately have no Dockerfile; assert that too, so a stray
# docker/windows-x86_64.Dockerfile can't appear unnoticed.
for p in $(known_platforms); do
  case "$(platform_toolchain "$p")" in
    container)
      df="$(cd "$here/.." && pwd)/$(build_dockerfile "$p")"
      assert_eq "$([ -f "$df" ] && echo yes || echo NO)" "yes" "dockerfile exists for $p"
      ;;
    runner)
      df="$(cd "$here/.." && pwd)/docker/$p.Dockerfile"
      assert_eq "$([ -f "$df" ] && echo NO || echo yes)" "yes" "no dockerfile for runner platform $p"
      ;;
  esac
done
# container_platforms/containers_json are the filtered subset that build-image.sh
# and warm-build-image.yml must use -- iterating known_platforms/platforms_json
# there would call build_image_tag/build_dockerfile on windows-x86_64 and abort.
assert_eq "$(container_platforms | tr '\n' ' ' | sed 's/ $//')" "linux-x86_64 linux-aarch64" \
  "container_platforms excludes windows-x86_64"
assert_contains "$(container_platforms)" "linux-x86_64"  "container_platforms includes linux-x86_64"
assert_contains "$(container_platforms)" "linux-aarch64" "container_platforms includes linux-aarch64"

assert_eq "$(containers_json)" '["linux-x86_64", "linux-aarch64"]' \
  "containers_json emits only container platforms"

# The full-list functions must stay unchanged -- release.yml still needs the
# complete platform list, since windows-x86_64 IS a release platform even
# though it is not a build-image platform.
assert_eq "$(known_platforms | tr '\n' ' ' | sed 's/ $//')" "linux-x86_64 linux-aarch64 windows-x86_64" \
  "known_platforms still lists all platforms including windows-x86_64"
assert_eq "$(platforms_json)" '["linux-x86_64", "linux-aarch64", "windows-x86_64"]' \
  "platforms_json still emits the full list"

exit "$ASSERT_FAILS"
