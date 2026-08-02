# Windows platform add — design

**Status:** approved design, ready for an implementation plan.
**Scope:** add `windows-x86_64` as a published platform alongside `linux-x86_64` and
`linux-aarch64`, producing the same attested, hash-pinned artifact shape.
**Evidence base:** `spike/windows-iree-runbook.md` (probes W1–W6) and issue #11. Every claim
below is measured on `winbox`, not assumed. Where the spike's own earlier assumptions were
disproved, the design follows the measurement.

## What the spike already settled

The build works. `default` configures and builds under MSVC with the Linux flag set minus
`-ffile-prefix-map`; the umbrella target links; the install prefix is coherent; and a
**Linux-produced `add.vmfb` loads and runs on Windows under both `local-sync` and
`local-task`**. `test/consumer/consumer.c` compiles unmodified. Of the four packaging repairs,
three apply and `libbacktrace` drops. The notices list is derived. C++17 propagation is a
non-issue. None of that is re-litigated here.

## Decisions

### 1. Toolchain provider: container for Linux, runner-native for Windows

The Linux container exists to pin a known-old compile environment and the clang/lld/ninja
NEVRAs. Windows has no analog and a Windows container would fix none of the Windows-specific
problems, so Windows builds directly on a GitHub-hosted runner via a VS dev-shell → Git-Bash
handoff. This follows the shipped `djl`/ExecuTorch precedent.

**Pin the runner to `windows-2022`, never `windows-latest`.** `msvc_toolset` is attested
provenance: a floating runner label would silently change the recorded value mid-release-series,
which is the same failure mode the Linux Dockerfile's pinned NEVRAs exist to prevent. The pin
makes both platforms consistent in intent — the toolchain is a declared input, not whatever the
provider happens to serve. Moving to a newer image is then a deliberate, reviewable change with
a provenance diff attached, and `runs-on` is derived from the platform token rather than
hardcoded per job.

**The CI toolchain will not be the one the spike measured.** Measured from a real
`executorch-runtime-dist` Windows run on `windows-2022` (which already pins the same label):

| | CI (`windows-2022`) | Spike (`winbox`) |
|---|---|---|
| Visual Studio | 2022 Enterprise, DevShell 17.14.35 | 2026, DevShell 18.8.0 |
| MSVC toolset | 14.44.35207 | — |
| `cl` | **19.44.35228.0** | **19.51.36248** |
| ninja | 1.13.0 (pip) | — |

ET activates via `vswhere` → `Launch-VsDevShell.ps1`, the same pattern as `winbox`'s
`build-iree.ps1`, so the activation approach carries over unchanged. Nothing in the findings is
expected to break, but three items were measured on the newer toolset and must be re-verified on
the pinned image during implementation:

- **`/d1trimfile:`** — undocumented, and the entire relocatability fix depends on it. It has
  existed since well before VS 2022, so this is expected to pass, but it is the highest-value
  thing to confirm first because the fallback is materially different work.
- **`/std:c17`** — MSVC has supported C11/C17 since VS 2019 16.8, so this should be unaffected.
- **`-DIREERuntime_DIR=`** — the `CMAKE_PREFIX_PATH` search change was observed under the CMake
  4.x that ships with VS 2026. A `windows-2022` image may carry CMake 3.x, where the plain
  prefix-path search still works. Setting `IREERuntime_DIR` explicitly is correct on both, so
  this needs no branch; it is recorded only so the finding isn't later read as universal.

Re-verifying these on the pinned image is a task in the implementation plan, not an assumption
carried forward.

Consequence for `scripts/lib/naming.sh`: the platform token currently *implies* a Dockerfile —
`build_image_tag()` and `build_dockerfile()` derive from it unconditionally, and CLAUDE.md
states that adding an arch is "a new `docker/<platform>.Dockerfile` plus a `PLATFORMS` entry,
nothing else." That invariant needs a documented exception, not a silent one.

Add `platform_toolchain(<platform>)` returning `container` or `runner`. `build_image_tag` and
`build_dockerfile` are defined only for `container` platforms and must fail loudly if called
for a `runner` platform. One function answers "how does this platform get its toolchain," and
the coupling stays explicit.

CLAUDE.md's invariant is **reworded as part of this work** rather than left in tension with the
code — see "CLAUDE.md updates" below for the exact replacement text and the other two passages
that change with it.

