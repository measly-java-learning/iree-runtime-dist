# Windows Platform Add Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish `windows-x86_64` runtime tarballs alongside the two Linux platforms, with the same attested manifest, notices, and consumer acceptance gate.

**Architecture:** The platform token stops implying a Dockerfile. A new `platform_toolchain()` classifier splits platforms into `container` (Linux, toolchain from `docker/<platform>.Dockerfile`) and `runner` (Windows, toolchain from a pinned `windows-2022` image plus a VS dev-shell activation). Provenance, variants, and notices all become platform-aware through their existing single-source shell libs rather than through new branches in YAML.

**Tech Stack:** Bash (`set -euo pipefail`), CMake + Ninja, MSVC (`cl` 19.44 on CI), GitHub Actions, Python 3 for JSON emission, `llvm-nm`/`llvm-objcopy` for COFF.

**Spec:** `docs/superpowers/specs/2026-07-26-windows-platform-add-design.md`
**Evidence:** `spike/windows-iree-runbook.md` (W1–W6), issue #11.

## Global Constraints

- `-DIREE_BUILD_COMPILER=OFF` always. Never build or ship `iree-compile`.
- IREE stable `v3.11.0` only, never `main`. Never point `--iree-src` at `/home/corey/workspace/iree`.
- Never `submodules: recursive`. Use the 11 paths in `scripts/lib/submodules.sh`.
- `set -euo pipefail` in every script. Guard `grep` with `|| true` (exits 1 on no-match).
- Windows is the **`default` variant only**. TSan is clang/Linux-only.
- Windows CRT is **`/MT`** (static). No `/MD` row in this plan.
- Packaging stays **`.tar.gz` on every platform**. Do not introduce `.zip`.
- Runner label is **`windows-2022`**, never `windows-latest`.
- `manifest.json` `schema_version` stays **`2`**. Provenance keys are additive and conditional.
- Never widen `RELOC_ALLOW_DEBUG_PATHS`. It stays gated to sanitizer variants.
- Upstream CMake files ship unmodified except the two sanctioned repairs (`relocatability_repair`, `config_repair_external_deps`).
- Two lists, two jobs: `IREE_REQUIRED_SUBMODULES` is a checkout gate; `IREE_LINKED_COMPONENTS` is the notices input. Never conflate.
- CI toolchain is cl **19.44.35228.0** (VS 2022 Enterprise, toolset 14.44.35207). The spike measured cl 19.51 on `winbox`; anything measured there is re-verified on CI.
- Run `bash test/run.sh` before every commit. It must print `ALL UNIT TESTS PASS`.

---

## File Structure

**Modified — single-source shell libs (the load-bearing changes):**
- `scripts/lib/naming.sh` — adds `platform_toolchain()`; gates `build_image_tag`/`build_dockerfile`; adds `windows-x86_64` to `PLATFORMS`.
- `scripts/lib/variants.sh` — `known_variants`/`variants_json` take a platform.
- `scripts/lib/linked-components.sh` — `linked_components()` takes a platform.

**Modified — recipe:**
- `build-runtime.sh` — skip the libbacktrace repair on Windows; pass `/d1trimfile:`; pass `/MT`.
- `scripts/gen-manifest.sh` — conditional provenance keys and notes.
- `scripts/gen-notices.sh` — thread the platform through.
- `scripts/relocatability.sh` — COFF-aware assertion.

**Modified — tests:**
- `test/lib_naming.test.sh`, `test/lib_variants.test.sh`, `test/manifest.test.sh`, `test/notices.test.sh`, `test/relocatability.test.sh`, `test/build_smoke.sh`, `test/consumer/CMakeLists.txt`, `test/consumer/run.sh`.

**Modified — CI and docs:**
- `.github/workflows/release.yml` — per-platform toolchain path, `runs-on` from the token.
- `CLAUDE.md` — three passages, each edited in the task that introduces its mechanism.

**Not created:** no `docker/windows-x86_64.Dockerfile`. That absence is the point of Task 1.

---

## Task ordering rationale

Task 1 first because every later task depends on the classifier. Task 2 (`install-headers.sh`) second because it is the plan's one genuine unknown with real rework risk — surfacing it before CI wiring is built on top of it. Task 3 (`/d1trimfile:`) third because the relocatability fallback decision gates how Tasks 8–9 are written. Everything after is mechanical.

---

### Task 1: Split platforms into `container` and `runner` toolchains

**Files:**
- Modify: `scripts/lib/naming.sh:17` (`PLATFORMS`), `:22-29` (`build_image_tag`/`build_dockerfile`)
- Modify: `CLAUDE.md:79-91`
- Test: `test/lib_naming.test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `platform_toolchain <platform>` → prints `container` or `runner`, returns 2 on unknown platform. `build_image_tag <platform>` / `build_dockerfile <platform>` → unchanged output for container platforms; print an error to stderr and return 2 for runner platforms. `PLATFORMS` now includes `windows-x86_64`.

Note the existing loop at `test/lib_naming.test.sh:22-26` asserts every platform in `known_platforms()` has a Dockerfile on disk. Adding `windows-x86_64` breaks it. That break is the guard doing its job — the fix is to make the loop toolchain-aware, not to add an empty Dockerfile.

- [ ] **Step 1: Write the failing test**

Append to `test/lib_naming.test.sh`, before the final `exit`:

```bash
# Platforms differ in HOW they get a toolchain. Container platforms build from a
# Dockerfile; runner platforms take it from a pinned CI image plus a VS dev shell.
assert_eq "$(platform_toolchain linux-x86_64)"   "container" "linux-x86_64 is containerised"
assert_eq "$(platform_toolchain linux-aarch64)"  "container" "linux-aarch64 is containerised"
assert_eq "$(platform_toolchain windows-x86_64)" "runner"    "windows-x86_64 is runner-native"

# An unknown platform must be an error, not a silent default.
platform_toolchain bogus-platform >/dev/null 2>&1
assert_eq "$?" "2" "platform_toolchain rejects an unknown platform"

# Asking a runner platform for a build image is a programming error and must fail
# loudly -- a silent empty string would produce `docker build -f ''` at CI time.
build_dockerfile windows-x86_64 >/dev/null 2>&1
assert_eq "$?" "2" "build_dockerfile refuses a runner platform"
build_image_tag windows-x86_64 >/dev/null 2>&1
assert_eq "$?" "2" "build_image_tag refuses a runner platform"

