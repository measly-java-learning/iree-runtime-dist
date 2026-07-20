#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/prefix/lib" "$tmp/out"
echo "fake" > "$tmp/prefix/lib/libfake.a"
echo "lic"  > "$tmp/prefix/LICENSE"

bash "$here/../scripts/package.sh" "$tmp/prefix" 3.11.0 default linux-x86_64 "$tmp/out"

tb="$tmp/out/iree-runtime-3.11.0-default-linux-x86_64.tar.gz"
if [ -s "$tb" ]; then echo "ok: tarball created"
else echo "FAIL: tarball missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
if [ -s "$tb.sha256" ]; then echo "ok: sha256 created"
else echo "FAIL: sha256 missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

# The sha file must verify from its own directory.
( cd "$tmp/out" && sha256sum -c "$(basename "$tb").sha256" >/dev/null 2>&1 ) \
  && echo "ok: sha256 verifies" \
  || { echo "FAIL: sha256 does not verify" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# Must unpack to exactly one top-level directory.
top="$(tar tzf "$tb" | cut -d/ -f1 | sort -u | wc -l)"
assert_eq "$top" "1" "single top-level directory"
assert_eq "$(tar tzf "$tb" | cut -d/ -f1 | sort -u)" \
  "iree-runtime-3.11.0-default-linux-x86_64" "top-level dir is the asset stem"

exit "$ASSERT_FAILS"