### 2. Provenance: conditional keys, no schema bump

`gen-manifest.sh` already sets `sanitizer` conditionally, with a matching conditional
`notes.sanitizer`. Windows provenance follows that existing, tested idiom:

- Linux manifests: `glibc_build`, unchanged.
- Windows manifests: **omit** `glibc_build`; add `msvc_toolset` (e.g. `19.51.36248`, from `cl`)
  and `crt` (`MT`).
- Each new key gets a `notes.*` entry. The `crt` note carries the same honesty caveat
  `glibc_build` has: with `/MT` the archives only emit `/DEFAULTLIB:LIBCMT` directives, so the
  CRT is resolved at the *consumer's* final link. It is not a compatibility floor.

`schema_version` stays `2` — the change is purely additive and no existing consumer breaks.
`BUILDINFO` gets the same conditional treatment; it currently writes `glibc_build=`
unconditionally.

Absence of a key is the honest encoding for "this platform has no glibc." A sentinel such as
`"n/a"` was rejected: it ships a meaningless key and invites reading it as "no glibc
requirement," the precise misreading the existing note exists to prevent.

### 3. CRT: a single `/MT` (static) row

The consumer is `djl-iree-engine`'s JNI shim, which links into a DLL; a static CRT avoids
pushing a VC++ redistributable requirement onto every downstream user. One platform token, no
third matrix axis. A `/MD` row is deferred to a follow-on if a CPython-style consumer ever needs
one.

### 4. Packaging: `.tar.gz` everywhere — no change

The earlier "almost certainly `.zip` on Windows" assumption is **withdrawn**;
`executorch-runtime-dist`, which shipped Windows artifacts, kept a single unbranched
`tarball_name()` emitting `.tar.gz` and extracts it on its Windows jobs via Git-Bash. Symlink
and POSIX-mode fidelity is the only capability where the formats differ, and this prefix has
zero symlinks — static archives, headers, and CMake files only. `tar.exe` has been in-box since
Windows 10 1803. Switching would branch `naming.sh`, `gen-pin.sh`, two extract steps and the
upload globs in `release.yml`, and `test/consumer/run.sh` — five currently-unbranched paths, for
convention alone.

The repo is not zip-averse: it already ships `iree-runtime-metadata-*.zip`. Format is per
artifact *kind*, not per platform.

### 5. Matrix: variants become platform-aware

`release.yml` fans out a full `variant × platform` cross-product, so adding the token would
schedule an unbuildable `tsan`/`windows-x86_64` job (TSan is clang/Linux-only).

Make the variant list platform-aware in `scripts/lib/variants.sh`: `known_variants <platform>`
returns `default tsan` for Linux platforms and `default` for Windows, with `variants_json`
taking the same argument and the setup job emitting per-platform lists. An `exclude:` block in
YAML was rejected because CLAUDE.md requires the variant list be single-sourced and never
hardcoded in a workflow; `exclude:` would put platform knowledge back into YAML.

### 6. Consumer-gate isolation: from the job boundary

The Linux gate gets "never seen the build tree" from a container. Windows takes the same
guarantee from the **job boundary**: the verify job runs on a fresh runner, downloads only the
release asset, and never checks out `iree-org/iree`. This is the same guarantee by a different
mechanism, not a weaker one.

To keep it honest rather than implied, `test/consumer/run.sh` gains an explicit assertion that
no IREE source tree or build directory is reachable. That makes the property testable on both
platforms instead of being a side effect of the container on one.

## Relocatability — the largest item

W6 measured this and it is materially bigger than W4's `-natvis:` finding suggested.

**All 191 archives embed absolute build- and source-tree paths.** On `iree_base_base.lib`: 22
occurrences before stripping, **9 surviving `llvm-objcopy --strip-debug`**. The survivors are
`__FILE__` expansions baked in by IREE's status/assert macros — string-table content in the link
surface, which is why they survive stripping. They are absent on Linux only because the recipe
passes `-ffile-prefix-map==iree`.

**Be precise about what this is.** These strings do **not** break relocation — the artifact
links and runs from any directory with them present. By the assertion's own stated rationale
(DWARF is exempt because it "does not affect whether or where the archive links"), `__FILE__`
constants sit in the same category. The reasons to remove them are **parity with the Linux
standard** and **not publishing the build machine's directory layout** — not functional
correctness. This matters because it sets the fallback below: if removal turns out to be
expensive, what we lose is parity and tidiness, not a working artifact.

