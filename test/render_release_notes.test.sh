#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Fixture: the five assets a full release delivers (names per scripts/lib/naming.sh).
for f in \
  iree-runtime-3.11.0-default-linux-aarch64.tar.gz \
  iree-runtime-3.11.0-default-linux-x86_64.tar.gz \
  iree-runtime-3.11.0-default-windows-x86_64.tar.gz \
  iree-runtime-3.11.0-tsan-linux-aarch64.tar.gz \
  iree-runtime-3.11.0-tsan-linux-x86_64.tar.gz; do
  touch "$tmp/$f" "$tmp/$f.sha256"
done

notes="$(bash "$here/../scripts/render-release-notes.sh" "$tmp" "org/iree-runtime-dist")"

assert_contains "$notes" "IREE runtime 3.11.0 (\`default\`/\`linux-aarch64\`, \`default\`/\`linux-x86_64\`, \`default\`/\`windows-x86_64\`, \`tsan\`/\`linux-aarch64\`, \`tsan\`/\`linux-x86_64\`)." "title lists every asset on disk"
assert_contains "$notes" "**Pair with \`iree-base-compiler==3.11.0\`.**" "pairing note carries the disk version"
assert_contains "$notes" "sha256sum -c iree-runtime-3.11.0-tsan-linux-x86_64.tar.gz.sha256" "verify block covers tsan/linux-x86_64"
assert_contains "$notes" "gh attestation verify iree-runtime-3.11.0-default-windows-x86_64.tar.gz --repo org/iree-runtime-dist" "attestation line carries the repo arg"
n_verify="$(printf '%s' "$notes" | grep -c '^gh attestation verify ')"
assert_eq "$n_verify" "5" "exactly one attestation line per asset on disk"

# A directory with no tarballs fails loudly (broken download must abort, not
# ship empty notes).
mkdir -p "$tmp/empty"
if bash "$here/../scripts/render-release-notes.sh" "$tmp/empty" "org/iree-runtime-dist" >/dev/null 2>&1; then
  printf 'FAIL: empty dir should fail loudly\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok: empty dir fails loudly\n'
fi

# A tarball without its sha256 sibling fails loudly (the verify block would
# instruct a `sha256sum -c` on a file that does not exist).
mkdir -p "$tmp/missing-sha"
touch "$tmp/missing-sha/iree-runtime-3.11.0-default-linux-x86_64.tar.gz"
if bash "$here/../scripts/render-release-notes.sh" "$tmp/missing-sha" "org/iree-runtime-dist" >/dev/null 2>&1; then
  printf 'FAIL: tarball without sha256 sibling should fail loudly\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok: missing sha256 sibling fails loudly\n'
fi

# Two tarballs with different versions fail loudly (a half-uploaded release
# must not produce notes claiming one version).
mkdir -p "$tmp/mixed-versions"
touch "$tmp/mixed-versions/iree-runtime-3.11.0-default-linux-x86_64.tar.gz" \
      "$tmp/mixed-versions/iree-runtime-3.11.0-default-linux-x86_64.tar.gz.sha256" \
      "$tmp/mixed-versions/iree-runtime-3.12.0-default-linux-x86_64.tar.gz" \
      "$tmp/mixed-versions/iree-runtime-3.12.0-default-linux-x86_64.tar.gz.sha256"
if bash "$here/../scripts/render-release-notes.sh" "$tmp/mixed-versions" "org/iree-runtime-dist" >/dev/null 2>&1; then
  printf 'FAIL: mixed versions should fail loudly\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok: mixed versions fail loudly\n'
fi

# A tarball whose name does not round-trip through naming.sh fails loudly.
mkdir -p "$tmp/unparseable"
touch "$tmp/unparseable/bogus.tar.gz"
if bash "$here/../scripts/render-release-notes.sh" "$tmp/unparseable" "org/iree-runtime-dist" >/dev/null 2>&1; then
  printf 'FAIL: unparseable asset name should fail loudly\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok: unparseable asset name fails loudly\n'
fi

exit "$ASSERT_FAILS"