assert_eq "$(asset_stem 3.11.0 default windows-x86_64)"   "iree-runtime-3.11.0-default-windows-x86_64"        "asset_stem windows"
assert_eq "$(tarball_name 3.11.0 default windows-x86_64)" "iree-runtime-3.11.0-default-windows-x86_64.tar.gz" "tarball_name windows stays .tar.gz"
```

Replace the existing Dockerfile-existence loop (`test/lib_naming.test.sh:22-26`) with:

```bash
# The Dockerfile every CONTAINER platform names must exist on disk -- otherwise a
# future platform added to PLATFORMS would fail only at CI image-build time.
# Runner platforms deliberately have no Dockerfile; assert that too, so a stray
# docker/windows-x86_64.Dockerfile can't appear unnoticed.
for p in $(known_platforms); do
  case "$(platform_toolchain "$p")" in
    container)
      df="$(cd "$here/.." && pwd)/$(build_dockerfile "$p")"
      assert_eq "$([ -f "$df" ] && echo yes || echo NO)" "yes" "dockerfile exists for $p"
      ;;
    runner)
      df="$(cd "$here/.." && pwd)/docker/$p.Dockerfile"
      assert_eq "$([ -f "$df" ] && echo NO || echo yes)" "yes" "no dockerfile for runner platform $p"
      ;;
  esac
done
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/lib_naming.test.sh`
Expected: FAIL — `platform_toolchain: command not found`, and the `asset_stem windows` assertions fail because `windows-x86_64` is not yet in `PLATFORMS`.

- [ ] **Step 3: Write minimal implementation**

In `scripts/lib/naming.sh`, change `PLATFORMS` and add the classifier. Replace lines 17-29:

```bash
PLATFORMS="linux-x86_64 linux-aarch64 windows-x86_64"
known_platforms() { printf '%s\n' $PLATFORMS; }

# How a platform gets its toolchain. NOT every platform is containerised.
#
#   container - Linux. The toolchain comes from docker/<platform>.Dockerfile,
#               which pins a known-old glibc and the clang/lld/ninja NEVRAs and
#               is the single source of truth for the glibc_build value
#               manifest.json attests to.
#   runner    - Windows. There is no Dockerfile. The toolchain comes from a
#               PINNED GitHub runner image (windows-2022, never windows-latest)
#               plus a VS dev-shell activation. A Windows container would fix
#               none of the Windows-specific problems, and pinning the label is
#               the analog of pinning NEVRAs: msvc_toolset is attested
#               provenance and must not drift silently.
platform_toolchain() { # <platform>
  case "${1:-}" in
    linux-*)   printf 'container' ;;
    windows-*) printf 'runner' ;;
    *) echo "error: unknown platform '${1:-}'" >&2; return 2 ;;
  esac
}

