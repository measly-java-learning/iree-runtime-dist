#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/consumer/mode.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A tsan prefix: BUILDINFO carries a sanitizer=thread line.
tsan_dir="$tmp/tsan"
mkdir -p "$tsan_dir"
cat > "$tsan_dir/BUILDINFO" <<EOF
iree-runtime-dist
variant=tsan
sanitizer=thread
EOF
assert_eq "$(consumer_run_mode "$tsan_dir")" "tsan" "sanitizer=thread selects tsan mode"

# A default prefix: BUILDINFO has no sanitizer= line at all.
default_dir="$tmp/default"
mkdir -p "$default_dir"
cat > "$default_dir/BUILDINFO" <<EOF
iree-runtime-dist
variant=default
platform=linux-x86_64
EOF
assert_eq "$(consumer_run_mode "$default_dir")" "default" "no sanitizer= line selects default mode"

# Missing BUILDINFO entirely must not blow up (grep failure is swallowed) and
# must fall back to default.
missing_dir="$tmp/missing"
mkdir -p "$missing_dir"
assert_eq "$(consumer_run_mode "$missing_dir")" "default" "missing BUILDINFO falls back to default mode"

exit "$ASSERT_FAILS"
