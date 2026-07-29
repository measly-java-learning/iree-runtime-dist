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

`verify` is half-migrated and currently cannot pass on Windows. Three problems, settled in
order:

1. **"Verify checksum" and "Extract" both fail on Windows** — neither step sets `shell: bash`,
   so the Windows runner's default shell (pwsh) receives the commands. pwsh does not
   glob-expand `*` in arguments to external commands, so `sha256sum` gets the literal string
   `./*.sha256` and `tar.exe` gets the literal string `assets/*.tar.gz`. The fix is
   `shell: bash` on both steps. The artifact IS downloaded correctly; this is purely a
   shell/globbing mismatch.
2. **Behind that sit Docker-dependent steps with no toolchain gate** — "Resolve build image
   identity", `docker/setup-buildx-action`, `docker/build-push-action`, and "Consumer e2e in a
   clean container" all run unconditionally and would fail on a Windows runner. Every one
   needs `if: matrix.toolchain == 'container'`, exactly matching the build job's guards.
3. **No runner-native verify path exists** — gating alone is wrong (see below).

The previous implementer deliberately left the Docker steps ungated, reasoning that gating them
would make the Windows leg green having done nothing. That instinct is right — see "the
recurring defect" below — but the conclusion is wrong. **Gating alone is wrong; gating plus
implementing the runner-native path is right.** Leaving it broken is not a safe middle ground.

What the leg must actually do:

- Add `shell: bash` to the shared "Verify checksum" and "Extract" steps (problems 1).
- Container-gate the Docker-dependent steps with `if: matrix.toolchain == 'container'`
  (problem 2). The four steps that need it: "Resolve build image identity",
  `docker/setup-buildx-action`, "Build the pinned toolchain image", and "Consumer e2e in a
  clean container". ("Lower ASLR entropy" is already gated on `tsan`, which cannot occur on
  Windows, so it self-gates.)
- Add a runner-native path using the vswhere → `Launch-VsDevShell.ps1 -Arch amd64
  -SkipAutomaticLocation` → Git-Bash pattern already proven in the build job.
- **Actually run the consumer acceptance gate.** `test/consumer/` works on Windows (Task 11) and
  passes against a real package with both drivers. Verify is where that must run in CI, on a
  fresh runner that never checks out IREE — the job boundary is Windows's substitute for the
  container's isolation.
- Extend `test/workflow_paths.test.sh` with three checks mirroring the ones it already runs
  against the build job:
  1. **Every Docker-dependent verify step is gated on `matrix.toolchain == 'container'`.**
     Match on the same patterns the build check uses: `docker/` in `uses:`, `docker run` in
     `run:`, and `build_image_tag`/`build_dockerfile` in `run:`.
  2. **A runner-toolchain verify step actually invokes `test/consumer/run.sh`.** The build
     check asserts a runner step calls `build-runtime.sh`; the verify check asserts a runner
     step calls `test/consumer/run.sh`. This is the same defect class: a future conditional
     that silently skips the only thing that matters.
  3. **Every shared (ungated) verify step whose `run:` calls bash tooling sets
     `shell: bash`.** The build check already does this; extend the loop to cover the verify
     job's steps too. Without it, the "Verify checksum" and "Extract" steps would regress
     the moment someone adds a new shared step.

Run this on a temporary branch trigger first (see "How the trial run was done"), not a tag.

**Trial gating for verify work.** The trial-run pattern gates `pin` and `release` at the job
level with `if: startsWith(github.ref, 'refs/tags/')`. The `attest` step is in the **build**
job, not a separate job, so gating it means adding the condition to that step within the
build job. For the verify trial, you want build (including attest) and verify to run freely
while pin+release stay locked to tags. The trigger is a temporary
`push: branches: ['feat/windows-platform-add']` at the top of `release.yml`.

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

The attest step lives in the **build** job (step 12, `subject-path: dist/assets/*.tar.gz`),
not the verify job. It is ungated — it runs on every platform, including Windows, on any
workflow trigger that reaches the build job. Two concerns:

- **Glob resolution on Windows.** `subject-path` takes a glob, and the action resolves it
  internally. Whether it handles backslash paths or pwsh-style globbing on a Windows runner
  is unknown — it has literally never executed there.
- **Cascade to the release notes.** The release job's rendered notes instruct consumers to
  run `gh attestation verify ${tb}` for every variant/platform, including Windows. If
  attestation silently fails or produces no attestation for the Windows tarball, the release
  notes are a false claim. A loud failure (build job goes red) is acceptable; a silent
  absence is not.

**Add a negative control:** after the first successful Windows attestation run, temporarily
break the subject-path glob (e.g. point it at a file that doesn't exist) and confirm the
build job goes red. This is the same discipline as 12b's deliberately-wrong compiler version.

### 4. Then, and only then: 12d — the real tagged release

Cut a real tag and confirm the published assets: both Linux platforms × both variants, plus
`windows-x86_64`/`default`, each with its `.sha256`, all `.tar.gz`. Burning a few tags is
acceptable (`linux-aarch64` took five).

Confirm the Task 6 obligation holds: `notes.msvc_toolset` asserts the archives were built on a
**pinned** `windows-2022` image. The build job pins it; verify and release must too, or the note
is a false provenance claim.

---

## After the release ships — fast-follow, in order

> **Reordered 2026-07-29.** A strategic reframe landed after this plan was written:
> [`notes/2026-07-29-package-port-regime.md`](../notes/2026-07-29-package-port-regime.md) treats
> this repo as a **package port** and replaces the flag-assembly machinery with `cmake -C`
> cache-init files, source patches, observed provenance, and a frozen header list. Five decisions
> are recorded there and all its open questions are closed.
>
> **What this changes about the order below and about §1 above.** §1 (the unimplemented Windows
> `verify` leg) is now *downstream* of the reframe, not the next thing: under the job split it is a
> job you write straight rather than more `if: matrix.toolchain` branches, and under `cmake -C` the
> flag plumbing it would have threaded no longer exists. Do the reframe's sequencing steps 1–2
> before §1, or §1 gets written twice. Item (1) below stays first among the items in this section —
> it is orthogonal to the reframe and unblocks both.
>
> Also read
> [`notes/2026-07-29-compiler-version-is-not-a-c-compiler.md`](../notes/2026-07-29-compiler-version-is-not-a-c-compiler.md)
> **before touching `release.yml`** — there is a TODO comment in it that prescribes the wrong fix.

1. **Matrix simplification** —
   [`notes/2026-07-27-gha-matrix-simplification.md`](../notes/2026-07-27-gha-matrix-simplification.md).
   Split `build`/`verify` into Linux and Windows jobs, scan disk instead of enumerating, and
   rewrite the CLAUDE.md sections that currently encode the removed design as doctrine.
2. **Post-mortem remedies** —
   [`notes/2026-07-27-windows-add-postmortem.md`](../notes/2026-07-27-windows-add-postmortem.md).
   Design-doc habits, principally: read a named reference's *topology* before its facts, and
   state its scope of authority up front.
3. **Org-wide standards review** —
   [`notes/2026-07-27-org-standards-review-fastfollow.md`](../notes/2026-07-27-org-standards-review-fastfollow.md).
   All four production repos, not just the two `*-runtime-dist` instances. Gated on (1) and (2)
   so the review does not codify the shape being remediated.

Item 1 also makes §1 above substantially smaller, but §1 is not blocked on it — sequence by
whichever is ready.

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