BUILD_IMAGE_REPO="iree-runtime-dist-build"
# Build-image identity, keyed off the platform token above -- one token, so tag,
# Dockerfile, and artifact platform cannot drift. Defined ONLY for container
# platforms: asking a runner platform for a build image is a programming error,
# and returning an empty string would silently produce `docker build -f ''`.
_require_container_platform() { # <platform> <caller>
  if [ "$(platform_toolchain "$1")" != container ]; then
    echo "error: $2 called for non-container platform '$1'" >&2; return 2
  fi
}
build_image_tag()  { # <platform>
  _require_container_platform "$1" build_image_tag || return 2
  printf '%s:%s' "$BUILD_IMAGE_REPO" "$1"
}
build_dockerfile() { # <platform>, repo-relative
  _require_container_platform "$1" build_dockerfile || return 2
  printf 'docker/%s.Dockerfile' "$1"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/lib_naming.test.sh`
Expected: PASS, all assertions `ok:`.

- [ ] **Step 5: Run the full suite**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`. If `test/workflow_paths.test.sh` fails, it is resolving `build_dockerfile` for every platform — make its loop container-only the same way.

- [ ] **Step 6: Update CLAUDE.md**

In `CLAUDE.md:79-91`, replace the clause "adding an arch is a new `docker/<platform>.Dockerfile` plus a `PLATFORMS` entry, nothing else." with:

```markdown
Not every platform is containerised. `platform_toolchain()` in `naming.sh` classifies each
platform as `container` or `runner`. Container platforms (all Linux) take their toolchain from
`docker/<platform>.Dockerfile`, and adding one is that Dockerfile plus a `PLATFORMS` entry,
nothing else. Runner platforms (Windows) have no Dockerfile — the toolchain comes from a pinned
GitHub runner image plus a VS dev-shell activation, and `build_image_tag`/`build_dockerfile`
fail loudly if called for one. The container exists to pin a known-old glibc and the
clang/lld/ninja NEVRAs; that has no Windows analog, and a Windows container would fix none of
the Windows-specific problems. Pin the runner label (`windows-2022`, never `windows-latest`)
for the same reason the Dockerfile pins NEVRAs: `msvc_toolset` is attested provenance and must
not drift silently.
```

Scope the existing trailing sentence to container platforms: change "the Dockerfile stays the single source of truth for the toolchain pins and the `glibc_build` value `manifest.json` attests to" to "for container platforms, the Dockerfile stays the single source of truth for the toolchain pins and the `glibc_build` value `manifest.json` attests to".

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/naming.sh test/lib_naming.test.sh CLAUDE.md
git commit -m "feat(naming): classify platforms as container or runner toolchains

Adds platform_toolchain() and windows-x86_64 to PLATFORMS. build_image_tag
and build_dockerfile now fail loudly for runner platforms rather than
returning an empty string that would become \`docker build -f ''\`.

The Dockerfile-existence guard in lib_naming.test.sh becomes toolchain-aware
and additionally asserts that runner platforms have NO Dockerfile, so a stray
docker/windows-x86_64.Dockerfile cannot appear unnoticed."
```

---

### Task 2: Verify `install-headers.sh` on Windows

**Files:**
- Modify (only if the probe fails): `scripts/install-headers.sh`
- Test: manual probe on `winbox`, then `test/build_smoke.sh` in Task 10

**Interfaces:**
- Consumes: `platform_toolchain` from Task 1 (not directly; this task is a probe).
- Produces: a recorded yes/no on whether `install-headers.sh` runs unmodified on Windows, appended to `spike/windows-iree-runbook.md` as W7.

This is the plan's **one genuine unknown**. The spike unblocked the header gap with a blanket `cp -rn`, which is not a port — it drags `.c` files and private headers into the prefix, where `install-headers.sh` deliberately walks the real `#include` graph. It uses shell tooling over paths; separators and case-sensitivity are both plausible failure points. Budget rework.

- [ ] **Step 1: Read the script and identify path assumptions**

Run: `cat scripts/install-headers.sh`
Look specifically for: `find` with `-path` patterns, `sed` rewriting `/`, `realpath`/`readlink -f`, and any comparison that assumes case-sensitive filenames.

- [ ] **Step 2: Run it against the existing winbox prefix**

On `winbox`, in Git-Bash inside an activated VS dev shell (never `C:\Windows\System32\bash.exe`, which is WSL):

```bash
rm -rf /c/Users/cored/hdr-probe && mkdir -p /c/Users/cored/hdr-probe
IREE_SRC=/c/Users/cored/workspace/iree \
BUILD_DIR=/c/Users/cored/workspace/iree-build \
PREFIX=/c/Users/cored/hdr-probe \
  bash /path/to/dist/scripts/install-headers.sh
echo "exit=$?"
find /c/Users/cored/hdr-probe -name '*.h' | wc -l
find /c/Users/cored/hdr-probe -name '*.c' | wc -l   # MUST be 0
```

- [ ] **Step 3: Verify the result is a real port, not a blanket copy**

Expected: non-zero `.h` count, **zero** `.c` files, and `iree/runtime/api.h` plus `iree/base/allocator.h` present. A non-zero `.c` count means the walk fell back to copying the tree and the port is not done.

- [ ] **Step 4: Fix only if it failed**

If the script errored or produced `.c` files, repair the specific path assumption. Do **not** replace the `#include`-graph walk with a copy — that is the exact over-broad behaviour the script exists to avoid.

- [ ] **Step 5: Record the outcome**

Append a `## W7 — install-headers.sh on Windows` section to `spike/windows-iree-runbook.md` stating whether it ran unmodified, and if not, exactly what changed and why.

- [ ] **Step 6: Commit**

```bash
git add spike/windows-iree-runbook.md scripts/install-headers.sh
git commit -m "test(headers): verify install-headers.sh walks the include graph on Windows

Records W7. The spike's blanket cp -rn was an expedient, not a port; this
confirms the real #include-graph walk works (or records what had to change)."
```

---

### Task 3: Verify `/d1trimfile:` on the CI toolset and decide the relocatability bar

**Files:**
- Modify: `docs/superpowers/specs/2026-07-26-windows-platform-add-design.md` (record the outcome)
- Modify: `spike/windows-iree-runbook.md` (append W8)

**Interfaces:**
- Consumes: nothing.
- Produces: a recorded decision — **parity** (`/d1trimfile:` works on cl 19.44; Tasks 8–9 implement the string-scan assertion) or **fallback** (port ET's functional gate instead). Tasks 8 and 9 branch on this.

The spike measured `/d1trimfile:` on cl **19.51** (VS 2026). CI is cl **19.44** (VS 2022). The whole parity approach depends on it working there.

- [ ] **Step 1: Probe on a VS 2022 toolset**

Prefer a real `windows-2022` GitHub runner via a throwaway workflow-dispatch job; a local VS 2022 install is acceptable if available. In Git-Bash inside the dev shell, with `MSYS_NO_PATHCONV=1` set (a leading `/` in a flag gets path-converted and silently feeds garbage):

```bash
export MSYS_NO_PATHCONV=1
mkdir -p /c/trimtest/sub && cd /c/trimtest
printf 'const char* f(void){ return __FILE__; }\n' > sub/foo.c
cl -nologo -c -Fo:base.obj 'C:/trimtest/sub/foo.c'
strings base.obj | grep -a 'foo\.c' | sort -u
cl -nologo -c '-d1trimfile:C:\trimtest\' -Fo:trim.obj 'C:/trimtest/sub/foo.c'
echo "exit=$?"
strings trim.obj | grep -a 'foo\.c' | sort -u
cl -nologo -c '-d1trimfile:C:\trimtest\' -Fo:t2.obj 'C:/trimtest/sub/foo.c' 2>&1 | grep -iE 'warning|error|unrecognized' || echo "(no diagnostics)"
```

- [ ] **Step 2: Read the result against the trip conditions**

**Parity holds** if baseline prints an absolute path, the trimmed build prints a relative one (`sub/foo.c`), exit is 0, and there are no diagnostics.

**Fallback trips** if `/d1trimfile:` is rejected or warned on cl 19.44; or it works for source files but generated sources under the build tree still leak and covering them needs more than one additional trim prefix; or the string scan later stays red for a reason requiring changes to the exemption or the assertion's own logic.

**Does NOT trip** on ordinary friction — a wrong prefix, a quoting bug, a missed `.lib` case. Those are bugs to fix.

- [ ] **Step 3: Record the decision**

Append `## W8 — /d1trimfile: on the CI toolset (cl 19.44)` to `spike/windows-iree-runbook.md` with the measured before/after `__FILE__` values and the verdict. Update the spec's "Fallback policy" section to state which bar was taken. If the fallback was taken, also comment on issue #11 with the specific failure and note that Windows then holds a weaker relocatability standard than Linux — visible and deliberate, not silent.

- [ ] **Step 4: Commit**

```bash
git add spike/windows-iree-runbook.md docs/superpowers/specs/2026-07-26-windows-platform-add-design.md
git commit -m "test(reloc): verify /d1trimfile: on the CI toolset, fix the relocatability bar

Records W8. Determines whether Tasks 8-9 implement Linux parity (string-scan
assertion plus compile-time prevention) or the ET functional gate fallback."
```

---

### Task 4: Make the variant list platform-aware

**Files:**
- Modify: `scripts/lib/variants.sh:52-54`
- Modify: `CLAUDE.md` (variant-matrix passage)
- Test: `test/lib_variants.test.sh`

**Interfaces:**
- Consumes: nothing (deliberately does not call `platform_toolchain` — the exclusion is about the *compiler*, not the toolchain delivery).
- Produces: `known_variants <platform>` → `default tsan` for `linux-*`, `default` for `windows-*`, returns 2 on unknown. `variants_json <platform>` → JSON array of the same.

- [ ] **Step 1: Write the failing test**

Append to `test/lib_variants.test.sh`, before the final `exit`:

```bash
# TSan is clang/Linux-only. The release matrix is a full variant x platform
# cross-product, so if this list were platform-independent the matrix would
# schedule an unbuildable tsan/windows job. The exclusion lives HERE, not in an
# exclude: block, because a variant list is never hardcoded in a workflow.
assert_eq "$(known_variants linux-x86_64)"   "default tsan" "linux-x86_64 builds both variants"
assert_eq "$(known_variants linux-aarch64)"  "default tsan" "linux-aarch64 builds both variants"
assert_eq "$(known_variants windows-x86_64)" "default"      "windows-x86_64 is default-only (no clang TSan)"

assert_eq "$(variants_json linux-x86_64)"   '["default", "tsan"]' "variants_json linux"
assert_eq "$(variants_json windows-x86_64)" '["default"]'         "variants_json windows"

known_variants bogus-platform >/dev/null 2>&1
assert_eq "$?" "2" "known_variants rejects an unknown platform"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/lib_variants.test.sh`
Expected: FAIL — `known_variants linux-x86_64` currently ignores its argument and returns `default tsan` for every input, so the `windows-x86_64` assertion fails.

- [ ] **Step 3: Write minimal implementation**

Replace `scripts/lib/variants.sh:52-54`:

```bash
# Which variants a platform builds. NOT platform-independent: tsan is
# -fsanitize=thread under clang, which the MSVC/Windows toolchain does not
# provide. release.yml fans out a full variant x platform cross-product, so
# without this a windows tsan job would be scheduled and fail. The exclusion
# lives here rather than in an `exclude:` block because a variant list is never
# hardcoded in a workflow -- YAML can't source this file, so it goes through the
# setup job's step output instead.
known_variants() { # <platform>
  case "${1:-}" in
    linux-*)   printf 'default tsan' ;;
    windows-*) printf 'default' ;;
    *) echo "error: unknown platform '${1:-}'" >&2; return 2 ;;
  esac
}

variants_json() { # <platform>, JSON array for GitHub Actions' fromJson()
  python3 -c "import json,sys; print(json.dumps(sys.argv[1].split()))" "$(known_variants "$1")"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/lib_variants.test.sh`
Expected: PASS.

- [ ] **Step 5: Find and fix every existing caller**

Run: `grep -rn "known_variants\|variants_json" --include=*.sh --include=*.yml . | grep -v test/`
Every call site must now pass a platform. Fix each one.

- [ ] **Step 6: Run the full suite**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`.

- [ ] **Step 7: Update CLAUDE.md**

In the "Variant matrix" section, change the description of `known_variants` from `(`default tsan`)` to record that `known_variants` and `variants_json` take a platform argument, that Windows is `default`-only because TSan is clang/Linux-only, and that the exclusion lives in `variants.sh` rather than an `exclude:` block so a variant list is never hardcoded in a workflow.

- [ ] **Step 8: Commit**

```bash
git add scripts/lib/variants.sh test/lib_variants.test.sh CLAUDE.md
git commit -m "feat(variants): make the variant list platform-aware

known_variants/variants_json take a platform. Windows is default-only:
tsan is -fsanitize=thread under clang, which MSVC does not provide, and
release.yml's full cross-product would otherwise schedule an unbuildable
tsan/windows job. Kept in variants.sh rather than an exclude: block so a
variant list is never hardcoded in a workflow."
```

---

### Task 5: Make the notices list platform-aware

**Files:**
- Modify: `scripts/lib/linked-components.sh:58-60`
- Modify: `scripts/gen-notices.sh:44`
- Test: `test/notices.test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `linked_components <platform>` → `flatcc printf libbacktrace` for `linux-*`, `flatcc printf` for `windows-*`, returns 2 on unknown.

The Windows value is **derived, not guessed** — W4 confirmed it four independent ways. Shipping the Linux list on a Windows artifact would claim a libbacktrace license for code not present in any form.

- [ ] **Step 1: Write the failing test**

Append to `test/notices.test.sh`, before the final `exit`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/notices.test.sh`
Expected: FAIL — `linked_components` ignores its argument and returns the Linux list for `windows-x86_64`.

- [ ] **Step 3: Write minimal implementation**

Replace `scripts/lib/linked-components.sh:58-60`. Keep all existing derivation prose above it, and add the Windows derivation in the same style:

```bash
#   WINDOWS (windows-x86_64) -- re-derived, not assumed. Same two-step method:
#   transitive INTERFACE_LINK_LIBRARIES closure from iree_runtime_impl (72
#   targets; iree_runtime_unified's own property is a genex delegating to it),
#   then an nm cross-check with llvm-nm over all 191 installed .lib archives.
#   flatcc      - ACCEPT. 10 flatcc_verify_* symbols defined in flatcc_parsing.lib
#                 and referenced undefined from iree_vm_bytecode_module.lib and
#                 iree_runtime_unified.lib. Same as Linux.
#   printf      - ACCEPT. vfctprintf/vsnprintf_ referenced undefined from
#                 iree_base_base.lib and iree_runtime_unified.lib. Same as Linux.
#   libbacktrace - REJECTED on Windows, confirmed four ways: CMake emits no
#                 install rule; no libbacktrace*.lib anywhere in the prefix; zero
#                 backtrace_create_state/_full/_pcinfo/_simple/_syminfo symbols
#                 across all 191 archives; and absent from iree_base_base's
#                 INTERFACE_LINK_LIBRARIES, where the Linux build carries it.
#                 It is NOT displaced by dbghelp -- that string appears zero times
#                 in IREETargets-Runtime.cmake and iree_runtime_unified.lib
#                 references no SymInitialize/SymFromAddr/StackWalk/
#                 CaptureStackBackTrace symbol. The symbolization path is simply
#                 not enabled in this configuration.
#   See spike/windows-iree-runbook.md W4 for the full derivation.
_IREE_LINKED_COMPONENTS_LINUX="flatcc printf libbacktrace"
_IREE_LINKED_COMPONENTS_WINDOWS="flatcc printf"

linked_components() { # <platform>
  case "${1:-}" in
    linux-*)   printf '%s' "$_IREE_LINKED_COMPONENTS_LINUX" ;;
    windows-*) printf '%s' "$_IREE_LINKED_COMPONENTS_WINDOWS" ;;
    *) echo "error: unknown platform '${1:-}'" >&2; return 2 ;;
  esac
}
```

- [ ] **Step 4: Update the consumer**

In `scripts/gen-notices.sh:44`, change `for name in $IREE_LINKED_COMPONENTS; do` to `for name in $(linked_components "$PLATFORM"); do`. Confirm `$PLATFORM` is in scope; if not, thread it in from the caller the same way `$VARIANT` is.

Run: `grep -rn "IREE_LINKED_COMPONENTS" --include=*.sh .` — no call site outside `linked-components.sh` may reference the bare variable any more.

- [ ] **Step 5: Run tests**

Run: `bash test/notices.test.sh && bash test/run.sh`
Expected: PASS, then `ALL UNIT TESTS PASS`.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/linked-components.sh scripts/gen-notices.sh test/notices.test.sh
git commit -m "feat(notices): derive the linked-components list per platform

Windows is 'flatcc printf' -- libbacktrace is absent from a Windows
artifact, confirmed four independent ways in spike W4. Shipping the Linux
list on a Windows manifest would claim a license for code not present in
any form, the over-claiming failure CLAUDE.md warns about, inverted."
```

