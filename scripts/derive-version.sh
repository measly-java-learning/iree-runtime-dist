#!/usr/bin/env bash
# Release tag -> IREE tag + paired compiler version.
#
# v1 anchors on IREE *stable* releases, where the pip iree-base-compiler version
# equals the IREE version. That is what makes pairing correct by construction and
# keeps this script trivial. Tracking `main` would key on a nightly compiler
# version instead and require resolving it to a commit -- deliberately not done here.
set -euo pipefail

tag="${1:-}"
if [ -z "$tag" ]; then
  echo "usage: derive-version.sh <tag>   e.g. v3.11.0-1" >&2
  exit 2
fi

# v<major>.<minor>.<patch>-<pkgrev>
if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$'; then
  echo "error: tag '$tag' does not match v<major>.<minor>.<patch>-<pkgrev> (e.g. v3.11.0-1)" >&2
  exit 2
fi

version="${tag#v}"       # 3.11.0-1
version="${version%-*}"  # 3.11.0

echo "IREE_VERSION=${version}"
echo "IREE_TAG=v${version}"
echo "COMPILER_VERSION=${version}"
