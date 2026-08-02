# GHA matrix simplification

**Date:** 2026-07-27
**Status:** revised 2026-07-27 after review against `/home/corey/workspace/executorch-runtime-dist`.
The original proposal is preserved below each amended section as *"Original proposal"* so the
reasoning trail stays legible.

**Motivation:** The Windows-platform-add work overbaked the single-source-of-truth discipline.
`PLATFORMS`, `known_platforms()`, `known_variants()`, and their JSON serializers exist
solely to feed a dynamic matrix in `release.yml` — but that same information is already
implicitly present in the artifacts that land on disk, and in the `include:` block of a
hard-coded matrix. The shell libraries should own naming *helpers* and flag *mappings*, not
enumeration of what CI topology exists.

## Revised diagnosis: the culprit is one matrix spanning two toolchain classes

The original note blamed enumeration in the shell libraries. That is the symptom, not the cause.

`executorch-runtime-dist` is the working example, but not for the reason first assumed. Its
`scripts/lib/naming.sh` is 6 lines and `scripts/lib/variants.sh` is 11 — no enumeration at all.
The reason it *can* be that small is not that enumeration was deleted; it is that **Windows is a
separate job**. See `release.yml:118-128` there: a `build-windows` job with a literal
`platform: [windows-x86_64, windows-x86_64-static]` and `variant: [logging]`, never a fifth row
in the Linux matrix.

Our causal chain runs:

> one matrix must cover Windows → a cross-product would schedule `tsan`/`windows-x86_64` → so
> `known_variants` becomes platform-aware → so a bare `variants_json` must fail loudly rather
> than emit `[]` → so the workflow can no longer use two independent matrix axes → so it needs a
> precomputed `pairs` list → so it needs the 30-line Python step in `setup` → so it needs
> `toolchain` in every matrix row → so it needs six `if: matrix.toolchain == …` step guards
> inside one job → so it needs `platform_toolchain` exported as a matrix input → so it needs
> `container_platforms` as its complement for the image builders.

Every item on the original §5 removal list is downstream of that single decision. Split the job
and most of the list falls out for free rather than being hand-deleted.

## Current state

`scripts/lib/naming.sh` and `scripts/lib/variants.sh` carry platform and variant
enumeration that feeds three separate paths:

| Consumer | What it uses | Why |
|---|---|---|
| `release.yml` setup job `pairs` step | `known_platforms`, `known_variants`, `platform_toolchain`, `runner_for` | Generates JSON for the build/verify matrices |
| `release.yml` "Render release notes" step | `known_platforms`, `known_variants` | Enumerates all artifacts in the release body |
| `scripts/gen-pin.sh` | `PLATFORMS`, `known_variants` | Generates URL/SHA entries for `IreeRuntimePin.cmake` |
| `scripts/build-image.sh` | `container_platforms` | Builds Docker images for container platforms |
| `.github/workflows/warm-build-image.yml` | `containers_json` | Warms the GHA layer cache for container platforms |
| `build-runtime.sh` | `known_platforms` | Validates `--platform` argument |

The setup job's `pairs` step is a 30-line bash pipeline that constructs JSON from these
functions — you cannot tell what jobs will run by reading the workflow; you must trace the
shell script.

## Proposed changes

### 1. Split `build` and `verify` into Linux and Windows jobs

Not "hard-code the unified matrix." Hard-coding the `include:` block **freezes the causal chain
above in YAML instead of dissolving it**, and it does so at a cost:

- The `build` job remains one job with two mutually exclusive halves interleaved by `if:`
  (`release.yml:160,170,172,183` gate on `container`; `211,225` gate on `runner`; the verify job
  adds `331,364`). That interleaving *is* the reason you cannot tell what runs by reading the
  workflow. A literal `include:` block does not touch it.
- It loses the loud failure. A literal `include:` block will happily accept a hand-added
  `tsan`/`windows-x86_64` row; nothing rejects it. Today that combination is structurally
  unrepresentable, which is the one thing the current complexity actually buys.

Instead, follow the executorch shape: `build` (Linux, containerised) and `build-windows`
(runner, VS dev shell), each with its own literal matrix, and the same split for verify.

```yaml
# build (Linux)
strategy:
  fail-fast: false
  matrix:
    variant: [default, tsan]
    combo:
      - { platform: linux-x86_64,  runner: ubuntu-latest }
      - { platform: linux-aarch64, runner: ubuntu-24.04-arm }

# build-windows
strategy:
  fail-fast: false
  matrix:
    variant: [default]
    platform: [windows-x86_64]
    # windows-2022, never windows-latest -- msvc_toolset is attested provenance
    # and must not drift silently when GitHub re-points the label.
```

With the split, the Linux matrix can go back to two independent axes (a real cross-product,
because within Linux the cross-product is valid), and `tsan`/`windows` is unschedulable because
no job spans both. The `toolchain` matrix key and all six `if: matrix.toolchain == …` guards
disappear — a containerised step lives in the containerised job.