---

### Task 6: Conditional provenance in `manifest.json` and `BUILDINFO`

**Files:**
- Modify: `scripts/gen-manifest.sh:80-160`
- Modify: `CLAUDE.md` (manifest.json passage)
- Test: `test/manifest.test.sh`

**Interfaces:**
- Consumes: `$PLATFORM` (already in scope in `gen-manifest.sh`).
- Produces: manifests with `glibc_build` on `linux-*` only, and `msvc_toolset` + `crt` on `windows-*` only. `schema_version` stays `2`.

Follows the existing conditional-`sanitizer` idiom at `gen-manifest.sh:130-138`. Absence of a key is the honest encoding for "this platform has no glibc"; a `"n/a"` sentinel was rejected because it invites reading it as "no glibc requirement".

- [ ] **Step 1: Write the failing test**

Append to `test/manifest.test.sh`, before the final `exit`. Reuse whatever fixture-generation helper the file already uses to produce `$m`; generate a second manifest with `PLATFORM=windows-x86_64`, `MSVC_TOOLSET=19.44.35228.0`, `CRT=MT` into `$mw`:

```bash
# Provenance keys are platform-conditional, following the existing conditional
# `sanitizer` idiom. schema_version stays 2 -- the change is purely additive.
assert_eq "$(get "$mw" "['schema_version']")" "2"             "windows manifest stays schema 2"
assert_eq "$(get "$mw" "['msvc_toolset']")"   "19.44.35228.0" "windows records msvc_toolset"
assert_eq "$(get "$mw" "['crt']")"            "MT"            "windows records the static CRT"

# Mutual absence is the assertion that stops the two provenance models silently
# merging later. A Windows manifest must not carry a glibc value, and a Linux
# manifest must not carry MSVC keys.
assert_eq "$(get "$mw" "get('glibc_build','ABSENT')")"  "ABSENT" "windows omits glibc_build"
assert_eq "$(get "$m"  "get('msvc_toolset','ABSENT')")" "ABSENT" "linux omits msvc_toolset"
assert_eq "$(get "$m"  "get('crt','ABSENT')")"          "ABSENT" "linux omits crt"

# The crt note must carry the same honesty caveat glibc_build has: with /MT the
# archives emit only /DEFAULTLIB:LIBCMT directives, so the CRT is resolved at the
# consumer's final link. It is NOT a compatibility floor.
assert_contains "$(get "$mw" "['notes']['crt']")" "final link" "crt note states where the CRT resolves"
```

