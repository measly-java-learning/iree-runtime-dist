# Windows platform add — handoff

**Branch:** `feat/windows-platform-add` (based on `docs/windows-spike-findings`, itself open as PR #12)
**Plan:** `docs/superpowers/plans/2026-07-26-windows-platform-add.md`
**Spec:** `docs/superpowers/specs/2026-07-26-windows-platform-add-design.md`
**Spike evidence:** `spike/windows-iree-runbook.md` (W1–W8), issue #11

This closes out the first implementation cycle. Tasks 1–11, 12a and 12b are complete and
reviewed. 12c is **partially** complete: the Windows build works end to end, but the `verify`
job's Windows leg was never implemented. Start a fresh session from the "Pending work" section
below — it is written to be actionable without reading the rest of this file.

---

## Pending work

### 1. Implement the `verify` job's Windows leg (blocks everything else)

`verify` is half-migrated and currently cannot pass on Windows. Two distinct problems:

- **It fails at the Extract step**, for a reason unrelated to Windows correctness — the step
  never receives the asset in a usable shape. The Windows tarball is `.tar.gz` like every other
  platform, so extraction goes through Git-Bash `tar -xzf`, not the container path.
- **Behind that failure sit Docker build/push steps** that would run on a Windows runner if
  Extract ever succeeded.

The previous implementer deliberately left the Docker steps ungated, reasoning that gating them
would make the Windows leg green having done nothing. That instinct is right — see "the
recurring defect" below — but the conclusion is wrong. **Gating alone is wrong; gating plus
implementing the runner-native path is right.** Leaving it broken is not a safe middle ground.

What the leg must actually do:

- Container-gate the Docker steps (`platform_toolchain <platform>` returns `container`|`runner`).
- Add a runner-native path using the vswhere → `Launch-VsDevShell.ps1 -Arch amd64
  -SkipAutomaticLocation` → Git-Bash pattern already proven in the build job.
- **Actually run the consumer acceptance gate.** `test/consumer/` works on Windows (Task 11) and
  passes against a real package with both drivers. Verify is where that must run in CI, on a
  fresh runner that never checks out IREE — the job boundary is Windows's substitute for the
  container's isolation.
- Extend the `workflow_paths.test.sh` guard that already exists for the build job: a runner-gated
  verify leg must actually invoke the consumer gate, so a future conditional cannot silently skip
  it.

Run this on a temporary hard-gated branch trigger first (see "How the trial run was done"), not a
tag.

### 2. Revisit the relocatability bar — the Task 3 decision was made on a false premise

**`relocatability_assert` is structurally blind on Windows.** Its needles are POSIX-form
(`/d/a/...`) while everything baked into Windows artifacts is `D:\` or `D:/`. It passed while
192 files carried absolute paths.

This inverts the decision taken in Task 3. Linux parity (a string-scan assertion plus
compile-time prevention) was chosen over ExecuTorch's functional gate, with a pre-authorised
fallback. The fallback's trip conditions were written entirely around `/d1trimfile:` failing.
It works — so the fallback never tripped, while the thing parity was supposed to buy never
functioned.

Two sub-problems, only one of which is fixed:

- **Fixed** (`d39b81b`): `relocatability_repair` now strips Windows-form absolute `-I` flags —
  a real leak, 10 occurrences.
- **Not fixed:** all 191 COFF archives embed absolute paths because `lib.exe` canonicalises
  member names to full paths. This has no `/d1trimfile:`-shaped answer and is a different
  problem from `__FILE__`.

Widening the needles to `D:\`/`D:/` without first addressing the member-name issue would turn a
silently-passing assert into a permanently-failing one. Decide the bar deliberately:
ExecuTorch's functional gate (extract elsewhere, `find_package`, link, run) may now be the
approach that actually verifies something on this platform. The spec's fallback section already
carries the authorisation.

### 3. `actions/attest` has never run on a Windows runner

It was tag-gated during the 12c trials, so it is unexercised on `windows-2022`.

### 4. Then, and only then: 12d — the real tagged release

Cut a real tag and confirm the published assets: both Linux platforms × both variants, plus
`windows-x86_64`/`default`, each with its `.sha256`, all `.tar.gz`. Burning a few tags is
acceptable (`linux-aarch64` took five).

Confirm the Task 6 obligation holds: `notes.msvc_toolset` asserts the archives were built on a
**pinned** `windows-2022` image. The build job pins it; verify and release must too, or the note
is a false provenance claim.

---

## What is done and proven

| Task | Outcome |
|---|---|
| 1 | `platform_toolchain()` classifier; `windows-x86_64` in `PLATFORMS`; `build_image_tag`/`build_dockerfile` fail loudly for runner platforms; `container_platforms()`/`containers_json()` for build-image call sites |
| 2 | `install-headers.sh` runs **unmodified** on Windows — 69 headers, 0 `.c` files, skip branch measured idempotent |
| 3 | `/d1trimfile:` verified on the pinned CI toolset (cl 19.44.35228) — parity bar selected |
| 4 | `known_variants`/`variants_json` take a platform; fail loudly (exit 2, empty stdout) on a missing one |
| 5 | `linked_components <platform>` — Windows is `flatcc printf`, libbacktrace dropped |
| 6 | Platform-conditional provenance; `schema_version` stays 2; `crt` derived from `effective_cmake_flags`, never hardcoded |
| 7 | Windows build path: `/MT` via `CMAKE_MSVC_RUNTIME_LIBRARY`, `/d1trimfile:` with `cygpath -w`, libbacktrace repair platform-guarded |
| 8 | COFF-aware relocatability exemption; `$LLVM_OBJCOPY` + versioned fallbacks; fail-closed |
| 9 | `-natvis:` absolute path stripped from `INTERFACE_LINK_OPTIONS` — verified against the real exported file, all 43 `-pdbpagesize:32768` preserved |
| 10 | `build_smoke.sh` handles both archive conventions; PIC check explicitly skips on COFF instead of faking a pass |
| 11 | **Acceptance gate passes on Windows** — both drivers, `[11, 22, 33, 44]`, `consumer.c` byte-identical |
| 12a | Matrix reshaped to `{variant, platform, runner}` pairs — exactly 5, no `tsan`/`windows` possible. Zero CI runs |
| 12b | Windows harness proven in a throwaway smoke workflow — 3 runs, ~3 min, plus a negative control proving the job goes red |
| 12c | **Build works.** Run 30285740702, all five build legs green. Artifact verified: `build_smoke.sh` exit 0; `msvc_toolset=19.44.35228`, `crt=MT`, no `glibc_build`; notices = flatcc + printf only |

### Defects found while porting, already fixed

- `build-runtime.sh` hardcoded `clang`/`clang++` — the Windows leg would have used the wrong compiler
- MSYS2 rewrote `-DCMAKE_C_FLAGS=/d1trimfile:…` into a Git-root path before `cl` saw it
- `gen-constants.sh` hit the same MSVC pre-C11 `_Generic` wall as `consumer.c`; is in the recipe's
  critical path (`build-runtime.sh:495`)
- `gen-manifest.sh` detected `msvc_toolset` with a four-component regex; `cl`'s banner has three
- `gen-addvmfb.sh` assumed `python3` and a POSIX `venv/bin`
- `manifest.test.sh` and `notices.test.sh` asserted Linux-only provenance unconditionally
- CMake's MSVC platform defaults (`/EHsc`, `/GR`) were clobbered by `-DCMAKE_CXX_FLAGS`

---

## The recurring defect — read this before writing any code

**Eight defects of one shape landed in twelve tasks: code that produces a plausible-looking
result instead of failing or acting.** Every one was caught by *running* the code. None was
caught by a review reading a diff.

1. `build_image_tag` → `''` (becomes `docker build -f ''`)
2. `variants_json` → `[]`, exit 0 — a release would publish nothing and report success
3. `/d1trimfile:` with an empty prefix — trims nothing
4. `cygpath` fallback to a POSIX path that cannot match
5. Two stale single-arg `effective_cmake_flags` calls, missed by a review *and* the controller
6. A missing-tool regression test that skipped when the tool was **present**
7. `build_smoke.sh` printing `ok: archives are PIC` for a check that never ran on COFF
8. `relocatability_assert` passing while 192 files carried absolute paths

Treat any "it's green" as unproven until you have run the thing and read its output. Prefer
negative controls: 12b deliberately asserted the wrong compiler version to prove the job could
go red, because a first-try green cannot distinguish "asserted and passed" from "asserted
nothing."

---

## How the trial run was done (repeat this for the verify work)

`release.yml` fires only on `v*-*` tags. To run a real build without minting a tag:

- temporary `push: branches: ['feat/windows-platform-add']` trigger
- placeholder version substitution so `derive-version.sh` accepts a branch ref
- **`if: startsWith(github.ref, 'refs/tags/')` on `pin`, `release`, and attest** — publication
  structurally impossible from a branch push, not merely avoided
- reverted in the same task (commit `20dec68`); `release.yml` is tag-only again now

Do **not** cut a tag off this branch. It would publish real assets from a branch about to be
rebased or squashed, and the tag would outlive the branch.

## Windows/CI traps, each paid for with a failed run

- `cd` does not switch drives in `cmd` — use `cd /D`. Runners are **D:-rooted**.
- `workflow_dispatch` only registers from the **default branch**; use `on: push` from a feature branch.
- A step `name:` containing a colon must be quoted.
- A trailing backslash before a closing quote mangles CRT argv.
- Under Git-Bash a leading `/` in a flag gets path-converted — dash forms or `MSYS_NO_PATHCONV=1`.
- **Never** `C:\Windows\System32\bash.exe` — that is WSL and builds Linux.
- `actionlint` is at `~/.local/bin/actionlint`. Run it before every push.

## Driving winbox

`ssh winbox` lands in **cmd**. Run bash as
`ssh winbox '"C:\Program Files\Git\bin\bash.exe" -c "<bash>"'`. For non-trivial quoting, write a
script locally and `scp` it (`scp file winbox:file` — a bare relative path; `winbox:/c/Users/...`
fails). For MSVC on PATH, mirror `/c/Users/cored/workspace/build-iree.ps1`.

Note `/c/Users/cored/workspace/iree-prefix` on winbox is contaminated with ~495 stray `.c` files
under `include/` from an early manual spike, and is not a real `build-runtime.sh` package.
