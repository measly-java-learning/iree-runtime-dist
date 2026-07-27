#!/usr/bin/env bash
# Single entrypoint for the IREE runtime dist build recipe.
#
# Must run inside quay.io/pypa/manylinux_2_28_x86_64. Never clones IREE --
# the caller always supplies --iree-src (CI via actions/checkout, locally a mount).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/scripts/lib/variants.sh"
. "$HERE/scripts/lib/cmakeflags.sh"
. "$HERE/scripts/lib/naming.sh"

VARIANT="default"
PREFIX=""
IREE_SRC=""
BUILD_DIR=""
PLATFORM=""
PRINT_FLAGS=0

usage() {
  cat <<'EOF'
usage: build-runtime.sh --variant <default> --prefix <dir> --iree-src <checkout> [--build-dir <dir>]
       build-runtime.sh --print-flags [--variant <default>]

  --variant      runtime variant (default: default)
  --prefix       install prefix for the staged tree
  --iree-src     checkout of iree-org/iree at the target tag, with required submodules
  --build-dir    cmake build tree (default: <dirname of prefix>/iree-build-<variant>)
  --platform     target platform token (default: host arch); one of naming.sh's
                 known_platforms. Feeds manifest.json/BUILDINFO provenance and
                 platform-specific source patches.
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
    --platform)    require_value "$@"; PLATFORM="$2"; shift 2 ;;
    --print-flags) PRINT_FLAGS=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

# Resolve the target platform token. It feeds manifest.json/BUILDINFO provenance
# (via gen-manifest.sh and the @PLATFORM@ substitutions below), the aarch64
# source patch in Phase 1, and (below) which compiler-flag/repair branch runs --
# so it MUST reflect the arch actually being built, not a fixed list index.
# Default to the host arch so a bare local run is correct; CI passes --platform
# explicitly from the build matrix. The value must be one of naming.sh's
# known_platforms, the single source of truth for platform tokens.
#
# Resolved BEFORE the --print-flags early-exit below (not after, where this
# lived originally) because --print-flags now needs PLATFORM to pick the
# right compiler flags and cache vars -- a caller that passes --print-flags
# --platform windows-x86_64 must see Windows flags, not fall through to a
# not-yet-resolved empty PLATFORM.
if [ -z "$PLATFORM" ]; then
  case "$(uname -m)" in
    x86_64)        PLATFORM="linux-x86_64" ;;
    aarch64|arm64) PLATFORM="linux-aarch64" ;;
    *) echo "error: unsupported host arch '$(uname -m)'; pass --platform explicitly" >&2; exit 2 ;;
  esac
fi
known_platforms | grep -qx "$PLATFORM" \
  || { echo "error: unknown --platform '$PLATFORM' (known: $(known_platforms | paste -sd' ' -))" >&2; exit 2; }

# variant_cflags is the injection point for non-cache-var compiler flags (e.g.
# tsan's -fsanitize=thread -g). Compose once so the build, --print-flags, and any
# provenance use the identical string.
VARIANT_CFLAGS="$(variant_cflags "$VARIANT")"

if [ "$(platform_toolchain "$PLATFORM")" = container ]; then
  # -ffile-prefix-map keeps __FILE__ (which IREE embeds in status strings) and
  # DWARF DW_AT_comp_dir relative, so published artifacts carry no
  # build-machine paths. clang/gcc-only -- not understood by cl.exe.
  PREFIX_MAP="-ffile-prefix-map=${IREE_SRC}=iree"
  COMPILER_FLAGS="$PREFIX_MAP${VARIANT_CFLAGS:+ $VARIANT_CFLAGS}"
