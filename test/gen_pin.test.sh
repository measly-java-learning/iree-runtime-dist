#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/assets"

# Fixture: a partial asset set on disk (linux-aarch64 deliberately absent).
# gen-pin must pin exactly what is here -- no phantom rows for platforms the
# declared lists would have enumerated.
for f in \
  iree-runtime-3.11.0-default-linux-x86_64.tar.gz \
  iree-runtime-3.11.0-default-windows-x86_64.tar.gz; do
  printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  %s\n' "$f" \
    > "$tmp/assets/$f.sha256"
done
# Real sha256 content for one asset so the value is asserted end to end.
( cd "$tmp/assets" \
  && printf 'payload' > iree-runtime-3.11.0-tsan-linux-x86_64.tar.gz \
  && sha256sum iree-runtime-3.11.0-tsan-linux-x86_64.tar.gz > iree-runtime-3.11.0-tsan-linux-x86_64.tar.gz.sha256 )

bash "$here/../scripts/gen-pin.sh" "org/iree-runtime-dist" "v3.11.0-1" "3.11.0" "$tmp/assets" "$tmp/IreeRuntimePin.cmake"
got="$(cat "$tmp/IreeRuntimePin.cmake")"

assert_contains "$got" "function(iree_runtime_dist_url" "defines the selector helper"
assert_contains "$got" "IREE_RUNTIME_DIST_tsan_linux-x86_64_URL" "has tsan data line"
assert_contains "$got" "IREE_RUNTIME_DIST_default_windows-x86_64_URL" "has windows data line"
case "$got" in
  *IREE_RUNTIME_DIST_default_linux-aarch64_*) printf 'FAIL: phantom row for absent linux-aarch64\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1));;
  *) printf 'ok: no phantom row for absent linux-aarch64\n';;
esac
case "$got" in
  *"releases/download/v3.11.0-1/iree-runtime-3.11.0-tsan-linux-x86_64.tar.gz"*) printf 'ok: URL uses tag + asset name\n';;
  *) printf 'FAIL: URL missing tag/asset\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1));;
esac
expected="$(cut -d' ' -f1 "$tmp/assets/iree-runtime-3.11.0-tsan-linux-x86_64.tar.gz.sha256")"
assert_contains "$got" "$expected" "sha value round-trips from the on-disk file"

# Helper resolves a known combo (cmake -P if available; else grep the data line).
if command -v cmake >/dev/null; then
  cat > "$tmp/probe.cmake" <<EOF
include("$tmp/IreeRuntimePin.cmake")
iree_runtime_dist_url(tsan linux-x86_64 U S)
message(STATUS "URL=\${U}")
message(STATUS "SHA=\${S}")
EOF
  probe="$(cmake -P "$tmp/probe.cmake" 2>&1)"
  assert_contains "$probe" "releases/download/v3.11.0-1/iree-runtime-3.11.0-tsan-linux-x86_64.tar.gz" "helper resolves tsan url"
  cat > "$tmp/bad.cmake" <<EOF
include("$tmp/IreeRuntimePin.cmake")
iree_runtime_dist_url(nope linux-x86_64 U S)
EOF
  if cmake -P "$tmp/bad.cmake" >/dev/null 2>&1; then printf 'FAIL: unknown combo should FATAL_ERROR\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); else printf 'ok: unknown combo fails fast\n'; fi
fi

# A directory with no sha files fails loudly (zero-row assertion).
mkdir -p "$tmp/empty"
if bash "$here/../scripts/gen-pin.sh" "org/iree-runtime-dist" "v3.11.0-1" "3.11.0" "$tmp/empty" "$tmp/out.cmake" >/dev/null 2>&1; then
  printf 'FAIL: empty assets dir should fail loudly\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok: empty assets dir fails loudly\n'
fi

# A malformed sha fails loudly.
mkdir -p "$tmp/badsha"
printf 'nothex  iree-runtime-3.11.0-default-linux-x86_64.tar.gz\n' > "$tmp/badsha/iree-runtime-3.11.0-default-linux-x86_64.tar.gz.sha256"
if bash "$here/../scripts/gen-pin.sh" "org/iree-runtime-dist" "v3.11.0-1" "3.11.0" "$tmp/badsha" "$tmp/out.cmake" >/dev/null 2>&1; then
  printf 'FAIL: malformed sha should fail loudly\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok: malformed sha fails loudly\n'
fi

# An asset whose name embeds the pkgrev (3.11.0-10) fails loudly -- parse_asset
# rejects the dash in the variant token instead of mislabeling it.
mkdir -p "$tmp/pkgrev"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  x\n' > "$tmp/pkgrev/iree-runtime-3.11.0-10-default-linux-x86_64.tar.gz.sha256"
if bash "$here/../scripts/gen-pin.sh" "org/iree-runtime-dist" "v3.11.0-1" "3.11.0" "$tmp/pkgrev" "$tmp/out.cmake" >/dev/null 2>&1; then
  printf 'FAIL: pkgrev-in-name should fail loudly\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok: pkgrev-in-name fails loudly\n'
fi

exit "$ASSERT_FAILS"
