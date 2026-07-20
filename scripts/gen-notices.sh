#!/usr/bin/env bash
# Collect license notices for what is ACTUALLY in the shipped artifact.
#
# Scoped to the real link surface (scripts/lib/linked-components.sh), not a
# listing of IREE's third_party/ dir. With IREE_BUILD_COMPILER=OFF, LLVM is
# never linked -- shipping its notice would over-claim what this artifact
# contains.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/linked-components.sh"

PREFIX="${1:?usage: gen-notices.sh <prefix> <iree-src> <build-dir>}"
IREE_SRC="${2:?iree-src required}"
BUILD_DIR="${3:?build-dir required}"

[ -d "$IREE_SRC" ]  || { echo "error: iree-src '$IREE_SRC' is not a directory" >&2; exit 2; }
[ -d "$BUILD_DIR" ] || { echo "error: build-dir '$BUILD_DIR' is not a directory" >&2; exit 2; }

# IREE's own license.
cp "$IREE_SRC/LICENSE" "$PREFIX/LICENSE"

NOTICES="$PREFIX/THIRD-PARTY-NOTICES"
rm -rf "$NOTICES"
mkdir -p "$NOTICES"

# Where a linked component's license actually lives is not uniform:
#   - flatcc, printf are real git submodules under third_party/<name>/.
#   - libbacktrace is NOT vendored in the source tree at all: its CMakeLists.txt
#     (build_tools/third_party/libbacktrace/CMakeLists.txt) pulls it in with
#     FetchContent at configure time, pinned to a specific upstream commit. Its
#     license only exists post-configure, under the build tree's
#     _deps/<name>_src-src/ (CMake's standard FetchContent populate-directory
#     naming). There is no copy of it anywhere under $IREE_SRC.
# Try every layout IREE actually uses for a vendored dependency, in order, so a
# component landing in a different one of these shapes is still found rather
# than silently skipped.
candidate_roots() { # <component-name>
  echo "$IREE_SRC/third_party/$1"
  echo "$IREE_SRC/build_tools/third_party/$1"
  echo "$BUILD_DIR/_deps/${1}_src-src"
}

for name in $IREE_LINKED_COMPONENTS; do
  found=""
  while IFS= read -r root; do
    for cand in LICENSE LICENSE.txt LICENSE.md COPYING NOTICE; do
      if [ -f "$root/$cand" ]; then found="$root/$cand"; break 2; fi
    done
  done < <(candidate_roots "$name")

  if [ -z "$found" ]; then
    echo "error: no license file found for linked component '$name'" >&2
    echo "hint: shipping a dependency without its license is a compliance failure" >&2
    echo "hint: checked: $(candidate_roots "$name" | tr '\n' ' ')" >&2
    exit 1
  fi
  mkdir -p "$NOTICES/$name"
  cp "$found" "$NOTICES/$name/LICENSE"
  echo "  notice: $name <- $found"
done

echo "==> collected $(find "$NOTICES" -name LICENSE | wc -l) third-party notice(s)"