`executorch-runtime-dist` is the counter-example and should be read accurately. It uses **no**
path-trimming flag and its Windows gate still reports
`GATE PASS: windows-x86_64 artifact is relocatable AND links under MSVC` — because
`test/relocatability-windows.sh` is a *functional* check (extract elsewhere, `find_package`,
link, run), not a string scan. Its Windows archives almost certainly carry the same absolute
paths; its gate does not look for them. **ET's shipped precedent therefore does not validate
"no absolute paths in Windows archives."** It clears a lower bar, deliberately.

### The DWARF exemption does not apply and must not be widened

`RELOC_ALLOW_DEBUG_PATHS` is the wrong tool three times over:

1. It never fires on Windows — `build-runtime.sh:417` gates it on `variant_sanitizer` being
   non-empty, and Windows is `default`-only.
2. It cannot see these files — the case pattern at `scripts/relocatability.sh:107` is
   `*.a|*.o|*.so|*.so.*`, so `.lib` falls to the `*)` branch and is treated as a real leak. Its
   tool is `objcopy`, which would need to be `llvm-objcopy` for COFF.
3. It should not exempt them anyway — 9 of 22 survive stripping, so by the assertion's own logic
   they are real leaks. Widening the exemption to swallow them is exactly the "weaken the
   assertion" move CLAUDE.md forbids.

**The exemption stays gated to sanitizer variants and stays off for Windows.**

### Fix: prevention at compile time

