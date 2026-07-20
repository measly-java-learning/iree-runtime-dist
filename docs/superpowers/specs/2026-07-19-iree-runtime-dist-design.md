# `iree-runtime-dist` — Design

**Date:** 2026-07-19
**Status:** Approved design, pending implementation plan
**Inputs:** `iree-runtime-dist-wishlist.md` (consumer requirements from `djl-iree-engine`),
`executorch-runtime-dist` (reference project for the overall shape)

## Purpose

`iree-runtime-dist` builds the IREE **runtime** from source and publishes it as attested,
hash-pinned tarballs that `djl-iree-engine` consumes without ever building IREE itself.

The organizing principle from the wishlist holds: the dist owns anything requiring the **IREE
source tree**, the **build configuration**, or the **matching compiler**. But grounding the
wishlist against IREE's actual CMake changes where the work is. Unlike ExecuTorch — whose dist
exists because upstream will not build `-fPIC` — IREE's upstream build is largely fine. This
project's value concentrates in three areas upstream does not cover:

1. **Relocatable packaging** of a real install tree.
2. **Compiler↔runtime pairing**, verified rather than asserted.
3. **Generated constants and a smoke artifact** that remove downstream guesswork.

### Grounding findings that shaped this design

These were verified against the local IREE checkout (`/home/corey/workspace/iree`) and reference
build tree (`/home/corey/workspace/iree-build`) during design. They are recorded because each one
removed or reshaped a requirement.

- **Upstream already ships a runtime CMake package.** `build_tools/cmake/IREERuntimeConfig.cmake.in`
  and `install(EXPORT)` machinery exist (`build_tools/cmake/CMakeLists.txt:35-44`). The config
  includes `IREETargets-Runtime.cmake`, the full export set with each target's `INTERFACE`
  properties.
- **But `cmake --install` alone installs neither archives nor headers.** Discovered during
  implementation (Task 4): `build_tools/cmake/iree_install_support.cmake:66,94` marks the
  library install rules `EXCLUDE_FROM_ALL`, so a bare `cmake --install` yields only `bin/`
  and `lib/cmake/`. The export set is still generated and complete — 197
  `IMPORTED_LOCATION` entries — but every one points at a `lib/*.a` that was never
  installed, so `find_package` succeeds and the *link* fails. That is a worse failure mode
  than a missing package. The install must name components explicitly:
  `IREEDevLibraries-Runtime` (headers + archives), `IREEBundledLibraries` (flatcc et al.),
  and `IREECMakeExports` (config). `IREETools-Runtime` is excluded to keep the artifact
  contract at lib/include/share; `IREEDevLibraries-Compiler` must never be installed.
- **Therefore wishlist item #2 largely dissolves — conditional on that install being right.**
  Its five sub-problems — archive selection,
  transitive flatcc archives, compile defines, split include dirs, link ordering — are all CMake
  target properties carried by that export set. They were painful downstream *only* because the
  build was never installed. Confirmed specifically for the hardest one: the
  `IREE_ALLOCATOR_SYSTEM_CTL` define is passed via `DEFINES` (public) on the `base` target
  (`runtime/src/iree/base/CMakeLists.txt:82`), so it propagates as an
  `INTERFACE_COMPILE_DEFINITIONS` entry through the export set. The dist's job on #2 shrinks from
  "reconstruct the link surface" to "run install, verify relocatability, add what upstream omits."
- **Upstream omits a version file.** There is no `write_basic_package_version_file`, so
  `find_package(IREERuntime 3.11)` with a version argument fails today. The dist supplies one.
- **Both CPU drivers coexist in one build.** The reference build tree has
  `IREE_HAL_DRIVER_LOCAL_SYNC=ON` and `IREE_HAL_DRIVER_LOCAL_TASK=ON` simultaneously. A
  compiled-in driver is not a *used* driver — selection happens at runtime by device URI. This
  collapses the wishlist's proposed `minimal`/`perf` variant split (see §3).
- **`llvm-project` is 2.6 GB; `flatcc` is 3.5 MB.** Every `third_party/llvm-project` reference
  under `runtime/` is a documentation comment. The single real reference
  (`CMakeLists.txt:982`) is to an in-tree shim declaring `INTERFACE` libraries with
  `add_dependencies` on MLIR tablegen targets that do not exist when `IREE_BUILD_COMPILER=OFF`.
  This makes a minimal submodule set very likely but **not yet proven** (see §8, Task 1).

