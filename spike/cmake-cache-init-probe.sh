#!/usr/bin/env bash
# Reproducible evidence for the two CMake mechanism claims in
# docs/superpowers/notes/2026-07-29-package-port-regime.md idiom 1.
#
# Self-contained: builds its own throwaway fixture in a temp dir, needs no IREE
# source and no build image. Run it directly on the host, or inside the build
# container to check the CMake version we actually ship with:
#
#   bash spike/cmake-cache-init-probe.sh
#   docker run --rm -v "$PWD/spike:/s:ro" iree-runtime-dist-build:linux-x86_64 \
#     bash /s/cmake-cache-init-probe.sh
#
# Verified identical on host CMake 3.28.3 and container CMake 4.3.2 (2026-07-29).
#
# PROBE A -- does `cmake -C` support what the design needs?
#   A1 include() composes, so cmake/common.cmake + cmake/<platform>.cmake works
#      without an inheritance algorithm of our own.
#   A2 $ENV{} supplies the path-dependent values (the prefix-map path, the
#      variant cflags), composed once in the file that sets CMAKE_C_FLAGS.
#   A3 a command-line -D still overrides a cache-init value (non-FORCE `set`).
#   A4 cache-init keys land in CMakeCache.txt TYPED (FOO:STRING) while an ad-hoc
#      -D lands UNINITIALIZED -- so declared keys are mechanically separable from
#      incidental ones when reading provenance back out of the cache.
#
# PROBE B -- why toolchain-file CMAKE_<LANG>_FLAGS_INIT is NOT usable here.
#   B1 control: FLAGS_INIT alone reaches CMAKE_C_FLAGS.
#   B2 FLAGS_INIT + a non-empty command-line -DCMAKE_C_FLAGS: _INIT is DROPPED,
#      not merged.
#   B3 FLAGS_INIT + an EMPTY -DCMAKE_C_FLAGS: still dropped.
#      cmake_initialize_per_config_variable does a non-FORCE
#      `set(CMAKE_C_FLAGS "${_INIT}" CACHE STRING ...)`, and a command-line -D
#      has already created that entry -- an empty string counts as created.
#      B3 is why the superseded CMakePresets.json design would have lost
#      -ffile-prefix-map / /d1trimfile: on BOTH variants (default passes an empty
#      VARIANT_CFLAGS), shipping absolute build paths.
#
# Uses a benign -D flag as the stand-in for variant cflags, NOT
# -fsanitize=thread: with no explicit -DCMAKE_C_COMPILER, CMake picks the
# container's default cc (gcc, no TSan runtime) and the compiler check fails for
# reasons that have nothing to do with the mechanism under test. The real build
# always names clang explicitly.
set -euo pipefail

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"
mkdir -p src

cat > src/CMakeLists.txt <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(probe C)
message(STATUS "PROBE FOO=${FOO}")
message(STATUS "PROBE CFLAGS=[${CMAKE_C_FLAGS}]")
message(STATUS "PROBE OVERRIDE=${OVERRIDE_ME}")
EOF

cat > common.cmake <<'EOF'
set(FOO "from-common" CACHE STRING "")
set(OVERRIDE_ME "cache-init-value" CACHE STRING "")
EOF

cat > init.cmake <<'EOF'
include("${CMAKE_CURRENT_LIST_DIR}/common.cmake")
set(CMAKE_C_FLAGS "-ffile-prefix-map=$ENV{IREE_SRC}=iree $ENV{VARIANT_CFLAGS}" CACHE STRING "")
EOF

cat > tc.cmake <<'EOF'
set(CMAKE_C_FLAGS_INIT "-ffile-prefix-map=/work/iree=iree")
EOF

echo "=== $(cmake --version | head -1) ==="

echo "--- A: -C  include() + \$ENV{} + command-line -D override ---"
IREE_SRC=/work/iree VARIANT_CFLAGS="-DVARIANT_MARKER=1" \
  cmake -C init.cmake -S src -B build -DOVERRIDE_ME=cmdline-wins 2>&1 | grep -E "PROBE|CMake Error"

echo "--- A4: cache readback (note the types) ---"
grep -E "^(FOO|CMAKE_C_FLAGS|OVERRIDE_ME):" build/CMakeCache.txt

echo "--- B1: FLAGS_INIT alone (control -- expect the prefix-map) ---"
cmake -S src -B b1 -DCMAKE_TOOLCHAIN_FILE="$work/tc.cmake" 2>&1 | grep "PROBE CFLAGS"

echo "--- B2: FLAGS_INIT + non-empty -DCMAKE_C_FLAGS (expect prefix-map GONE) ---"
cmake -S src -B b2 -DCMAKE_TOOLCHAIN_FILE="$work/tc.cmake" \
  -DCMAKE_C_FLAGS="-DVARIANT_MARKER=1" 2>&1 | grep "PROBE CFLAGS"

echo "--- B3: FLAGS_INIT + EMPTY -DCMAKE_C_FLAGS (expect EMPTY, not the prefix-map) ---"
cmake -S src -B b3 -DCMAKE_TOOLCHAIN_FILE="$work/tc.cmake" \
  -DCMAKE_C_FLAGS="" 2>&1 | grep "PROBE CFLAGS"