If `get` cannot express a default, add a sibling helper in the test file rather than changing `assert.sh`.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/manifest.test.sh`
Expected: FAIL — `msvc_toolset` missing, and `glibc_build` present on the Windows manifest.

- [ ] **Step 3: Write minimal implementation**

In `scripts/gen-manifest.sh`, pass `$PLATFORM`, `$MSVC_TOOLSET`, and `$CRT` into the Python heredoc alongside the existing arguments. Remove `"glibc_build": glibc_build,` from the unconditional dict and add, after the `sanitizer` block:

```python
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
```

Move the existing `notes["glibc_build"]` entry out of the unconditional `notes` dict into the Linux branch above, so it cannot appear on a Windows manifest.

For `BUILDINFO`, replace the unconditional `glibc_build=$GLIBC_BUILD` line with a conditional block after the heredoc:

```bash
case "$PLATFORM" in
  linux-*)   echo "glibc_build=$GLIBC_BUILD" >> "$PREFIX/BUILDINFO" ;;
  windows-*) { echo "msvc_toolset=$MSVC_TOOLSET"; echo "crt=$CRT"; } >> "$PREFIX/BUILDINFO" ;;
esac
```

- [ ] **Step 4: Run tests**

Run: `bash test/manifest.test.sh && bash test/run.sh`
Expected: PASS, then `ALL UNIT TESTS PASS`.

- [ ] **Step 5: Update CLAUDE.md**

In the `## manifest.json` section, record that provenance keys are platform-conditional: `glibc_build` on container platforms, `msvc_toolset` + `crt` on Windows, each absent on the other, `schema_version` unchanged at `2`. Keep the existing not-a-floor warning for `glibc_build` and add its `crt` counterpart.

- [ ] **Step 6: Commit**

```bash
git add scripts/gen-manifest.sh test/manifest.test.sh CLAUDE.md
git commit -m "feat(manifest): platform-conditional provenance keys

Windows omits glibc_build and records msvc_toolset + crt instead,
following the existing conditional sanitizer idiom. schema_version stays
2 -- purely additive, no consumer breaks. Tests assert mutual absence, so
the two provenance models cannot silently merge later."
```

---

### Task 7: Windows build path in `build-runtime.sh`

**Files:**
- Modify: `build-runtime.sh:299`, `:304`, `:346-358` (libbacktrace repair), plus the flag assembly
- Test: `test/print_flags.test.sh`

**Interfaces:**
- Consumes: `platform_toolchain` (Task 1), `known_variants` (Task 4).
- Produces: a Windows build that passes `/MT` and `/d1trimfile:` and skips the libbacktrace repair.

- [ ] **Step 1: Write the failing test**

Append to `test/print_flags.test.sh`:

```bash
# Windows needs a static CRT (/MT) because the consumer is a JNI shim linking
# into a DLL; a dynamic CRT would push a VC++ redistributable requirement onto
# every downstream user. /d1trimfile: is MSVC's -ffile-prefix-map analog and is
# what keeps absolute __FILE__ paths out of the shipped archives.
wf="$(PLATFORM=windows-x86_64 bash ./build-runtime.sh --print-flags --variant default)"
assert_contains "$wf" "/MT"          "windows uses the static CRT"
assert_contains "$wf" "d1trimfile"   "windows trims __FILE__ paths"

lf="$(PLATFORM=linux-x86_64 bash ./build-runtime.sh --print-flags --variant default)"
assert_contains "$lf" "-ffile-prefix-map" "linux keeps its own prefix map"
case "$lf" in *d1trimfile*) echo "FAIL: MSVC-only flag leaked into linux flags" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1));; *) echo "ok: no MSVC flag on linux";; esac
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/print_flags.test.sh`
Expected: FAIL — no `/MT` or `d1trimfile` in the Windows flag output.

- [ ] **Step 3: Write minimal implementation**

Add the Windows flags where `effective_cmake_flags` is assembled, keyed on platform. `/MT` goes through `CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded` (the supported CMake spelling), and `/d1trimfile:` through `CMAKE_C_FLAGS`/`CMAKE_CXX_FLAGS` with the **source root** as the prefix, trailing backslash included. If Task 3 found generated sources also leak, add a second `-d1trimfile:` for the build root.

