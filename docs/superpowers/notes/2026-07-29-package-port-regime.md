# Strategy: this repo is a package port, not a build

**Date:** 2026-07-29
**Status:** proposed regime change. Not a task list — a reframe that changes which
mechanisms are correct.
**Relationship to other notes:** supersedes the *mechanism* choice in
[2026-07-28-cmake-presets-extraction.md](2026-07-28-cmake-presets-extraction.md) while keeping
several of its findings. See "What carries over" below. It does not touch
[2026-07-27-gha-matrix-simplification.md](2026-07-27-gha-matrix-simplification.md), which is
orthogonal and lands independently.

## The claim

We have been treating this repo as *a build with unusual requirements*. It is not. It is a
**package port**: it takes a third-party source tree at a pinned tag, configures it with a fixed
feature set, repairs upstream defects, fixes up the installed tree so it relocates, and emits an
archive plus provenance metadata.

That is the same job a vcpkg portfile, a Conan recipe, a Homebrew formula, a Debian `rules` file,
or a Spack package does. Those ecosystems converged on a small set of idioms because they all hit
the same four problems we hit. We have been solving those four problems from first principles, in
shell, without knowing they were named problems with known answers.

The sharpest confirmation: `scripts/relocatability.sh` is 221 lines and the most bespoke thing in
the repo. Its repair half is a **built-in** in vcpkg — `vcpkg_cmake_config_fixup`, which rewrites
absolute paths in exported CMake config files to `${CMAKE_CURRENT_LIST_DIR}`-relative form. We
reinvented a solved problem because nothing in our framing told us it was solved.

## What this is not a recommendation to do

**Do not adopt vcpkg or Conan.** The deliverable here is an attested GitHub Release consumed by a
Gradle project via `find_package`. Neither tool does that half, and the install repairs would
simply become portfile patches — the same work in different syntax, plus a dependency our
consumers do not have. The recommendation is to **steal the idioms, not the tool**.

## The measurable symptom

| | Lines |
|---|---|
| Shell (`build-runtime.sh` + `scripts/` + `scripts/lib/`) | 1,688 |
| Tests (`test/*.sh`) | 2,071 |

A 1:1.2 test-to-code ratio is not rigor. It is the signal that the shell contains **logic** rather
than **invocation**. Logic must be tested; invocation mostly need not be. The tests cannot be
deleted without deleting the logic they exist to pin down — which is the actual goal.

Three stages account for most of it, and all three are the same error in different costume:

| Stage | What it does | What it should do |
|---|---|---|
| `cmakeflags.sh` + the flag-assembly block | **Computes** the flag set in shell, with a hand-rolled dedup/priority merge | **Declares** it in a file CMake reads |
| `install-headers.sh` | **Discovers** missing headers by walking the `#include` graph at build time | **Declares** a frozen list, asserts the closure |
| `gen-manifest.sh` provenance | **Reconstructs** recorded values from the arguments that drove the build | **Observes** them from what the build produced |

Ports declare and observe. We compute and reconstruct. Everything downstream — the merge
algorithm, the tests for the merge algorithm, `--print-flags` as a bespoke reimplementation of
"what did we ask for" — is consequence.

## The four idioms, and what each replaces

### 1. Canned configuration → `cmake -C`, **not** `CMakePresets.json`

This is the central mechanism decision and it is where this note diverges from the presets note.

`CMakePresets.json` is read **only from the source directory** — for us, `$IREE_SRC`, a pristine
IREE checkout we do not own. There is no `--preset-file` flag and no search path. Presets are
designed for configuring *your own* project. `cmake -C <script>` is the older mechanism designed
for exactly our case: canned configuration of a tree we do not control, from a file that lives
**in this repo**.

Verified on **CMake 3.28.3** (host) and **CMake 4.3.2** (inside
`iree-runtime-dist-build:linux-x86_64`, which inherits `/usr/local/bin/cmake` from the PyPA
manylinux base). Identical behaviour on every property below — no 3.x/4.x divergence. Three
properties the design depends on:

```bash
cmake -C init.cmake -S src -B build -DOVERRIDE_ME=cmdline-wins
```

- **`include()` composes.** `init.cmake` including `common.cmake` works, so
  `cmake/common.cmake` + `cmake/<platform>.cmake` layering needs no inheritance algorithm of our
  own.