elif [ -n "$IREE_SRC" ]; then
  # Windows: /d1trimfile: is MSVC's -ffile-prefix-map analog -- verified
  # working on the pinned CI toolset (cl 19.44.35228, VS 2022): baseline
  # __FILE__ "C:\trimtest\sub\foo.c" became "sub\foo.c" using the probe
  # `-d1trimfile:C:\trimtest\` -- ONE trailing backslash, not doubled. Unlike
  # -ffile-prefix-map it TRIMS A PREFIX rather than remapping to a token, so
  # the prefix must be the source root WITH that trailing backslash or the
  # last path component gets glued onto the following relative path.
  #
  # cl.exe bakes __FILE__ in as a Windows path (C:\...), but this recipe
  # runs under Git-Bash on the actual Windows runner, so $IREE_SRC arrives
  # as a POSIX-style mount path (e.g. /c/Users/cored/workspace/iree).
  # /d1trimfile: only trims a LITERAL prefix match against what cl.exe
  # actually emits -- a POSIX-flavoured prefix matches nothing and silently
  # leaves every absolute __FILE__ path in the shipped archives, the same
  # silent-no-op failure mode this whole guard exists to avoid. Convert with
  # cygpath -w (Git-Bash-provided) when it's on PATH; when it isn't (e.g.
  # this script's hermetic --print-flags tests, which run on a non-Windows
  # host to exercise flag assembly only) fall back to the raw value -- that
  # value is never fed to a real cl.exe in that case.
  if command -v cygpath >/dev/null 2>&1; then
    _trimfile_src="$(cygpath -w "$IREE_SRC")"
  else
    _trimfile_src="$IREE_SRC"
  fi
  TRIMFILE_FLAG="/d1trimfile:${_trimfile_src}\\"
  COMPILER_FLAGS="$TRIMFILE_FLAG${VARIANT_CFLAGS:+ $VARIANT_CFLAGS}"
else
  # --print-flags is documented to need no source tree, so IREE_SRC may be
  # empty here. A /d1trimfile: with an EMPTY prefix trims nothing -- every
  # archive would keep its absolute __FILE__ paths while the build looks
  # configured correctly, exactly the silent-no-op class this branch has
  # already hit twice. Omit the flag entirely rather than emit a
  # prefix-less one; a real build always supplies --iree-src (enforced
  # below), so this branch is --print-flags-only and never reaches cmake.
  COMPILER_FLAGS="${VARIANT_CFLAGS:-}"
fi

if [ "$PRINT_FLAGS" -eq 1 ]; then
  effective_cmake_flags "$VARIANT" "$PLATFORM"
  # --print-flags must emit cmake arguments and nothing else -- this output
  # feeds BUILDINFO/manifest.json provenance, and the next task derives
  # `crt` by grepping it. No decorative/cosmetic lines here.
  echo "compiler_flags: $COMPILER_FLAGS"
  exit 0
fi

[ -n "$PREFIX" ]   || { echo "error: --prefix is required" >&2; exit 2; }
[ -n "$IREE_SRC" ] || { echo "error: --iree-src is required (this recipe never clones IREE)" >&2; exit 2; }
[ -d "$IREE_SRC" ] || { echo "error: --iree-src '$IREE_SRC' is not a directory" >&2; exit 2; }

if [ -z "$BUILD_DIR" ]; then
  BUILD_DIR="$(dirname "$PREFIX")/iree-build-${VARIANT}"
fi

# The IREE source is a bind mount owned by the invoking user, while the container
# runs as root, so git refuses it as "dubious ownership" and every `git -C
# $IREE_SRC` below fails. Declaring it safe here -- via the environment rather
# than `git config --global`, so no state outside this process is mutated --
# covers this script and the scripts it invokes (gen-manifest.sh reads the same
# repo). Without it the provenance git calls fail inside the container but not on
# a bare host run, which is exactly the divergence CI trips over.
_iree_src_abs="$(cd "$IREE_SRC" && pwd)"
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0="$_iree_src_abs"

# No `|| echo unknown` fallback: a failure here is not a benign "version not
# known", it silently stamps "unknown" into BUILDINFO and manifest.json as
# recorded provenance. gen-manifest.sh already hard-requires this same repo be
# readable (`git rev-parse HEAD`, no fallback), so tolerating failure here was
# never coherent -- it just moved the error somewhere less obvious.
IREE_VERSION="$(git -C "$IREE_SRC" describe --tags --abbrev=0 | sed 's/^v//')" || {
  echo "error: could not read a tag from '$IREE_SRC' -- is it a git checkout at a tagged commit?" >&2
  exit 1
}
COMPILER_VERSION="${COMPILER_VERSION:-$IREE_VERSION}"

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

