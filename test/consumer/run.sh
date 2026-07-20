#!/usr/bin/env bash
# Consumer acceptance gate. Usage: run.sh <prefix>
#
# Run this in a container with NO build tree and NO IREE source. Passing here is
# the property the "point IREE_INSTALL at a build tree" escape hatch never had.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="$(cd "${1:?usage: run.sh <prefix>}" && pwd)"

build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

echo "==> configuring consumer against $PREFIX"
cmake -G Ninja -B "$build" -S "$HERE" \
  -DCMAKE_PREFIX_PATH="$PREFIX/lib/cmake/IreeRuntimeDist" \
  -DCMAKE_BUILD_TYPE=Release

echo "==> building consumer"
cmake --build "$build"

vmfb="$PREFIX/share/iree-runtime-dist/add.vmfb"
if [ ! -s "$vmfb" ]; then
  echo "FAIL: shipped module not found or empty: $vmfb" >&2
  exit 1
fi

# Both drivers ship in one tarball and the consumer picks at runtime, so both
# must work. Driver names, not URIs: iree_runtime_instance_try_create_default_device
# does an exact string compare against the registered driver name
# (driver_module.c), so "local-sync://" would fail to resolve.
fails=0
for driver in "local-sync" "local-task"; do
  echo "==> running with $driver"
  if "$build/consumer" "$vmfb" "$driver"; then
    echo "ok: $driver"
  else
    echo "FAIL: consumer failed with $driver" >&2
    fails=$((fails + 1))
  fi
done

if [ "$fails" -ne 0 ]; then
  echo "CONSUMER E2E FAILED ($fails driver(s))" >&2
  exit 1
fi
echo "CONSUMER E2E PASSED"