Guard the libbacktrace repair. Wrap `build-runtime.sh:299`, `:304`, and `:346-358` in:

```bash
# libbacktrace is a Linux-only repair. On Windows IREE emits no install rule for
# it, ships no libbacktrace*.lib, references zero backtrace_* symbols across all
# 191 archives, and omits it from iree_base_base's INTERFACE_LINK_LIBRARIES. It
# is dropped outright -- NOT substituted by dbghelp, which appears nowhere in the
# export set (spike W4). Guarded on platform, deliberately NOT on "does the
# archive exist": an existence check would silently no-op if the Linux archive
# ever went missing, turning a loud failure into a quiet one.
if [ "$(platform_toolchain "$PLATFORM")" = container ]; then
  ... existing libbacktrace repair ...
fi
```

- [ ] **Step 4: Run tests**

Run: `bash test/print_flags.test.sh && bash test/run.sh`
Expected: PASS, then `ALL UNIT TESTS PASS`.

- [ ] **Step 5: Commit**

```bash
git add build-runtime.sh test/print_flags.test.sh
git commit -m "feat(build): Windows build path -- static CRT, path trimming, no libbacktrace

Adds /MT via CMAKE_MSVC_RUNTIME_LIBRARY and /d1trimfile: as MSVC's
-ffile-prefix-map analog. Guards the libbacktrace repair on platform
rather than on archive existence, so a missing Linux archive stays a loud
failure instead of a silent no-op."
```

---

### Task 8: COFF-aware relocatability assertion

**Files:**
- Modify: `scripts/relocatability.sh:100-125`
- Test: `test/relocatability.test.sh`

**Interfaces:**
- Consumes: the Task 3 decision.
- Produces: `relocatability_assert` handling `.lib`/`.obj` via `llvm-objcopy`.

**If Task 3 took the fallback, skip this task** and instead port `executorch-runtime-dist/test/relocatability-windows.sh` as a functional extract-and-link gate. Record the substitution in the plan and issue #11.

`RELOC_ALLOW_DEBUG_PATHS` stays gated to sanitizer variants and stays off for Windows. Do not widen it. The `__FILE__` paths are not debug-only — 9 of 22 survived stripping — so exempting them is the forbidden move.

- [ ] **Step 1: Write the failing test**

Append to `test/relocatability.test.sh`:

```bash
# A leaked path in a Windows .lib must be caught. The existing case pattern is
# *.a|*.o|*.so|*.so.*, so a .lib falls through to the "always real" branch --
# correct by accident today, asserted deliberately here.
win_tmp="$(mktemp -d)"; mkdir -p "$win_tmp/lib"
printf 'C:\\Users\\builder\\workspace\\iree-build\\junk\n' > "$win_tmp/lib/leaky.lib"
if relocatability_assert "$win_tmp" 'C:\Users\builder\workspace\iree-build' 'C:\Users\builder\workspace\iree' >/dev/null 2>&1; then
  echo "FAIL: a leaked build path in a .lib was not caught" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok: leaked build path in a .lib is caught"
fi
rm -rf "$win_tmp"

# The debug-path exemption must NOT rescue a .lib, even when enabled: the paths
# it would need to exempt are __FILE__ string constants, not debug sections.
win2="$(mktemp -d)"; mkdir -p "$win2/lib"
printf 'C:\\Users\\builder\\workspace\\iree\\runtime\\src\\iree\\base\\allocator.c\n' > "$win2/lib/file.lib"
if RELOC_ALLOW_DEBUG_PATHS=1 relocatability_assert "$win2" 'C:\Users\builder\workspace\iree-build' 'C:\Users\builder\workspace\iree' >/dev/null 2>&1; then
  echo "FAIL: RELOC_ALLOW_DEBUG_PATHS wrongly exempted a __FILE__ leak in a .lib" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok: exemption does not rescue a __FILE__ leak in a .lib"
fi
rm -rf "$win2"
```

- [ ] **Step 2: Run test to verify it fails or passes for the wrong reason**

Run: `bash test/relocatability.test.sh`
Expected: the first assertion may already pass (a `.lib` falls to the `*)` branch). Confirm the second fails or passes only incidentally, then make both deliberate.

- [ ] **Step 3: Write minimal implementation**

In `scripts/relocatability.sh`, extend the exemption's case pattern to name COFF explicitly and use the right tool, while keeping the semantics identical:

```bash
        *.a|*.o|*.so|*.so.*)
          tmp="$(mktemp)"
          if objcopy --strip-debug "$f" "$tmp" 2>/dev/null \
               && ! grep -qE -- "$pattern" "$tmp"; then
            : # path was debug-only -> exempt
          else
            surviving="$surviving $f"
          fi
          rm -f "$tmp"
          ;;
        *.lib|*.obj)
          # COFF. objcopy cannot read these; llvm-objcopy can. Note this branch
          # is currently unreachable in practice -- RELOC_ALLOW_DEBUG_PATHS is
          # gated to sanitizer variants and Windows is default-only -- but the
          # tool must be correct if a future sanitizer variant ever lands there.
          tmp="$(mktemp)"
          if llvm-objcopy --strip-debug "$f" "$tmp" 2>/dev/null \
               && ! grep -qE -- "$pattern" "$tmp"; then
            :
          else
            surviving="$surviving $f"
          fi
          rm -f "$tmp"
          ;;
        *) surviving="$surviving $f" ;;
```

- [ ] **Step 4: Run tests**

Run: `bash test/relocatability.test.sh && bash test/run.sh`
Expected: PASS, then `ALL UNIT TESTS PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/relocatability.sh test/relocatability.test.sh
git commit -m "feat(reloc): make the assertion COFF-aware

Adds .lib/.obj handling via llvm-objcopy. RELOC_ALLOW_DEBUG_PATHS stays
gated to sanitizer variants and stays off for Windows: the __FILE__ paths
are not debug-only (9 of 22 survived stripping), so exempting them would
weaken the assertion rather than port it."
```

---

### Task 9: Repair the `-natvis:` absolute path

**Files:**
- Modify: `build-runtime.sh` (`relocatability_repair` section)
- Test: `test/relocatability.test.sh`

**Interfaces:**
- Consumes: Task 8's assertion.
- Produces: an installed `IREETargets-Runtime.cmake` with no absolute `-natvis:` path.

Required under **both** relocatability bars — it is a text-file leak reaching a consumer's actual link line, categorically different from `__FILE__` string constants. Text files are never exempt from the assertion. This falls inside the existing `relocatability_repair` sanctioned exception, so it does **not** create a third exception to CLAUDE.md's rule.

