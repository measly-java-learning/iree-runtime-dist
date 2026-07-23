#!/usr/bin/env bash
# Consumer acceptance gate. Usage: run.sh <prefix>
#
# Run this in a container with NO build tree and NO IREE source. Passing here is
# the property the "point IREE_INSTALL at a build tree" escape hatch never had.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="$(cd "${1:?usage: run.sh <prefix>}" && pwd)"

. "$HERE/mode.sh"

build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

mode="$(consumer_run_mode "$PREFIX")"
echo "==> consumer run mode: $mode"

# A sanitizer variant is instrumented by clang's compiler-rt; its INTERFACE flag
# makes the consumer link -fsanitize=thread too. The consumer MUST build with
# clang so clang's TSan runtime resolves the __tsan_* symbols -- gcc's libtsan is
# a different, non-interchangeable runtime (and isn't present in the manylinux
# image). This mirrors exactly what a downstream consumer of the tsan variant
# must do, and is documented in share/iree-runtime-dist/TSAN.md.
compiler_args=()
if [ "$mode" = "tsan" ]; then
  # consumer.c is a C-only project, so only the C compiler matters here.
  compiler_args=(-DCMAKE_C_COMPILER=clang)
fi

echo "==> configuring consumer against $PREFIX"
cmake -G Ninja -B "$build" -S "$HERE" \
  -DCMAKE_PREFIX_PATH="$PREFIX/lib/cmake/IreeRuntimeDist" \
  -DCMAKE_BUILD_TYPE=Release \
  "${compiler_args[@]}"

echo "==> building consumer"
cmake --build "$build"

vmfb="$PREFIX/share/iree-runtime-dist/add.vmfb"
if [ ! -s "$vmfb" ]; then
  echo "FAIL: shipped module not found or empty: $vmfb" >&2
  exit 1
fi

fails=0
if [ "$mode" = "tsan" ]; then
  # A thread-sanitized prefix already links -fsanitize=thread into the
  # consumer binary via iree-runtime-dist::runtime's INTERFACE flag (Task 4).
  # Drive the worker pool over local-task and require a clean TSan run.
  echo "==> running with local-task under ThreadSanitizer"
  supp=""
  if [ -f "$PREFIX/share/iree-runtime-dist/tsan.supp" ]; then
    supp="suppressions=$PREFIX/share/iree-runtime-dist/tsan.supp"
  fi
  if out="$(TSAN_OPTIONS="halt_on_error=1 $supp" "$build/consumer" "$vmfb" local-task 2>&1)"; then
    if echo "$out" | grep -q "ThreadSanitizer:"; then
      echo "$out"
      echo "FAIL: tsan reported a race over local-task" >&2
      fails=$((fails + 1))
    elif ! echo "$out" | grep -q "11, 22, 33, 44"; then
      echo "$out"
      echo "FAIL: wrong result under tsan" >&2
      fails=$((fails + 1))
    else
      echo "$out"
      echo "ok: tsan clean over local-task"
    fi
  else
    echo "$out"
    echo "FAIL: consumer crashed under tsan" >&2
    fails=$((fails + 1))
  fi
else
  # Both drivers ship in one tarball and the consumer picks at runtime, so both
  # must work. Driver names, not URIs: iree_runtime_instance_try_create_default_device
  # does an exact string compare against the registered driver name
  # (driver_module.c), so "local-sync://" would fail to resolve.
  for driver in "local-sync" "local-task"; do
    echo "==> running with $driver"
    if "$build/consumer" "$vmfb" "$driver"; then
      echo "ok: $driver"
    else
      echo "FAIL: consumer failed with $driver" >&2
      fails=$((fails + 1))
    fi
  done
fi

if [ "$fails" -ne 0 ]; then
  echo "CONSUMER E2E FAILED ($fails driver(s))" >&2
  exit 1
fi
echo "CONSUMER E2E PASSED"
