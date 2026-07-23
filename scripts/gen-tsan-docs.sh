#!/usr/bin/env bash
# Ship the TSan consumer runbook (and a suppressions file, if one exists) with a
# sanitizer variant's prefix. Called by build-runtime.sh Phase 3 ONLY when the
# variant is thread-sanitized -- a default prefix ships neither.
#
# The runbook captures the hard-won recipe (build with clang, the ASLR/mmap
# note, suppressions wiring, what the gate proves) so a consumer inherits it
# rather than rediscovering it. See docs/TSAN.md.in.
set -euo pipefail

PREFIX="${1:?usage: gen-tsan-docs.sh <prefix> <iree-version> <compiler-version>}"
IREE_VERSION="${2:?iree-version required}"
COMPILER_VERSION="${3:?compiler-version required}"
HERE="$(cd "$(dirname "$0")" && pwd)"

OUT_DIR="$PREFIX/share/iree-runtime-dist"
mkdir -p "$OUT_DIR"

sed -e "s|@IREE_VERSION@|${IREE_VERSION}|g" \
    -e "s|@COMPILER_VERSION@|${COMPILER_VERSION}|g" \
    "$HERE/../docs/TSAN.md.in" \
    > "$OUT_DIR/TSAN.md"

echo "==> shipped TSAN.md"