The `setup` job drops its `pairs` step and `outputs.pairs`. The remaining outputs
(`iree_version`, `iree_tag`, `compiler_version`, `submodules`) stay.

> **Original proposal:** replace `fromJson(needs.setup.outputs.pairs)` with a single literal
> `include:` block listing all five variant/platform rows, keeping one `build` job. Superseded
> for the two reasons above.

**Cost this incurs, which the original note did not budget for:** splitting duplicates the
checkout / submodule-init / package / attest / upload boilerplate across two jobs. Executorch
pays the same cost and absorbs it with composite actions (`.github/actions/checkout-executorch`,
`.github/actions/lstm-roundtrip`). We have none. Budget one or two composite actions, or
knowingly accept ~40 duplicated lines. Do not discover this mid-implementation and retreat to
the unified matrix.

### 2. Make `gen-pin.sh` scan assets on disk

Unchanged from the original proposal, and confirmed against the working example: executorch
already ships exactly this shape — `scripts/discover-pin-rows.sh` emits `variant\tplatform\tsha`
triples that feed `gen-pin.sh --row`, so the generator never enumerates anything.

Instead of iterating `PLATFORMS` × `known_variants` to construct expected filenames, scan
`$ASSETS/*.sha256` and read whatever is present:

```bash
for shafile in "$ASSETS"/*.sha256; do
    read -r sha tb < "$shafile"
    # tb = iree-runtime-3.11.0-default-linux-x86_64.tar.gz
    rest="${tb#iree-runtime-${VERSION}-}"
    rest="${rest%.tar.gz}"
    variant="${rest%%-*}"       # default
    platform="${rest#*-}"       # linux-x86_64
    echo "set(IREE_RUNTIME_DIST_${variant}_${platform}_URL ...)"
    echo "set(IREE_RUNTIME_DIST_${variant}_${platform}_SHA256 ${sha})"
done
```

The parse depends on the naming convention that no variant token contains a hyphen and
every platform token does — true for `default`, `tsan`, `tracy` (future) and `linux-x86_64`,
`linux-aarch64`, `windows-x86_64`. A unit test for this parse would catch a future variant
that accidentally includes a hyphen.

**Amendment — do not silently drop the completeness check.** `gen-pin.sh:34` currently hard-errors
on a missing sha file. `needs:` on the build/verify jobs makes that *mostly* redundant, but not
entirely: a partial `actions/download-artifact` would produce a short pin file, and the release
step globs `release/*.tar.gz`, so nothing downstream catches an under-populated release. The
scan must assert a nonzero row count, and fail loudly at zero. That is the floor; asserting an
expected count is better but requires enumeration we are removing, so the nonzero check is what
we get.

If an unexpected asset is present (e.g. a stale file), it gets a pin entry — loud and harmless.

### 3. Make the release notes scan files on disk

Unchanged. Same pattern in the "Render release notes" step: scan `release/*.tar.gz`, parse names,
group by variant and platform, list them. No dependency on `known_platforms` or `known_variants`.

### 4. Glob `docker/*.Dockerfile` — do not hard-code container platforms

Apply this note's own §2 principle consistently. The existence of `docker/<platform>.Dockerfile`
*is* the fact that `<platform>` is a container platform; a hardcoded list is a second copy of
that fact, and `warm-build-image.yml` would make it a third.

`scripts/build-image.sh` replaces `container_platforms` with a glob over `docker/*.Dockerfile`,
stripping the extension to recover the platform token. `warm-build-image.yml` keeps a small
discovery step that does the same glob and emits JSON — YAML cannot glob directly, but that step
is three lines of `ls`, not an enumeration function in a shared library.

> **Original proposal:** hard-code `[{linux-x86_64, ubuntu-latest}, {linux-aarch64,
> ubuntu-24.04-arm}]` in `warm-build-image.yml` and a literal list in `build-image.sh`.
> Superseded: globbing is strictly better and is the same move as §2.

Note the runner label still has to be mapped somewhere (a Dockerfile does not know it needs
`ubuntu-24.04-arm`), so `warm-build-image.yml`'s discovery step carries that two-entry mapping
inline. That is one copy, in the file that uses it.

### 5. Remove dead functions from shell libraries

**From `naming.sh` — remove:**
- `PLATFORMS` / `known_platforms()`
- `platforms_json()`
- `container_platforms()` / `containers_json()`

**From `variants.sh` — remove:**
- `known_variants()` / `variants_json()`

**What stays in `naming.sh`:**
- `asset_stem` / `tarball_name` / `sha_name` — used by `package.sh`
- `build_image_tag` / `build_dockerfile` / `_require_container_platform` / `BUILD_IMAGE_REPO` — Docker image identity
- `platform_toolchain` — but **demoted**. After the job split it is no longer a matrix input or a
  step-guard source; its only remaining callers are `_require_container_platform` and the
  `--platform` guard below. It stays as an internal validator/classifier, not an enumerator.

