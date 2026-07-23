#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
outdir="$(mktemp -d)"; trap 'rm -rf "$tmp" "$outdir"' EXIT
mkdir -p "$tmp/prefix/share/iree-runtime-dist"
for f in element_types.json status_codes.json element_types.schema.json status_codes.schema.json; do
  echo '{}' > "$tmp/prefix/share/iree-runtime-dist/$f"
done

bash "$here/../scripts/package-metadata.sh" "$tmp/prefix" 9.9.9 "$outdir"

zip_path="$outdir/iree-runtime-metadata-9.9.9.zip"
if [ -s "$zip_path" ]; then echo "ok: zip created"
else echo "FAIL: zip missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

members="$(unzip -Z1 "$zip_path" 2>/dev/null)"
for member in element_types.json status_codes.json element_types.schema.json status_codes.schema.json README.md; do
  assert_contains "$members" "$member" "zip contains $member"
done

member_count="$(printf '%s\n' "$members" | grep -c .)"
assert_eq "$member_count" "5" "zip has exactly five members"

exit "$ASSERT_FAILS"
