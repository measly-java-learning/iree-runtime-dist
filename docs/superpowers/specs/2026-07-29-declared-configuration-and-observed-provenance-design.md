# Declared configuration and observed provenance

**Date:** 2026-07-29
**Status:** approved design, ready for an implementation plan.
**Source note:** [2026-07-29-package-port-regime.md](../notes/2026-07-29-package-port-regime.md).
This spec implements items **1, 2, and 3** of that note's Sequencing section and nothing else.
**Baseline:** commit `4bb545b` (`wip: GHA matrix simplification checkpoint`). That commit is
deliberately non-working — `windows-x86_64` is broken at the verify stage in it — and exists as a
revert target, not as a releasable state. See [The WIP overlap](#the-wip-overlap).

## Why

The regime note's diagnosis: this repo is a package port, and ports **declare** their
configuration and **observe** their provenance. We compute configuration in shell and reconstruct
provenance from the arguments that drove the build. Two paths to one fact can disagree silently,
and the flag-assembly block is the single largest concentration of that error.

This spec moves configuration into `cmake -C` cache-init files that CMake reads directly, and
makes `manifest.json`/`BUILDINFO` read what the build actually produced. It does not touch the
artifact contract: every hard constraint in CLAUDE.md holds unchanged, and the relocatability
assertion stays exactly as strict.

## Verified CMake behaviour this design depends on

All four probes were run this session on CMake 3.28.3. The note additionally verified `-C`
composition and command-line-`-D` precedence on 4.3.2 inside
`iree-runtime-dist-build:linux-x86_64` with identical results.

1. **Multiple `-C` files compose in order.** Later files see and can extend earlier files' cache
   values (`b.cmake` appended to `a.cmake`'s `CMAKE_C_FLAGS`, yielding
   `-base=/work/iree -fsanitize=thread -g`). Variant layering needs no `include()` chain.
2. **Appending across `-C` files requires `FORCE`**, because the earlier file already created the
   entry.
3. **Command-line `-D` wins even against a `FORCE`d cache-init `set()`.** `-C` files load before
   `-D` entries are applied. Ad-hoc overrides keep working. **But the override resets the entry's
   type to `UNINITIALIZED`** — so the note's idea that typed-vs-`UNINITIALIZED` mechanically
   distinguishes declared keys from ad-hoc ones is false for any key someone overrode. Provenance
   must filter by declared key *name*.
4. **`-C` does not fix the `CMAKE_<LANG>_FLAGS_INIT` clobber.** A cache-init file setting
   `CMAKE_C_FLAGS` drops the platform `_INIT` contribution exactly as a command-line `-D` does
   (control with a toolchain file: `-DFROM_INIT`; with `-C` as well: `-DFROM_CACHE_INIT`, `_INIT`
   gone). The restated MSVC platform defaults remain load-bearing and must move into the Windows
   cache-init file. Do not delete them as "solved by `-C`".

Finding 4 is the one that would have shipped a silent defect. `build-runtime.sh`'s current comment
records `-EHsc` being clobbered as a real observed failure — run 30281540210, dead 322 objects in
on `third_party/benchmark`. Migrating to `-C` does not change that mechanism at all.

## The `cmake/` layer

### Invocation

```bash
cmake -C cmake/common.cmake \
      -C cmake/<platform>.cmake \
      -C cmake/variant-<variant>.cmake \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -S "$IREE_SRC" -B "$BUILD_DIR"
```

One `-C` file per axis: universal, platform, variant. `CMAKE_INSTALL_PREFIX` is the only remaining
`-D`, because it is the only value that is genuinely per-invocation.

### Files

| File | Contents |
|---|---|
| `cmake/dist-set.cmake` | The `dist_set()` macro (below). Included by each of the others. |
| `cmake/common.cmake` | 19 declared entries: the 11 from `common_flags()`, the 7 from `_runtime_capability_flags()`, and `CMAKE_INSTALL_LIBDIR=lib` (today a bare `-D` at the `cmake` call, and not per-invocation). Does not touch `CMAKE_C_FLAGS`/`CMAKE_CXX_FLAGS`. |
| `cmake/gnu-toolchain.cmake` | `CMAKE_C_COMPILER=clang` / `CMAKE_CXX_COMPILER=clang++`, and `-ffile-prefix-map=$ENV{IREE_SRC}=iree` into `CMAKE_C_FLAGS`/`CMAKE_CXX_FLAGS`. Composed here, once, where the path is known — these flags are path-dependent by construction, which is why they cannot live in `common.cmake`. |
| `cmake/linux-x86_64.cmake` | One `include()` of `gnu-toolchain.cmake`. |
| `cmake/linux-aarch64.cmake` | One `include()` of `gnu-toolchain.cmake`. |
| `cmake/windows-x86_64.cmake` | `CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded`; `find_program(... cl REQUIRED)` for both compilers; the restated MSVC platform defaults; `/d1trimfile:$ENV{IREE_SRC_NATIVE}\`. |
| `cmake/variant-default.cmake` | Deliberately declares no compiler flags. Present, with a comment saying why an empty file is correct rather than missing. |
| `cmake/variant-tsan.cmake` | Appends `-fsanitize=thread -g` (`FORCE`, per finding 2), with the why-not-`RelWithDebInfo` rationale. |

Putting every capability and build-type entry in one file makes the "`default` and `tsan` cannot
drift on capability" property structural in the strongest available form: there is only one file
that can state them, and neither variant file can reach them.

The two Linux platform files are one line each rather than one shared `cmake/linux.cmake`, so the
`-C` path is derived directly from the platform token with no platform→file mapping in shell. A
missing file is a loud `cmake` error. Adding a platform is adding a file — the same shape as
"adding a container platform is a Dockerfile plus a `PLATFORMS` entry".

### Compiler selection moves too

`TOOLCHAIN_ARGS` at `build-runtime.sh:320` currently branches on `platform_toolchain()` — a
function the baseline commit already deleted — to pick `clang`/`clang++` versus `cl`. That branch
becomes two lines in the two toolchain files, which also resolves the standing `TODO` beside it
noting that a future macOS platform would use clang *without* being containerised: the scissor was
never container-vs-runner, it was which compiler, and a per-platform file states that directly.

Windows uses `find_program(CL_EXE NAMES cl REQUIRED)` rather than a `command -v cl` guard, per the
presets note's retained finding. `REQUIRED` fails at configure with CMake's own diagnostic, and the
resolved absolute path is what lands in the cache — so recorded provenance names the exact `cl`
used, not whatever `PATH` resolved at the time.

### `cygpath` stays in shell

`cygpath` is a Git-Bash tool, not a CMake concept, and `execute_process()`-ing it from inside a
cache-init file would put computation in a file whose whole purpose is declaration.
`build-runtime.sh` exports `IREE_SRC_NATIVE` (`cygpath -w "$IREE_SRC"`) alongside `IREE_SRC` on
Windows, and `cmake/windows-x86_64.cmake` consumes `$ENV{IREE_SRC_NATIVE}`.

Deleting `--print-flags` retires the `cygpath`-absent fallback, whose only justification was
hermetic flag-assembly tests on a non-Windows host. A real Windows build always has `cygpath`, so
its absence becomes a loud failure instead of a silently prefix-less `/d1trimfile:`.

### Hazards that die, and the one that does not

- **`MSYS2_ARG_CONV_EXCL` goes away.** It exists only because `/d1trimfile:` is passed as
  `-DCMAKE_C_FLAGS=/...`, whose value begins with `/`. Composed inside a cache-init file, the
  string never crosses MSYS2's argument converter.
- **The empty-`IREE_SRC` branch goes away.** It existed only to keep `--print-flags` working with
  no source tree.
- **The `_INIT` clobber does not go away** (finding 4). The restated `-DWIN32 -D_WINDOWS` (C) and
  `-DWIN32 -D_WINDOWS -GR -EHsc` (C++) move into `cmake/windows-x86_64.cmake` unchanged.

### The comments are the payload

The ~90 lines being deleted from `build-runtime.sh` are ~65 lines of comment, each recording a
separately-discovered silent-failure mode: one trailing backslash not two; `/d1trimfile:` trims a
prefix rather than remapping to a token; a POSIX-flavoured prefix matches nothing so `cygpath -w`
is mandatory; dash spelling because MSYS2 path-converts a leading `/`; the MSVC defaults being
clobbered rather than merged. **Every one of these must land in the cache-init files.** This is not
a line-count win and the implementation must not be judged as one — the cache-init files will be
~50 lines each, not 7, and the real delta is close to flat. What improves is failure-mode surface,
not size.

## Provenance

### The declared-key registry

`gen-manifest.sh` must know which of `CMakeCache.txt`'s hundreds of entries are ours. Grepping the
`cmake/` files for that list would be a second parser of the same data — the `iree_tag` mistake in
new clothing. Instead the declaration site registers itself:

```cmake
# cmake/dist-set.cmake
macro(dist_set key value type doc)
  set(${key} "${value}" CACHE ${type} "${doc}")
  set(_k "${IREE_DIST_DECLARED_KEYS};${key}")
  set(IREE_DIST_DECLARED_KEYS "${_k}" CACHE INTERNAL "keys this recipe declares")
endmacro()
```

Verified to accumulate correctly across separate `-C` files:
`IREE_DIST_DECLARED_KEYS:INTERNAL=;FOO;BAR;BAZ`. A macro is not a cache variable and does not
persist between `-C` scripts, so each `-C` file begins with
`include("${CMAKE_CURRENT_LIST_DIR}/dist-set.cmake")`.

`CMAKE_C_FLAGS` and `CMAKE_CXX_FLAGS` are declared through `dist_set` too, not a bare `set()` —
they must appear in `build_config`, and `sanitizer` is derived from one of them. Because the
variant file re-declares `CMAKE_C_FLAGS` to append to it, a key can be registered more than once;
the leading empty element in the verified output above shows the list is not sanitized either. The
macro deduplicates (`list(REMOVE_DUPLICATES)`) and drops empty elements, so the registry is a set.
`test/cmake_init.test.sh` does not need to know about this, but the manifest reader must not emit a
key twice.

`build_config` is then: read `IREE_DIST_DECLARED_KEYS`, emit those keys with their post-build
values from the same cache. Filtering is by **key name, not entry type**, per finding 3 — an
overridden key would otherwise vanish from recorded provenance precisely when it differs from what
we declared, which is the only interesting case.

### Field sources

| Field | Today | After |
|---|---|---|
| `build_config` | `effective_cmake_flags` re-run | `CMakeCache.txt` ∩ `IREE_DIST_DECLARED_KEYS` |
| `crt` | grep `effective_cmake_flags` output | `CMAKE_MSVC_RUNTIME_LIBRARY` from the cache |
| `sanitizer` | `variant_sanitizer "$VARIANT"` | `-fsanitize=thread` present in the cache's `CMAKE_C_FLAGS` |
| `iree_tag` | `"v" + iree_version` | `git describe --tags --abbrev=0`, the tag unstripped |
| `runtime_commit` | computed twice (`gen-manifest.sh:20`, `build-runtime.sh:594`) | once, in `gen-manifest.sh` |
| `cmake_version` | absent | `CMAKE_CACHE_{MAJOR,MINOR,PATCH}_VERSION` from the cache |
| `runtime_dist_commit` | absent | `git describe --always --dirty` on this repo |
| `iree_compile_version` | published key | **unchanged.** Only the internal shell name `COMPILER_VERSION` → `IREE_COMPILER_VERSION` |
| `clang_version` | absent | `clang --version \| head -1`, parsed beside `msvc_toolset`, `linux-*`-conditional |
| `glibc_build`, `msvc_toolset` | observed | unchanged — these are the model the rest now matches |

`cmake_version` comes from the cache rather than a separate `cmake --version` call for the same
reason as everything else here: the cache is what the build used.

`runtime_commit` is computed once by `gen-manifest.sh` (Phase 3, `build-runtime.sh:570`), and the
Phase-3 template step at `build-runtime.sh:593` reads it back out of the just-emitted
`manifest.json` rather than re-running `git rev-parse`. Ordering already favours this — the
manifest is generated 23 lines earlier — and it makes template and manifest provably agree instead
of coincidentally agreeing.

`clang_version` closes the gap the compiler-version note identified: Linux manifests carry
`glibc_build` but the compiler that actually built the archives is attested only indirectly, via
the pinned NEVRAs in `docker/<platform>.Dockerfile`. Same shape as `msvc_toolset` — detected where
the compiler lives, from the tool's own banner, `"unknown"` on failure rather than a guessed value.
Provenance, not a compatibility claim.

`runtime_dist_commit` needs the same `safe.directory` treatment `$IREE_SRC` already gets at
`build-runtime.sh:207`: this repo is also a bind mount under a container running as root, and
without it the call fails in CI but not on a bare host run — exactly the divergence that idiom
exists to prevent. `--dirty` matters because a local Radxa build routinely runs from an
uncommitted tree; CI is always clean, so the marker only ever annotates hand builds, which is
where it is needed.

### `schema_version` stays `2`

**Corrected 2026-07-29, after
[2026-07-29-compiler-version-is-not-a-c-compiler.md](../notes/2026-07-29-compiler-version-is-not-a-c-compiler.md).**
An earlier draft of this spec bumped to `3` to cover a `compiler_version` → `iree_compiler_version`
rename. That premise was wrong: the manifest's published key is already `iree_compile_version`, and
that note explicitly forbids renaming it — it is already unambiguous and it is schema surface. The
rename is **internal only**: the shell/CLI name `COMPILER_VERSION` → `IREE_COMPILER_VERSION`.

So no published key changes shape. `cmake_version`, `clang_version`, and `runtime_dist_commit` are
purely additive and break no consumer, which is the same criterion under which the
platform-conditional `glibc_build`/`msvc_toolset`/`crt` keys were added while staying at `2`.
Bumping with nothing broken would train consumers to ignore the number.

The internal rename touches `scripts/derive-version.sh`, `.github/workflows/release.yml`,
`scripts/gen-addvmfb.sh`, `scripts/gen-manifest.sh`, `scripts/gen-tsan-docs.sh`, and
`build-runtime.sh`. The misleading `release.yml` TODO that note documents (proposing
`compiler_version=$(clang --version)`) is deleted in the same pass; acting on it would replace an
ABI-pairing version with a toolchain version under the same key.

`manifest.test.sh` asserts the new fields, that `schema_version` is still `2`, and that
`iree_compile_version` is unchanged.

### Inline Python leaves the shell

Regime note item 1, and the cheapest thing on the list. `scripts/gen-manifest.sh` is the only
remaining site: a `python3 -c` at line 102 parsing `effective_cmake_flags` output into
`build_config`, and a `python3 - <<'EOF'` heredoc at line 122 emitting `manifest.json`.

- The line-102 parser is **deleted, not extracted** — its input no longer exists. Reading
  `CMakeCache.txt` filtered by `IREE_DIST_DECLARED_KEYS` replaces it.
- The line-122 heredoc becomes `scripts/emit-manifest.py`, a standalone script `gen-manifest.sh`
  invokes. It keeps the existing argv discipline: every value is passed as an argument, never
  interpolated into the source, so a value containing a quote or backslash cannot break the parse
  or smuggle content into the JSON. Extraction makes that property structural rather than
  comment-enforced, and makes the file lintable and directly runnable.

The `CMakeCache.txt` reader is part of `emit-manifest.py` rather than a third script: it parses a
file and produces JSON keys, which is the same job.

### `gen-manifest.sh` gains a `<build-dir>` argument

Consequence to accept explicitly: the manifest can no longer be regenerated from an installed
prefix alone — it needs the build tree that produced it. That is the point of observing rather than
reconstructing, not a regression. During implementation, check whether any `release.yml` step
regenerates a manifest without the build tree.

## Deletions

**Deleted outright:**

- `scripts/lib/cmakeflags.sh` (63 lines) — `common_flags`, `platform_cmake_flags`,
  `effective_cmake_flags`
- `build-runtime.sh`: `--print-flags` (flag parsing, early exit, usage text), the ~90-line
  platform-conditional flag block, `TOOLCHAIN_ARGS`
- `scripts/lib/variants.sh`: `_runtime_capability_flags`, `variant_flags`, `variant_cflags`,
  `variant_sanitizer` — the file shrinks to `known_variants` alone
- `test/print_flags.test.sh` (4.5K)

**Why `--print-flags` goes rather than becoming `cat cmake/<platform>.cmake`:** the `cmake/` files
*are* the human-facing view of the build inputs, and a command that reformats them is a second view
of the same data. Nothing in CI consumes it (`gen-manifest.sh` calls `effective_cmake_flags`
directly, not the CLI), so removing it costs no automation. It is referenced by CLAUDE.md and both
platform runbooks; all three are updated in the same PR.

**Updated:**

- `test/lib_variants.test.sh` — down to `known_variants` coverage
- `test/manifest.test.sh` — new fields; `schema_version` still `2`; `iree_compile_version` unchanged
- `scripts/gen-manifest.sh` — new `<build-dir>` argument, no longer sources `cmakeflags.sh`, no
  inline Python

**Added:** `cmake/` (8 files), `scripts/emit-manifest.py`, `test/cmake_init.test.sh`.
- `build-runtime.sh:587` — the `gen-tsan-docs.sh` gate becomes `[ "$VARIANT" = tsan ]` rather than
  a `variant_sanitizer` test
- `scripts/derive-version.sh`, `.github/workflows/release.yml`, `scripts/gen-addvmfb.sh`,
  `scripts/gen-tsan-docs.sh` — the `COMPILER_VERSION` → `IREE_COMPILER_VERSION` internal rename,
  plus deleting the misleading `release.yml` TODO

### The replacement test

`print_flags.test.sh` is today the only hermetic check that `-EHsc` is present in the Windows C++
flags and absent from the C flags, and that guard exists because its absence killed a real CI run
322 objects into a 40-minute build. "Nothing to test about a static file" is true about *values*
and false about *deletions*: a static file can still be edited wrong.

New `test/cmake_init.test.sh`, roughly 40 lines, asserting:

1. `cmake/<platform>.cmake` exists for every `known_platforms` entry, and
   `cmake/variant-<variant>.cmake` exists for every `known_variants "<platform>"` entry on every
   platform.
2. `cmake/windows-x86_64.cmake` declares `-GR -EHsc` in the C++ flags and not in the C flags.

Assertion 1 also catches "added a platform, forgot the file" — a failure mode that does not exist
today because there are no per-platform files yet.

## Validation

**The acceptance gate is a cache diff.** Before changing anything, configure each affected
combination on the baseline and capture `CMakeCache.txt` filtered to the 19 declared keys plus
`CMAKE_C_FLAGS`/`CMAKE_CXX_FLAGS`. After the migration, re-configure and diff. The expected diff
is exactly:

- entry types change (declared keys go from `UNINITIALIZED` to typed), and
- one new `IREE_DIST_DECLARED_KEYS` entry appears.

Any *value* difference is a defect. This gate needs only *configure* to succeed, which is what
makes the Windows row checkable at all given the baseline's broken verify stage.

| Combination | Where | Gate |
|---|---|---|
| `linux-x86_64` × `default`, `tsan` | dev host, inside `iree-runtime-dist-build:linux-x86_64` | cache diff, full build, `build_smoke.sh`, `test/consumer/run.sh` |
| `linux-aarch64` × `default`, `tsan` | Radxa | cache diff, full build, `build_smoke.sh`, `test/consumer/run.sh` |
| `windows-x86_64` × `default` | winbox over SSH | cache diff only |

Every affected variant/platform is built on hardware before commit. The Windows row is the one
explicit exception: configure parity proven, build and verify parity **unproven**, because they are
already broken on the baseline. Fixing that is not in this spec.

The Linux rows run the recipe end to end *inside* the container, so the relocatability assertion
sees container-internal build and source paths — checking for leaked host paths that never appear
in the build would make the assertion pass trivially.

`bash test/run.sh` (hermetic) passes on every commit. `test/consumer/run.sh` runs in a clean
container with no build tree and no IREE source, since relocatability, link surface, and
compile-define propagation are exactly what a configuration rewrite could break invisibly.

The IREE checkout used for validation is a `v3.11.0` checkout. **Never
`/home/corey/workspace/iree`** — that one tracks `main`.

## Documentation

CLAUDE.md changes land in the same PR, per the Windows post-mortem's check 5, and record what each
rule protects rather than merely that a file exists:

- Key commands: drop the `--print-flags` line.
- Architecture: rewrite the `effective_cmake_flags` paragraph. In particular "the static-CRT choice
  must be greppable in its output" becomes "declared in `cmake/windows-x86_64.cmake` and observed
  from `CMakeCache.txt`".
- New boundary rule: `cmake/` holds build inputs, `lib/cmake/IreeRuntimeDist/` holds shipped
  artifacts a consumer's `find_package` reads. Nothing under `cmake/` is ever installed; nothing
  under `lib/cmake/` is ever a configure-time input. One glance at the path answers which side a
  file is on.
- New constraints, all verified: command-line `-D` beats a `FORCE`d cache-init `set()`; `-C`
  setting `CMAKE_<LANG>_FLAGS` drops the platform `_INIT` contribution, so the restated MSVC
  defaults stay load-bearing; an overridden entry loses its type, so provenance filters by declared
  key name.
- Variant matrix section: `variant_cflags`/`variant_sanitizer` are gone; `variants.sh` owns
  `known_variants` only.
- manifest.json section: `schema_version` stays `2` and why (additive only); the new
  `cmake_version`, `clang_version`, and `runtime_dist_commit` fields; and `crt`/`sanitizer`/
  `iree_tag` now being observed rather than reconstructed. Also record that
  `iree_compile_version` is deliberately **not** renamed despite the internal
  `COMPILER_VERSION` → `IREE_COMPILER_VERSION` change, so the next reader doesn't
  "finish" the rename into schema surface.

`spike/windows-iree-runbook.md:89` and `spike/macos-iree-runbook.md:135` both instruct the reader to
regenerate flags with `--print-flags`; both are rewritten to read the `cmake/` files.
`docs/superpowers/notes/2026-07-29-package-port-regime.md` gets a status line pointing at this spec
and noting which of its items remain unimplemented, plus the finding-3 and finding-4 corrections to
its own text.

## The WIP overlap

Baseline `4bb545b` is partial. Naming it concretely so the implementer does not meet it cold:

- It deletes `platform_toolchain()` from `scripts/lib/naming.sh` while `build-runtime.sh:100` still
  calls it. This spec deletes that call site outright — the branch becomes the per-platform
  cache-init file — so this spec **completes** the WIP's deletion rather than superseding it.
- Its two `TODO`s in the flag block ("`platform_toolchain = container` is the wrong scissor"; "MSVC
  and MSYS values don't need to be buried in an `if`") are resolved by deletion. Both were correct
  diagnoses; neither needs a separate fix.
- CLAUDE.md still documents the helpers `4bb545b` deleted (`platform_toolchain`, `build_image_tag`,
  `build_dockerfile`). That drift is fixed by this spec's CLAUDE.md pass.
- `release.yml` is otherwise independent: nothing in CI consumes `--print-flags`.

## Out of scope

Each named so it does not drift out of view:

- The `patches/` idiom and converting the `iree_hardware_destructive_interference_size` `sed` at
  `build-runtime.sh:296` — regime note idiom 2, its own spec.
- Freezing the header list and demoting `install-headers.sh` to a version-bump tool — item 4.
- Upstreaming the four install gaps — item 5, a long-fuse external track.
- Finishing the GHA matrix simplification — item 6, and the baseline here.
- Fixing the `windows-x86_64` verify-stage break.

## Accepted risks

- **CMake stays unpinned**, as already decided in the regime note: the pin is unavailable on the
  runner platform, and a container-only half-pin would hide risk rather than reduce it. Recording
  `cmake_version` in `manifest.json` is the mitigation, and is strictly more useful for a shipped
  tarball than a Dockerfile pin could be.
- **The Windows half ships with configure parity proven and build parity unproven.** The gates that
  would catch a real Windows regression are the artifact gates — the relocatability assertion,
  `build_smoke.sh`, `test/consumer/` — and they cannot run until the verify break is fixed
  separately.

## What does not change

No hard constraint moves. `-DIREE_BUILD_COMPILER=OFF` always; never `submodules: recursive`;
`IREE_REQUIRED_SUBMODULES` and `IREE_LINKED_COMPONENTS` stay distinct; upstream CMake files in the
shipped prefix stay unmodified but for the two sanctioned repairs; v1 is stable `v3.11.0` only.
`CMAKE_BUILD_TYPE` stays `Release` for both variants. The relocatability assertion stays exactly as
strict — if it fires, extend the repair. This spec changes where configuration and provenance live,
not what the artifact must satisfy.
