#!/usr/bin/env bash
# Asset naming. Single source of truth. Source me.
asset_stem()   { printf 'iree-runtime-%s-%s-%s' "$1" "$2" "$3"; }   # <version> <variant> <platform>
tarball_name() { printf '%s.tar.gz' "$(asset_stem "$@")"; }
sha_name()     { printf '%s.sha256' "$(tarball_name "$@")"; }

# Inverse of asset_stem -- parse an asset basename (tarball OR sha) back into
# <version> <variant> <platform> tokens. The single parser shared by gen-pin.sh
# and the release-notes renderer, so a naming-scheme change is handled in
# exactly one place. Fails loudly (exit 2, no stdout) on any name that does
# not round-trip through asset_stem, and on a version token that is not a
# dotted number or a variant token containing '-' -- both would silently
# mis-split (e.g. an asset name embedding the pkgrev: 3.11.0-10-...).
# Usage: read -r v variant platform < <(parse_asset "$b")
parse_asset() { # <basename>
  local b="${1:?parse_asset: basename required}" rest stem v variant platform
  rest="${b#iree-runtime-}"
  rest="${rest%.tar.gz.sha256}"
  rest="${rest%.tar.gz}"
  stem="$rest"
  v="${rest%%-*}"; rest="${rest#*-}"
  variant="${rest%%-*}"; platform="${rest#*-}"
  case "$v" in
    *[!0-9.]*) echo "parse_asset: '$b' version token '$v' is not a dotted number" >&2; return 2 ;;
  esac
  case "$variant" in
    *-*) echo "parse_asset: '$b' variant token '$variant' contains '-' (pkgrev in asset name?)" >&2; return 2 ;;
    *[!0-9]*) : ;;  # real variant names carry letters/underscores
    *) echo "parse_asset: '$b' variant token '$variant' is a bare number (pkgrev in asset name?)" >&2; return 2 ;;
  esac
  [ "$(asset_stem "$v" "$variant" "$platform")" = "iree-runtime-$stem" ] \
    || { echo "parse_asset: '$b' does not round-trip through asset_stem" >&2; return 2; }
  printf '%s %s %s\n' "$v" "$variant" "$platform"
}

# Supported platforms: the tokens build-runtime.sh will accept for --platform
# (validated at build-runtime.sh:90) and stamp into manifest.json/BUILDINFO/the
# tarball name. Also drives test/cmake_init.test.sh's coverage matrix, so
# "added a platform, forgot cmake/<platform>.cmake" fails in a second.
#
# This is NOT the CI matrix source. release.yml and warm-build-image.yml each
# declare their own `PLATFORMS` JSON literal (platform + container + runner),
# because a matrix needs a runner label and an image tag that this list does
# not carry, and YAML cannot source a shell lib. The drift that leaves is
# bounded and loud in the directions that matter: a workflow platform this
# list does not know fails build-runtime.sh in seconds, and one the workflow
# omits simply does not appear in the release notes (rendered from the assets
# on disk). Moving those details back in here is what the 2026-07-29 package-
# port regime note argues against -- see docs/superpowers/notes/.
PLATFORMS="linux-x86_64 linux-aarch64 windows-x86_64"
known_platforms() { printf '%s\n' $PLATFORMS; }
