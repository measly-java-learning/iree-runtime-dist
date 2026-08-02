#!/usr/bin/env bash
# variants.sh owns ONE thing now: which variants a platform builds. The flag
# mappings it used to own moved to cmake/variant-*.cmake, where CMake reads
# them directly.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/variants.sh"

assert_eq "$(known_variants linux-x86_64)"  "default tsan" "linux-x86_64 builds both variants"
assert_eq "$(known_variants linux-aarch64)" "default tsan" "linux-aarch64 builds both variants"
# tsan is -fsanitize=thread under clang, which the MSVC toolchain does not
# provide. release.yml keeps Windows in its own job to avoid scheduling that
# leg; this list is what stops cmake_init.test.sh from demanding a
# cmake/variant-tsan.cmake coverage entry for a platform that cannot build it.
assert_eq "$(known_variants windows-x86_64)" "default"     "windows-x86_64 builds default only"

# An unknown platform must FAIL, not return an empty list. An empty list
# collapses a release matrix to zero jobs while setup reports success.
if known_variants bogus-platform >/dev/null 2>&1; then
  printf 'FAIL: known_variants accepted an unknown platform\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok: known_variants rejects an unknown platform\n'
fi

# The deleted functions must STAY deleted. A reintroduced variant_cflags would
# be a second place that says what tsan's flags are.
for fn in variant_flags variant_cflags variant_sanitizer _runtime_capability_flags; do
  if command -v "$fn" >/dev/null 2>&1; then
    printf 'FAIL: %s still exists -- flag mappings belong in cmake/variant-*.cmake\n' "$fn" >&2
    ASSERT_FAILS=$((ASSERT_FAILS+1))
  else
    printf 'ok: %s is gone\n' "$fn"
  fi
done

[ "$ASSERT_FAILS" -eq 0 ] || exit 1
echo "lib_variants: all assertions passed"