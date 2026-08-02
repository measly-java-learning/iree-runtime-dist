#!/usr/bin/env bash
# Render the GitHub release body from the assets on disk. Nothing is enumerated
# from declared variant/platform lists: every tarball in <dir> is a release
# asset, and the version/variant/platform tokens in the prose and the verify
# block come from naming.sh's parse_asset -- the same parser gen-pin.sh uses,
# so one naming scheme has one inverse.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/naming.sh"

DIR="${1:?usage: render-release-notes.sh <release-dir> <owner/repo>}"
REPO="${2:?owner/repo required}"
[ -d "$DIR" ] || { echo "render-release-notes: '$DIR' is not a directory" >&2; exit 1; }

shopt -s nullglob
tarballs=("$DIR"/*.tar.gz)
if [ "${#tarballs[@]}" -eq 0 ]; then
  echo "render-release-notes: no *.tar.gz in '$DIR' -- nothing to release" >&2
  exit 1
fi

version=""
pairs=""
for tb in "${tarballs[@]}"; do
  b="$(basename "$tb")"
  read -r v variant platform < <(parse_asset "$b") || exit 1
  # The verify block below instructs `sha256sum -c` on the sibling; a tarball
  # without one would publish a broken instruction.
  [ -f "$DIR/${b}.sha256" ] \
    || { echo "render-release-notes: missing sha256 sibling for '$b'" >&2; exit 1; }
  if [ -z "$version" ]; then
    version="$v"
  elif [ "$v" != "$version" ]; then
    echo "render-release-notes: mixed versions ('$version' and '$v') in '$DIR'" >&2
    exit 1
  fi
  pairs="${pairs}\`${variant}\`/\`${platform}\`, "   # NOTE: \` is an escaped backtick, keep it
done
pairs="${pairs%, }"

{
  echo "IREE runtime ${version} (${pairs})."
  echo ""
  echo "**Pair with \`iree-base-compiler==${version}\`.**"
  echo "Modules compiled by a different compiler version may fail to load with a VM"
  echo "import signature mismatch. See \`share/iree-runtime-dist/manifest.json\`."
  echo ""
  echo "The pip \`iree-base-runtime\` wheel is not linkable at any version; use this artifact."
  echo ""
  echo "Verify before consuming:"
  echo '```'
  for tb in "${tarballs[@]}"; do
    b="$(basename "$tb")"
    echo "sha256sum -c ${b}.sha256"
    echo "gh attestation verify ${b} --repo ${REPO}"
  done
  echo '```'
}