- **`$ENV{}` supplies the dynamic values.** `CMAKE_C_FLAGS` was assembled in the cache-init file
  from `$ENV{IREE_SRC}` and `$ENV{VARIANT_CFLAGS}`, yielding
  `-ffile-prefix-map=/work/iree=iree -fsanitize=thread -g`. The path-dependent flag is composed
  once, in one place, where the path is known.
- **Command-line `-D` still wins.** `set(... CACHE ...)` is non-`FORCE`, so
  `OVERRIDE_ME` resolved to `cmdline-wins`. Overrides keep working for ad-hoc invocations.

Bonus for provenance: cache-init values land in `CMakeCache.txt` **typed**
(`FOO:STRING=from-common`), whereas an ad-hoc `-DX=y` lands as `X:UNINITIALIZED=y`. The keys we
declared are mechanically distinguishable from the ones we passed in passing.

**Why not toolchain-file `CMAKE_<LANG>_FLAGS_INIT`** — the presets note's mechanism. Also verified
on both 3.28.3 and 4.3.2, and it is silently broken on both:

| Invocation | Resulting `CMAKE_C_FLAGS` |
|---|---|
| `-DCMAKE_TOOLCHAIN_FILE=tc.cmake` (control) | `-ffile-prefix-map=/work/iree=iree` |
| `… -DCMAKE_C_FLAGS="-fsanitize=thread -g"` | `-fsanitize=thread -g` |
| `… -DCMAKE_C_FLAGS=""` | *(empty)* |

`cmake_initialize_per_config_variable` does a non-`FORCE` `set(CMAKE_C_FLAGS "${_INIT}" CACHE …)`.
A command-line `-D` has already created that entry, so `_INIT` is **dropped, not merged** — and an
empty string still creates the entry, so this fires on `default` as well as `tsan`. Under the
presets note's design, `-ffile-prefix-map=` / `/d1trimfile:` never reach the compiler on either
variant, and every archive ships with absolute build paths. That is exactly the silent-no-op class
`build-runtime.sh:113` already documents having been bitten by twice.

`-C` has no such trap because we compose the full string ourselves, once.

**Deletes:** `scripts/lib/cmakeflags.sh` (63), `variant_flags`/`_runtime_capability_flags`, the
`TOOLCHAIN_ARGS` array, the ~90-line platform-conditional flag block, and most of
`test/print_flags.test.sh` (70) — `--print-flags` becomes approximately `cat cmake/<platform>.cmake`,
and there is nothing to test about a static file that the build does not already prove.

### 2. Upstream defects → patch files, not post-hoc surgery

Every port ecosystem expresses "upstream is broken here" as a **patch against the source**, applied
before configure. We express it as surgery on the installed tree afterward. The difference that
matters is the failure mode: a patch that stops applying fails **loudly and immediately** on the
next version bump; surgery that no longer matches silently does nothing and ships a broken package.

Concretely: unified diffs we own, in-repo (`patches/…`), applied to `$IREE_SRC` before configure.
This should be the shape for the libbacktrace install rule, the missing header `install(FILES …)`
rules, and the `find_package(Threads)` gap in `IREERuntimeConfig.cmake`.

We do **not** already have this idiom in-tree. The aarch64+tsan interference-size change
(`build-runtime.sh:296`) is `sed -i` plus a post-condition `grep`. That is precedent for *mutating
the checkout*, not for the patch-file idiom, and converting it is the natural first patch.

**Apply with `git apply`, not `/usr/bin/patch`.** The checkout is already a git repo
(`gen-manifest.sh:20` runs `git -C "$IREE_SRC" rev-parse HEAD`), so this is free. It matters because
`patch` fuzzes by default: it matches hunks at an offset, tolerates whitespace drift, applies 3 of 4
hunks, drops a `.rej`, and leaves a half-repaired tree — the exact silent-partial-repair mode this
repo keeps getting bitten by. `git apply` is atomic: all hunks or none.

**Idempotency is a requirement, not a nicety** — CLAUDE.md demands re-runs succeed, and a local
Radxa checkout stays patched between builds. Three outcomes, not two:

```bash
git -C "$IREE_SRC" apply --check "$p" 2>/dev/null && git -C "$IREE_SRC" apply "$p" \
  || git -C "$IREE_SRC" apply --reverse --check "$p" 2>/dev/null \
  || { echo "error: $p neither applies nor is already applied -- upstream changed?" >&2; exit 1; }
```

