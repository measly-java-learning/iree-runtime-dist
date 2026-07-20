#!/usr/bin/env bash
# Tarball a staged prefix + emit its .sha256.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/naming.sh"

PREFIX="${1:?usage: package.sh <prefix> <version> <variant> <platform> <outdir>}"
VERSION="${2:?version required}"
VARIANT="${3:?variant required}"
PLATFORM="${4:?platform required}"
OUTDIR="${5:?outdir required}"

mkdir -p "$OUTDIR"
stem="$(asset_stem "$VERSION" "$VARIANT" "$PLATFORM")"
tarball="$(tarball_name "$VERSION" "$VARIANT" "$PLATFORM")"

# Stage under the asset stem so the tarball unpacks to one predictable directory.
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -a "$PREFIX" "$staging/$stem"

tar -czf "$OUTDIR/$tarball" -C "$staging" "$stem"

# The sha file must verify from its own directory, so store a bare basename.
( cd "$OUTDIR" && sha256sum "$tarball" > "$(sha_name "$VERSION" "$VARIANT" "$PLATFORM")" )

echo "==> packaged $OUTDIR/$tarball"