- [ ] **Step 1: Write the failing test**

Append to `test/relocatability.test.sh`:

```bash
# -natvis: carries an absolute SOURCE path into INTERFACE_LINK_LIBRARIES, so a
# consumer on any other machine gets a dangling flag on their link line. A .cmake
# file is a text file and is never exempt from the assertion.
nat="$(mktemp -d)"; mkdir -p "$nat/lib/cmake/IREE"
cat > "$nat/lib/cmake/IREE/IREETargets-Runtime.cmake" <<'X'
set_target_properties(iree_runtime_impl PROPERTIES
  INTERFACE_LINK_LIBRARIES "flatcc_parsing;-natvis:C:/Users/builder/workspace/iree/runtime/iree.natvis;-pdbpagesize:32768"
)
X
relocatability_repair "$nat" 'C:\Users\builder\workspace\iree-build' 'C:/Users/builder/workspace/iree'
if grep -q 'natvis:C:' "$nat/lib/cmake/IREE/IREETargets-Runtime.cmake"; then
  echo "FAIL: -natvis: absolute path survived the repair" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok: -natvis: absolute path repaired"
fi
# The repair must be surgical: sibling entries stay intact.
assert_contains "$(cat "$nat/lib/cmake/IREE/IREETargets-Runtime.cmake")" "flatcc_parsing"     "sibling link entry untouched"
assert_contains "$(cat "$nat/lib/cmake/IREE/IREETargets-Runtime.cmake")" "-pdbpagesize:32768" "sibling linker flag untouched"
rm -rf "$nat"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/relocatability.test.sh`
Expected: FAIL — `-natvis: absolute path survived the repair`.

- [ ] **Step 3: Write minimal implementation**

Extend `relocatability_repair` to drop the `-natvis:<abs>` entry from `INTERFACE_LINK_LIBRARIES`. Removing it is correct rather than rewriting it to a relative path: `.natvis` is a Visual Studio debugger visualiser, it is not shipped in the prefix, and a consumer has no use for a path to the builder's source tree. Match only `-natvis:` entries whose path is absolute, and leave every sibling entry untouched.

Add an idempotency guard in the style of the existing Phase 1 repairs (`grep -q`), so a re-run does not fail on an already-repaired file.

- [ ] **Step 4: Run tests**

Run: `bash test/relocatability.test.sh && bash test/run.sh`
Expected: PASS, then `ALL UNIT TESTS PASS`.

- [ ] **Step 5: Commit**

```bash
git add build-runtime.sh test/relocatability.test.sh
git commit -m "fix(reloc): drop the absolute -natvis: path from the export set

iree_runtime_impl's INTERFACE_LINK_LIBRARIES carried an absolute source
path that would reach a consumer's link line as a dangling flag. Removed
rather than rewritten: the .natvis visualiser is not shipped in the
prefix, so a relative path would dangle too. Inside the existing
relocatability_repair sanctioned exception; not a third exception."
```

---

### Task 10: Windows-aware `build_smoke.sh`

**Files:**
- Modify: `test/build_smoke.sh:38`, `:46`, `:52`, `:96`, `:265-321`, `:306`

**Interfaces:**
- Consumes: a built Windows prefix.
- Produces: a structural check that works on both archive naming conventions.

`llvm-nm` emits BSD 3-column output structurally identical to GNU nm. x86-64 COFF does not underscore-prefix C symbols, so identifiers appear verbatim and substring matching ports unchanged; undefined symbols print a blank address (2 fields) exactly as on ELF, so the existing awk selector at `:283` (`$3 == s && $2 ~ /^[TtDd]$/`) works unmodified. Only naming and the tool need to change.

- [ ] **Step 1: Add archive-convention detection**

Near the top of `test/build_smoke.sh`, after `prefix` is set:

```bash
# Archive naming and the symbol tool differ by platform. Measured: every file in
# a Windows prefix's lib/ ends in .lib with no `lib` prefix (plain MSVC
# defaults), and llvm-nm reads COFF with output structurally identical to GNU nm.
if ls "$prefix"/lib/*.lib >/dev/null 2>&1; then
  AR_EXT="lib"; AR_PRE="";    NM="${NM:-llvm-nm}"
else
  AR_EXT="a";   AR_PRE="lib"; NM="${NM:-nm}"
fi
```

- [ ] **Step 2: Replace the hardcoded names**

- `:38` → `if ls "$prefix"/lib/*."$AR_EXT" >/dev/null 2>&1; then`
- `:46` → `unified="$prefix/lib/${AR_PRE}iree_runtime_unified.$AR_EXT"`
- `:52` → `for f in ${AR_PRE}flatcc_runtime.$AR_EXT ${AR_PRE}flatcc_parsing.$AR_EXT; do`
- `:96`, `:306` → `for a in "$prefix"/lib/*."$AR_EXT"; do`
- `:265`, `:283`, `:307` → replace `nm` with `"$NM"`, and `:321`'s availability check with `command -v "$NM"`

Update the literal `libiree_runtime_unified.a` strings in the ok/FAIL messages at `:47`, `:285`, `:287` to use `$(basename "$unified")`.

- [ ] **Step 3: Verify on Linux (no regression)**

Run: `bash test/build_smoke.sh out`
Expected: same output as before the change — `ok: static archives present`, `ok: libiree_runtime_unified.a present and non-empty`, and the symbol checks passing.

- [ ] **Step 4: Verify on a Windows prefix**

On `winbox`, against the built prefix: `bash test/build_smoke.sh /c/Users/cored/workspace/iree-prefix`
Expected: `ok: static archives present`, `ok: iree_runtime_unified.lib present and non-empty`, symbol checks pass.

- [ ] **Step 5: Commit**

```bash
git add test/build_smoke.sh
git commit -m "test(smoke): handle both archive naming conventions

Detects .lib vs .a and selects llvm-nm vs nm. llvm-nm's BSD 3-column
output is structurally identical to GNU nm and x86-64 COFF does not
underscore-prefix C symbols, so the existing awk selector works unchanged."
```

---

### Task 11: Windows consumer acceptance gate

**Files:**
- Modify: `test/consumer/CMakeLists.txt`, `test/consumer/run.sh`
- **Do NOT modify:** `test/consumer/consumer.c`

**Interfaces:**
- Consumes: a packaged Windows tarball.
- Produces: a consumer gate that compiles, links, loads `add.vmfb`, and runs it under both drivers on Windows.

`consumer.c` stays byte-identical. Compiling it as C++ to dodge `_Generic` cascades into C7555/C4576/C7560 and breaks the rule that the gate is only meaningful while the consumer is exactly what a real consumer would write. `/std:c17` is the entire source-language delta.

