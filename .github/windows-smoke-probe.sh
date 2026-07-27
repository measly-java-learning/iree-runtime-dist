#!/usr/bin/env bash
# THROWAWAY probe -- paired with .github/workflows/windows-smoke.yml (Task 12b).
# Both files are removed in Task 12c once release.yml carries the proven pattern.
#
# Runs under Git-Bash on a windows-2022 runner, INSIDE an activated VS dev shell
# (see the workflow: vswhere -> Launch-VsDevShell.ps1 -Arch amd64
# -SkipAutomaticLocation -> "${env:ProgramFiles}\Git\bin\bash.exe"). Never
# C:\Windows\System32\bash.exe -- that is WSL and would build Linux ELF objects,
# making every assertion below meaningless.
#
# This script ASSERTS. It must exit non-zero when a measurement does not hold;
# printing values for a human to eyeball is exactly the failure mode this
# sub-task exists to avoid.
set -euo pipefail

fail() { echo "ASSERTION FAILED: $*" >&2; exit 1; }

# GITHUB_WORKSPACE arrives as a Windows path (D:\a\repo\repo -- runners are
# D:-rooted). Backslashes are escapes in bash, so convert before using it.
ws="$(cygpath -u "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is unset}")"

# ---------------------------------------------------------------- assertion 1
# The pinned windows-2022 image ships MSVC 19.44.x. `windows-latest` would drift
# silently, and msvc_toolset is attested provenance.
command -v cl >/dev/null 2>&1 \
  || fail "cl is not on PATH -- the VS dev shell did not activate"
banner="$(cl 2>&1 | tr -d '\r' | head -n 2 || true)"
echo "--- cl banner ---"
printf '%s\n' "$banner"
echo "MEASURED cl_banner: $(printf '%s\n' "$banner" | head -n 1)"
printf '%s\n' "$banner" | grep -Eq 'Version 19\.44\.[0-9]+' \
  || fail "cl banner is not 19.44.x -- toolset is not the pinned windows-2022 one"
echo "OK assertion 1: cl is 19.44.x"

# ------------------------------------------------------------- emit the flags
# --iree-src is deliberately a POSIX-form path so that cygpath -w inside
# build-runtime.sh has real work to do; that conversion is what assertion 3
# proves actually resolved on the runner.
flags="$(./build-runtime.sh --print-flags --variant default \
  --platform windows-x86_64 --iree-src "$ws/iree")"
echo "--- effective flags ---"
printf '%s\n' "$flags"

# ---------------------------------------------------------------- assertion 2
# Static CRT. Anchored so MultiThreadedDLL cannot satisfy a substring match.
printf '%s\n' "$flags" | grep -Eq '^-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded$' \
  || fail "flags do not contain -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded"
echo "MEASURED crt_flag: $(printf '%s\n' "$flags" | grep -E '^-DCMAKE_MSVC_RUNTIME_LIBRARY=' || true)"
echo "OK assertion 2: -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded present"

# ---------------------------------------------------------------- assertion 3
# /d1trimfile: must carry a Windows-form, NON-EMPTY prefix ending in exactly one
# backslash. cl.exe bakes __FILE__ in as C:\... , so a POSIX-form (/d/a/...) or
# empty prefix matches nothing, trims nothing, and silently ships absolute build
# paths in every archive while the build still looks configured correctly.
cf="$(printf '%s\n' "$flags" | grep -E '^compiler_flags: ' | head -n 1 || true)"
[ -n "$cf" ] || fail "--print-flags emitted no 'compiler_flags: ' line"
case "$cf" in
  *"/d1trimfile:"*) ;;
  *) fail "compiler_flags carries no /d1trimfile: prefix -- got: $cf" ;;
esac
prefix="${cf##*/d1trimfile:}"
prefix="${prefix%% *}"
echo "MEASURED trimfile_prefix: [$prefix]"

[ -n "$prefix" ] || fail "/d1trimfile: prefix is EMPTY -- it would trim nothing"
# Windows form: a drive letter, colon, backslash. This also rejects the POSIX
# form (/d/a/...) that would silently no-op.
case "$prefix" in
  [A-Za-z]:\\*) ;;
  *) fail "/d1trimfile: prefix is not Windows-form (expected e.g. D:\\...): [$prefix]" ;;
esac
stripped="${prefix%\\}"
[ "$stripped" != "$prefix" ] \
  || fail "/d1trimfile: prefix does not end in a backslash: [$prefix]"
case "$stripped" in
  *\\) fail "/d1trimfile: prefix ends in a DOUBLED backslash: [$prefix]" ;;
esac
# The prefix must actually be the IREE source root we passed in, not some
# truncated or unrelated path.
case "$stripped" in
  *[Ii]ree) ;;
  *) fail "/d1trimfile: prefix is not the iree source root: [$prefix]" ;;
esac
echo "OK assertion 3: /d1trimfile: prefix is Windows-form, non-empty, single trailing backslash"

echo "ALL ASSERTIONS PASSED"