## 1. Scope

**v1 ships:** the `default` variant for `linux-x86_64`, built from IREE stable tag **`v3.11.0`**
(`e4a3b04`), paired with pip stable `iree-base-compiler==3.11.0`.

**Explicitly deferred:** `devtools` variant (Tracy + allocation statistics), the GPU axis,
`windows-x86_64`, a TSan CI leg, and a tiered PR gate. Each is a milestone, not a gap.

**Explicitly out of contract:** the IREE **compiler**. The dist builds with
`-DIREE_BUILD_COMPILER=OFF` and never builds, ships, or vendors `iree-compile`. The compiler
appears in exactly two places, both as a reference: a version string in `manifest.json`, and a
CI-time pip wheel used to produce the smoke artifact.

Two consequences follow from that exclusion and are load-bearing:

- Only the `Runtime` export set installs; no `IREECompilerConfig.cmake` ships.
- **LLVM is never linked into the shipped artifact.** The wishlist's item #9 assumed otherwise.
  Third-party notices must therefore be collected from the *actual installed link surface*, not
  from a listing of IREE's `third_party/` directory — bundling LLVM's notices would over-claim.

## 2. The artifact contract

One tarball per {variant × platform}, unpacking to a single top-level directory:

```
lib/                      # static archives
  cmake/IREE/             # upstream IREERuntimeConfig.cmake + IREETargets-Runtime.cmake (untouched)
  cmake/IreeRuntimeDist/  # dist additions (version file + umbrella target)
include/                  # merged source + generated headers
share/iree-runtime-dist/
  manifest.json           # pairing + build-config attestation
  element_types.json      # generated from IREE_HAL_ELEMENT_TYPE_*
  status_codes.json       # generated from iree_status_code_t
  add.vmfb                # compiled by the paired compiler
LICENSE
THIRD-PARTY-NOTICES/
BUILDINFO
```

### CMake package

Upstream's `IREERuntimeConfig.cmake` and `IREETargets-Runtime.cmake` ship **unmodified**, so the
link surface tracks upstream rather than being re-derived. The dist adds, alongside them:

- `IREERuntimeConfigVersion.cmake` — the file upstream omits.
- `IreeRuntimeDist.cmake` — a thin layer defining one curated `iree-runtime-dist::runtime`
  umbrella target and exposing `manifest.json` fields as CMake variables.

The consumer links one target and can version-check. Upstream remains authoritative for what that
target actually pulls in.

### `manifest.json`

Answers wishlist items #3 and #7 in one tested schema:

- **Pairing:** `iree_tag`, `runtime_commit`, `iree_compile_version`, and the HAL/VM module ABI
  version the runtime expects — so a consumer can fail fast with a clear message instead of a
  cryptic VM import signature mismatch.
- **Build-config attestation:** PIC, HAL drivers, executable loaders, build type,
  `BUILD_SHARED_LIBS`, allocator, glibc floor.

Also recorded here as durable knowledge: **the pip `iree-base-runtime` wheel is not linkable** —
no headers, no static libraries, at any version. Only a from-source build yields a linkable runtime.

### Generated, not transcribed

`element_types.json` and `status_codes.json` are emitted by a small C program compiled against the
just-built runtime, `#include`-ing IREE's own headers. The wishlist's concrete bug — hard-coding
`FLOAT_32 = 0x00000120` when the real value is `0x21000020` — becomes structurally impossible
rather than something review must catch.

### `add.vmfb`

Compiled by the paired compiler in the same CI run. Because only the dist has the matching
compiler, only the dist can ship an artifact guaranteed to load. A consumer can then smoke-test
"the runtime loads and runs a known module" **without needing a compiler at all**.

## 3. Variants

The wishlist proposed `minimal` (local-sync) and `perf` (+local-task) as separate tarballs. The
reference build shows both drivers compiling into one build, and driver selection is a runtime
choice by device URI (`local-sync://` vs `local-task://`). They therefore collapse into a single
`default` variant carrying both drivers and both executable loaders (`embedded-elf`,
`system-library`).

This halves the release matrix and removes a class of "consumer downloaded the wrong tarball"
bugs. The wishlist's TSan concern moves with it: threads appear only when `local-task` is
selected, so thread-safety coverage becomes a property of a *consumer test configuration* rather
than of a build variant.

`devtools` (Tracy + allocation statistics) remains a genuine variant — tracing carries overhead
that must not be in the ship default — and is deferred to a later milestone.

## 4. Repo layout