The third branch is the loud failure that the current `sed`+`grep` pair hand-builds per site. With
`git apply` it is generic and written once.

**The dual-use property is a forcing function, not a convenience.** A patch that must be
presentable as an upstream PR cannot be a local hack — it needs a coherent rationale, minimal scope,
and no dependence on our layout. The `sed` for `iree_hardware_destructive_interference_size` could
never be a PR; the patch replacing it plausibly is one, since upstream already carries a TODO to
test 128.

**Accepted tradeoff:** a patch file is *more* drift-sensitive than a `sed`, because context lines
break on nearby edits and not just the target line. That means more failures on a version bump —
correct here, since we pin one version and a bump is already a gated event with hardware validation.
Loud-and-early beats tolerant-and-silent.

### 3. Discovery → declaration + assertion

`install-headers.sh` walks the real `#include` graph at build time. Its own comment defends this as
version-robust: *"this keeps working unmodified if IREE adds/removes/renames transitive headers in
a future version bump."*

That is a real argument, and the counter-argument is the pin. We build `v3.11.0` and **never**
`main`. A version bump is a deliberate release-engineering event with a full validation pass on
hardware — not something that happens behind our back. We are paying for a dynamic algorithm, plus
its tests, permanently, to insure against an event that already carries a manual gate.

**Freeze the list.** Keep the walker as a *tool run when bumping versions*, not code that runs in
production. Assert the closure is complete at build time so a gap is still loud. Discovery becomes
a maintenance aid instead of a runtime dependency.

### 4. Provenance → observe, never reconstruct

Generalizing the `iree_tag` defect (`gen-manifest.sh:136` reconstructs `"v" + iree_version` while
`gen-manifest.sh:20` observes `runtime_commit` from the same checkout, 116 lines apart): every
recorded value should be read from something that exists *after* the build.

- `build_config` / `cmake_flags` → `CMakeCache.txt`, filtered to the keys the cache-init file
  declares. One authority: what the build actually did.
- `iree_tag` → `git -C "$IREE_SRC" describe`, beside the existing `rev-parse`.
- `msvc_toolset`, `glibc_build` → already observed. These are the model; the rest should match.
- `runtime_commit` → currently computed **twice**, at `gen-manifest.sh:20` and
  `build-runtime.sh:594`. Same duplication class as `iree_tag`; compute once.

### Two commits, not a patch inventory

**Decision (2026-07-29):** record `runtime_commit` (the IREE commit) **and** `runtime_dist_commit`
(ours). Do not enumerate patches or their hashes in the manifest.

The gap this closes is real and predates any patch work: our own commit is recorded **nowhere** in
`manifest.json` or `BUILDINFO` today. Every repair, the packaging, and the whole recipe come from
this repo, and a shipped tarball currently cannot say which version of the recipe produced it.

Once patches exist, `runtime_commit` alone becomes an active under-description — it names a commit
whose tree is *not* what we compiled. (The `sed` at `build-runtime.sh:296` already broke this on
`linux-aarch64`/`tsan`; patches only make it routine.) But per-patch filenames and content hashes are
the wrong fix: the patches live in *our* repo, so `runtime_dist_commit` pins the patch set exactly
and transitively. One hash instead of N, and it's the hash a curious reader can actually act on —
clone the repo at that commit and read `patches/`. A hash list is noise for everyone who does not
already have the repo, and redundant for everyone who does.

**One wrinkle to handle:** a local Radxa build routinely runs from a dirty working tree, and a bare
`rev-parse HEAD` would then attest a commit that isn't what built the artifact — the same defect one
level up. Use `git describe --always --dirty` (or append a `-dirty` marker) so a
locally-built-from-uncommitted-changes tarball says so. CI is always clean, so this only ever annotates
hand builds, which is exactly where it matters.

Nothing derived from an argument that *also* drove the build, because that is two paths to one
fact and they can disagree silently.

This also settles the question the presets note left inverted. `CMakeCache.txt` **is** the source
of truth for `manifest.json` and `BUILDINFO`. The cache-init file is a human-facing preview for
`--print-flags`, which must keep working with no source tree and no build directory
(`test/print_flags.test.sh:11`). They answer different questions, only one is an attestation, and
`--print-flags` output should say so in as many words so nobody greps it for something the manifest
is supposed to answer.