**What stays in `variants.sh`:**
- `variant_cflags` / `variant_sanitizer` / `variant_flags` / `_runtime_capability_flags` — used by `build-runtime.sh` and `gen-manifest.sh`

### 6. Keep `build-runtime.sh`'s `--platform` guard

> **Original proposal:** remove the `known_platforms | grep -qx "$PLATFORM"` guard, on the
> grounds that "the `case` statements in `effective_cmake_flags` already fail loudly."

That premise is true — `scripts/lib/cmakeflags.sh:34` returns 2 on an unknown platform — but the
conclusion does not follow. The guard at `build-runtime.sh:79` fires at **argument-parse time**,
before a multi-hour clone and build; the `case` statement fires wherever the first call happens
to land, which is well downstream. `build-runtime.sh` is a human-facing CLI run by hand on the
Radxa, where every affected variant/platform gets validated on hardware before commit — those
runs are long, and a typo'd `--platform` should cost seconds, not hours.

Keep the guard. It does not need `known_platforms` — rewrite it as:

```bash
platform_toolchain "$PLATFORM" >/dev/null \
  || { echo "error: unknown --platform '$PLATFORM'" >&2; exit 2; }
```

which validates against a function §5 keeps anyway.

### 7. Test changes

| Test | Change |
|---|---|
| `test/lib_naming.test.sh` | Remove tests for `known_platforms`, `platforms_json`, `container_platforms`, `containers_json`. Keep `platform_toolchain` tests — it survives as a classifier. |
| `test/lib_variants.test.sh` | Remove tests for `known_variants`, `variants_json` |
| `test/gen_pin.test.sh` | Replace `known_platforms` iteration with direct file creation; add a parse test for the tarball-name split; **add a test that a zero-asset directory fails loudly** (§2 amendment) |
| `test/workflow_paths.test.sh` | See below |

**`workflow_paths.test.sh` — corrected.** The original table proposed cross-checking the
hardcoded matrix against `known_platforms` "still in the libs during transition, then removed,"
which leaves the test asserting nothing once the transition completes. After the job split, the
assertions that survive removal and still carry meaning are:

- the `build-windows` / `verify-windows` jobs' `runs-on` is literally `windows-2022`, never
  `windows-latest` (msvc_toolset provenance must not drift)
- every `platform` in the Linux matrix has a corresponding `docker/<platform>.Dockerfile` on disk
- the Windows jobs declare `shell: bash` where the step body is bash
- the Docker-gating checks, now expressed as "the Linux job builds an image, the Windows job
  never references `docker/`"

## What does not change

- `package.sh` still uses `tarball_name`/`sha_name` to name files — it *produces* assets and needs to know the naming convention.
- `manifest.json`'s platform-conditional provenance keys (`glibc_build` vs `msvc_toolset`/`crt`) are untouched; they are derived from `effective_cmake_flags` and the build environment, not from any enumeration being removed.
- The verify job's Windows leg still needs implementation (see
  `docs/superpowers/plans/2026-07-27-windows-platform-add-handoff.md` §1). The job split makes
  this **nearly trivial** rather than merely easier: it becomes a `verify-windows` job written
  straight, instead of a set of `if: matrix.toolchain == 'runner'` branches threaded through a
  job whose other half is containerised.

## CLAUDE.md must change in the same PR

`CLAUDE.md` currently encodes the design being removed as doctrine — the "Variant matrix" section
states that the Windows/tsan exclusion "lives in `variants.sh` rather than a workflow `exclude:`
block, for the same single-source-of-truth reason as the rest of this section: a variant list is
never hardcoded in a workflow," and the "Architecture" section describes `platform_toolchain` as
feeding the matrix. Both become false.

Rewrite those two sections in the same PR. Otherwise the next session re-derives the complexity
straight from the docs, which is how it arrived the first time.

## Order of operations

1. Split `build` into `build` (Linux) and `build-windows`; split `verify` the same way. Remove
   the `pairs` step and `outputs.pairs`. Factor shared steps into composite actions if the
   duplication exceeds ~40 lines.
2. Rewrite `gen-pin.sh` to scan disk, with the nonzero-row assertion. Update `gen_pin.test.sh`.
3. Rewrite the release-notes step to scan disk.
4. Glob `docker/*.Dockerfile` in `build-image.sh` and in `warm-build-image.yml`'s discovery step.
5. Remove the dead enumeration functions from `naming.sh` and `variants.sh`.
6. Rewrite `build-runtime.sh`'s `--platform` guard onto `platform_toolchain`.
7. Update `workflow_paths.test.sh` and the unit tests.
8. Rewrite `CLAUDE.md`'s "Variant matrix" and "Architecture" sections.
9. Implement the verify job's Windows leg (handoff plan §1) on the simplified workflow.

Steps 1–8 ship as a single PR. Step 9 is blocked on nothing from 1–8 but is substantially
smaller once step 1 lands.
