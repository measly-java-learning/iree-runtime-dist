# Declared Configuration and Observed Provenance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the IREE runtime recipe's build configuration out of shell flag-assembly into `cmake -C` cache-init files, and make `manifest.json`/`BUILDINFO` provenance read what the build actually produced instead of reconstructing it from the arguments that drove the build.

**Architecture:** Three `-C` cache-init files (universal, platform, variant) are composed on the `cmake` command line; each declares its cache entries through a `dist_set()` macro that also registers the key name in an `IREE_DIST_DECLARED_KEYS` internal cache list. `gen-manifest.sh` then reads `CMakeCache.txt`, filtered by that registry, as the single authority for recorded build configuration. `scripts/lib/cmakeflags.sh`, the ~90-line platform-conditional flag block, `--print-flags`, and most of `scripts/lib/variants.sh` are deleted.

**Tech Stack:** Bash (`set -euo pipefail`), CMake cache-init scripts (`cmake -C`), Python 3 stdlib only, the repo's own dependency-free assertion harness (`test/assert.sh`).

**Spec:** `docs/superpowers/specs/2026-07-29-declared-configuration-and-observed-provenance-design.md`

**Baseline:** commit `4bb545b` (`wip: GHA matrix simplification checkpoint`). That commit is deliberately non-working — `windows-x86_64` is broken at the verify stage — and exists as a revert target. Two follow-on doc commits (`4ccc1a3`, `5c7ca9d`) are on top of it.

## Global Constraints

Every task's requirements implicitly include this section. Values are copied verbatim from the spec and CLAUDE.md.

- `set -euo pipefail` in every shell script. `grep` exits 1 on no-match and aborts under `set -e`; guard with `|| true`.
- **The compiler is out of contract.** `IREE_BUILD_COMPILER=OFF` always. Never build or ship `iree-compile`.
- **`CMAKE_BUILD_TYPE` stays `Release` for both variants**, never `RelWithDebInfo` — that would rename the exported config (`IMPORTED_LOCATION_RELEASE` → `_RELWITHDEBINFO`) and silently break the Release-hardcoded libbacktrace and relocatability repairs.
- **v1 is stable `v3.11.0` only.** Never `main`. Never point `--iree-src` at `/home/corey/workspace/iree` — that checkout tracks `main`.
- **The relocatability assertion stays exactly as strict.** If it fires, extend the repair; never weaken the assertion.
- **`schema_version` stays `2`.** All new manifest fields are additive. The published key `iree_compile_version` is **not** renamed.
- **The recipe is idempotent.** Re-runs must not fail on existing build trees or already-patched export files.
- **Never `git add -A` or `git add .`** — stage explicit paths only.
- Four verified CMake behaviours the design depends on:
  1. Multiple `-C` files compose in order; a later file can read and extend an earlier file's cache values.
  2. Appending across `-C` files requires `FORCE`, because the earlier file already created the entry.
  3. A command-line `-D` wins even against a `FORCE`d cache-init `set()`, **but the override resets the entry's type to `UNINITIALIZED`** — so provenance filters by declared key *name*, never by type.
  4. `-C` does **not** fix the `CMAKE_<LANG>_FLAGS_INIT` clobber. A cache-init file setting `CMAKE_C_FLAGS` drops the platform `_INIT` contribution exactly as a command-line `-D` does. The restated MSVC platform defaults remain load-bearing.

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `cmake/dist-set.cmake` | The `dist_set()` macro and the `IREE_DIST_DECLARED_KEYS` registry. Nothing else. |
| `cmake/common.cmake` | The 19 platform- and variant-independent cache entries. Touches no compiler-flag variable. |
| `cmake/gnu-toolchain.cmake` | clang/clang++ selection and `-ffile-prefix-map` composition. Shared by both Linux platform files. |
| `cmake/linux-x86_64.cmake` | One `include()` of `gnu-toolchain.cmake`. |
| `cmake/linux-aarch64.cmake` | One `include()` of `gnu-toolchain.cmake`. |
| `cmake/windows-x86_64.cmake` | MSVC compiler selection, static CRT, restated MSVC platform defaults, `/d1trimfile:`. |
| `cmake/variant-default.cmake` | Declares no compiler flags, deliberately. |
| `cmake/variant-tsan.cmake` | Appends `-fsanitize=thread -g` to both flag variables. |
| `scripts/emit-manifest.py` | Reads `CMakeCache.txt` and argv; writes `manifest.json`. The only place manifest JSON shape is defined. |
| `test/cmake_init.test.sh` | Hermetic: every platform/variant has a cache-init file; the Windows MSVC defaults are present in C++ and absent in C. |

**Deleted:** `scripts/lib/cmakeflags.sh`, `test/print_flags.test.sh`.

**Modified:** `build-runtime.sh`, `scripts/gen-manifest.sh`, `scripts/lib/variants.sh`, `scripts/derive-version.sh`, `scripts/gen-addvmfb.sh`, `scripts/gen-tsan-docs.sh`, `.github/workflows/release.yml`, `test/lib_variants.test.sh`, `test/manifest.test.sh`, `CLAUDE.md`, `spike/windows-iree-runbook.md`, `spike/macos-iree-runbook.md`, `docs/superpowers/notes/2026-07-29-package-port-regime.md`.

## Terminology for this plan

- **`$WORK`** — the scratchpad directory, `/tmp/claude-1000/-home-corey-workspace-iree-runtime-dist/<session>/scratchpad`. Nothing here is committed.
- **`$IREE_SRC`** — a checkout of `iree-org/iree` at tag `v3.11.0` with required submodules initialised. **Not** `/home/corey/workspace/iree`.
- **cache fingerprint** — `CMakeCache.txt` reduced to the declared keys plus the two compiler-flag keys, sorted. The acceptance gate is a diff of these before and after.

---

### Task 1: Capture the baseline cache fingerprints

No source changes. This task produces the artifacts every later task's acceptance gate diffs against. It must run **before** any other task, on baseline `4bb545b` behaviour.

**Files:**
- Create: `$WORK/baseline/<platform>-<variant>.cache` (5 files, uncommitted)
- Create: `$WORK/fingerprint.sh` (uncommitted helper)

**Interfaces:**
- Produces: 5 baseline fingerprint files consumed by Tasks 4 and 7. Also `$WORK/fingerprint.sh`, whose contract is `fingerprint.sh <build-dir> > <out-file>`.

- [ ] **Step 1: Write the fingerprint helper**

The key list is written out literally rather than read from anywhere, because on the baseline there is no `IREE_DIST_DECLARED_KEYS` to read — that is exactly what Task 3 introduces. These are the 19 entries `effective_cmake_flags` plus the two bare `-D`s produce, and the two compiler-flag keys.

Create `$WORK/fingerprint.sh`:

```bash
#!/usr/bin/env bash
# Reduce a CMakeCache.txt to the entries this recipe declares, plus the two
# compiler-flag variables. Value-only comparison: the TYPE deliberately differs
# before and after the migration (UNINITIALIZED -> typed), so it is stripped.
#
# CMAKE_C_COMPILER / CMAKE_CXX_COMPILER are deliberately EXCLUDED. On Windows
# their value legitimately changes -- the baseline passes the bare name `cl`,
# while cmake/windows-x86_64.cmake uses find_program(... REQUIRED) and lands the
# resolved absolute path, which is the point (provenance names the exact cl).
# Including them would make the Windows row diff for an intended reason and
# train the reader to ignore the gate. Verify them by eye instead: same clang on
# linux, an absolute path ending in cl.exe on windows.
set -euo pipefail
build_dir="${1:?usage: fingerprint.sh <build-dir>}"
keys='
IREE_BUILD_COMPILER
IREE_BUILD_TESTS
IREE_BUILD_SAMPLES
IREE_BUILD_BINDINGS_TFLITE
IREE_BUILD_BINDINGS_TFLITE_JAVA
IREE_BUILD_PYTHON_BINDINGS
BUILD_SHARED_LIBS
CMAKE_BUILD_TYPE
CMAKE_POSITION_INDEPENDENT_CODE
IREE_ALLOCATOR_SYSTEM
IREE_ENABLE_THREADING
IREE_HAL_DRIVER_DEFAULTS
IREE_HAL_DRIVER_LOCAL_SYNC
IREE_HAL_DRIVER_LOCAL_TASK
IREE_HAL_EXECUTABLE_LOADER_DEFAULTS
IREE_HAL_EXECUTABLE_LOADER_EMBEDDED_ELF
IREE_HAL_EXECUTABLE_LOADER_SYSTEM_LIBRARY
IREE_ENABLE_RUNTIME_TRACING
CMAKE_INSTALL_LIBDIR
CMAKE_MSVC_RUNTIME_LIBRARY
CMAKE_C_FLAGS
CMAKE_CXX_FLAGS
'
for k in $keys; do
  # grep -m1 on an anchored "KEY:" match. Absent keys are reported explicitly
  # rather than skipped -- a key silently vanishing between runs is precisely
  # the regression this gate exists to catch.
  line="$(grep -m1 "^${k}:" "$build_dir/CMakeCache.txt" || true)"
  if [ -z "$line" ]; then
    printf '%s=<ABSENT>\n' "$k"
  else
    printf '%s=%s\n' "$k" "${line#*=}"
  fi
done
```

- [ ] **Step 2: Verify the helper runs and reports sensibly against a throwaway cache**

Run:

```bash
mkdir -p "$WORK/probe" && printf 'CMAKE_BUILD_TYPE:STRING=Release\n' > "$WORK/probe/CMakeCache.txt"
bash "$WORK/fingerprint.sh" "$WORK/probe" | head -3
```

Expected: `IREE_BUILD_COMPILER=<ABSENT>`, then more `<ABSENT>` lines, and `CMAKE_BUILD_TYPE=Release` further down. This confirms both branches work before spending 40 minutes of configure time on them.

- [ ] **Step 3: Capture the two Linux x86_64 fingerprints**

Configure only — do not build. `--print-flags` is still present on the baseline but is **not** what we capture; the cache is.

```bash
for v in default tsan; do
  docker run --rm \
    -v "$PWD":/work/recipe -v "$IREE_SRC":/iree \
    -w /work/recipe iree-runtime-dist-build:linux-x86_64 \
    bash -c "bash build-runtime.sh --variant $v --platform linux-x86_64 \
             --prefix /work/out-$v --iree-src /iree --build-dir /work/b-$v 2>&1 | tail -40"
done
```

Stop each run once `==> configuring` has completed and `==> building` has started — the fingerprint only needs `CMakeCache.txt` to exist. Then:

```bash
for v in default tsan; do
  bash "$WORK/fingerprint.sh" "$WORK/b-$v" > "$WORK/baseline/linux-x86_64-$v.cache"
done
```

**Note on paths:** the container writes `/work/b-$v` inside the bind mount, so adjust the host-side path in the `fingerprint.sh` call to wherever `/work` is mounted. Getting this wrong yields a "no such file" error, not a wrong fingerprint, so it is self-announcing.

- [ ] **Step 4: Capture the two Linux aarch64 fingerprints on the Radxa**

Same two commands with `--platform linux-aarch64` and `iree-runtime-dist-build:linux-aarch64`, run on the Radxa. Copy the two resulting files back to `$WORK/baseline/linux-aarch64-{default,tsan}.cache`.

- [ ] **Step 5: Capture the Windows fingerprint on winbox**

Over SSH to winbox. The default shell is `cmd`; `System32\bash.exe` is WSL and is the wrong bash — use Git-Bash explicitly. Run the recipe far enough to configure:

```
"C:\Program Files\Git\bin\bash.exe" -lc "cd /c/path/to/iree-runtime-dist && bash build-runtime.sh --variant default --platform windows-x86_64 --prefix /c/out --iree-src /c/iree --build-dir /c/b-default"
```

This must run inside an activated VS dev shell or `cl` will not resolve. Interrupt once configure completes. Then run `fingerprint.sh` against `C:\b-default` and copy the result to `$WORK/baseline/windows-x86_64-default.cache`.

- [ ] **Step 6: Verify all five fingerprints exist and none is entirely `<ABSENT>`**

Run:

```bash
wc -l "$WORK"/baseline/*.cache
grep -c '=<ABSENT>' "$WORK"/baseline/*.cache
```

Expected: 5 files, 22 lines each. `<ABSENT>` counts should be 1 on `linux-*` (`CMAKE_MSVC_RUNTIME_LIBRARY` does not apply) and 0 on `windows-*`. A file that is all-`<ABSENT>` means the configure never happened; re-run that row rather than proceeding.

- [ ] **Step 7: No commit**

Nothing in this task is committed — the baselines are throwaway evidence for later tasks. Record the five files' locations in the task report so Tasks 4 and 7 can find them.

---

### Task 2: Extract the manifest emitter to a standalone Python script

Pure refactor with no behaviour change, so the existing `manifest.test.sh` is the whole gate. Doing it first means later tasks edit a real Python file rather than a heredoc.

**Files:**
- Create: `scripts/emit-manifest.py`
- Modify: `scripts/gen-manifest.sh:122-206` (the `python3 - <<'EOF'` heredoc)
- Test: `test/manifest.test.sh` (existing, unmodified in this task)

**Interfaces:**
- Produces: `scripts/emit-manifest.py`, invoked as
  `python3 scripts/emit-manifest.py <out_path> <variant> <platform> <iree_version> <runtime_commit> <compiler_version> <glibc_build> <build_config_json> <vm_bytecode_version> <sanitizer> <msvc_toolset> <crt>` — the same 12 positional arguments the heredoc already takes, in the same order. Task 5 changes this signature.

- [ ] **Step 1: Run the existing manifest test to establish it passes on the baseline**

