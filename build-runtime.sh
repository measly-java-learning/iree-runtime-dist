#!/usr/bin/env bash
# Single entrypoint for the IREE runtime dist build recipe.
#
# Must run inside quay.io/pypa/manylinux_2_28_x86_64. Never clones IREE --
# the caller always supplies --iree-src (CI via actions/checkout, locally a mount).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/scripts/lib/variants.sh"
. "$HERE/scripts/lib/cmakeflags.sh"

VARIANT="default"
PREFIX=""
IREE_SRC=""
BUILD_DIR=""
PRINT_FLAGS=0

usage() {
  cat <<'EOF'
usage: build-runtime.sh --variant <default> --prefix <dir> --iree-src <checkout> [--build-dir <dir>]
       build-runtime.sh --print-flags [--variant <default>]

  --variant      runtime variant (default: default)
  --prefix       install prefix for the staged tree
  --iree-src     checkout of iree-org/iree at the target tag, with required submodules
  --build-dir    cmake build tree (default: <dirname of prefix>/iree-build-<variant>)
  --print-flags  print the effective cmake flags and exit; needs no source tree

Env:
  HOST_UID, HOST_GID   if set, chown BUILD_DIR and PREFIX back to this
                       uid:gid on exit (success or failure) -- fixes up the
                       root ownership left by a container bind mount. Unset
                       in CI, where the runner already runs as a normal user.
EOF
}

require_value() { # <flag>
  [ $# -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --variant)     require_value "$@"; VARIANT="$2"; shift 2 ;;
    --prefix)      require_value "$@"; PREFIX="$2"; shift 2 ;;
    --iree-src)    require_value "$@"; IREE_SRC="$2"; shift 2 ;;
    --build-dir)   require_value "$@"; BUILD_DIR="$2"; shift 2 ;;
    --print-flags) PRINT_FLAGS=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$PRINT_FLAGS" -eq 1 ]; then
  effective_cmake_flags "$VARIANT"
  exit 0
fi

[ -n "$PREFIX" ]   || { echo "error: --prefix is required" >&2; exit 2; }
[ -n "$IREE_SRC" ] || { echo "error: --iree-src is required (this recipe never clones IREE)" >&2; exit 2; }
[ -d "$IREE_SRC" ] || { echo "error: --iree-src '$IREE_SRC' is not a directory" >&2; exit 2; }

if [ -z "$BUILD_DIR" ]; then
  BUILD_DIR="$(dirname "$PREFIX")/iree-build-${VARIANT}"
fi

echo "build-runtime.sh: variant=$VARIANT prefix=$PREFIX build-dir=$BUILD_DIR"

# This script runs inside a container with a bind-mounted volume, so everything
# it writes (BUILD_DIR and PREFIX) is owned by container-root on the host. Use a
# trap -- not a trailing command -- so ownership gets fixed even when the build
# FAILS partway through; a failed run must not leave a root-owned tree the host
# user can't clean up without sudo. rc=$? / exit "$rc" re-raises the original
# exit code so this never masks a build failure as success. No-op when HOST_UID
# is unset (the CI case: GitHub Actions already runs as a normal user).
# Mirrors executorch-runtime-dist/build-runtime.sh; HOST_UID/HOST_GID names kept
# identical since Task 13's CI workflow references them.
cleanup() {
  rc=$?
  if [ -n "${HOST_UID:-}" ]; then
    chown -R "${HOST_UID}:${HOST_GID}" "${BUILD_DIR}" 2>/dev/null || true
    [ -d "${PREFIX}" ] && chown -R "${HOST_UID}:${HOST_GID}" "${PREFIX}" 2>/dev/null || true
  fi
  exit "$rc"
}
trap cleanup EXIT

# --- Phase 1: configure, build, install -------------------------------------

