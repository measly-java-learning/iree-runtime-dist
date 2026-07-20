#!/usr/bin/env bash
# Usage: notices.test.sh <prefix>. Skips when no prefix given.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
prefix="${1:-}"
if [ -z "$prefix" ]; then echo "skip: notices.test.sh needs a built prefix"; exit 0; fi

if [ -s "$prefix/LICENSE" ]; then echo "ok: IREE LICENSE present and non-empty"
else echo "FAIL: LICENSE missing or empty" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

if [ -d "$prefix/THIRD-PARTY-NOTICES" ]; then echo "ok: THIRD-PARTY-NOTICES present"
else echo "FAIL: THIRD-PARTY-NOTICES missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

# Determined empirically (Task 8): flatcc, printf, and libbacktrace are the
# components with a real link-graph footprint reaching iree_runtime_unified.
# See scripts/lib/linked-components.sh for the evidence trail.
for linked in flatcc printf libbacktrace; do
  if [ -s "$prefix/THIRD-PARTY-NOTICES/$linked/LICENSE" ]; then echo "ok: $linked notice shipped"
  else echo "FAIL: $linked notice missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
done

# Nothing unlinked may be claimed. llvm-project is excluded by IREE_BUILD_COMPILER=OFF.
# The rest are submodules IREE's checkout gate demands but that a local-sync/local-task
# CPU runtime never links -- claiming them would misrepresent the artifact's contents.
# benchmark in particular was verified empirically (Task 8, Step 3): its symbols are
# referenced only by iree_testing_benchmark.a, a sibling test-tool archive that is not
# in iree_runtime_unified's transitive INTERFACE_LINK_LIBRARIES closure, so it never
# reaches a consumer that links iree::runtime::unified.
for unlinked in llvm-project tracy spirv_cross vulkan_headers webgpu-headers \
                hip-build-deps hsa-runtime-headers benchmark googletest; do
  if [ -e "$prefix/THIRD-PARTY-NOTICES/$unlinked" ]; then
    echo "FAIL: $unlinked notice must not ship -- it is not linked into this artifact" >&2
    ASSERT_FAILS=$((ASSERT_FAILS+1))
  else echo "ok: no $unlinked notice (correctly not claimed)"; fi
done

# Every notice directory must correspond to something actually shipped.
for d in "$prefix"/THIRD-PARTY-NOTICES/*/; do
  [ -d "$d" ] || continue
  if [ -s "$d/LICENSE" ]; then echo "ok: $(basename "$d") notice non-empty"
  else echo "FAIL: $(basename "$d") notice is empty" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
done

exit "$ASSERT_FAILS"
