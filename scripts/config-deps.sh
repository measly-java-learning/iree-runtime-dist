#!/usr/bin/env bash
# Patch the shipped IREERuntimeConfig.cmake to re-find its own external
# dependencies. Source me.
#
# CONCRETE FAILURE THIS FIXES: the minimal, README-documented consumer
#
#   cmake_minimum_required(VERSION 3.21)
#   project(vfy C)
#   find_package(IREERuntime REQUIRED)
#   add_executable(vfy c.c)
#   target_link_libraries(vfy PRIVATE iree_runtime_unified)
#
# fails to even CONFIGURE against the shipped prefix with:
#
#   CMake Error at .../lib/cmake/IREE/IREETargets-Runtime.cmake:2231 (set_target_properties):
#     The link interface of target "iree_vm_impl" contains:
#       Threads::Threads
#     but the target was not found.
#
# because IREETargets-Runtime.cmake references the imported target
# Threads::Threads (via iree_vm_impl, iree_base_threading_threading, and
# others), but IREERuntimeConfig.cmake -- the file a consumer's
# find_package(IREERuntime) actually runs -- is upstream's 3-line stub that
# only does `include(.../IREETargets-Runtime.cmake)`. It never calls
# find_package(Threads) first, so when the targets file is included, the
# Threads::Threads imported target doesn't exist yet and CMake errors out
# before a single line of the consumer's own code is even parsed.
#
# A CMake package config is responsible for re-finding its own external
# (non-exported) dependencies before including its targets file -- see
# https://cmake.org/cmake/help/latest/manual/cmake-packages.7.html
# ("Third Party Packages" / find_package find-modules called from Config
# files). Upstream's IREERuntimeConfig.cmake does not do this for Threads.
# This is the second sanctioned exception (after relocatability_repair in
# relocatability.sh) to the project's "ship upstream CMake files unmodified"
# principle: repairing an upstream packaging gap, not rewriting behavior.
#
# Full enumeration backing "Threads is the only gap" lives in the Step 1
# write-up of the associated fix; briefly: every other token appearing in
# INTERFACE_LINK_LIBRARIES across IREETargets-Runtime.cmake is either (a) a
# target this same export set defines via add_library(... IMPORTED), or (b)
# a bare system library name (-lm, dl, rt) that the linker resolves directly
# with no find_package needed. Threads::Threads is the only externally
# sourced imported target referenced.

config_repair_external_deps() { # <prefix>
  local prefix="${1:?prefix required}"
  local config="$prefix/lib/cmake/IREE/IREERuntimeConfig.cmake"
  local marker='include("${CMAKE_CURRENT_LIST_DIR}/IREETargets-Runtime.cmake")'
  local find_line='find_package(Threads REQUIRED)'

  [ -e "$config" ] || { echo "error: $config not found; install step failed?" >&2; return 1; }

  # Idempotent: skip if a previous run already inserted the find_package call.
  if grep -qF "$find_line" "$config"; then
    return 0
  fi

  grep -qF "$marker" "$config" || {
    echo "error: expected include(...IREETargets-Runtime.cmake) line not found in $config (upstream config shape changed?)" >&2
    return 1
  }

  local patch; patch="$(mktemp)"
  cat > "$patch" <<EOF
# --- iree-runtime-dist patch: re-find external deps the export set needs ---
# IREETargets-Runtime.cmake references the imported target Threads::Threads
# (e.g. via iree_vm_impl), but never defines it itself. Without this,
# find_package(IREERuntime) fails at the include() below with:
#   "The link interface of target ... contains: Threads::Threads
#    but the target was not found."
# See scripts/config-deps.sh for the full explanation. Must run BEFORE the
# targets file is included.
$find_line

EOF
  awk -v marker="$marker" -v patchfile="$patch" '
    $0 == marker {
      while ((getline line < patchfile) > 0) print line
      close(patchfile)
    }
    { print }
  ' "$config" > "$config.tmp"
  mv "$config.tmp" "$config"
  rm -f "$patch"
}