## The only move that actually shrinks the surface: upstream

Every install repair exists because IREE's build has a gap. Four of them, all narrow, all
mechanical, all plausibly acceptable upstream:

1. `install(TARGETS …)` for libbacktrace's archive, and exporting its target.
2. `install(FILES …)` for headers already declared in a target's `HDRS`.
3. `find_package(Threads)` in `IREERuntimeConfig.cmake` before including the targets file.
4. The `printf` subdirectory's install never chaining into the parent.

Patches merged upstream **delete** this code. Everything else in this note relocates it to a better
place. Long fuse, low effort per patch, and worth starting now precisely because it is slow.

## Testing follows the same rule: test artifacts, not mechanics

The tests worth keeping assert properties of the **thing we ship** — `relocatability.test.sh`,
`build_smoke.sh`, `test/consumer/`, `manifest.test.sh`. They survive any rewrite of the machinery
beneath them, which is exactly what makes them valuable.

The tests that pin down flag-composition mechanics exist to protect logic that should not exist.
**Do not delete them as a first move** — delete the logic, and let them fall out. A test deleted
ahead of its subject is how a silent regression ships.

## What carries over from the presets note

**Keep:**
- Principle 2 (no inline Python in shell heredocs) — correct, independent of everything here, and
  the cheapest thing on the list.
- The inventory of what is genuinely static vs. dynamic, with one correction below.
- `find_program(cl REQUIRED)` beating `command -v cl` for compiler selection.

**Drop:**
- `CMakePresets.json` as the mechanism — cannot be read from a source tree we do not own.
- Toolchain files carrying `CMAKE_<LANG>_FLAGS_INIT` — silently dropped, demonstrated above.
- `scripts/resolve-preset.py` — a second resolver of the same data is the `iree_tag` pattern again.
  `CMakeCache.txt` is the one authority.

**Correct:**
- The note files `-ffile-prefix-map=` and `/d1trimfile:` under "platform-determined, not discovered
  at invocation time." Their entire payload is `$IREE_SRC`, and on Windows they additionally need
  `cygpath -w`. They are **path-dependent by construction** — the one category the note's own
  principle 1 assigns to shell. `-C` + `$ENV{}` resolves this cleanly.
- The net-delta table. The ~90 lines being deleted are ~65 lines of *comment*, each recording a
  separately-discovered silent-failure mode (one trailing backslash not two; `/d1trimfile:` trims a
  prefix rather than remapping; POSIX prefixes match nothing so `cygpath -w` is mandatory; dash
  spelling because MSYS2 path-converts a leading `/`; `MSYS2_ARG_CONV_EXCL` scoped to two argument
  prefixes and explicitly not widened). The code should go. **The knowledge cannot.** Those
  comments must land in the cache-init files, which are then ~50 lines each, not 7 — and the real
  delta is far closer to flat. Line count is not the argument here; failure-mode surface is.

## Sequencing

Independently landable, ordered by risk:

1. **Extract inline Python to standalone scripts.** Zero coupling, ships immediately.
2. **`cmake -C` cache-init files.** Deletes `cmakeflags.sh`, the flag block, most of
   `print_flags.test.sh`. Self-contained and the largest single win.
3. **Provenance reads `CMakeCache.txt`.** Fold in the `iree_tag` and `compiler_version` fixes —
   same principle, one pass. (`compiler_version` is the `iree-base-compiler` wheel version, not a C
   compiler; rename to `iree_compiler_version` while here.)
4. **Freeze the header list**, demote the walker to a version-bump tool.
5. **Upstream the four install gaps.** Long fuse, start now.
6. **CI job split** — [gha-matrix-simplification](2026-07-27-gha-matrix-simplification.md),
   orthogonal, any time.

## What this does not change

None of the hard constraints move. `-DIREE_BUILD_COMPILER=OFF` always; never `submodules:
recursive`; `IREE_REQUIRED_SUBMODULES` and `IREE_LINKED_COMPONENTS` stay distinct; upstream CMake
files ship unmodified but for the two sanctioned repairs; v1 is stable `v3.11.0` only. The
relocatability **assertion** stays exactly as strict — if it fires, extend the repair. This note
argues about where configuration and provenance *live*, not about what the artifact must satisfy.

## Decided: CMake is assumed 4.x and deliberately not pinned

