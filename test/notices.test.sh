#!/usr/bin/env bash
# Usage: notices.test.sh <prefix>. Skips when no prefix given.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"

. "$here/../scripts/lib/linked-components.sh"

# Derived per platform, never assumed. W4 confirmed libbacktrace is absent from
# a Windows artifact four ways: no install rule, no archive in the prefix, zero
# backtrace_* symbols across all 191 archives, and absent from iree_base_base's
# INTERFACE_LINK_LIBRARIES where Linux carries it. Shipping the Linux list on a
# Windows artifact would claim a license for code that is not there.
assert_eq "$(linked_components linux-x86_64)"   "flatcc printf libbacktrace" "linux linked components"
assert_eq "$(linked_components linux-aarch64)"  "flatcc printf libbacktrace" "linux-aarch64 linked components"
assert_eq "$(linked_components windows-x86_64)" "flatcc printf"              "windows drops libbacktrace"

linked_components bogus-platform >/dev/null 2>&1
assert_eq "$?" "2" "linked_components rejects an unknown platform"

# A caller that forgets the platform argument entirely must fail loudly, not
# silently fall back to the Linux list or succeed with empty output -- either
# would ship a notices set that doesn't match what the artifact contains.
noarg_out="$(linked_components 2>/dev/null)"; noarg_status=$?
assert_eq "$noarg_out" "" "linked_components with no argument produces no stdout"
assert_eq "$noarg_status" "2" "linked_components with no argument returns non-zero"

unknown_out="$(linked_components totally-unknown-platform 2>/dev/null)"; unknown_status=$?
assert_eq "$unknown_out" "" "linked_components with unknown platform produces no stdout"
assert_eq "$unknown_status" "2" "linked_components with unknown platform returns non-zero"

prefix="${1:-}"
if [ -z "$prefix" ]; then
  echo "skip: prefix-dependent notices checks need a built prefix"
  exit "$ASSERT_FAILS"
fi

if [ -s "$prefix/LICENSE" ]; then echo "ok: IREE LICENSE present and non-empty"
else echo "FAIL: LICENSE missing or empty" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

if [ -d "$prefix/THIRD-PARTY-NOTICES" ]; then echo "ok: THIRD-PARTY-NOTICES present"
else echo "FAIL: THIRD-PARTY-NOTICES missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

# Determined empirically (Task 8): flatcc, printf, and libbacktrace are the
# components with a real link-graph footprint reaching iree_runtime_unified --
# on LINUX. Windows links no libbacktrace at all (W4: no install rule, no
# archive, zero backtrace_* symbols across the shipped archives), so the
# expected set is per-platform. Read the platform from the prefix's own
# BUILDINFO and ask linked-components.sh, rather than hard-coding a list that
# is right for one platform and over-claims on the other. A missing/unreadable
# platform is a hard failure: silently falling back to a default list is how a
# notices test ends up asserting the wrong artifact's contents.
platform="$(grep -oE '^platform=.*' "$prefix/BUILDINFO" 2>/dev/null | cut -d= -f2)"
if [ -z "$platform" ]; then
  echo "FAIL: no platform= line in $prefix/BUILDINFO -- cannot determine expected notices" >&2
  exit $((ASSERT_FAILS+1))
fi
expected_linked="$(linked_components "$platform")" || {
  echo "FAIL: linked_components rejected platform '$platform' from BUILDINFO" >&2
  exit $((ASSERT_FAILS+1))
}
for linked in $expected_linked; do
  if [ -s "$prefix/THIRD-PARTY-NOTICES/$linked/LICENSE" ]; then echo "ok: $linked notice shipped"
  else echo "FAIL: $linked notice missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
done

# The other direction: a component this platform does NOT link must not have a
# notice shipped for it. Over-claiming a license is the same class of error as
# claiming LLVM -- and on Windows libbacktrace is exactly that case.
for maybe in flatcc printf libbacktrace; do
  case " $expected_linked " in
    *" $maybe "*) continue ;;
  esac
  if [ -e "$prefix/THIRD-PARTY-NOTICES/$maybe" ]; then
    echo "FAIL: $maybe notice shipped but $maybe is not linked on $platform" >&2
    ASSERT_FAILS=$((ASSERT_FAILS+1))
  else echo "ok: no $maybe notice on $platform (correctly not claimed)"; fi
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
