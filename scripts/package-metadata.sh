#!/usr/bin/env bash
# Build iree-runtime-metadata-<version>.zip from a prefix's share/ metadata.
# Constants are variant-independent, so this runs once per release.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${1:?usage: package-metadata.sh <prefix> <version> <outdir>}"
VERSION="${2:?version required}"; OUTDIR="${3:?outdir required}"
src="$PREFIX/share/iree-runtime-dist"
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
for f in element_types.json status_codes.json element_types.schema.json status_codes.schema.json; do
  cp "$src/$f" "$stage/"
done
sed "s|@IREE_VERSION@|${VERSION}|g" "$HERE/../docs/metadata-README.md.in" > "$stage/README.md"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"
( cd "$stage" && zip -q -X "$OUTDIR/iree-runtime-metadata-${VERSION}.zip" \
    element_types.json status_codes.json element_types.schema.json status_codes.schema.json README.md )
echo "==> packaged iree-runtime-metadata-${VERSION}.zip"