**Decision (2026-07-29): assume CMake 4.x, do not attempt to pin it, accept the residual risk.**

Not a compatibility question — `-C` predates everything we care about, and the behaviour verified
above is identical on 3.28.3 and 4.3.2, so this imposes no minimum the way presets v6 would have.
The question was only ever provenance and drift.

Rationale: **the pin is not available where the risk actually lives.** A NEVRA pin is possible
inside the Dockerfile, but GitHub owns the `windows-2022` runner inventory and makes no provision
for pinning CMake. Pinning only the container would be worse than pinning nothing — it would buy a
strong guarantee on the platform that is already stable while leaving the platform we cannot control
silently floating, and the asymmetry would read as "CMake is pinned" to anyone skimming the
Dockerfile. A half-pin hides risk rather than reducing it. This is the one axis where the container's
usual "pin the toolchain" doctrine has no Windows analog, which is the same reasoning
`platform_toolchain` already encodes for the toolchain class as a whole.

Consequence to accept explicitly: a CMake release could change cache-init semantics, default flag
initialization, or export-file generation under us, on either platform, without a repo change. The
gates that would catch it are the ones that test the artifact — the relocatability assertion,
`build_smoke.sh`, and `test/consumer/` — not anything that inspects the toolchain.

**Mitigation, which pinning was never needed for:** record the configure-time CMake version in
`manifest.json`, alongside `msvc_toolset` and `glibc_build`. It is exactly the same class of
attested build-environment fact, it is the only major one currently unrecorded, and it is strictly
more useful than a pin would have been — it makes "which CMake built this artifact" answerable after
the fact for a *shipped* tarball, which a Dockerfile pin cannot do for the Windows half at all.
Observation over reconstruction, per idiom 4.

## Decided: patching `$IREE_SRC` is sanctioned

**Decision (2026-07-29): patching the IREE checkout is allowed as a matter of course.** A
`patches/` directory is a clear, reviewable contract for exactly what we change and why, and CI
clones fresh on every run, so the mutation is invisible where the artifacts are actually produced.

What this buys over the alternatives: a patch states the change as before/after context rather than
as a substitution expression, fails loudly and atomically instead of half-applying, needs no
hand-written post-condition assertion per site, and is the same artifact we would submit upstream.
The rejected alternative is post-hoc surgery on the *installed* tree, which is what we do today and
which fails silently when it stops matching.

**This does not weaken the "upstream CMake files ship unmodified" constraint — it strengthens it.**
That rule governs the files in the shipped prefix (`lib/cmake/IREE/IREETargets-Runtime.cmake` and
friends, guarded by `test/cmake_additions.test.sh`), not the source checkout. A source patch that
makes IREE's build *generate* the right install rules removes the reason to repair the generated
output afterwards. The two sanctioned repairs stay sanctioned and stay narrow; the goal is to need
fewer of them, not more.

**Consequence to accept:** a local checkout stays patched after a build. That is already true of the
`sed` and already flagged as a wart in its comment. Mitigations, in order of preference: the
idempotency guard above means a stale-patched tree is a no-op rather than an error; a
`--unpatch`/reverse-apply path is cheap to add if hand builds start tripping on it; and
`runtime_dist_commit` with `--dirty` makes a hand build from a mutated tree self-identifying either
way.

**CLAUDE.md changes in the same PR**, per the post-mortem's check 5 — the text records what the rule
protects (loud failure over silent partial repair; upstream-submittable diffs) and what was rejected
(installed-tree surgery, `sed` with hand-written post-conditions), not merely that `patches/` exists.

## Decided: cache-init files live in `cmake/` at repo root

**Decision (2026-07-29):** `cmake/common.cmake` + `cmake/<platform>.cmake` at the repo root.

They are **build inputs, not shipped artifacts**, and that distinction is the whole reason to keep
them out of `lib/cmake/IreeRuntimeDist/` — which is the sanctioned home for our own CMake content
*inside the installed prefix*, i.e. files a consumer's `find_package` actually reads. Nothing under
`cmake/` is ever installed, and nothing under `lib/cmake/` is ever a configure-time input. One glance
at the path answers which side of the boundary a file is on.

Sibling to `patches/`, which is the same category: an input we own, applied to a build, never
shipped.

## All questions closed

Every question this note opened has a recorded decision. Implementation order is in
[Sequencing](#sequencing); nothing above is blocked on a further ruling.