Pass `/d1trimfile:<source-root>\` on Windows, the direct analog of `-ffile-prefix-map==iree`.
Measured on cl 19.51.36248 (VS 2026), compiling by absolute path as CMake/Ninja does:

| Invocation | resulting `__FILE__` |
|---|---|
| baseline, no flag | `C:/Users/cored/trimtest/sub/foo.c` |
| `-d1trimfile:C:\Users\cored\trimtest\` | `sub/foo.c` |

Exit 0, no warning or "unrecognized flag" diagnostic.

Two caveats for implementation. It *trims a prefix* rather than remapping to a token, so Windows
yields `sub/foo.c` where Linux yields `iree/...`; relocatability only cares that the absolute
path is gone, but the two platforms' `__FILE__` strings will not be identical. Generated sources
under the build tree likely need a second trim prefix.

It is an undocumented `/d1` flag and could disappear in a future toolset. The mitigation is that
the assertion is the backstop — if the flag stops working, the assertion fails loudly rather
than silently shipping leaks. **Wire the Windows assertion before depending on the flag.**

### Fallback policy: parity first, ET's functional gate on the first real obstacle

**Target Linux parity** (`/d1trimfile:` + the string-scan assertion). **On the first genuine
obstacle, drop to ET's functional gate** — port `test/relocatability-windows.sh` and gate on
extract-elsewhere-and-link instead. Do not escalate, do not invent workarounds, and above all do
not widen `RELOC_ALLOW_DEBUG_PATHS` to make the scan pass.

This is pre-authorised, so the implementer switches without re-opening the design. It trips on
any of:

- `/d1trimfile:` does not work on cl 19.44 (the CI toolset), or is rejected/warned on it;
- it works for source files but generated sources under the build tree still leak, and covering
  them needs more than one additional trim prefix;
- the string scan stays red for a reason that would require touching the exemption or the
  assertion's own logic to clear.

It does **not** trip on ordinary implementation friction — a wrong prefix, a quoting bug, a
missed `.lib` case in the assertion. Those are bugs to fix, not obstacles.

If the fallback is taken, record it in the spec and issue #11 with the specific failure, and
note that Windows then holds a weaker relocatability standard than Linux — visible and
deliberate, not silent. The `-natvis:` repair below is **not** part of the fallback: it is a
text-file leak that reaches a consumer's link line, so it is required under either bar.

**Decided (W8, spike/windows-iree-runbook.md): parity bar taken.** `/d1trimfile:` was measured
directly on cl `19.44.35228` for x64 — the exact pinned CI toolset (VS 2022 Enterprise, toolset
14.44.35207), via a throwaway `windows-2022` GitHub Actions run, not the earlier `winbox` cl 19.51
(VS 2026) reading. Baseline `__FILE__` was absolute (`C:\trimtest\sub\foo.c`), the trimmed build
was relative (`sub\foo.c`), both compiles exited 0, and no warning/error/unrecognized-flag
diagnostics appeared. None of the trip conditions above fired. Tasks 8–9 implement Linux parity:
the string-scan assertion plus `/d1trimfile:` as compile-time prevention.

### The `-natvis:` repair

`IREETargets-Runtime.cmake`'s **`INTERFACE_LINK_OPTIONS`** carries
`-natvis:C:/…/iree/runtime/iree.natvis`, an absolute source path that would reach a consumer's
link line — three occurrences, each sharing the option list with `-pdbpagesize:32768`, which
must survive the repair untouched. (An earlier draft placed this in `iree_runtime_impl`'s
`INTERFACE_LINK_LIBRARIES`; that was wrong, and the correction matters because the repair has
to be surgical within a shared list rather than dropping a whole property.) This is a text-file repair in `IREETargets-Runtime.cmake` and falls **inside** the
existing `relocatability_repair` sanctioned exception — it does not create a third exception to
CLAUDE.md's "upstream CMake files ship unmodified" rule. Text files are never exempt from the
assertion, so the DWARF relaxation never applied to it.

### Assertion port

Add `.lib`/`.obj` to the assertion's file-type handling and use `llvm-objcopy` for COFF. Per
CLAUDE.md, the assertion is only meaningful when fed the paths that could actually leak — on a
runner-native build those are the runner's real workspace paths, not invented ones.

## Recipe changes

**Skip the libbacktrace repair on Windows.** `build-runtime.sh:299`, `:304`, `:346`–`:358` are
unconditional and hardcode `.a` names. Guard on platform identity, **not** on "does the archive
exist" — an existence check would silently no-op if the Linux archive ever went missing, turning
a loud failure into a quiet one. The guard carries a comment in the surrounding style recording
that Windows drops libbacktrace outright and is **not** substituting `dbghelp` (measured: zero
`dbghelp` references in the export set, zero stack-walking symbols in
`iree_runtime_unified.lib`).

**Port `install-headers.sh`.** This is the one genuine unknown remaining. The spike unblocked
the header gap with a blanket `cp -rn`, which is not a port — it drags `.c` files and private
headers into the prefix, where `install-headers.sh` deliberately walks the real `#include`
graph. It uses shell tooling over paths, so separators and case-sensitivity are both plausible
failure points. **Sequence this early in the plan**, with rework budgeted, so a surprise
surfaces before CI wiring is built on top of it.

**Ports unchanged:** the printf subdirectory's second `cmake --install`, and the
`find_package(Threads)` insertion into `IREERuntimeConfig.cmake`.

**Notices.** `linked_components()` gains a platform parameter, returning
`flatcc printf libbacktrace` for Linux and `flatcc printf` for Windows, with the W4 derivation
recorded in the file's prose the way the Linux derivation already is. `gen-notices.sh:44` passes
the platform through. (The musl rejection note already landed separately.)

## Tests

- `test/build_smoke.sh` — `NM=${NM:-nm}` and `.a`→`.lib` globs (`:38`, `:46`, `:52`, `:96`,
  `:306`). It already fails loudly on a Windows prefix rather than producing a false green;
  `llvm-nm` emits BSD 3-column output structurally identical to GNU nm, and the existing awk
  selector (`:283`) works unchanged.
- `test/consumer/` — CMake gains `/std:c17` (MSVC's default C mode predates C11 and rejects
  `_Generic`) and `-DIREERuntime_DIR=<prefix>/lib/cmake/IREE` (CMake 4.x no longer searches
  `lib/cmake/` from `CMAKE_PREFIX_PATH`). **`consumer.c` stays unmodified.** Compiling it as C++
  to dodge `_Generic` cascades into C7555/C4576/C7560 and breaks the rule that the gate is only
  meaningful while the consumer is what a real consumer would write.
- `test/manifest.test.sh` — platform-conditional provenance: assert `glibc_build` on Linux,
  `msvc_toolset`/`crt` on Windows, and assert each is **absent** on the other. The mutual-absence
  assertion is what stops the two provenance models silently merging later.