# aarch64: bump both hardware interference-size constants from 64 to 128.
#
# WHY (aarch64 + tsan specifically): iree_task_worker_t's first field is an
# iree_atomic_task_slist_t, whose static_assert requires
# `sizeof(slist) < iree_hardware_constructive_interference_size`. The slist
# embeds an iree_slim_mutex_t. On a normal build that mutex is a 4-byte futex
# int, but under ThreadSanitizer futex.h deliberately clears IREE_RUNTIME_USE_FUTEX
# (TSan can't instrument futex syscalls), so the mutex falls back to
# pthread_mutex_t -- which is 48 bytes on aarch64 vs 40 on x86_64 (a glibc ABI
# difference, not TSan padding). 48 + 8-byte head, aligned to iree_max_align_t,
# lands sizeof(slist) at exactly 64, so `64 < 64` fails. x86_64+tsan (40+8=48)
# and aarch64 non-tsan (4-byte futex) both pass, which is why only aarch64+tsan
# broke. 128 restores a full cache line of headroom against a fixed ABI constant,
# and upstream carries a TODO to test 128 anyway (atomics.h); 128 also matches
# the real cache-line/prefetch stride of common aarch64 CPUs.
#
# TSAN-GATED, deliberately NOT applied to every aarch64 variant: the bump is both
# necessary AND mutually exclusive across variants. iree_async_posix_worker_t
# carries the opposite assert -- `sizeof(worker) >= constructive_interference_size`
# (async/platform/posix/worker.h) -- and on a non-sanitizer build that struct is
# exactly 64 bytes, so 128 fails it (64 >= 128). Under tsan the same struct bloats
# past 128 (the pthread_mutex_t fallback again) so it holds. So default aarch64
# must stay at 64 (its known-good value, which builds clean) and only tsan gets
# 128. Gate on the thread sanitizer via variant_sanitizer so a future
# thread-sanitized variant inherits this without another edit here.
#
# Idempotent (a re-run's sed matches nothing, the post-condition grep still
# holds) and fail-loud (if upstream ever reformats the #define, the grep aborts
# rather than silently shipping the unpatched 64). NOTE: mutates the caller's
# --iree-src tree in place -- CI clones fresh each run; a local host does not, so
# a local aarch64 checkout stays patched after the build.
if [ "$PLATFORM" = linux-aarch64 ] && [ "$(variant_sanitizer "$VARIANT")" = thread ]; then
  _atomics_h="$IREE_SRC/runtime/src/iree/base/internal/atomics.h"
  for _c in destructive constructive; do
    sed -i "s/^#define iree_hardware_${_c}_interference_size 64\$/#define iree_hardware_${_c}_interference_size 128/" \
      "$_atomics_h"
    grep -qx "#define iree_hardware_${_c}_interference_size 128" "$_atomics_h" \
      || { echo "error: failed to patch iree_hardware_${_c}_interference_size to 128 in $_atomics_h (upstream layout changed?)" >&2; exit 1; }
  done
  echo "==> patched aarch64 interference-size constants to 128"
fi

mapfile -t FLAGS < <(effective_cmake_flags "$VARIANT" "$PLATFORM")

echo "==> configuring"
cmake -G Ninja -B "$BUILD_DIR" -S "$IREE_SRC" \
  "${FLAGS[@]}" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_C_FLAGS="$COMPILER_FLAGS" \
  -DCMAKE_CXX_FLAGS="$COMPILER_FLAGS"

echo "==> building"
cmake --build "$BUILD_DIR"

# libbacktrace is NOT in the `all` target, so the build above does not produce it.
# Upstream adds the directory with
#   add_subdirectory(build_tools/third_party/libbacktrace EXCLUDE_FROM_ALL)
# and the only edge to it runs through libbacktrace::libbacktrace, an
# `INTERFACE IMPORTED` target -- and IMPORTED targets carry no build-order
# dependency. So iree_base_base "depends on" libbacktrace in the link sense while
# nothing ever schedules the archive to be compiled. Verified against the
# generated build.ninja: the `all` phony edge has no libbacktrace input.
#
# This must be an explicit --target build, and it must run BEFORE the install
# phase copies the archive into the prefix (see the libbacktrace repair below).
# The archive is only produced on Linux with IREE_ENABLE_LIBBACKTRACE ON, which is
# the default there and what effective_cmake_flags relies on; if that ever stops
# holding, the existence assert below is the thing that catches it, not this line.
# On Windows there is no libbacktrace_impl target to build at all (see the
# platform_toolchain guard around the repair below), so skip this too.
if [ "$(platform_toolchain "$PLATFORM")" = container ]; then
  cmake --build "$BUILD_DIR" --target libbacktrace_impl
fi

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

# libbacktrace is a Linux-only repair. On Windows IREE emits no install rule for
# it, ships no libbacktrace*.lib, references zero backtrace_* symbols across all
# 191 archives, and omits it from iree_base_base's INTERFACE_LINK_LIBRARIES. It
# is dropped outright -- NOT substituted by dbghelp, which appears nowhere in the
# export set (spike W4). Guarded on platform, deliberately NOT on "does the
# archive exist": an existence check would silently no-op if the Linux archive
# ever went missing, turning a loud failure into a quiet one.
if [ "$(platform_toolchain "$PLATFORM")" = container ]; then