- [ ] **Step 1: Add the MSVC branch to CMakeLists.txt**

```cmake
if(MSVC)
  # MSVC's default C mode predates C11 and rejects _Generic, which IREE's
  # atomics headers use throughout. /std:c17 is the whole delta -- do NOT
  # switch LANGUAGE to CXX, which cascades into C7555/C4576/C7560 and would
  # require editing consumer.c away from what a real consumer writes.
  set_source_files_properties(consumer.c PROPERTIES COMPILE_FLAGS "/std:c17")
endif()
```

- [ ] **Step 2: Point `find_package` at the config directory**

In `test/consumer/run.sh`, pass `-DIreeRuntimeDist_DIR="$prefix/lib/cmake/IreeRuntimeDist"` (adjust to the package name the prefix actually installs) in addition to the existing `CMAKE_PREFIX_PATH`. CMake 4.x no longer searches `<prefix>/lib/cmake/` from `CMAKE_PREFIX_PATH`; setting `<pkg>_DIR` explicitly is correct on both 3.x and 4.x, so this needs no platform branch.

- [ ] **Step 3: Add the isolation assertion**

In `test/consumer/run.sh`, before configuring:

```bash
# The Linux gate gets "never seen the build tree" from a container; the Windows
# gate gets it from the job boundary. Assert it explicitly so the property is
# testable on both rather than implied by the container on one.
for forbidden in "$PWD/iree" "$PWD/../iree" "$PWD/iree-build-default"; do
  if [ -e "$forbidden" ]; then
    echo "FAIL: consumer gate can reach '$forbidden'; it must run with no IREE source or build tree" >&2
    exit 1
  fi
done
```

- [ ] **Step 4: Verify on Linux (no regression)**

Run in a clean container: `bash test/consumer/run.sh out`
Expected: passes for both `local-sync` and `local-task`.

- [ ] **Step 5: Verify on Windows**

On `winbox`, against an extracted tarball in a directory with no build tree. Expected: compiles, links, and prints the correct sum under both drivers.

- [ ] **Step 6: Commit**

```bash
git add test/consumer/CMakeLists.txt test/consumer/run.sh
git commit -m "test(consumer): run the acceptance gate on Windows

/std:c17 for MSVC's pre-C11 default mode, explicit <pkg>_DIR for CMake
4.x's prefix-path change, and an explicit no-source-tree assertion so
isolation is testable rather than implied by the container. consumer.c is
unmodified -- the gate is only meaningful while it is what a real
consumer would write."
```

---

### Task 12: Wire the Windows job into `release.yml`

**Files:**
- Modify: `.github/workflows/release.yml:55-160` (build job), `:160-260` (verify job), `:340-365` (upload)
- Test: `test/workflow_paths.test.sh`

**Interfaces:**
- Consumes: every preceding task.
- Produces: a release run that publishes `iree-runtime-3.11.0-default-windows-x86_64.tar.gz` and its `.sha256`.

- [ ] **Step 1: Make the matrix platform-aware**

The setup job currently emits one `variants` list. Emit a per-platform mapping instead, or fan out `include:` entries computed from `known_variants <platform>` so no `tsan`/`windows-x86_64` combination is ever generated. Add `- platform: windows-x86_64` / `runner: windows-2022` to the `include:` block that assigns runners.

- [ ] **Step 2: Branch the build step on toolchain**

Guard the existing Docker steps with `if: matrix.toolchain == 'container'` (computed from `platform_toolchain` in the setup job) and add a runner-native path for Windows:

```yaml
      - name: Build (runner-native, Windows)
        if: matrix.toolchain == 'runner'
        shell: pwsh
        run: |
          $ErrorActionPreference = "Stop"
          $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
          $vsPath = & $vswhere -latest -products * -property installationPath
          if (-not $vsPath) { throw "vswhere found no Visual Studio installation" }
          & "$vsPath\Common7\Tools\Launch-VsDevShell.ps1" -Arch amd64 -SkipAutomaticLocation
          $bash = "${env:ProgramFiles}\Git\bin\bash.exe"
          & $bash -c 'set -euo pipefail; ./dist/build-runtime.sh --variant default --platform windows-x86_64'
          if ($LASTEXITCODE -ne 0) { throw "windows build failed (exit $LASTEXITCODE)" }
```

Never invoke `C:\Windows\System32\bash.exe` — that is WSL and would build Linux ELF/glibc, giving a false green.

- [ ] **Step 3: Branch the verify job the same way**

The Linux verify job runs in a container. The Windows one runs directly on the fresh runner, downloads only the release asset, and must **not** check out `iree-org/iree`. Extract with `tar -xzf` via Git-Bash — packaging is `.tar.gz` on every platform.

- [ ] **Step 4: Run the workflow-path test**

Run: `bash test/workflow_paths.test.sh && bash test/run.sh`
Expected: PASS, then `ALL UNIT TESTS PASS`.

- [ ] **Step 5: Dry-run the workflow**

Trigger a `workflow_dispatch` run on the branch. Confirm: no `tsan`/`windows-x86_64` job is scheduled; the Windows job reports `windows-2022`; the built manifest carries `msvc_toolset`/`crt` and no `glibc_build`; the notices tree contains no libbacktrace entry.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: build and verify windows-x86_64 on a pinned windows-2022 runner

Container steps are gated on the toolchain classifier; Windows takes a
runner-native path via vswhere -> VS dev shell -> Git-Bash. The verify job
takes its no-build-tree isolation from the job boundary and never checks
out IREE. Packaging stays .tar.gz."
```

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: toolchain provider → 1; provenance → 6; CRT `/MT` → 7; packaging (no change) → asserted in 1; matrix → 4 and 12; consumer isolation → 11; relocatability → 3, 8, 9; libbacktrace skip → 7; `install-headers.sh` → 2; notices → 5; tests → 10, 11; CLAUDE.md's three passages → 1, 4, 6.

**Sequencing.** The two risk-bearing unknowns (Tasks 2 and 3) run before any CI wiring depends on them, per the spec's instruction to surface `install-headers.sh` rework early and to settle the relocatability bar before Tasks 8–9 are written.

**Known gaps, deliberate.** Task 12's matrix fan-out is described rather than given as literal YAML, because the exact shape depends on whether the setup job emits a mapping or an `include:` list — a choice better made against the file than guessed here. Task 2's fix step is conditional by nature: the whole point is that the failure mode is unknown until probed. Neither is a placeholder standing in for work I could have specified.

**Out of scope, restated:** a `/MD` CRT row; the upstream `native_module_cc.h` missing-include bug (own issue); any `tracy` variant.
