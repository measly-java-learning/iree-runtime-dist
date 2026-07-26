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

# Platforms differ in HOW they get a toolchain. Container platforms build from a
# Dockerfile; runner platforms take it from a pinned CI image plus a VS dev shell.
assert_eq "$(platform_toolchain linux-x86_64)"   "container" "linux-x86_64 is containerised"
assert_eq "$(platform_toolchain linux-aarch64)"  "container" "linux-aarch64 is containerised"
assert_eq "$(platform_toolchain windows-x86_64)" "runner"    "windows-x86_64 is runner-native"

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
exit "$ASSERT_FAILS"