Mirrors `executorch-runtime-dist`'s proven shape:

```
build-runtime.sh            # single entrypoint
scripts/lib/
  variants.sh               # variant -> cmake flags
  cmakeflags.sh             # common flags + effective_cmake_flags (composes/dedupes)
  naming.sh                 # tarball/sha/asset naming
  submodules.sh             # IREE_REQUIRED_SUBMODULES
scripts/
  derive-version.sh         # tag -> IREE tag + compiler version
  gen-manifest.sh
  gen-constants.sh
  gen-pin.sh
  package.sh
emit/                       # C constant-emitter + add.mlir
test/                       # hermetic *.test.sh + consumer e2e
.github/workflows/release.yml
```

`scripts/lib/*.sh` are sourced by both the build and CI so the two cannot drift — when changing
what they define, change it there, not at a call site. `--print-flags` prints the full effective
cmake flag set per variant without building.

**Dropped from the ExecuTorch template:** `extras/` (no first-party IREE ops in scope), the USDT
machinery, the Windows CRT machinery (deferred with per-platform artifacts), and the tiered PR
gate (worth building only once there is a release to gate against).

## 5. Build recipe

```
build-runtime.sh --variant <default> --prefix <dir> --iree-src <checkout> [--build-dir <dir>]
```

Runs inside `quay.io/pypa/manylinux_2_28_x86_64` with clang/lld 21.1.8 and CPython 3.12 installed
into it — building *against* an old glibc rather than repairing a new build afterward. Clang is
independent of the container's glibc, so installing a recent clang into an old-glibc base is the
strategy, not a workaround. The recipe **never clones IREE**; the caller supplies a checkout
(CI via `actions/checkout`, locally via a mount).

Four phases:

1. **Configure, build, install.** `IREE_BUILD_COMPILER=OFF`, `BUILD_SHARED_LIBS=OFF`, `Release`,
   PIC, `IREE_ALLOCATOR_SYSTEM=libc`, drivers `local-sync` + `local-task`, loaders `embedded-elf`
   + `system-library`. Then run `cmake --install` — the step the walking skeleton skipped, and
   the one that makes the export set real.
2. **Relocatability repair, then verification.** Scrub absolute paths from `lib/cmake`; build with
   `-ffile-prefix-map=` so `__FILE__` in status strings and DWARF `DW_AT_comp_dir` stay relative;
   exclude build-tree metadata (`CMakeCache.txt`, `compile_commands.json`) from the tarball; scrub
   RPATH/RUNPATH on any shipped shared object. Then **assert** it: grep the entire staged prefix
   for the build path and fail on any hit. Repair is a step; the assertion is the contract.
3. **Generate.** Compile and run the constant emitter against the just-built runtime. Collect
   notices for the actual link surface. Write `manifest.json` and `BUILDINFO` from
   `effective_cmake_flags`, so provenance cannot diverge from the build that produced it.
4. **Pair.** `pip install iree-base-compiler==3.11.0`, compile `add.mlir` to `add.vmfb`, record
   the compiler version and module ABI into the manifest.

The recipe is idempotent: re-runs must not fail on already-patched sources or existing build trees.

## 6. Versioning

Release tag `v<iree-version>-<pkgrev>`, e.g. `v3.11.0-1`. `<pkgrev>` bumps re-roll the same IREE
version after a recipe fix.

Anchoring v1 on the **stable** `v3.11.0` tag rather than `main` is what keeps this simple: stable
pip `iree-base-compiler==3.11.0` pairs with it by construction, so no nightly-resolution machinery
is needed. This also directly forecloses the walking skeleton's version-mismatch saga, which was
caused by precisely the mix being rejected here — a runtime built from `main` (`3.12.0.dev`)
against a stable `3.11.0` compiler.

Tracking `main` later would key the release on the paired *nightly compiler* version instead
(deriving the runtime commit from it, rather than hunting for a compiler after the fact). That
path is deferred, not designed away.

## 7. Testing

Test-first, in two layers.

**Hermetic shell unit tests** (`test/*.test.sh`, no build and no container, seconds to run, every
PR): naming, variant flag composition, version derivation, manifest schema, pin generation,
notice collection, and the required-submodule set.

**Consumer e2e — the acceptance gate.** In a clean container with no build tree and no IREE
source: extract the tarball, `find_package(IREERuntime)`, compile a small C consumer, load the
shipped `add.vmfb`, run it, and assert the numeric result. Run it once per device URI
(`local-sync://`, `local-task://`); the `local-task` pass is where a TSan leg lands later.

