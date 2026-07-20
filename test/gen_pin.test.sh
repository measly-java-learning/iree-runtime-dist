#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/assets"
echo "payload" > "$tmp/assets/iree-runtime-3.11.0-default-linux-x86_64.tar.gz"
( cd "$tmp/assets" && sha256sum iree-runtime-3.11.0-default-linux-x86_64.tar.gz \
    > iree-runtime-3.11.0-default-linux-x86_64.tar.gz.sha256 )

bash "$here/../scripts/gen-pin.sh" "org/iree-runtime-dist" "v3.11.0-1" "3.11.0" \
  "$tmp/assets" "$tmp/IreeRuntimePin.cmake"

got="$(cat "$tmp/IreeRuntimePin.cmake")"
assert_contains "$got" "IREE_RUNTIME_URL_default_linux-x86_64"    "url variable"
assert_contains "$got" "IREE_RUNTIME_SHA256_default_linux-x86_64" "sha variable"
assert_contains "$got" "https://github.com/org/iree-runtime-dist/releases/download/v3.11.0-1/" "release url"

expected_sha="$(cd "$tmp/assets" && sha256sum iree-runtime-3.11.0-default-linux-x86_64.tar.gz | cut -d' ' -f1)"
assert_contains "$got" "$expected_sha" "records the real sha256"

exit "$ASSERT_FAILS"
