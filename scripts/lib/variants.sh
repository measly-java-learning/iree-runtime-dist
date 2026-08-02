#!/usr/bin/env bash
# Which variants each platform builds. Single source of truth. Source me.
#
# This file used to own the variant -> cmake flag mapping as well. That moved to
# cmake/variant-<variant>.cmake, which CMake reads directly via -C: the flags
# are now DECLARED where they are consumed rather than computed here and passed
# along. What is left is the one genuinely platform-dependent piece of logic,
# which is not expressible as a static file.

# Which variants a platform builds. NOT platform-independent: tsan is
# -fsanitize=thread under clang, which the MSVC/Windows toolchain does not
# provide.
#
# release.yml no longer reads this: it fans out `[default, tsan]` x the Linux
# PLATFORMS cross-product in `build`, and keeps Windows in a separate
# `build-windows` job declaring `variant: [default]`. The unbuildable
# windows x tsan leg is therefore prevented structurally by the job split
# rather than by this list. What this list still owns is
# test/cmake_init.test.sh's coverage matrix -- every variant a platform builds
# must have a cmake/variant-<variant>.cmake.
known_variants() { # <platform>
  case "${1:-}" in
    linux-*)   printf 'default tsan' ;;
    windows-*) printf 'default' ;;
    *) echo "error: unknown platform '${1:-}'" >&2; return 2 ;;
  esac
}