- `test/relocatability.test.sh` — Windows-shaped fixtures covering both the `__FILE__` case and
  the `-natvis:` text-file case.

## CLAUDE.md updates (a deliverable of implementation)

Three passages in CLAUDE.md assert invariants this design changes. They are **not** edited when
this spec lands — CLAUDE.md is loaded as authoritative instruction in every session, so it must
not describe a `platform_toolchain()` that does not yet exist. They are edited in the same change
that introduces each mechanism, and a PR that adds the mechanism without the wording is
incomplete.

### 1. The build-image invariant (currently at CLAUDE.md:79–91)

Today: "…adding an arch is a new `docker/<platform>.Dockerfile` plus a `PLATFORMS` entry,
nothing else."

Replace the invariant clause with:

> Not every platform is containerised. `platform_toolchain()` in `naming.sh` classifies each
> platform as `container` or `runner`. Container platforms (all Linux) take their toolchain from
> `docker/<platform>.Dockerfile`, and adding one is that Dockerfile plus a `PLATFORMS` entry,
> nothing else. Runner platforms (Windows) have no Dockerfile — the toolchain comes from a pinned
> GitHub runner image plus a VS dev-shell activation, and `build_image_tag`/`build_dockerfile`
> fail loudly if called for one. The container exists to pin a known-old glibc and the
> clang/lld/ninja NEVRAs; that has no Windows analog, and a Windows container would fix none of
> the Windows-specific problems. Pin the runner label (`windows-2022`, never `windows-latest`)
> for the same reason the Dockerfile pins NEVRAs: `msvc_toolset` is attested provenance and must
> not drift silently.

The existing trailing sentence — that the Dockerfile is the single source of truth for the
toolchain pins and the `glibc_build` value — must be scoped to container platforms, since a
runner platform has neither a Dockerfile nor a `glibc_build`.

### 2. The `manifest.json` provenance passage

Today it describes `glibc_build` as unconditional. It must state that provenance keys are
platform-conditional: `glibc_build` on container platforms, `msvc_toolset` + `crt` on Windows,
each absent on the other, `schema_version` unchanged at `2`. The existing warning that
`glibc_build` is not a compatibility floor stays as-is and gains its `crt` counterpart — with
`/MT` the archives carry only `/DEFAULTLIB:LIBCMT` directives, so the CRT resolves at the
consumer's final link.

### 3. The variant-matrix passage

Today: "Variants are single-sourced in `scripts/lib/variants.sh`: `known_variants`
(`default tsan`)…". It must record that `known_variants` and `variants_json` take a platform
argument, that Windows is `default`-only because TSan is clang/Linux-only, and that the
exclusion lives in `variants.sh` rather than an `exclude:` block — keeping the rule that a
variant list is never hardcoded in a workflow.

## Explicitly out of scope

- **A `/MD` CRT row.** Deferred; see decision 3.
- **The `native_module_cc.h` upstream bug.** `iree/vm/native_module_packing.h` references
  `iree_vm_buffer_t` without including `iree/vm/buffer.h`, so any TU whose first IREE include is
  `native_module_cc.h` fails to compile. It is standard-independent, reproduces on Linux `g++`,
  and affects the shipping `v3.11.0-10` artifacts. It is upstream, pre-existing, and unrelated
  to Windows — folding it in would let a platform-add PR change the C++ header surface. It
  belongs in its own issue.
- **Any `tracy` variant.**

## Risks

| Risk | Mitigation |
|---|---|
| `install-headers.sh` needs non-trivial rework | Sequenced early; rework budgeted rather than assumed away |
| `/d1trimfile:` is undocumented, and unverified on cl 19.44 | Assertion wired first, so failure is loud; pre-authorised fallback to ET's functional gate on the first genuine obstacle |
| CI toolchain (cl 19.44) differs from the spike's (cl 19.51) | Three items re-verified on the pinned image as an explicit plan task, `/d1trimfile:` first |
| `windows-2022` eventually deprecates | Pin is a declared input; migration is a reviewable change with a provenance diff, not a silent drift |
| Runner-native build is less hermetic than a container | Job-boundary isolation plus an explicit no-source-tree assertion in the consumer gate |
| Generated sources need a second trim prefix | Implementation detail; the assertion catches it if missed |