Run: `bash test/manifest.test.sh`
Expected: PASS (it takes no `<prefix>` argument path here; if it reports skipping, note that and rely on Task 5's hardware validation instead).

- [ ] **Step 2: Create `scripts/emit-manifest.py`**

Move the heredoc body verbatim, changing only the argv unpacking (a real script's `sys.argv[0]` is the script path, same as the heredoc's `-`, so the existing tuple unpack works unchanged) and adding a module docstring.

```python
#!/usr/bin/env python3
"""Emit manifest.json for a staged iree-runtime-dist prefix.

Extracted from a gen-manifest.sh heredoc so it is lintable and directly
runnable. Every value arrives as a positional argument and is never
interpolated into source: a value containing a quote or backslash (e.g. an
unusual path) could otherwise break the parse or smuggle content into the
JSON. Keeping this a real script makes that property structural rather than
comment-enforced.
"""
import json
import sys

(_, out_path, variant, platform, iree_version, runtime_commit,
 compiler_version, glibc_build, build_config_json,
 vm_bytecode_version, sanitizer, msvc_toolset, crt) = sys.argv

manifest = {
    "schema_version": 2,
    "variant": variant,
    "platform": platform,
    "iree_version": iree_version,
    "iree_tag": "v" + iree_version,
    "runtime_commit": runtime_commit,
    "iree_compile_version": compiler_version,
    "vm_bytecode_version": vm_bytecode_version,
    "build_config": json.loads(build_config_json),
    "notes": {
        "compiler": (
            "The IREE compiler is out of contract: built with "
            "IREE_BUILD_COMPILER=OFF and never shipped. Install "
            "iree-base-compiler==" + compiler_version + " to produce loadable "
            ".vmfb files."
        ),
        "pip_runtime_wheel": (
            "The pip iree-base-runtime wheel is NOT linkable at any version -- "
            "no headers, no static libs. Only a from-source build or this dist "
            "yields a linkable runtime."
        ),
        "vm_bytecode_version": (
            "IREE_VM_BYTECODE_VERSION_MAJOR.MINOR from the shipped runtime's "
            "own iree/vm/bytecode/utils/isa.h -- the value the VM bytecode "
            "verifier checks a loaded .vmfb against. A .vmfb compiled by a "
            "mismatched compiler version fails to load with a VM import "
            "signature mismatch; compare this field before loading one built "
            "elsewhere."
        ),
    },
}

if sanitizer:
    manifest["sanitizer"] = sanitizer
    manifest["notes"]["sanitizer"] = (
        "This variant is built with -fsanitize=" + sanitizer + ". The umbrella "
        "target propagates the sanitizer flag as an INTERFACE option, so linking "
        "it instruments the whole consumer program. See share/iree-runtime-dist/"
        "TSAN.md for how to run it (ASLR/mmap_rnd_bits) and any suppressions."
    )

# Provenance keys are platform-conditional: a Windows artifact has no glibc,
# and a container-built Linux artifact has no MSVC toolset/CRT. Absence of
# the inapplicable key is the honest encoding -- a "n/a" sentinel would invite
# reading it as "no glibc requirement" rather than "wrong provenance model".
if platform.startswith("linux-"):
    manifest["glibc_build"] = glibc_build
    manifest["notes"]["glibc_build"] = (
        "glibc_build is the glibc version of the container these static "
        "archives were compiled against, NOT a detected minimum/floor -- "
        "static archives carry unversioned undefined libc symbols, so the "
        "consumer's own final link is what actually resolves glibc symbol "
        "versions. Do not read this as a guarantee of compatibility with "
        "any glibc older than the value recorded here."
    )
elif platform.startswith("windows-"):
    manifest["msvc_toolset"] = msvc_toolset
    manifest["crt"] = crt
    manifest["notes"]["msvc_toolset"] = (
        "msvc_toolset is the cl.exe version these archives were compiled "
        "with, on a PINNED runner image (windows-2022). It is provenance, "
        "not a compatibility claim."
    )
    manifest["notes"]["crt"] = (
        "crt is the C runtime model these archives were compiled with (MT = "
        "static). The archives carry only /DEFAULTLIB:LIBCMT directives; the "
        "CRT itself is resolved at the consumer's final link, not embedded "
        "here. This is NOT a compatibility floor -- it is the CRT a consumer "
        "must match to avoid a mixed-CRT link."
    )

with open(out_path, "w") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
```

- [ ] **Step 3: Replace the heredoc call in `gen-manifest.sh`**

Replace the whole `python3 - "$OUT_DIR/manifest.json" ... <<'EOF' ... EOF` block (lines 122-206) with:

```bash
# Every value is passed as argv, never interpolated into Python source -- see
# the docstring in emit-manifest.py for why.
python3 "$HERE/emit-manifest.py" "$OUT_DIR/manifest.json" "$VARIANT" "$PLATFORM" \
  "$IREE_VERSION" "$RUNTIME_COMMIT" "$COMPILER_VERSION" "$GLIBC_BUILD" \
  "$BUILD_CONFIG_JSON" "$VM_BYTECODE_VERSION" "$SANITIZER" "$MSVC_TOOLSET" "$CRT"
```

`HERE` is already defined at `gen-manifest.sh:6` as the script's own directory, so `$HERE/emit-manifest.py` resolves regardless of the caller's cwd.

- [ ] **Step 4: Verify byte-identical output**

Generate a manifest before and after by checking out the previous version of the script to a temp path. The simplest reliable check, given a staged prefix from a previous build at `$WORK/out-default`:

```bash
cp "$WORK/out-default/share/iree-runtime-dist/manifest.json" "$WORK/manifest.before.json"
# re-run gen-manifest.sh with the extracted script, then:
diff "$WORK/manifest.before.json" "$WORK/out-default/share/iree-runtime-dist/manifest.json"
```

Expected: no output. A pure extraction must change nothing.

- [ ] **Step 5: Run the hermetic suite**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`.

- [ ] **Step 6: Commit**

```bash
git add scripts/emit-manifest.py scripts/gen-manifest.sh
git commit -m "refactor: extract the manifest emitter from a shell heredoc

Regime-note item 1. No behaviour change -- the JSON is byte-identical and
the argv discipline is unchanged. A real script is lintable, directly
runnable, and makes the never-interpolate-values property structural
rather than comment-enforced.

The other inline python3 in this file (the build_config parser) is not
extracted: a later task deletes it outright, because its input
(effective_cmake_flags output) ceases to exist.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Create the `cmake/` cache-init layer and its hermetic test

The files are created and tested in isolation here. Nothing invokes them yet — Task 4 does the wiring. This split exists because a reviewer can meaningfully reject the file contents while approving the wiring, and vice versa.

**Files:**
- Create: `cmake/dist-set.cmake`, `cmake/common.cmake`, `cmake/gnu-toolchain.cmake`, `cmake/linux-x86_64.cmake`, `cmake/linux-aarch64.cmake`, `cmake/windows-x86_64.cmake`, `cmake/variant-default.cmake`, `cmake/variant-tsan.cmake`
- Test: `test/cmake_init.test.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `dist_set(<key> <value> <type> <doc>)` — a CMake macro. Sets `<key>` as a cache entry of `<type>` and appends `<key>` to the `IREE_DIST_DECLARED_KEYS` internal cache list, deduplicated and with empty elements removed.
  - `IREE_DIST_DECLARED_KEYS` — a `;`-separated `INTERNAL` cache entry naming every key this recipe declares. Task 5 reads it.
  - Two environment variables the files read: `IREE_SRC` (POSIX path, used by `gnu-toolchain.cmake`) and `IREE_SRC_NATIVE` (Windows path, used by `windows-x86_64.cmake`). Task 4 exports both.

- [ ] **Step 1: Write the failing test**

Create `test/cmake_init.test.sh`:

```bash
#!/usr/bin/env bash
# Hermetic checks on the cmake -C cache-init layer. No cmake invocation, no
# build: this asserts the files EXIST for every platform/variant the recipe
# knows about, and that the MSVC platform defaults are present.
#
# Why assert on the content of a static file at all: the -EHsc restatement
# below is not a value that might be wrong, it is a line that must not be
# DELETED. Its absence clobbers Windows-MSVC.cmake's CXX default, and every
# C++ translation unit touching <ostream> then fails C4530, which IREE's -WX
# turns into an error. That is an observed failure, not a hypothetical: run
# 30281540210 died 322 objects in, on third_party/benchmark, for exactly this.
# A 40-minute Windows build is the only other thing that catches it.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/assert.sh"
. "$root/scripts/lib/naming.sh"
. "$root/scripts/lib/variants.sh"

# 1. Every platform has a cache-init file, and every variant that platform
#    builds has one too. Catches "added a platform, forgot the file" -- a
#    failure mode that did not exist before this layer.
for p in $(known_platforms); do
  [ -f "$root/cmake/$p.cmake" ] \
    && printf 'ok: cmake/%s.cmake exists\n' "$p" \
    || { printf 'FAIL: cmake/%s.cmake missing\n' "$p" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
  for v in $(known_variants "$p"); do
    [ -f "$root/cmake/variant-$v.cmake" ] \
      && printf 'ok: cmake/variant-%s.cmake exists (for %s)\n' "$v" "$p" \
      || { printf 'FAIL: cmake/variant-%s.cmake missing (needed by %s)\n' "$v" "$p" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
  done
done

[ -f "$root/cmake/common.cmake" ] \
  && printf 'ok: cmake/common.cmake exists\n' \
  || { printf 'FAIL: cmake/common.cmake missing\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
[ -f "$root/cmake/dist-set.cmake" ] \
  && printf 'ok: cmake/dist-set.cmake exists\n' \
  || { printf 'FAIL: cmake/dist-set.cmake missing\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# 2. Every -C file includes dist-set.cmake. A macro is not a cache variable
#    and does not persist between -C scripts, so a file that forgets this
#    include fails with "Unknown CMake command" at configure -- but only for
#    the platform/variant that happens to be built. Assert it for all of them.
for f in "$root"/cmake/*.cmake; do
  case "$(basename "$f")" in dist-set.cmake|gnu-toolchain.cmake) continue ;; esac
  assert_contains "$(cat "$f")" 'dist-set.cmake' "$(basename "$f") includes dist-set.cmake"
done

# 3. The Windows MSVC platform defaults. -EHsc and -GR are C++-only; -EHsc in
#    the C flags would be an unknown-option warning on cl, and IREE's -WX
#    would escalate it.
w="$(cat "$root/cmake/windows-x86_64.cmake")"
assert_contains "$w" '-EHsc' 'windows cache-init restates -EHsc'
assert_contains "$w" '-GR'   'windows cache-init restates -GR'
assert_contains "$w" '-DWIN32' 'windows cache-init restates -DWIN32'
assert_contains "$w" '_WINDOWS' 'windows cache-init restates -D_WINDOWS'

# The C-flags line must NOT carry -EHsc. Isolate the CMAKE_C_FLAGS
# declaration: the line naming CMAKE_C_FLAGS, excluding CMAKE_CXX_FLAGS.
c_line="$(grep 'CMAKE_C_FLAGS' "$root/cmake/windows-x86_64.cmake" | grep -v 'CMAKE_CXX_FLAGS' || true)"
[ -n "$c_line" ] \
  && printf 'ok: found a CMAKE_C_FLAGS declaration to check\n' \
  || { printf 'FAIL: no CMAKE_C_FLAGS declaration found in cmake/windows-x86_64.cmake\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
case "$c_line" in
  *-EHsc*) printf 'FAIL: -EHsc must not appear in the C flags (C++-only)\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) printf 'ok: -EHsc absent from the C flags\n' ;;
esac

# 4. CMAKE_BUILD_TYPE is Release, and no cache-init file says RelWithDebInfo.
#    Switching tsan to RelWithDebInfo renames the exported config
#    (IMPORTED_LOCATION_RELEASE -> _RELWITHDEBINFO) and silently breaks the
#    Release-hardcoded libbacktrace and relocatability repairs.
assert_contains "$(cat "$root/cmake/common.cmake")" 'Release' 'common.cmake sets CMAKE_BUILD_TYPE Release'
for f in "$root"/cmake/*.cmake; do
  case "$(cat "$f")" in
    *RelWithDebInfo*) printf 'FAIL: %s mentions RelWithDebInfo\n' "$(basename "$f")" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  esac
done
printf 'ok: no cache-init file mentions RelWithDebInfo\n'

[ "$ASSERT_FAILS" -eq 0 ] || exit 1
echo "cmake_init: all assertions passed"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/cmake_init.test.sh`
Expected: FAIL — several `FAIL: cmake/<platform>.cmake missing` lines, exit 1. If it errors instead on `known_variants: command not found`, the `variants.sh` source line is wrong; fix that before continuing, because a test that errors is not the same as a test that fails.

- [ ] **Step 3: Create `cmake/dist-set.cmake`**

```cmake
# The declaration primitive for this recipe's cmake -C cache-init files.
#
# Two jobs in one call, deliberately coupled: set the cache entry, and record
# that we are the ones who declared it. gen-manifest.sh reads
# IREE_DIST_DECLARED_KEYS to know which of CMakeCache.txt's hundreds of entries
# belong to us. The alternative -- grepping these files for `set(` calls -- would
# be a second parser of the same data, which is the exact defect class this
# whole change exists to remove.
#
# Filter by KEY NAME, never by entry type. A command-line -D overrides a
# cache-init value (verified: -C files load before -D entries, so -D wins even
# against FORCE) and resets the entry's TYPE to UNINITIALIZED. Filtering by
# type would therefore silently drop exactly the keys that differ from what we
# declared -- the only interesting case.
#
# Include me from every -C file. A macro is not a cache variable and does not
# persist between -C scripts, so each one needs its own include.

macro(dist_set key value type doc)
  set(${key} "${value}" CACHE ${type} "${doc}")
  # The list accumulates across separate -C files because it lives in the cache.
  # REMOVE_DUPLICATES matters because a later file re-declares CMAKE_C_FLAGS to
  # append to it; REMOVE_ITEM "" strips the leading empty element the first
  # append leaves behind.
  set(_dist_keys "${IREE_DIST_DECLARED_KEYS};${key}")
  list(REMOVE_DUPLICATES _dist_keys)
  list(REMOVE_ITEM _dist_keys "")
  set(IREE_DIST_DECLARED_KEYS "${_dist_keys}" CACHE INTERNAL
      "Cache keys declared by iree-runtime-dist's -C files; gen-manifest.sh reads this")
endmacro()
```

- [ ] **Step 4: Create `cmake/common.cmake`**

```cmake
# Platform- and variant-independent configuration. The single place the runtime
# feature set is stated.
#
# `default` and `tsan` build the SAME runtime -- same drivers, same loaders,
# tracing off. Keeping every capability entry here, where no variant file can
# reach it, makes that sameness structural: the two cannot drift, because
# there is only one file that can say what they are.
#
# Deliberately touches no CMAKE_C_FLAGS / CMAKE_CXX_FLAGS. Those are
# path-dependent (-ffile-prefix-map / d1trimfile embed $IREE_SRC) and so belong
# to the platform files.
include("${CMAKE_CURRENT_LIST_DIR}/dist-set.cmake")

# The compiler is out of contract: never built, never shipped. It appears only
# as a version string in manifest.json and as a CI-time pip wheel that compiles
# add.vmfb.
dist_set(IREE_BUILD_COMPILER             OFF BOOL "")
dist_set(IREE_BUILD_TESTS                OFF BOOL "")
dist_set(IREE_BUILD_SAMPLES              OFF BOOL "")
dist_set(IREE_BUILD_BINDINGS_TFLITE      OFF BOOL "")
dist_set(IREE_BUILD_BINDINGS_TFLITE_JAVA OFF BOOL "")
dist_set(IREE_BUILD_PYTHON_BINDINGS      OFF BOOL "")

dist_set(BUILD_SHARED_LIBS               OFF BOOL "")
# Release for BOTH variants, never RelWithDebInfo: that renames the exported
# config (IMPORTED_LOCATION_RELEASE -> _RELWITHDEBINFO) and silently breaks the
# Release-hardcoded libbacktrace and relocatability repairs. tsan gets its
# symbolized frames from -g in cmake/variant-tsan.cmake instead.
dist_set(CMAKE_BUILD_TYPE                Release STRING "")
dist_set(CMAKE_POSITION_INDEPENDENT_CODE ON  BOOL "")
dist_set(IREE_ALLOCATOR_SYSTEM           libc STRING "")
dist_set(IREE_ENABLE_THREADING           ON  BOOL "")

# Drivers and loaders. DEFAULTS=OFF then an explicit opt-in list, so a future
# IREE version adding a driver to its defaults cannot silently widen what we
# ship. The two driver names here are what a consumer passes to
# iree_runtime_instance_try_create_default_device -- exact names, not URIs.
dist_set(IREE_HAL_DRIVER_DEFAULTS                    OFF BOOL "")
dist_set(IREE_HAL_DRIVER_LOCAL_SYNC                  ON  BOOL "")
dist_set(IREE_HAL_DRIVER_LOCAL_TASK                  ON  BOOL "")
dist_set(IREE_HAL_EXECUTABLE_LOADER_DEFAULTS         OFF BOOL "")
dist_set(IREE_HAL_EXECUTABLE_LOADER_EMBEDDED_ELF     ON  BOOL "")
dist_set(IREE_HAL_EXECUTABLE_LOADER_SYSTEM_LIBRARY   ON  BOOL "")
dist_set(IREE_ENABLE_RUNTIME_TRACING                 OFF BOOL "")

# Not per-invocation, so it is declared here rather than passed as a -D:
# the packaged layout is lib/, always. CMAKE_INSTALL_PREFIX is the only value
# that genuinely varies per invocation and stays on the command line.
dist_set(CMAKE_INSTALL_LIBDIR lib STRING "")
```

- [ ] **Step 5: Create `cmake/gnu-toolchain.cmake`**

```cmake
# Shared clang/GNU-style toolchain configuration for every non-MSVC platform.
# Included by cmake/linux-x86_64.cmake and cmake/linux-aarch64.cmake; a future
# macOS platform file would include it too, which is the point of splitting it
# out from the platform files rather than duplicating it.
#
# Naming the compiler explicitly is what keeps a stray gcc on the build image
# from being picked up. The container Dockerfile pins the clang/lld NEVRAs; this
# selects them.
include("${CMAKE_CURRENT_LIST_DIR}/dist-set.cmake")

dist_set(CMAKE_C_COMPILER   clang   STRING "")
dist_set(CMAKE_CXX_COMPILER clang++ STRING "")

# -ffile-prefix-map keeps __FILE__ (which IREE embeds in status strings) and
# DWARF DW_AT_comp_dir relative, so published artifacts carry no build-machine
# paths. clang/gcc-only; cl.exe does not understand it, which is why this lives
# here and not in common.cmake.
#
# $ENV{IREE_SRC} is the container-internal source path, exported by
# build-runtime.sh. Composed here, once, where the path is actually known --
# these flags are path-dependent by construction.
#
# Setting CMAKE_C_FLAGS here DROPS the platform's CMAKE_C_FLAGS_INIT
# contribution rather than merging with it (verified: -C behaves exactly like a
# command-line -D in this respect). On Linux that initialised default is empty,
# so the clobber costs nothing. On MSVC it does not -- see
# cmake/windows-x86_64.cmake.
dist_set(CMAKE_C_FLAGS   "-ffile-prefix-map=$ENV{IREE_SRC}=iree" STRING "")
dist_set(CMAKE_CXX_FLAGS "-ffile-prefix-map=$ENV{IREE_SRC}=iree" STRING "")
```

- [ ] **Step 6: Create the two Linux platform files**

`cmake/linux-x86_64.cmake`:

```cmake
# linux-x86_64. Everything is shared with linux-aarch64; this file exists as a
# distinct file so the -C path is derived straight from the platform token, with
# no platform-to-file mapping in shell. It is also where a genuinely
# arch-specific entry would go if one ever appears.
include("${CMAKE_CURRENT_LIST_DIR}/gnu-toolchain.cmake")
```

`cmake/linux-aarch64.cmake`:

```cmake
# linux-aarch64. See cmake/linux-x86_64.cmake for why this is a separate file
# rather than a shared cmake/linux.cmake.
include("${CMAKE_CURRENT_LIST_DIR}/gnu-toolchain.cmake")
```

- [ ] **Step 7: Create `cmake/windows-x86_64.cmake`**

Every comment here records a separately-discovered silent-failure mode. They are the payload of this migration, not decoration.

```cmake
# windows-x86_64 (MSVC). No Dockerfile: the toolchain comes from a PINNED
# GitHub runner image (windows-2022, never windows-latest) plus a VS dev-shell
# activation that release.yml enters before invoking build-runtime.sh.
include("${CMAKE_CURRENT_LIST_DIR}/dist-set.cmake")

# find_program with REQUIRED rather than a `command -v cl` guard in shell: it
# fails at configure with CMake's own diagnostic, and the RESOLVED ABSOLUTE
# PATH is what lands in the cache -- so recorded provenance names the exact cl
# that was used, not whatever PATH happened to resolve. Asking for clang here
# would either not resolve, or worse, pick up the LLVM that ships alongside VS
# and silently build with a different toolchain than the msvc_toolset value
# manifest.json attests to.
find_program(IREE_DIST_CL NAMES cl REQUIRED)
dist_set(CMAKE_C_COMPILER   "${IREE_DIST_CL}" STRING "")
dist_set(CMAKE_CXX_COMPILER "${IREE_DIST_CL}" STRING "")

# Static CRT (/MT). The consumer is a JNI shim linking into a DLL; a dynamic
# CRT would push a VC++ redistributable requirement onto every downstream user.
# CMAKE_MSVC_RUNTIME_LIBRARY is the supported CMake spelling -- deliberately a
# cache variable rather than smuggled into a raw flag string, because
# gen-manifest.sh derives manifest.json's `crt` field from this exact entry.
dist_set(CMAKE_MSVC_RUNTIME_LIBRARY MultiThreaded STRING "")

# /d1trimfile: is MSVC's -ffile-prefix-map analog -- verified working on the
# pinned CI toolset (cl 19.44.35228, VS 2022): baseline __FILE__
# "C:\trimtest\sub\foo.c" became "sub\foo.c" using -d1trimfile:C:\trimtest\ --
# ONE trailing backslash, not doubled. Unlike -ffile-prefix-map it TRIMS A
# PREFIX rather than remapping to a token, so the prefix must be the source
# root WITH that trailing backslash, or the last path component gets glued onto
# the following relative path.
#
# $ENV{IREE_SRC_NATIVE} is the cygpath -w form, produced by build-runtime.sh.
# cl.exe bakes __FILE__ in as a Windows path (C:\...), but the recipe runs under
# Git-Bash, where $IREE_SRC is a POSIX mount path (/c/Users/...). /d1trimfile:
# only trims a LITERAL prefix match against what cl emits, so a POSIX-flavoured
# prefix matches NOTHING and silently leaves every absolute __FILE__ in the
# shipped archives. Do not use $ENV{IREE_SRC} here.
#
# Dash spelling (-d1trimfile, not /d1trimfile): cl accepts both. This is now
# composed inside a cache-init file rather than passed as
# -DCMAKE_C_FLAGS=/d1trimfile:..., so MSYS2's argument converter never sees it
# and MSYS2_ARG_CONV_EXCL is no longer needed. The dash spelling is kept anyway
# -- it costs nothing and removes the trap entirely rather than relying on the
# invocation shape staying as it is.
set(_trimfile "-d1trimfile:$ENV{IREE_SRC_NATIVE}\\")

# Restate the platform defaults we are about to clobber.
#
# Setting CMAKE_C_FLAGS / CMAKE_CXX_FLAGS here DROPS what Windows-MSVC.cmake
# initialised, it does not add to it. Verified: cmake_initialize_per_config_
# variable does a non-FORCE set(... CACHE ...), and a -C file has already
# created the entry, so _INIT is dropped rather than merged. `-C` does NOT fix
# this -- it behaves exactly like a command-line -D did.
#
# Windows-MSVC.cmake seeds CXX with /DWIN32 /D_WINDOWS /GR /EHsc. Losing /EHsc
# makes every C++ translation unit that touches <ostream> fail C4530 ("C++
# exception handler used, but unwind semantics are not enabled"), which IREE's
# own -WX turns into an error. That is an OBSERVED failure: run 30281540210 died
# 322 objects in, on third_party/benchmark, for exactly this reason.
#
# /W3 is deliberately NOT restated -- IREE sets its own /W4, and restating a
# weaker warning level would only fight it. -GR and -EHsc are C++-only and must
# not appear in the C flags. If CMake ever changes these defaults, these two
# lines are what to update; test/cmake_init.test.sh asserts -EHsc is present in
# CXX and absent from C precisely so a future edit dropping it fails
# hermetically instead of 322 objects into a 40-minute CI build.
dist_set(CMAKE_C_FLAGS   "-DWIN32 -D_WINDOWS ${_trimfile}"          STRING "")
dist_set(CMAKE_CXX_FLAGS "-DWIN32 -D_WINDOWS -GR -EHsc ${_trimfile}" STRING "")
```

- [ ] **Step 8: Create the two variant files**

`cmake/variant-default.cmake`:

```cmake
# The `default` variant contributes NO compiler flags. This file is empty of
# declarations on purpose and must not be deleted: build-runtime.sh passes
# -C cmake/variant-$VARIANT.cmake unconditionally, so a missing file is a
# configure error. Present-and-empty states "default adds nothing" explicitly;
# absent would state "someone forgot".
#
# It also includes dist-set.cmake for uniformity, so every -C file has the same
# shape and test/cmake_init.test.sh can assert that uniformly.
include("${CMAKE_CURRENT_LIST_DIR}/dist-set.cmake")
```

`cmake/variant-tsan.cmake`:

```cmake
# The `tsan` variant differs from `default` ONLY in compiler flags. Every
# capability entry -- drivers, loaders, tracing -- lives in cmake/common.cmake
# where this file cannot reach it, so the two variants cannot drift on what
# runtime they build.
include("${CMAKE_CURRENT_LIST_DIR}/dist-set.cmake")

# FORCE is required: cmake/<platform>.cmake already created these entries, and
# a non-FORCE set() on an existing cache entry is a no-op (verified). This is
# also why the platform file must be passed BEFORE this one on the command
# line -- ${CMAKE_C_FLAGS} below reads what it set.
#
# FORCE here does NOT defeat ad-hoc overrides: -C files load before
# command-line -D entries are applied, so a -DCMAKE_C_FLAGS=... still wins
# (verified).
#
# -g, not CMAKE_BUILD_TYPE=RelWithDebInfo. RelWithDebInfo renames the exported
# config (IMPORTED_LOCATION_RELEASE -> _RELWITHDEBINFO), silently breaking the
# Release-hardcoded libbacktrace and relocatability repairs. -g gives TSan
# symbolized frames without that rename.
#
# -g also embeds the build directory in debug info that -ffile-prefix-map does
# not reach, which is why scripts/relocatability.sh exempts DWARF-only paths for
# sanitizer variants via RELOC_ALLOW_DEBUG_PATHS. That exemption is expected for
# a sanitizer variant; do not widen it beyond debug paths.
#
# The flag is propagated to consumers as an INTERFACE option on the umbrella
# target, so linking this variant instruments the consumer's whole program --
# but the consumer's own build must use clang to match this toolchain.
dist_set(CMAKE_C_FLAGS   "${CMAKE_C_FLAGS} -fsanitize=thread -g"   STRING "" FORCE)
dist_set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fsanitize=thread -g" STRING "" FORCE)
```

**Note:** `dist_set` as written in Step 3 takes exactly four arguments and does not accept `FORCE`. Extend the macro to pass through extra arguments before writing this file — change the `set()` line in `cmake/dist-set.cmake` to:

```cmake
macro(dist_set key value type doc)
  # ${ARGN} carries an optional trailing FORCE, which cmake/variant-tsan.cmake
  # needs: it re-declares an entry the platform file already created, and a
  # non-FORCE set() on an existing cache entry is a no-op.
  set(${key} "${value}" CACHE ${type} "${doc}" ${ARGN})
```

- [ ] **Step 9: Run the test to verify it passes**

Run: `bash test/cmake_init.test.sh`
Expected: PASS, ending with `cmake_init: all assertions passed`.

- [ ] **Step 10: Verify the layer actually configures and registers keys**

The hermetic test does not invoke `cmake`. Prove the files work against a trivial project before Task 4 depends on them:

```bash
mkdir -p "$WORK/cmprobe/src" && cd "$WORK/cmprobe"
printf 'cmake_minimum_required(VERSION 3.20)\nproject(p C)\n' > src/CMakeLists.txt
IREE_SRC=/work/iree cmake \
  -C "$OLDPWD/cmake/common.cmake" \
  -C "$OLDPWD/cmake/linux-x86_64.cmake" \
  -C "$OLDPWD/cmake/variant-tsan.cmake" \
  -S src -B b >/dev/null 2>&1
grep -E '^(IREE_DIST_DECLARED_KEYS|CMAKE_C_FLAGS|CMAKE_BUILD_TYPE|CMAKE_INSTALL_LIBDIR):' b/CMakeCache.txt
```

Expected: `IREE_DIST_DECLARED_KEYS:INTERNAL=` listing **23** keys with no duplicates and no empty leading element — 19 from `common.cmake`, plus `CMAKE_C_COMPILER`, `CMAKE_CXX_COMPILER`, `CMAKE_C_FLAGS`, `CMAKE_CXX_FLAGS` from `gnu-toolchain.cmake`; `variant-tsan.cmake` re-declares two of those and must add none. Also expect `CMAKE_C_FLAGS:STRING=-ffile-prefix-map=/work/iree=iree -fsanitize=thread -g`; `CMAKE_BUILD_TYPE:STRING=Release`; `CMAKE_INSTALL_LIBDIR:STRING=lib`.

A count of 25 means `REMOVE_DUPLICATES` is not working and the two flag keys are listed twice.

If `CMAKE_C_FLAGS` is missing the `-fsanitize` half, the `FORCE` passthrough in Step 8's macro amendment did not land. If the key list has a leading `;`, the `REMOVE_ITEM ""` is missing.

- [ ] **Step 11: Run the hermetic suite**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`, now including `cmake_init.test.sh`.

- [ ] **Step 12: Commit**

```bash
git add cmake/dist-set.cmake cmake/common.cmake cmake/gnu-toolchain.cmake \
        cmake/linux-x86_64.cmake cmake/linux-aarch64.cmake \
        cmake/windows-x86_64.cmake cmake/variant-default.cmake \
        cmake/variant-tsan.cmake test/cmake_init.test.sh
git commit -m "feat: add the cmake -C cache-init layer

Declares the build configuration in files CMake reads directly, replacing
computation in shell. Nothing invokes these yet -- the next commit does the
wiring.

Three files per configure: common (platform- and variant-independent
capability set), platform, variant. dist_set() both sets a cache entry and
registers its key in IREE_DIST_DECLARED_KEYS, so provenance can later
filter CMakeCache.txt by key NAME -- necessary because a command-line -D
override resets an entry's type to UNINITIALIZED, making a type-based
filter drop exactly the keys that differ from what we declared.

The ~65 lines of comment recording Windows silent-failure modes move here
verbatim in substance. In particular the restated MSVC platform defaults
are still load-bearing: -C drops the CMAKE_<LANG>_FLAGS_INIT contribution
exactly as a command-line -D does, so a missing -EHsc still fails every
C++ TU touching <ostream> under IREE's -WX. test/cmake_init.test.sh keeps
that guard hermetically, replacing print_flags.test.sh's version of it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Wire `build-runtime.sh` to `-C` and delete the flag machinery

The behaviour-changing task. The gate is a cache fingerprint diff against Task 1's baseline.

**Files:**
- Modify: `build-runtime.sh` (usage text, arg parsing, the flag block at ~80-178, `TOOLCHAIN_ARGS` at ~306-327, the `cmake` invocation at ~330-337, the `gen-tsan-docs.sh` gate at ~587)
- Modify: `scripts/lib/variants.sh` (delete four functions)
- Delete: `scripts/lib/cmakeflags.sh`, `test/print_flags.test.sh`
- Modify: `test/lib_variants.test.sh`

**Interfaces:**
- Consumes: `cmake/*.cmake` and `IREE_DIST_DECLARED_KEYS` from Task 3; `$WORK/baseline/*.cache` and `$WORK/fingerprint.sh` from Task 1.
- Produces:
  - `build-runtime.sh` exports `IREE_SRC` and (on `windows-*`) `IREE_SRC_NATIVE` before invoking `cmake`.
  - `scripts/lib/variants.sh` exposes exactly one function: `known_variants <platform>` → prints a space-separated variant list, returns 2 on an unknown platform.

- [ ] **Step 1: Write the failing test — shrink `test/lib_variants.test.sh`**

Delete every block in `test/lib_variants.test.sh` that calls `variant_flags`, `variant_cflags`, `variant_sanitizer`, or `_runtime_capability_flags`. Keep and extend the `known_variants` coverage:

```bash
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
# provide. The release matrix is a full variant x platform cross-product, so a
# platform-independent list would schedule an unbuildable job.
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash test/lib_variants.test.sh`
Expected: FAIL with four `FAIL: <fn> still exists` lines — the functions are still in `variants.sh`.

- [ ] **Step 3: Shrink `scripts/lib/variants.sh`**

Delete `_runtime_capability_flags`, `variant_flags`, `variant_cflags`, and `variant_sanitizer`. Replace the file header comment, keep `known_variants` and its comment verbatim:

```bash
#!/usr/bin/env bash
# Which variants each platform builds. Single source of truth. Source me.
#
# This file used to own the variant -> cmake flag mapping as well. That moved to
# cmake/variant-<variant>.cmake, which CMake reads directly via -C: the flags
# are now DECLARED where they are consumed rather than computed here and passed
# along. What is left is the one genuinely platform-dependent piece of logic,
# which is not expressible as a static file.

# Which variants a platform builds. NOT platform-independent: tsan is
# -fsanitize=thread under clang, which the MSVC/Windows toolchain does not
# provide. release.yml fans out a full variant x platform cross-product, so
# without this a windows tsan job would be scheduled and fail.
known_variants() { # <platform>
  case "${1:-}" in
    linux-*)   printf 'default tsan' ;;
    windows-*) printf 'default' ;;
    *) echo "error: unknown platform '${1:-}'" >&2; return 2 ;;
  esac
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash test/lib_variants.test.sh`
Expected: PASS, ending `lib_variants: all assertions passed`.

- [ ] **Step 5: Delete the flag machinery**

```bash
git rm scripts/lib/cmakeflags.sh test/print_flags.test.sh
```

- [ ] **Step 6: Edit `build-runtime.sh` — header, usage, arg parsing**

Remove the `cmakeflags.sh` source line (line 8). Remove `PRINT_FLAGS=0` (line 16). Remove the `--print-flags) PRINT_FLAGS=1; shift ;;` case (line 51). In `usage()`, delete the second synopsis line and the `--print-flags` description line.

- [ ] **Step 7: Edit `build-runtime.sh` — replace the flag block**

Delete everything from the `# variant_cflags is the injection point...` comment (line 80) through the `--print-flags` early-exit block's `exit 0` and closing `fi` (line 185). In the platform-resolution comment above it (lines 65-69), delete the paragraph beginning "Resolved BEFORE the `--print-flags` early-exit below" — it explains a constraint that no longer exists.

Add in its place, after the `known_platforms` validation:

```bash
# The configuration itself lives in cmake/*.cmake and is read by CMake via -C.
# What shell still owns is the two PATH-DEPENDENT values those files interpolate
# through $ENV{}: the source root, in each toolchain's native spelling. Composed
# here, once, where the path is actually known.
export IREE_SRC

# cl.exe bakes __FILE__ in as a Windows path, but this recipe runs under
# Git-Bash on the Windows runner, so $IREE_SRC arrives POSIX-style
# (/c/Users/...). /d1trimfile: trims a LITERAL prefix match against what cl
# emits, so a POSIX-flavoured prefix matches nothing and silently leaves every
# absolute __FILE__ in the shipped archives. cygpath -w is mandatory, not
# best-effort: a missing cygpath is a hard error rather than a fallback to the
# raw value, because the fallback produced a silently prefix-less flag. (The
# fallback existed only for --print-flags on a non-Windows host, and
# --print-flags is gone.)
case "$PLATFORM" in
  windows-*)
    command -v cygpath >/dev/null 2>&1 \
      || { echo "error: cygpath is not on PATH -- a windows build must run under Git-Bash" >&2; exit 1; }
    IREE_SRC_NATIVE="$(cygpath -w "$IREE_SRC")"
    export IREE_SRC_NATIVE
    ;;
esac
```

**Ordering caveat:** `IREE_SRC` is validated as non-empty and a directory further down (the `[ -n "$IREE_SRC" ]` / `[ -d "$IREE_SRC" ]` checks that currently follow the `--print-flags` exit). Move this new block **below** those checks, so `cygpath -w` never runs on an empty string.

- [ ] **Step 8: Edit `build-runtime.sh` — replace `TOOLCHAIN_ARGS` and the `cmake` call**

Delete the `mapfile -t FLAGS < <(effective_cmake_flags ...)` line, the `TODO: This is dumb` comment block, and the whole `if [ "$(platform_toolchain "$PLATFORM")" = container ]` / `else` / `fi` block that sets `TOOLCHAIN_ARGS`. Compiler selection now lives in the platform cache-init files, which also resolves that TODO: the scissor was never container-vs-runner, it was which compiler.

Replace the `cmake` invocation with:

```bash
echo "==> configuring"
# Three cache-init files, composed left to right: universal, platform, variant.
# ORDER IS LOAD-BEARING -- cmake/variant-tsan.cmake appends to the CMAKE_C_FLAGS
# that the platform file sets, and can only read a value already in the cache.
#
# CMAKE_INSTALL_PREFIX is the only remaining -D: the only value that genuinely
# varies per invocation. Everything else is declared in the files above, where
# gen-manifest.sh can read back what the build actually used.
cmake -G Ninja -B "$BUILD_DIR" -S "$IREE_SRC" \
  -C "$HERE/cmake/common.cmake" \
  -C "$HERE/cmake/$PLATFORM.cmake" \
  -C "$HERE/cmake/variant-$VARIANT.cmake" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
```

- [ ] **Step 9: Edit `build-runtime.sh` — the tsan docs gate**

At line ~587, replace `if [ -n "$(variant_sanitizer "$VARIANT")" ]; then` with:

```bash
# Sanitizer variants ship a consumer runbook (build with clang, ASLR note,
# suppressions wiring). A default prefix ships none. Gated on the variant name
# directly now that variant_sanitizer is gone -- the sanitizer VALUE recorded in
# provenance is observed from the build's own CMAKE_C_FLAGS, but "does this
# variant ship TSAN.md" is a property of the variant, not of the build.
if [ "$VARIANT" = tsan ]; then
```

- [ ] **Step 10: Verify no dangling references remain**

Run:

```bash
grep -rn "effective_cmake_flags\|cmakeflags.sh\|variant_cflags\|variant_sanitizer\|variant_flags\|platform_toolchain\|print-flags\|PRINT_FLAGS\|TOOLCHAIN_ARGS\|MSYS2_ARG_CONV_EXCL" \
  build-runtime.sh scripts/ test/ .github/ || echo "CLEAN"
```

Expected: the only remaining hits are in `scripts/gen-manifest.sh` (which Task 5 fixes) and possibly `.github/workflows/release.yml`. Anything in `build-runtime.sh` is a miss — go fix it. `platform_toolchain` must have zero hits, since the baseline commit already deleted its definition.

- [ ] **Step 11: Run the hermetic suite**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`. `print_flags.test.sh` is gone; `cmake_init.test.sh` and the shrunk `lib_variants.test.sh` pass.

- [ ] **Step 12: The acceptance gate — cache fingerprint diff, linux-x86_64, both variants**

Configure both variants in the container as in Task 1 Step 3, then:

```bash
for v in default tsan; do
  bash "$WORK/fingerprint.sh" "$WORK/b-$v" > "$WORK/after/linux-x86_64-$v.cache"
  echo "== linux-x86_64-$v =="
  diff "$WORK/baseline/linux-x86_64-$v.cache" "$WORK/after/linux-x86_64-$v.cache" && echo "IDENTICAL"
done
```

Expected: `IDENTICAL` for both. The fingerprint strips entry types deliberately, so the `UNINITIALIZED` → typed change does not show; any **value** difference is a defect in the cache-init files, not an acceptable variation. Do not proceed past a non-empty diff — fix the cmake file and re-run.

- [ ] **Step 13: Full build and consumer gate, linux-x86_64, both variants**

Run the recipe end to end **inside the container** (so the relocatability assertion sees container-internal paths), then:

```bash
bash test/build_smoke.sh "$WORK/out-default"
bash test/consumer/run.sh "$WORK/out-default"
```

Expected: both pass. Repeat for `tsan`. `gen-manifest.sh` still reconstructs provenance at this point, which is fine — Task 5 changes that.

- [ ] **Step 14: Commit**

```bash
git add build-runtime.sh scripts/lib/variants.sh test/lib_variants.test.sh
git commit -m "refactor: configure via cmake -C, delete the flag-assembly block

build-runtime.sh now passes three cache-init files -- universal, platform,
variant -- and exactly one -D (CMAKE_INSTALL_PREFIX, the only genuinely
per-invocation value). Deletes scripts/lib/cmakeflags.sh, the ~90-line
platform-conditional flag block, TOOLCHAIN_ARGS, --print-flags, and the
flag mappings in variants.sh, which keeps only known_variants.

Acceptance gate: CMakeCache.txt reduced to the declared keys plus the two
compiler-flag variables is byte-identical before and after, on
linux-x86_64 for both variants. Full build, build_smoke.sh, and
test/consumer/run.sh pass for both.

--print-flags is deleted rather than reshaped. Nothing in CI consumed it
(gen-manifest.sh called effective_cmake_flags directly), and the cmake/
files are now the human-facing view of the build inputs -- a command that
reformats them would be a second view of the same data. Its one real
guard, the -EHsc restatement check, moved to test/cmake_init.test.sh.

Two Windows hazards die with the block: MSYS2_ARG_CONV_EXCL (the flag
string no longer crosses the argument converter) and the empty-IREE_SRC
branch (it existed only for --print-flags). cygpath is now a hard
requirement rather than a fallback, since the fallback's only caller was
--print-flags on a non-Windows host.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Provenance reads `CMakeCache.txt`

**Files:**
- Modify: `scripts/gen-manifest.sh` (argument list, `build_config`, `crt`, `sanitizer`, `iree_tag`, `runtime_commit`, `clang_version`, `cmake_version`, `runtime_dist_commit`, `BUILDINFO`)
- Modify: `scripts/emit-manifest.py` (new fields, new argv)
- Modify: `build-runtime.sh` (pass `$BUILD_DIR`; read `runtime_commit` back)
- Modify: `test/manifest.test.sh`
- Modify: `scripts/derive-version.sh`, `scripts/gen-addvmfb.sh`, `scripts/gen-tsan-docs.sh`, `.github/workflows/release.yml` (the internal rename)

**Interfaces:**
- Consumes: `IREE_DIST_DECLARED_KEYS` in `$BUILD_DIR/CMakeCache.txt` from Tasks 3-4.
- Produces: `gen-manifest.sh <prefix> <variant> <platform> <iree-src> <iree-version> <iree-compiler-version> <build-dir>` — `<build-dir>` appended as a seventh required argument. `emit-manifest.py` gains `cmake_version`, `clang_version`, `runtime_dist_commit`, and `iree_tag` as positional arguments, and `build_config_json` now arrives already-filtered.

- [ ] **Step 1: Write the failing test**

Append to `test/manifest.test.sh`. It takes a `<prefix>` and skips without one, so this only runs against a real built prefix — which is correct: these are assertions about observation, and there is nothing to observe without a build.

```bash
# --- observed provenance (spec: 2026-07-29-declared-configuration-and-observed-provenance) ---

# schema_version stays 2: every new field below is additive and breaks no
# consumer, the same criterion under which glibc_build/msvc_toolset/crt were
# added. The published iree_compile_version key is deliberately NOT renamed,
# despite the internal COMPILER_VERSION -> IREE_COMPILER_VERSION change.
assert_eq "$(get "$m" "['schema_version']")" "2" "schema_version still 2"
assert_eq "$(get "$m" "['iree_compile_version']")" "3.11.0" "iree_compile_version not renamed"

# iree_tag is OBSERVED from the checkout, not reconstructed as "v" + version.
assert_eq "$(get "$m" "['iree_tag']")" "v3.11.0" "iree_tag observed from git describe"

# cmake_version: the configure-time CMake, read from CMakeCache.txt's own
# CMAKE_CACHE_*_VERSION entries. CMake is deliberately unpinned (the pin is
# unavailable on the Windows runner, and a container-only half-pin would hide
# risk rather than reduce it), so recording it is the mitigation.
cmv="$(get "$m" "['cmake_version']")"
case "$cmv" in
  [0-9]*.[0-9]*.[0-9]*) printf 'ok: cmake_version looks like a version (%s)\n' "$cmv" ;;
  *) printf 'FAIL: cmake_version is not a dotted version: [%s]\n' "$cmv" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
esac

# runtime_dist_commit: which version of THIS recipe produced the tarball. Was
# recorded nowhere before. --dirty so a hand build from uncommitted changes says
# so; CI is always clean, so the marker only ever annotates local builds.
rdc="$(get "$m" "['runtime_dist_commit']")"
[ -n "$rdc" ] \
  && printf 'ok: runtime_dist_commit present (%s)\n' "$rdc" \
  || { printf 'FAIL: runtime_dist_commit missing\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# build_config is filtered to the keys the cache-init files declared -- by key
# NAME, never by entry type, because a command-line -D override resets the type
# to UNINITIALIZED. It must contain our keys and NOT contain IREE's hundreds of
# unrelated ones.
assert_eq "$(get "$m" "['build_config']['IREE_BUILD_COMPILER']")" "OFF" "build_config carries a declared key"
assert_eq "$(get "$m" "['build_config']['CMAKE_BUILD_TYPE']")" "Release" "build_config carries CMAKE_BUILD_TYPE"
bc_n="$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))['build_config']))" "$m")"
if [ "$bc_n" -lt 40 ]; then
  printf 'ok: build_config is filtered, not the whole cache (%s keys)\n' "$bc_n"
else
  printf 'FAIL: build_config has %s keys -- the declared-key filter is not being applied\n' "$bc_n" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

# Platform-conditional provenance, unchanged in shape and extended with
# clang_version. Each key is ABSENT (not null, not "n/a") on the other
# platform, so the two provenance models cannot silently merge.
plat="$(get "$m" "['platform']")"
case "$plat" in
  linux-*)
    cv="$(get "$m" "['clang_version']")"
    [ -n "$cv" ] && [ "$cv" != "None" ] \
      && printf 'ok: clang_version present on linux (%s)\n' "$cv" \
      || { printf 'FAIL: clang_version missing on a linux manifest\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
    assert_eq "$(get "$m" "['sanitizer'] if 'sanitizer' in __import__('json').load(open('$m')) else ''")" \
      "$(case "$(get "$m" "['variant']")" in tsan) echo thread ;; *) echo '' ;; esac)" \
      "sanitizer observed from the build's own flags"
    ;;
  windows-*)
    if python3 -c "import json,sys;sys.exit(0 if 'clang_version' not in json.load(open(sys.argv[1])) else 1)" "$m"; then
      printf 'ok: clang_version absent on a windows manifest\n'
    else
      printf 'FAIL: clang_version present on a windows manifest\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
    fi
    assert_eq "$(get "$m" "['crt']")" "MT" "crt observed from the cache's CMAKE_MSVC_RUNTIME_LIBRARY"
    ;;
esac
```

**Note on the `sanitizer` assertion:** the inline-Python-in-a-shell-assertion above is awkward. Prefer replacing it with the simpler form, matching how the file already handles conditional keys:

```bash
case "$(get "$m" "['variant']")" in
  tsan) assert_eq "$(get "$m" "['sanitizer']")" "thread" "sanitizer observed from the build's own flags" ;;
  *)    python3 -c "import json,sys;sys.exit(0 if 'sanitizer' not in json.load(open(sys.argv[1])) else 1)" "$m" \
          && printf 'ok: sanitizer absent on default\n' \
          || { printf 'FAIL: sanitizer present on a default manifest\n' >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); } ;;
esac
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash test/manifest.test.sh "$WORK/out-default"`
Expected: FAIL on `cmake_version`, `runtime_dist_commit`, `clang_version`, and the `build_config` key-count check — the current manifest has none of these and `build_config` comes from `effective_cmake_flags`, which no longer exists (so `gen-manifest.sh` is currently broken after Task 4; this test failing is the expected state).

- [ ] **Step 3: Add the cache reader to `scripts/emit-manifest.py`**

Add above the `manifest = {...}` literal:

```python
def read_cache(build_dir):
    """Return (declared_config, cmake_version) from a build tree's CMakeCache.txt.

    The cache is the one authority for what the build actually did. Filtering is
    by KEY NAME, taken from the IREE_DIST_DECLARED_KEYS entry the cache-init
    files register -- never by entry type. A command-line -D override wins over
    a cache-init set() and resets the entry's type to UNINITIALIZED, so a
    type-based filter would silently drop exactly the keys that differ from what
    we declared, which is the only interesting case.
    """
    entries = {}
    path = os.path.join(build_dir, "CMakeCache.txt")
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith(("#", "//")):
                continue
            name, sep, value = line.partition("=")
            if not sep or ":" not in name:
                continue
            key, _, _type = name.partition(":")
            # First occurrence wins, matching CMake's own read order.
            entries.setdefault(key, value)

    declared = entries.get("IREE_DIST_DECLARED_KEYS", "")
    keys = [k for k in declared.split(";") if k]
    if not keys:
        raise SystemExit(
            "error: %s has no IREE_DIST_DECLARED_KEYS -- was it configured with "
            "this recipe's cmake -C files?" % path
        )
    missing = [k for k in keys if k not in entries]
    if missing:
        raise SystemExit(
            "error: keys declared but absent from the cache: %s" % ", ".join(missing)
        )

    version = ".".join(
        entries.get("CMAKE_CACHE_%s_VERSION" % part, "?")
        for part in ("MAJOR", "MINOR", "PATCH")
    )
    return {k: entries[k] for k in keys}, version
```

Add `import os` to the imports.

- [ ] **Step 4: Rework `emit-manifest.py`'s argv and manifest body**

Replace the argv unpack with:

```python
(_, out_path, variant, platform, iree_version, iree_tag, runtime_commit,
 runtime_dist_commit, compiler_version, glibc_build, clang_version,
 vm_bytecode_version, msvc_toolset, build_dir) = sys.argv

build_config, cmake_version = read_cache(build_dir)

# sanitizer and crt are OBSERVED from the build's own cache rather than
# reconstructed from the variant/platform arguments that drove it. Two paths to
# one fact can disagree silently; this is the one path.
sanitizer = "thread" if "-fsanitize=thread" in build_config.get("CMAKE_C_FLAGS", "") else ""

crt = ""
if platform.startswith("windows-"):
    _rt = build_config.get("CMAKE_MSVC_RUNTIME_LIBRARY", "")
    crt = {"MultiThreaded": "MT", "MultiThreadedDLL": "MD"}.get(_rt, "")
    if not crt:
        raise SystemExit(
            "error: windows platform requires CMAKE_MSVC_RUNTIME_LIBRARY to be "
            "MultiThreaded or MultiThreadedDLL in CMakeCache.txt (got '%s')"
            % (_rt or "<absent>")
        )
```

In the manifest literal, change `"iree_tag": "v" + iree_version` to `"iree_tag": iree_tag`, `"build_config": json.loads(build_config_json)` to `"build_config": build_config`, and add after `vm_bytecode_version`:

```python
    "runtime_dist_commit": runtime_dist_commit,
    "cmake_version": cmake_version,
```

Extend the `notes` dict with:

```python
        "cmake_version": (
            "The CMake that configured this build, read from the build tree's "
            "own CMakeCache.txt. CMake is deliberately NOT pinned: a NEVRA pin "
            "is possible in the container but GitHub owns the windows-2022 "
            "runner's CMake, and pinning only one platform would hide risk "
            "rather than reduce it. This field is the mitigation -- it answers "
            "'which CMake built this artifact' for a shipped tarball, which a "
            "Dockerfile pin cannot do for the Windows half at all."
        ),
        "runtime_dist_commit": (
            "The iree-runtime-dist commit that produced this artifact -- every "
            "repair, the packaging, and the whole recipe come from that repo. A "
            "'-dirty' suffix means the build ran from an uncommitted working "
            "tree, which only ever happens for hand builds; CI is always clean."
        ),
```

Add to the `linux-` branch:

```python
    manifest["clang_version"] = clang_version
    manifest["notes"]["clang_version"] = (
        "clang_version is the clang that compiled these archives, from the "
        "compiler's own banner. Provenance, not a compatibility claim -- the "
        "same standard as msvc_toolset on windows-*."
    )
```

Change the `sanitizer` note's construction to use the observed value (it already reads `sanitizer`, so no edit is needed beyond the variable now being derived rather than passed).

- [ ] **Step 5: Rework `scripts/gen-manifest.sh`**

Remove the `. "$HERE/lib/cmakeflags.sh"` and `. "$HERE/lib/variants.sh"` source lines — neither is needed now. Add the seventh argument:

```bash
PREFIX="${1:?usage: gen-manifest.sh <prefix> <variant> <platform> <iree-src> <iree-version> <iree-compiler-version> <build-dir>}"
VARIANT="${2:?variant required}"
PLATFORM="${3:?platform required}"
IREE_SRC="${4:?iree-src required}"
IREE_VERSION="${5:?iree-version required}"
IREE_COMPILER_VERSION="${6:?iree-compiler-version required}"
# The build tree is now a required input: build_config, crt, sanitizer, and
# cmake_version are all read from its CMakeCache.txt rather than reconstructed
# from the arguments that drove the build. Consequence to accept: a manifest can
# no longer be regenerated from an installed prefix alone. That is the point of
# observing rather than reconstructing, not a regression.
BUILD_DIR="${7:?build-dir required}"
[ -f "$BUILD_DIR/CMakeCache.txt" ] \
  || { echo "error: no CMakeCache.txt in '$BUILD_DIR'" >&2; exit 1; }
```

Delete the `CRT=` block, the `BUILD_CONFIG_JSON=` block with its inline `python3 -c`, and the `SANITIZER=` line. Add beside `MSVC_TOOLSET`:

```bash
# clang provenance, mirroring the MSVC_TOOLSET pattern exactly: from the
# compiler's own banner, tolerant of failure (grep exiting non-zero under
# set -euo pipefail would abort the script), "unknown" rather than a silent
# empty string or an assumed value. Only meaningful on linux-*, where clang is
# the compiler the Dockerfile pins; on windows it is never on PATH and the
# manifest omits the key entirely.
CLANG_VERSION="$(clang --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
[ -n "$CLANG_VERSION" ] || CLANG_VERSION="unknown"
```

Add near `RUNTIME_COMMIT`:

```bash
# iree_tag is OBSERVED beside runtime_commit rather than reconstructed as
# "v" + iree_version. Same checkout, same git, one path to the fact.
IREE_TAG="$(git -C "$IREE_SRC" describe --tags --abbrev=0)" \
  || { echo "error: could not read a tag from '$IREE_SRC'" >&2; exit 1; }

# Which version of THIS recipe produced the artifact -- recorded nowhere until
# now, even though every repair and all the packaging come from here.
# --always so a shallow/tagless clone still yields a hash; --dirty so a hand
# build from an uncommitted tree says so. CI is always clean.
#
# safe.directory for our own repo, for the same reason build-runtime.sh declares
# it for $IREE_SRC: this repo is a bind mount owned by the invoking user while
# the container runs as root, so git refuses it as "dubious ownership" and the
# call fails inside the container but not on a bare host run -- exactly the
# divergence CI trips over.
_dist_repo="$(cd "$HERE/.." && pwd)"
RUNTIME_DIST_COMMIT="$(
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="$_dist_repo" \
  git -C "$_dist_repo" describe --always --dirty
)" || { echo "error: could not describe the iree-runtime-dist repo at '$_dist_repo'" >&2; exit 1; }
```

Update the `emit-manifest.py` call to the new signature:

```bash
python3 "$HERE/emit-manifest.py" "$OUT_DIR/manifest.json" "$VARIANT" "$PLATFORM" \
  "$IREE_VERSION" "$IREE_TAG" "$RUNTIME_COMMIT" "$RUNTIME_DIST_COMMIT" \
  "$IREE_COMPILER_VERSION" "$GLIBC_BUILD" "$CLANG_VERSION" \
  "$VM_BYTECODE_VERSION" "$MSVC_TOOLSET" "$BUILD_DIR"
```

- [ ] **Step 6: Rework the `BUILDINFO` heredoc**

`cmake_flags=` came from `effective_cmake_flags`. Read it back from the manifest that was just written, so BUILDINFO and manifest.json cannot disagree:

```bash
# cmake_flags is read back out of the manifest just written, rather than
# recomputed: one authority, and the two files cannot disagree.
_cmake_flags="$(python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))["build_config"]
print(" ".join("-D%s=%s" % (k, v) for k, v in sorted(cfg.items())))
' "$OUT_DIR/manifest.json")"

cat > "$PREFIX/BUILDINFO" <<EOF
iree-runtime-dist
variant=$VARIANT
platform=$PLATFORM
iree_version=$IREE_VERSION
iree_tag=$IREE_TAG
runtime_commit=$RUNTIME_COMMIT
runtime_dist_commit=$RUNTIME_DIST_COMMIT
iree_compile_version=$IREE_COMPILER_VERSION
vm_bytecode_version=$VM_BYTECODE_VERSION
cmake_version=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["cmake_version"])' "$OUT_DIR/manifest.json")
cmake_flags=$_cmake_flags
EOF

case "$PLATFORM" in
  linux-*)   { echo "glibc_build=$GLIBC_BUILD"; echo "clang_version=$CLANG_VERSION"; } >> "$PREFIX/BUILDINFO" ;;
  windows-*) { echo "msvc_toolset=$MSVC_TOOLSET"
               python3 -c 'import json,sys;print("crt="+json.load(open(sys.argv[1]))["crt"])' "$OUT_DIR/manifest.json"
             } >> "$PREFIX/BUILDINFO" ;;
esac

_san="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("sanitizer",""))' "$OUT_DIR/manifest.json")"
if [ -n "$_san" ]; then echo "sanitizer=$_san" >> "$PREFIX/BUILDINFO"; fi
```

- [ ] **Step 7: Update `build-runtime.sh`'s call and the duplicate `runtime_commit`**

Pass the build dir:

```bash
echo "==> generating manifest"
bash "$HERE/scripts/gen-manifest.sh" "$PREFIX" "$VARIANT" "$PLATFORM" \
  "$IREE_SRC" "$IREE_VERSION" "$IREE_COMPILER_VERSION" "$BUILD_DIR"
```

At line ~594, replace `RUNTIME_COMMIT="$(git -C "$IREE_SRC" rev-parse HEAD)"` with a read-back:

```bash
# Read back from the manifest generated 20-odd lines above rather than running
# git rev-parse a second time. Same duplication class as the iree_tag
# reconstruction: two paths to one fact can disagree silently. This makes the
# template substitution and the manifest provably agree.
RUNTIME_COMMIT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["runtime_commit"])' \
  "$PREFIX/share/iree-runtime-dist/manifest.json")"
```

- [ ] **Step 8: The internal `COMPILER_VERSION` → `IREE_COMPILER_VERSION` rename**

Mechanical, across `scripts/derive-version.sh`, `.github/workflows/release.yml`, `scripts/gen-addvmfb.sh`, `scripts/gen-tsan-docs.sh`, and `build-runtime.sh`. **Do not** touch the published `iree_compile_version` JSON/BUILDINFO key or the `@COMPILER_VERSION@` template placeholder name unless you rename it in the `.in` files too.

Also delete the misleading TODO in `release.yml` that proposes `compiler_version=$(clang --version)`. Acting on it would replace an ABI-pairing version (the `iree-base-compiler` wheel version, used to compile `add.vmfb`) with a toolchain version under the same key. The instinct behind it is now satisfied properly by `clang_version`.

Verify: `grep -rn "COMPILER_VERSION" --include=*.sh --include=*.yml . | grep -v IREE_COMPILER_VERSION | grep -v '@COMPILER_VERSION@'` should print nothing.

- [ ] **Step 9: Run the hermetic suite**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`. Note `manifest.test.sh` skips its new assertions without a prefix.

- [ ] **Step 10: Full build and the manifest gate, linux-x86_64, both variants**

Inside the container, end to end. Then:

```bash
bash test/manifest.test.sh "$WORK/out-default"
bash test/manifest.test.sh "$WORK/out-tsan"
bash test/build_smoke.sh "$WORK/out-default"
bash test/consumer/run.sh "$WORK/out-default"
```

Expected: all pass. Inspect `manifest.json` by eye once: `iree_tag` is `v3.11.0`, `cmake_version` is the container's CMake, `runtime_dist_commit` carries `-dirty` (uncommitted work in progress) or a clean describe, `build_config` has **23** keys and none of IREE's unrelated ones, `clang_version` present, `sanitizer` present only on tsan.

- [ ] **Step 10b: Check whether CI regenerates a manifest without a build tree**

`gen-manifest.sh` now requires `<build-dir>`, so any CI step that regenerates a manifest from a downloaded prefix alone is now broken. Check:

```bash
grep -rn "gen-manifest" .github/ || echo "no CI callers"
```

If a caller exists that has no build tree in scope, that is a real blocker: report it rather than working around it by making `<build-dir>` optional, which would restore the reconstruct-vs-observe fork this whole task removes. The expected finding is that `build-runtime.sh` is the only caller.

- [ ] **Step 11: Commit**

```bash
git add scripts/gen-manifest.sh scripts/emit-manifest.py build-runtime.sh \
        test/manifest.test.sh scripts/derive-version.sh scripts/gen-addvmfb.sh \
        scripts/gen-tsan-docs.sh .github/workflows/release.yml
git commit -m "feat: observe provenance from CMakeCache.txt instead of reconstructing it

build_config, crt, sanitizer, and cmake_version now come from the build
tree's own cache, filtered by the IREE_DIST_DECLARED_KEYS registry the
cache-init files populate. iree_tag is observed via git describe rather
than reconstructed as \"v\" + iree_version, and runtime_commit is computed
once (build-runtime.sh reads it back from the manifest instead of running
rev-parse a second time).

Filtering is by declared key NAME, not entry type: a command-line -D
override wins over a cache-init set() and resets the type to
UNINITIALIZED, so a type-based filter would drop exactly the keys that
differ from what we declared.

New additive fields, so schema_version stays 2: cmake_version (the
mitigation for CMake being deliberately unpinned -- the pin is
unavailable on the windows-2022 runner, and a container-only half-pin
would hide risk rather than reduce it), runtime_dist_commit (which
version of THIS recipe built the tarball -- recorded nowhere until now),
and clang_version for linux-* (the Linux compiler was attested only
indirectly, via Dockerfile NEVRAs).

gen-manifest.sh gains a required <build-dir>. A manifest can no longer be
regenerated from an installed prefix alone; that is the point of
observing rather than reconstructing.

Also renames COMPILER_VERSION -> IREE_COMPILER_VERSION internally and
deletes the release.yml TODO that proposed filling it from
\`clang --version\`. The published iree_compile_version key is unchanged:
it is the iree-base-compiler wheel version that pairs add.vmfb, not a C
toolchain version, and it is schema surface.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Documentation

Lands in the same PR as the code, per the Windows post-mortem's check 5: the text must record what each rule protects, not merely that a file exists.

**Files:**
- Modify: `CLAUDE.md`
- Modify: `spike/windows-iree-runbook.md:89`, `spike/macos-iree-runbook.md:135`
- Modify: `docs/superpowers/notes/2026-07-29-package-port-regime.md`

- [ ] **Step 1: `CLAUDE.md` — key commands**

Delete the `./build-runtime.sh --print-flags --variant default` line. Do not replace it with a `cat` command — the point is that the files are read directly.

- [ ] **Step 2: `CLAUDE.md` — architecture**

Rewrite the `scripts/lib/*.sh` paragraph's second half. The sentence "`effective_cmake_flags` in particular feeds the build, `--print-flags`, and `BUILDINFO`/`manifest.json` provenance" and the "static-CRT choice must be greppable in its output" clause both describe machinery that no longer exists. Replace with:

```markdown
Configuration is **declared**, not computed. `cmake/common.cmake` +
`cmake/<platform>.cmake` + `cmake/variant-<variant>.cmake` are passed to `cmake -C` in that
order — order is load-bearing, since the variant file appends to the `CMAKE_C_FLAGS` the platform
file sets. `CMAKE_INSTALL_PREFIX` is the only remaining `-D`: the only genuinely per-invocation
value. There is no `--print-flags`; the `cmake/` files are the human-facing view of the build
inputs, and `manifest.json` is the attestation of what was actually used.

`cmake/` holds **build inputs**; `lib/cmake/IreeRuntimeDist/` holds **shipped artifacts** a
consumer's `find_package` reads. Nothing under `cmake/` is ever installed; nothing under
`lib/cmake/` is ever a configure-time input. One glance at the path answers which side of the
boundary a file is on. `patches/`, when it exists, is the same category as `cmake/`.

Four CMake behaviours the cache-init layer depends on, each verified rather than assumed:

- Multiple `-C` files compose in order, and a later file can read and extend an earlier one's
  cache values.
- Appending across `-C` files requires `FORCE`, since the earlier file already created the entry.
- A command-line `-D` wins even against a `FORCE`d cache-init `set()` — `-C` files load first —
  **but the override resets the entry's type to `UNINITIALIZED`.** This is why provenance filters
  `CMakeCache.txt` by declared key *name* (the `IREE_DIST_DECLARED_KEYS` registry that `dist_set`
  populates) and never by type: a type filter would drop exactly the keys that differ from what
  we declared.
- **`-C` does not fix the `CMAKE_<LANG>_FLAGS_INIT` clobber.** A cache-init file setting
  `CMAKE_C_FLAGS` drops the platform `_INIT` contribution exactly as a command-line `-D` does. On
  Linux that default is empty and the clobber is free; on MSVC it is not, which is why
  `cmake/windows-x86_64.cmake` restates `-DWIN32 -D_WINDOWS -GR -EHsc`. Deleting that restatement
  costs `/EHsc`, and every C++ TU touching `<ostream>` then fails C4530 under IREE's `-WX` — an
  observed failure, 322 objects into a 40-minute build. `test/cmake_init.test.sh` guards it
  hermetically.

Compiler selection lives in the platform files (`clang`/`clang++` via `cmake/gnu-toolchain.cmake`;
`find_program(... cl REQUIRED)` on Windows, so the resolved absolute path is what lands in the
cache as provenance). The scissor is which compiler, not container-vs-runner — a future macOS
platform would use clang without being containerised.
```

- [ ] **Step 3: `CLAUDE.md` — variant matrix**

`variants.sh` now owns only `known_variants`. Rewrite the paragraph that describes `variant_cflags` and `variant_sanitizer`:

```markdown
Variants are single-sourced in two places, split by kind. `scripts/lib/variants.sh` owns
`known_variants <platform>` — the one genuinely platform-dependent piece of logic, not expressible
as a static file: `linux-*` builds `default tsan`, but `windows-*` builds `default` only, because
TSan is `-fsanitize=thread` under clang and the MSVC toolchain does not provide it. The release
matrix is a full variant × platform cross-product, so a platform-independent list would schedule
an unbuildable job.

The flags themselves are declared in `cmake/variant-<variant>.cmake`. `default` and `tsan` differ
**only** there: `variant-default.cmake` declares no compiler flags (present-and-empty on purpose —
`build-runtime.sh` passes the file unconditionally, so absent would be a configure error), and
`variant-tsan.cmake` appends `-fsanitize=thread -g`. Every capability entry lives in
`cmake/common.cmake`, which no variant file can reach, so the two cannot drift on what runtime they
build. A new variant (e.g. a future `tracy`) is a new `cmake/variant-*.cmake` plus a
`known_variants` case — never a workflow edit.
```

- [ ] **Step 4: `CLAUDE.md` — manifest.json**

Keep the `glibc_build`, `msvc_toolset`, and `crt` honesty paragraphs, amending `crt`'s derivation. Add:

```markdown
`schema_version` stays `2`. `cmake_version`, `clang_version`, and `runtime_dist_commit` are
additive and break no consumer — the same criterion under which the platform-conditional
provenance keys were added.

**The published `iree_compile_version` key is deliberately NOT renamed**, despite the internal
`COMPILER_VERSION` → `IREE_COMPILER_VERSION` rename. It is the `iree-base-compiler` wheel version
that pairs `add.vmfb`, not a C toolchain version; the name is already unambiguous, and it is schema
surface. Do not "finish" the rename into it.

Provenance is **observed, never reconstructed**. `build_config` is `CMakeCache.txt` filtered to the
`IREE_DIST_DECLARED_KEYS` registry; `crt` comes from that cache's `CMAKE_MSVC_RUNTIME_LIBRARY`;
`sanitizer` from the presence of `-fsanitize=thread` in its `CMAKE_C_FLAGS`; `iree_tag` from
`git describe` rather than `"v" + iree_version`. Consequently `gen-manifest.sh` takes a
`<build-dir>` and a manifest cannot be regenerated from an installed prefix alone — that is the
point, not a regression.

`cmake_version` records the configure-time CMake. CMake is deliberately **not pinned**: a NEVRA pin
is possible in the Dockerfile but GitHub owns the `windows-2022` runner's CMake, and pinning only
the container would buy a strong guarantee on the already-stable platform while leaving the
uncontrollable one silently floating — a half-pin hides risk rather than reducing it. Recording the
version is the mitigation, and it is strictly more useful than a pin: it answers "which CMake built
this artifact" for a *shipped tarball*, which a Dockerfile pin cannot do for the Windows half at
all.

`runtime_dist_commit` records which version of *this recipe* produced the artifact — every repair,
the packaging, and the whole build recipe come from here, and until now a shipped tarball could not
say. `git describe --always --dirty`: the `-dirty` marker only ever annotates hand builds, since CI
is always clean, and that is exactly where it matters.

`clang_version` is the Linux analog of `msvc_toolset`, from the compiler's own banner. Provenance,
not a compatibility claim.
```

- [ ] **Step 5: `CLAUDE.md` — testing**

Add to the testing section:

```markdown
`test/cmake_init.test.sh` is hermetic and asserts two things about the `cmake/` layer: that a
cache-init file exists for every `known_platforms` entry and every variant each platform builds
(so "added a platform, forgot the file" fails in a second rather than at configure time on one
platform), and that `cmake/windows-x86_64.cmake` restates `-GR -EHsc` in the C++ flags and not in
the C flags. The second is a deletion guard, not a value check — the only other thing that catches
a dropped `-EHsc` is a 40-minute Windows build failing 322 objects in.
```

- [ ] **Step 6: The two runbooks**

`spike/windows-iree-runbook.md:89` and `spike/macos-iree-runbook.md:135` both tell the reader to regenerate flags with `./build-runtime.sh --print-flags`. Replace each with a pointer to the actual files, e.g.:

```markdown
(The effective configuration is declared in `cmake/common.cmake`,
`cmake/<platform>.cmake`, and `cmake/variant-<variant>.cmake` — read those three files. What a
given build actually used is in that tarball's `manifest.json` under `build_config`.)
```

- [ ] **Step 7: Status line on the regime note**

At the top of `docs/superpowers/notes/2026-07-29-package-port-regime.md`, add:

```markdown
**Implementation status (2026-07-29):** items 1-3 of [Sequencing](#sequencing) are implemented —
see [the spec](../specs/2026-07-29-declared-configuration-and-observed-provenance-design.md).
Items 4 (freeze the header list), 5 (upstream the four install gaps), and 6 (CI job split) are
not, and idiom 2's `patches/` directory — decided here but never sequenced — is not either.

**Two corrections to this note, found while implementing it:**

1. The "bonus for provenance" claim under idiom 1 — that typed cache entries are mechanically
   distinguishable from ad-hoc `-D` ones — is **false for any key that was overridden**. A
   command-line `-D` resets the entry's type to `UNINITIALIZED`. Provenance filters by declared
   key name instead.
2. `-C` does **not** avoid the `CMAKE_<LANG>_FLAGS_INIT` trap this note documents for toolchain
   files. It avoids the *silent* part — we compose the string ourselves — but the platform `_INIT`
   contribution is still dropped rather than merged, so the restated MSVC platform defaults remain
   load-bearing.
```

- [ ] **Step 8: Verify no stale references remain**

Run:

```bash
grep -rn "print-flags\|effective_cmake_flags\|variant_cflags\|variant_sanitizer\|cmakeflags" \
  CLAUDE.md spike/ docs/superpowers/specs/ || echo "CLEAN"
```

Expected: only historical mentions inside notes (which are dated records and stay) and the spec's own description of what was deleted. `CLAUDE.md` and `spike/` must be clean.

- [ ] **Step 9: Commit**

```bash
git add CLAUDE.md spike/windows-iree-runbook.md spike/macos-iree-runbook.md \
        docs/superpowers/notes/2026-07-29-package-port-regime.md
git commit -m "docs: record the declared-configuration regime in CLAUDE.md

Documents what the new rules protect, not just that cmake/ exists: the
build-inputs vs shipped-artifacts path boundary, the four verified CMake
behaviours the cache-init layer depends on (including the two that
correct the regime note), why schema_version stays 2, why
iree_compile_version is deliberately not renamed, and why CMake is
unpinned with cmake_version as the mitigation.

Also drops --print-flags from the key commands and from both platform
runbooks, and adds an implementation-status header to the regime note
naming which of its items are still open.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Hardware validation across all five combinations

The final gate. Tasks 4 and 5 validated `linux-x86_64` only; this covers the rest. Per the standing rule, every affected variant/platform is built on hardware before the branch is considered done — a combination that was only reasoned about does not ship.

**Files:** none modified unless a defect is found.

**Interfaces:**
- Consumes: `$WORK/baseline/*.cache` from Task 1, `$WORK/fingerprint.sh` from Task 1.

- [ ] **Step 1: `linux-aarch64` × `default` on the Radxa — cache fingerprint**

Build inside `iree-runtime-dist-build:linux-aarch64` end to end, then:

```bash
bash "$WORK/fingerprint.sh" "$WORK/b-default" > "$WORK/after/linux-aarch64-default.cache"
diff "$WORK/baseline/linux-aarch64-default.cache" "$WORK/after/linux-aarch64-default.cache" && echo IDENTICAL
```

Expected: `IDENTICAL`.

- [ ] **Step 2: `linux-aarch64` × `default` — artifact gates**

Run: `bash test/build_smoke.sh <prefix> && bash test/consumer/run.sh <prefix> && bash test/manifest.test.sh <prefix>`
Expected: all pass. `manifest.json` must show `platform: linux-aarch64` and a `clang_version`.

- [ ] **Step 3: `linux-aarch64` × `tsan` — cache fingerprint and artifact gates**

Same two steps with `--variant tsan`. Additionally confirm the relocatability assertion passed during the build (it runs inside `build-runtime.sh`) — `-g` embeds build paths in DWARF that `-ffile-prefix-map` does not reach, and `RELOC_ALLOW_DEBUG_PATHS` is what exempts them for sanitizer variants. If the assertion fires on a **non**-debug path, extend the repair; never widen the exemption.

Expected: `IDENTICAL` fingerprint; `manifest.json` shows `sanitizer: thread`; `share/iree-runtime-dist/TSAN.md` present.

- [ ] **Step 4: `windows-x86_64` × `default` on winbox — cache fingerprint only**

Over SSH, in an activated VS dev shell, using Git-Bash (not `System32\bash.exe`, which is WSL). Configure, then fingerprint and diff against the baseline.

Expected: `IDENTICAL`. In particular `CMAKE_CXX_FLAGS` must still contain `-GR -EHsc` and `CMAKE_C_FLAGS` must not, and both must contain a `-d1trimfile:` with a **Windows** path and one trailing backslash.

- [ ] **Step 5: Confirm the Windows build parity is unproven, and say so**

The verify stage is broken on the baseline and this plan does not fix it. Do not report Windows as validated beyond configure. Record in the task report: configure parity proven by fingerprint diff; build, `build_smoke.sh`, `consumer/`, and `manifest.test.sh` **not run** on Windows, because they cannot be until the verify break is fixed separately.

If the Windows *build* happens to get further than the baseline did, that is a bonus observation, not a gate — note it and move on.

- [ ] **Step 6: Full hermetic suite one final time**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`.

- [ ] **Step 7: Record results**

Write a short validation table into the task report: the five combinations, what gate each passed, and the one explicit exception. If any row failed, do not paper over it — the branch is not done, and the failing row's diff is the next thing to fix.

- [ ] **Step 8: Commit only if a defect was fixed**

If validation was clean, there is nothing to commit. If a cache-init file needed a fix, commit it with a message naming the combination that caught it — that is the useful part of the record.

---

## Notes for whoever executes this

**The cache fingerprint gate is the spine of this plan.** It is what makes a large mechanical refactor safe: the claim "the build is configured identically" is checked mechanically rather than reasoned about, on every platform, including the one whose build is broken. If you find yourself tempted to skip it because the change "obviously" preserves behaviour, that is precisely the situation it exists for — the `_INIT` clobber discovery came from exactly that kind of "obviously".

**The comments in the `cmake/` files are the deliverable, not decoration.** Each one records a separately-discovered silent failure. A reviewer who trims them for brevity is deleting the reason the code looks the way it does. The spec says this explicitly and so does the commit message for Task 3.

**Line count is not the metric.** ~90 lines leave `build-runtime.sh` and roughly the same number arrive in `cmake/`. What improves is that configuration is declared where it is consumed, and that provenance has one path to each fact instead of two.
