#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/naming.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/assets"

for v in default tsan; do
  for p in $(known_platforms); do
    f="iree-runtime-3.11.0-$v-$p.tar.gz"
    echo "payload-$v-$p" > "$tmp/assets/$f"
    ( cd "$tmp/assets" && sha256sum "$f" > "$f.sha256" )
  done
done

bash "$here/../scripts/gen-pin.sh" "org/iree-runtime-dist" "v3.11.0-1" "3.11.0" "$tmp/assets" "$tmp/IreeRuntimePin.cmake"
got="$(cat "$tmp/IreeRuntimePin.cmake")"

assert_contains "$got" "function(iree_runtime_dist_url" "defines the selector helper"
assert_contains "$got" "IREE_RUNTIME_DIST_tsan_linux-x86_64_URL" "has tsan data line"
case "$got" in *"IREE_RUNTIME_URL_default_linux-x86_64"*) echo "FAIL: old flat var still present" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1));; *) echo "ok: clean break, no old flat vars";; esac

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
  # fail-fast on an unbuilt combo -> FATAL_ERROR -> nonzero exit
  cat > "$tmp/bad.cmake" <<EOF
include("$tmp/IreeRuntimePin.cmake")
iree_runtime_dist_url(nope linux-x86_64 U S)
EOF
  if cmake -P "$tmp/bad.cmake" >/dev/null 2>&1; then echo "FAIL: unknown combo should FATAL_ERROR" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); else echo "ok: unknown combo fails fast"; fi
fi

exit "$ASSERT_FAILS"
