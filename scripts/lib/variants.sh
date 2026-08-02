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
# provide. release.yml fans out a full variant x platform cross-product, so
# without this a windows tsan job would be scheduled and fail.
known_variants() { # <platform>
  case "${1:-}" in
    linux-*)   printf 'default tsan' ;;
    windows-*) printf 'default' ;;
    *) echo "error: unknown platform '${1:-}'" >&2; return 2 ;;
  esac
}