# build_tools/third_party/libbacktrace has the same EXCLUDE_FROM_ALL shape as printf
# above, but worse: its CMakeLists.txt has NO install(TARGETS ...) rule at all for the
# libbacktrace_impl archive, in any component -- so no `cmake --install --component`
# invocation can ever produce it; `cmake_install.cmake` for that subdirectory contains
# only boilerplate. Discovered while proving the header fix compiles+links+runs
# end-to-end (Step 3 of the header-gap fix): iree_base_base's public DEPS include
# libbacktrace::libbacktrace, an `add_library(... INTERFACE IMPORTED GLOBAL)` target that
# upstream's own comment says is deliberately "only used internally during build" and not
# meant to be exported. CMake's install(EXPORT) machinery does not honor that intent: it
# writes the bare name "libbacktrace_libbacktrace" straight into iree_base_base's
# INTERFACE_LINK_LIBRARIES in IREETargets-Runtime.cmake, with no corresponding
# add_library(...IMPORTED) anywhere in the export set (unlike e.g. printf_printf, which
# IS a real imported target with an IMPORTED_LOCATION -- compare the two in
# IREETargets-Runtime.cmake). A downstream consumer's CMake can't resolve the bare name as
# a target, so it falls back to treating it as a raw library name -- the linker sees
# "-llibbacktrace_libbacktrace" with no matching -L search path, and fails. Fix this the
# same way CMake's own generator would have, had upstream exported the target: copy the
# real archive in, then define the missing imported target by hand, pointing
# IMPORTED_LOCATION at it. This is a distinct defect from the printf install gap and from
# the missing public headers (scripts/install-headers.sh); flagged for a proper
# upstream/export-set fix rather than papered over silently -- fail loudly if the build
# tree doesn't have the archive this depends on, since a silent no-op here is exactly how
# the header gap shipped.
_libbacktrace_archive="$BUILD_DIR/build_tools/third_party/libbacktrace/liblibbacktrace_impl.a"
if [ ! -f "$_libbacktrace_archive" ]; then
  echo "error: $_libbacktrace_archive not found -- was IREE_ENABLE_LIBBACKTRACE disabled, or the build tree incomplete?" >&2
  exit 1
fi
cp "$_libbacktrace_archive" "$PREFIX/lib/liblibbacktrace_libbacktrace.a"

_targets_runtime="$PREFIX/lib/cmake/IREE/IREETargets-Runtime.cmake"
_targets_runtime_release="$PREFIX/lib/cmake/IREE/IREETargets-Runtime-release.cmake"
[ -e "$_targets_runtime" ] || { echo "error: $_targets_runtime not found; install step failed?" >&2; exit 1; }
[ -e "$_targets_runtime_release" ] || { echo "error: $_targets_runtime_release not found; install step failed?" >&2; exit 1; }

# Idempotent: only patch if a previous run of this script hasn't already. The
# add_library() block must land BEFORE the "Load information for each installed
# configuration" section (which globs and includes *-release.cmake, setting
# IMPORTED_LOCATION_RELEASE on already-declared targets) -- so insert it there
# rather than appending at end of file.
if ! grep -q '^add_library(libbacktrace_libbacktrace STATIC IMPORTED)$' "$_targets_runtime"; then
  marker='# Load information for each installed configuration.'
  grep -qF "$marker" "$_targets_runtime" || {
    echo "error: expected marker line not found in $_targets_runtime (IREE's export-set generator changed shape?)" >&2
    exit 1
  }
  _patch="$(mktemp)"
  cat > "$_patch" <<'EOF'
# --- iree-runtime-dist patch: see the libbacktrace comment in build-runtime.sh ---
# Create imported target libbacktrace_libbacktrace (upstream declines to export this
# target; we define it ourselves so the bare name referenced by iree_base_base's
# INTERFACE_LINK_LIBRARIES resolves to the archive build-runtime.sh installs).
add_library(libbacktrace_libbacktrace STATIC IMPORTED)

set_target_properties(libbacktrace_libbacktrace PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES "${_IMPORT_PREFIX}/include"
)

EOF
  awk -v marker="$marker" -v patchfile="$_patch" '
    $0 == marker {
      while ((getline line < patchfile) > 0) print line
      close(patchfile)
    }
    { print }
  ' "$_targets_runtime" > "$_targets_runtime.tmp"
  mv "$_targets_runtime.tmp" "$_targets_runtime"
  rm -f "$_patch"