This single test transitively proves relocatability, correct link surface, compile-define
propagation, compiler↔runtime ABI pairing, glibc floor, and that both drivers work. Passing in a
container that has never seen the build tree is precisely the property the wishlist's
`IREE_INSTALL`-points-at-a-build-tree escape hatch lacks.

Structural assertions run alongside it as cheap checks: PIC via relocations, glibc floor via
symbol versions, absence of absolute paths, expected and unexpected symbols.

Shell scripts run under `set -euo pipefail`. `grep` exits 1 on no-match, which aborts under
`set -e`/`pipefail`; guard these with `|| true`.

## 8. CI

Pushing a version tag is the **only** release trigger. Jobs: `setup` (derive version, resolve
commit) → `build` (matrix over variant × platform; attest each tarball) → `verify` (consumer e2e
in a clean container) → `pin` (generate `IreeRuntimePin.cmake`) → `release`. `verify` gating
`release` is the structural expression of test-first: no artifact publishes without proving itself
consumable.

### Submodule exclusion

CI must not do `submodules: recursive` — `third_party/llvm-project` alone is 2.6 GB and, with
`IREE_BUILD_COMPILER=OFF`, is expected to be unnecessary. The required set is a named, tested
constant in `scripts/lib/submodules.sh`:

```yaml
- uses: actions/checkout@v4
  with: { repository: iree-org/iree, ref: v3.11.0, submodules: false, fetch-depth: 1 }
- run: git submodule update --init --depth 1 $IREE_REQUIRED_SUBMODULES
```

**Task 1 of implementation is to determine that set empirically**, because the hypothesis
(`third_party/flatcc` alone, plus `third_party/tracy` for the later `devtools` variant) is
well-grounded but unproven — the local build that demonstrated `IREE_BUILD_COMPILER=OFF` had all
submodules present. The experiment is cheap: clone `v3.11.0` with `--filter=blob:none --depth 1`,
init only `third_party/flatcc`, and configure. It either succeeds or fails naming the missing
submodule. Either outcome yields the true minimal set in minutes, which is then codified and
asserted by a hermetic test.

## 9. Downstream consumption

Downstream projects do not build this recipe. They pull a release's generated
`IreeRuntimePin.cmake` (recording URL + SHA-256 per variant/platform), `FetchContent` the pinned
tarball (re-verified on every build), and `find_package(IREERuntime)` against the extracted
prefix:

```cmake
include(cmake/IreeRuntimePin.cmake)

include(FetchContent)
FetchContent_Declare(iree_runtime
  URL      "${IREE_RUNTIME_URL_default_linux-x86_64}"
  URL_HASH "SHA256=${IREE_RUNTIME_SHA256_default_linux-x86_64}"
)
FetchContent_MakeAvailable(iree_runtime)

find_package(IREERuntime REQUIRED
  PATHS "${iree_runtime_SOURCE_DIR}/lib/cmake/IREE" NO_DEFAULT_PATH)
```

This replaces the consumer's stub seam `native/cmake/IreeRuntimePin.cmake` and obsoletes its
hand-rolled `native/cmake/ResolveIree.cmake`.

## 10. Wishlist traceability

| # | Wishlist item | Disposition |
|---|---|---|
| 1 | CMake pin (FetchContent) | v1 — `gen-pin.sh` → `IreeRuntimePin.cmake` |
| 2 | Install tree + `IREERuntimeConfig.cmake` | v1 — mostly free via upstream export set; dist adds version file + umbrella target and asserts relocatability |
| 3 | Compiler↔runtime compatibility manifest | v1 — `manifest.json`, verified by CI compiling `add.vmfb` |
| 4 | Element-type constants | v1 — `element_types.json`, generated |
| 5 | Status-code enum | v1 — `status_codes.json`, generated |
| 6 | Canonical `add.vmfb` | v1 — compiled by the paired compiler |
| 7 | Build-config attestation | v1 — folded into `manifest.json` + `BUILDINFO` |
| 8 | glibc floor via container | v1 — manylinux_2_28 build container |
| 9 | Third-party license notices | v1 — scoped to the actual link surface (no LLVM) |
| 10 | Per-platform artifacts | v1 `linux-x86_64`; `windows-x86_64` deferred |
| — | Variant matrix | `minimal`/`perf` collapsed into `default`; `devtools` and `gpu` deferred |
