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

IMAGE_TAG="iree-runtime-dist-build:manylinux_2_28"

echo "==> building $IMAGE_TAG from docker/Dockerfile"
docker build -t "$IMAGE_TAG" -f "$ROOT/docker/Dockerfile" "$ROOT/docker"

echo "==> resolved tool versions in $IMAGE_TAG"
docker run --rm "$IMAGE_TAG" bash -lc '
  echo "clang:      $(clang --version | head -1)"
  echo "lld:        $(ld.lld --version)"
  echo "ninja:      $(ninja --version)"
  echo "patchelf:   $(patchelf --version) (from $(command -v patchelf))"
  echo "glibc:      $(getconf GNU_LIBC_VERSION)"
'

echo "==> $IMAGE_TAG ready"