fi

if ! grep -q 'IMPORTED_LOCATION_RELEASE "\${_IMPORT_PREFIX}/lib/liblibbacktrace_libbacktrace.a"' "$_targets_runtime_release"; then
  cat >> "$_targets_runtime_release" <<'EOF'

# --- iree-runtime-dist patch: see the libbacktrace comment in build-runtime.sh ---
# Import target "libbacktrace_libbacktrace" for configuration "Release"
set_property(TARGET libbacktrace_libbacktrace APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(libbacktrace_libbacktrace PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELEASE "C"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/liblibbacktrace_libbacktrace.a"
  )

list(APPEND _cmake_import_check_targets libbacktrace_libbacktrace )
list(APPEND _cmake_import_check_files_for_libbacktrace_libbacktrace "${_IMPORT_PREFIX}/lib/liblibbacktrace_libbacktrace.a" )
EOF
fi

fi # platform_toolchain "$PLATFORM" = container (libbacktrace repair)

# Remove compiler target files that were installed by the IREECMakeExports component.
# The IREE compiler is explicitly out of contract for this project (-DIREE_BUILD_COMPILER=OFF),
# so compiler-only target files must not ship. Specifically:
#   - IREETargets-Compiler.cmake and IREETargets-Compiler-release.cmake define imported targets
#     for compiler libraries (e.g., iree_compiler_bindings_c_loader).
#   - These files' IMPORTED_LOCATION_RELEASE entries point to archives like
#     libiree_compiler_bindings_c_loader.a that were never built or installed.
#   - Shipping a targets file with dangling IMPORTED_LOCATION entries reproduces the exact
#     failure mode this project fixed for runtime: find_package() succeeds, but the first
#     downstream link fails on a missing file.
#   - IREERuntimeConfig.cmake includes ONLY IREETargets-Runtime.cmake, so removing these
#     compiler files cannot break find_package(IREERuntime).
#
# Guard: verify that IREERuntimeConfig.cmake does NOT reference "Compiler". If it ever does,
# removing these files would break downstream consumers, so fail loudly instead.
runtime_config="$PREFIX/lib/cmake/IREE/IREERuntimeConfig.cmake"
if [ -e "$runtime_config" ]; then
  if grep -q "Compiler" "$runtime_config"; then
    echo "error: IREERuntimeConfig.cmake references 'Compiler'; cannot remove compiler targets" >&2
    exit 1
  fi
else
  echo "error: IREERuntimeConfig.cmake not found at $runtime_config; install step failed?" >&2
  exit 1
fi

# Remove the compiler targets (idempotent: will not fail if already missing).
rm -f "$PREFIX/lib/cmake/IREE/IREETargets-Compiler.cmake"
rm -f "$PREFIX/lib/cmake/IREE/IREETargets-Compiler-release.cmake"

# Fill in public headers that IREE's generated cmake_install.cmake declares in a
# target's HDRS but never emits an install(FILES ...) rule for (e.g.
# iree/base/status.h, iree/hal/buffer.h) -- see scripts/install-headers.sh for
# the full explanation. Must run AFTER the component installs above so it only
# fills gaps rather than being overwritten by them.
. "$HERE/scripts/install-headers.sh"
install_missing_headers "$PREFIX" "$IREE_SRC"

# Patch IREERuntimeConfig.cmake to find_package(Threads) before including the
# targets file -- upstream's config never does, so a naive consumer's bare
# find_package(IREERuntime) fails to configure. See scripts/config-deps.sh.
. "$HERE/scripts/config-deps.sh"
config_repair_external_deps "$PREFIX"

echo "==> phase 1 complete"

# --- Phase 2: relocatability repair, then proof ------------------------------
. "$HERE/scripts/relocatability.sh"

# Sanitizer variants build with -g, whose DWARF records the (neutral,
# container-internal) build dir in DW_AT_comp_dir -- debug metadata, not link
# surface. Let the assertion exempt build paths that live ONLY in debug
# sections of objects/archives; a leak in any link-relevant content (a .cmake
# config, a string table, an INTERFACE flag) still fails. Empty for default.
if [ -n "$(variant_sanitizer "$VARIANT")" ]; then
  export RELOC_ALLOW_DEBUG_PATHS=1
fi

echo "==> repairing relocatability"
relocatability_repair "$PREFIX"

echo "==> asserting relocatability (mid-build; Phase 3/4 outputs don't exist yet)"
relocatability_assert "$PREFIX" "$(cd "$BUILD_DIR" && pwd)" "$(cd "$IREE_SRC" && pwd)" "$HERE"

echo "==> phase 2 complete"

# --- Phase 3: generated metadata --------------------------------------------
echo "==> generating constants"
bash "$HERE/scripts/gen-constants.sh" "$PREFIX"

echo "==> generating manifest"
bash "$HERE/scripts/gen-manifest.sh" "$PREFIX" "$VARIANT" "$PLATFORM" \
  "$IREE_SRC" "$IREE_VERSION" "$COMPILER_VERSION"

echo "==> collecting license notices"
bash "$HERE/scripts/gen-notices.sh" "$PREFIX" "$IREE_SRC" "$BUILD_DIR" "$PLATFORM"

# Ship an in-artifact README documenting the share/ layout + JSON schema, so a
# non-CMake consumer (Gradle/Python/Rust) has the path convention and file shapes
# without reverse-engineering IreeRuntimeDistConfig.cmake (consumer report #6).
echo "==> shipping share/ README"
sed -e "s|@IREE_VERSION@|${IREE_VERSION}|g" \
    -e "s|@VARIANT@|${VARIANT}|g" \
    -e "s|@PLATFORM@|${PLATFORM}|g" \
    "$HERE/docs/share-README.md.in" \
    > "$PREFIX/share/iree-runtime-dist/README.md"

# Sanitizer variants ship a consumer runbook (build with clang, ASLR note,
# suppressions wiring). A default prefix ships none.
if [ -n "$(variant_sanitizer "$VARIANT")" ]; then
  echo "==> shipping sanitizer runbook"
  bash "$HERE/scripts/gen-tsan-docs.sh" "$PREFIX" "$IREE_VERSION" "$COMPILER_VERSION"
fi

echo "==> installing dist cmake additions"
RUNTIME_COMMIT="$(git -C "$IREE_SRC" rev-parse HEAD)"
mkdir -p "$PREFIX/lib/cmake/IreeRuntimeDist"
sed -e "s|@IREE_VERSION@|${IREE_VERSION}|g" \
    -e "s|@COMPILER_VERSION@|${COMPILER_VERSION}|g" \
    -e "s|@VARIANT@|${VARIANT}|g" \
    -e "s|@PLATFORM@|${PLATFORM}|g" \
    -e "s|@RUNTIME_COMMIT@|${RUNTIME_COMMIT}|g" \
    "$HERE/cmake/IreeRuntimeDist.cmake.in" \
    > "$PREFIX/lib/cmake/IreeRuntimeDist/IreeRuntimeDistConfig.cmake"

# Upstream has no write_basic_package_version_file, so find_package(IREERuntime 3.11)
# with a version argument fails today. Supply the file it omits.
cat > "$PREFIX/lib/cmake/IREE/IREERuntimeConfigVersion.cmake" <<EOF
set(PACKAGE_VERSION "${IREE_VERSION}")
if(PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
  if(PACKAGE_FIND_VERSION STREQUAL PACKAGE_VERSION)
    set(PACKAGE_VERSION_EXACT TRUE)
  endif()
endif()
EOF

echo "==> phase 3 complete"

# --- Phase 4: pair with the compiler ----------------------------------------
echo "==> compiling paired smoke artifact"
bash "$HERE/scripts/gen-addvmfb.sh" "$PREFIX" "$COMPILER_VERSION"

# --- Final relocatability proof ----------------------------------------------
# The Phase 2 assertion above only covers what existed at that point in the
# build. add.vmfb (Phase 4) and manifest.json/BUILDINFO/both constants
# JSONs/IreeRuntimeDistConfig.cmake/IREERuntimeConfigVersion.cmake (Phase 3)
# are all written AFTER it, and nothing re-checked them -- which is precisely
# how a build-machine path (an absolute iree-compile input path baked into
# add.vmfb) shipped in a published tarball despite the Phase 2 assertion
# passing cleanly. Re-run the assertion here, now that every artifact the
# tarball will contain has actually been written, so it covers the entire
# staged prefix as the design's phase-2 contract requires -- not just the
# two-phases-old snapshot of it.
echo "==> asserting relocatability (final; covers the full staged prefix)"
relocatability_assert "$PREFIX" "$(cd "$BUILD_DIR" && pwd)" "$(cd "$IREE_SRC" && pwd)" "$HERE"

echo "==> build complete: $PREFIX"
