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
echo "error: build phases not yet implemented" >&2
exit 1
