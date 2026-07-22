#!/usr/bin/env bash
# Build (or rebuild) the local manylinux_2_28 specialization used by every
# build/verify invocation in this project, and print the resolved tool
# versions baked into it so a human can confirm what they got.
#
# Idempotent: `docker build` on an unchanged Dockerfile is a no-op cache hit,
# and this script can be re-run any number of times safely.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/naming.sh"

# Build every known platform's image (currently just linux-x86_64). Tag and
# Dockerfile are derived from naming.sh, so this needs no edit when a platform
# is added -- only a new docker/<platform>.Dockerfile. An arg selects one.
platforms="${1:-$(known_platforms)}"

for platform in $platforms; do
  image_tag="$(build_image_tag "$platform")"
  dockerfile="$ROOT/$(build_dockerfile "$platform")"

  echo "==> building $image_tag from $(build_dockerfile "$platform")"
  docker build -t "$image_tag" -f "$dockerfile" "$ROOT/docker"

  echo "==> resolved tool versions in $image_tag"
  docker run --rm "$image_tag" bash -lc '
    echo "clang:      $(clang --version | head -1)"
    echo "lld:        $(ld.lld --version)"
    echo "ninja:      $(ninja --version)"
    echo "patchelf:   $(patchelf --version) (from $(command -v patchelf))"
    echo "glibc:      $(getconf GNU_LIBC_VERSION)"
  '

  echo "==> $image_tag ready"
done