# Verify the caller supplied the submodules the runtime build needs. Failing here
# with a clear message beats a confusing CMake error 30 seconds in.
#
# NOTE: not every required submodule has a top-level CMakeLists.txt (e.g.
# hip-build-deps, hsa-runtime-headers, musl, webgpu-headers are header/data-only
# submodules with no build of their own at this path). Testing for CMakeLists.txt
# would false-fail on those even when properly initialized. Instead check that the
# submodule directory exists and is non-empty -- the reliable signal that
# `git submodule update --init` has actually populated it (an uninitialized
# submodule path is an empty directory).
. "$HERE/scripts/lib/submodules.sh"
for sm in $IREE_REQUIRED_SUBMODULES; do
  if [ ! -d "$IREE_SRC/$sm" ] || [ -z "$(ls -A "$IREE_SRC/$sm" 2>/dev/null)" ]; then
    echo "error: required submodule '$sm' is not initialized in $IREE_SRC" >&2
    echo "hint: git -C '$IREE_SRC' submodule update --init --depth 1 $sm" >&2
    exit 2
  fi
done

mapfile -t FLAGS < <(effective_cmake_flags "$VARIANT")

# -ffile-prefix-map keeps __FILE__ (which IREE embeds in status strings) and DWARF
# DW_AT_comp_dir relative, so published artifacts carry no build-machine paths.
PREFIX_MAP="-ffile-prefix-map=${IREE_SRC}=iree"

echo "==> configuring"
cmake -G Ninja -B "$BUILD_DIR" -S "$IREE_SRC" \
  "${FLAGS[@]}" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_C_FLAGS="$PREFIX_MAP" \
  -DCMAKE_CXX_FLAGS="$PREFIX_MAP"

echo "==> building"
cmake --build "$BUILD_DIR"

echo "==> installing to $PREFIX"
# The step the walking skeleton skipped. Running it is what makes the export set
# real -- and with it the flatcc transitives, the IREE_ALLOCATOR_SYSTEM_CTL define,
# the merged include dirs, and link ordering all come free as target properties.
#
# A bare `cmake --install` is NOT enough: IREE's own
# build_tools/cmake/iree_install_support.cmake marks every library install rule
# EXCLUDE_FROM_ALL (both the archive `install(TARGETS ...)` and the associated
# header `install(FILES ...)`), specifically so that a default `make install`
# from a full (compiler + runtime) build doesn't dump everything into one prefix.
# That means a bare install copies only the always-on pieces (bin/, lib/cmake/)
# and silently installs ZERO .a archives and ZERO headers -- the CMake export set
# still gets generated and still looks complete (196+ IMPORTED_LOCATION entries),
# but every one of those entries points at a file that was never installed, so
# find_package(IREERuntime) succeeds and the first downstream link fails instead.
# Do NOT "simplify" this back to a bare `cmake --install` -- that is precisely
# what silently ships a package with no archives.
#
# Install only the components this project's artifact contract needs, by name:
#   IREEDevLibraries-Runtime  -- runtime headers + static libraries (the payload)
#   IREEBundledLibraries      -- bundled deps pulled in transitively (flatcc, etc.)
#   IREECMakeExports          -- IREERuntimeConfig.cmake + the IREETargets-*.cmake files
# Deliberately excluded:
#   IREETools-Runtime         -- CLI tools (iree-run-module, etc.); contract is
#                                lib/ + include/ + share/ + LICENSE, no bin/
#   IREEDevLibraries-Compiler -- the IREE compiler is out of contract for this
#                                project and must never be installed (-DIREE_BUILD_COMPILER=OFF)
for _component in IREEDevLibraries-Runtime IREEBundledLibraries IREECMakeExports; do
  cmake --install "$BUILD_DIR" --component "$_component" --prefix "$PREFIX"
done

# IREE's top-level CMakeLists.txt does `add_subdirectory(build_tools/third_party/printf
# EXCLUDE_FROM_ALL)`. CMake's documented behavior for an EXCLUDE_FROM_ALL subdirectory is
# that its cmake_install.cmake is never chained into the parent directory's install script
# -- so the component-scoped installs above never reach it, even though the export set's
# IREETargets-Runtime-release.cmake references libprintf_printf.a via IMPORTED_LOCATION.
# Install that one subdirectory's IREEBundledLibraries component explicitly, or the printf
# archive silently never lands in $PREFIX/lib despite the export set claiming it exists.
cmake --install "$BUILD_DIR/build_tools/third_party/printf" --component IREEBundledLibraries --prefix "$PREFIX"

echo "==> phase 1 complete"
