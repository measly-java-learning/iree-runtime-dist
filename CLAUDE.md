# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this repo is

CI infrastructure that builds the IREE **runtime** and publishes attested, hash-pinned tarballs.
It produces *artifacts*, not a library — a build recipe plus packaging plus CI. The repo lives at
`measly-java-learning/iree-runtime-dist`. No release has published successfully yet, so no release
URL resolves — don't write or imply commands against one until a run has actually produced assets.

Design: `docs/superpowers/specs/2026-07-19-iree-runtime-dist-design.md`.

## Key commands

```bash
bash test/run.sh                                    # hermetic unit tests; no build, no container
./build-runtime.sh --print-flags --variant default   # effective cmake flags without building
bash test/build_smoke.sh out                          # structural check of a built prefix
bash test/consumer/run.sh out                         # consumer e2e (run in a clean container)
```

## Hard constraints

- **The compiler is out of contract.** `-DIREE_BUILD_COMPILER=OFF` always. Never build or ship
  `iree-compile`. It appears only as a version string in `manifest.json` and a CI-time pip wheel
  used to compile `add.vmfb`.
- **Never `submodules: recursive`.** IREE's `check_submodule_init.py --runtime_only` hard-requires
  every path in `runtime_submodules.txt` — 11 paths, all listed in `scripts/lib/submodules.sh` —
  regardless of which HAL drivers/loaders are enabled. `third_party/llvm-project` (2.6 GB) is not
  one of them and is never needed.
- **Two lists, two different jobs — do not conflate them.**
  `scripts/lib/submodules.sh` (`IREE_REQUIRED_SUBMODULES`) is a *checkout gate*: what IREE's own
  configure step demands exist on disk. `scripts/lib/linked-components.sh`
  (`IREE_LINKED_COMPONENTS`) is the *notices input*: what's actually reachable from
  `iree_runtime_unified`'s transitive `INTERFACE_LINK_LIBRARIES` closure, verified against the
  built archives with `nm`. Most required-submodule paths are never linked. Generating
  `THIRD-PARTY-NOTICES/` from the submodule list instead of the linked-components list would
  over-claim licenses for code that isn't in the artifact — the same category of error as
  claiming LLVM.
- **Upstream CMake files ship unmodified**, with exactly two sanctioned, narrow, commented
  exceptions: `relocatability_repair` (path rewriting) and `config_repair_external_deps`
  (adding the missing `find_package(Threads)` call). Anything else added lives in
  `lib/cmake/IreeRuntimeDist/`. Editing `lib/cmake/IREE/IREETargets-Runtime.cmake` beyond those
  two repairs is a test failure (`test/cmake_additions.test.sh` checks for it).
- **v1 is stable `v3.11.0` only. Never `main`.** Mixing a main-branch runtime with a stable
  compiler is exactly the VM import-signature mismatch this project exists to prevent. Never
  point `--iree-src` at `/home/corey/workspace/iree` — that checkout tracks `main`, not the
  pinned `v3.11.0` tag this recipe, `manifest.json`, and the paired `add.vmfb` all assume.

## Architecture

`build-runtime.sh` runs four phases: build+install, relocatability repair+assert, generate
metadata, pair with the compiler.

Phase 1's `cmake --install` is load-bearing but not sufficient by itself — IREE marks every
library install rule `EXCLUDE_FROM_ALL`, so a bare install ships zero archives and zero headers
even though the export set still looks complete. The recipe installs three named components
(`IREEDevLibraries-Runtime`, `IREEBundledLibraries`, `IREECMakeExports`) and then repairs four
separate upstream packaging gaps found the hard way: the `printf` subdirectory's install never
chains into the parent (needs an explicit second `cmake --install --component`), `libbacktrace`
has no `install(TARGETS ...)` rule at all for its archive and its target is never exported
(hand-copy the archive, hand-write the imported-target block), `IREERuntimeConfig.cmake` never
`find_package(Threads)`s before including the targets file (breaks bare `find_package` at
*configure* time, not link time), and several public headers are declared in a target's `HDRS`
but never get an `install(FILES ...)` rule generated (`scripts/install-headers.sh` walks the real
`#include` graph and fills the gap from source). None of these are "reconstruct IREE's build" —
each is a specific, load-bearing, commented repair for a specific upstream omission. Do not
"simplify" any of them back toward a bare install; that is precisely what silently ships an
empty or half-broken package.

`scripts/lib/*.sh` are sourced by both the build and CI so the two cannot drift. When changing
what they define, change it there, not at a call site. `effective_cmake_flags` in particular
feeds the build, `--print-flags`, and `BUILDINFO`/`manifest.json` provenance, so recorded
provenance cannot diverge from the build that produced it.

A prebuilt build image (`docker/<platform>.Dockerfile` → `iree-runtime-dist-build:<platform>`,
built by `scripts/build-image.sh`) pins the toolchain (clang/lld/ninja NEVRAs) and saves the
`dnf install` tax on every invocation. The image tag and its Dockerfile are both named by the
platform token from `scripts/lib/naming.sh` (`build_image_tag`/`build_dockerfile`) — one token,
so tag, Dockerfile, and artifact platform cannot drift; adding an arch is a new
`docker/<platform>.Dockerfile` plus a `PLATFORMS` entry, nothing else. CI cannot pull this local
image — a GH runner never sees it — so `release.yml` instead builds the per-platform Dockerfile
itself in every job that needs it, backed by GitHub Actions' layer cache
(`cache-from`/`cache-to: type=gha`). That cache is ref-scoped, so a separate `warm-build-image.yml`
rebuilds it on `main` (the one scope tag runs can read) whenever the Dockerfile changes; the
Dockerfile stays the single source of truth for the toolchain pins and the `glibc_build` value
`manifest.json` attests
to, with no second copy to drift.

## Variant matrix

Variants are single-sourced in `scripts/lib/variants.sh`: `known_variants` (`default tsan`),
`variants_json` (feeds the release matrix's `fromJson()` fan-out, mirroring how `naming.sh` feeds
the platform matrix), `variant_cflags` (extra `CMAKE_C_FLAGS`/`CXX_FLAGS`, not a `-D` cache
option), and `variant_sanitizer` (the `sanitizer` value recorded in `manifest.json`/`BUILDINFO`).
Never hardcode a variant list anywhere else — CI's `build`/`verify` jobs source it, and a new
variant (e.g. a future `tracy`) is a `variants.sh` change, not a workflow edit.

`default` and `tsan` share `_runtime_capability_flags` (drivers, loaders, tracing-off) so the two
cannot drift apart on capability — they differ **only** in `variant_cflags`: empty for `default`,
`-fsanitize=thread -g` for `tsan`. `CMAKE_BUILD_TYPE` stays `Release` for both variants,
**never `RelWithDebInfo`** — switching `tsan` to `RelWithDebInfo` renames the exported config
(`IMPORTED_LOCATION_RELEASE` → `_RELWITHDEBINFO`), silently breaking the Release-hardcoded
libbacktrace and relocatability repairs. `-g` via `variant_cflags` gives TSan symbolized frames
without that config rename.

The relocatability assertion (`scripts/relocatability.sh`) exempts DWARF-only build paths for
sanitizer variants via `RELOC_ALLOW_DEBUG_PATHS` — `-g` embeds the build directory in debug info
the existing `-ffile-prefix-map` doesn't reach, and that's expected for a sanitizer variant, not a
leak of the kind the assertion otherwise guards against. Do not widen this exemption beyond debug
paths.

The `tsan` variant ships `share/iree-runtime-dist/TSAN.md` (generated by `gen-tsan-docs.sh`,
`default` ships neither) and propagates `-fsanitize=thread` as an `INTERFACE` flag on the
umbrella target, so a consumer's whole program gets instrumented by linking it — but the
consumer's own build must use clang to match the toolchain this variant was compiled with.

## manifest.json

`schema_version: 2`. `glibc_build` records the glibc of the container the archives were
*compiled against* (2.28) — it is not a compatibility floor and must never be described as one.
Static archives carry unversioned undefined libc symbols; glibc symbol-version resolution happens
at the *consumer's* final link, not in the archive, so scanning `.a` files for `GLIBC_x.y`
strings is structurally incapable of producing a floor. `gen-manifest.sh` documents this in the
manifest's own `notes.glibc_build` field — keep that note in sync with any future change to how
this value is computed.

## Testing

Two layers. Hermetic `test/*.test.sh` need no build and run via `test/run.sh`. Tests taking a
`<prefix>` argument skip when given none, so `run.sh` stays hermetic.

`test/consumer/` is the acceptance gate: extract the tarball in a container with no build tree and
no IREE source, `find_package`, compile, load `add.vmfb`, run it, assert the result — once per
driver name (`local-sync`, `local-task` — exact driver names, not URIs;
`iree_runtime_instance_try_create_default_device` does an exact string compare against the
registered driver name, so `"local-sync://"` fails to resolve). It transitively proves
relocatability, link surface, compile-define propagation, ABI pairing, and the glibc build
provenance. `test/consumer/consumer.c` is meant to be exactly what a real downstream consumer
would write — not a harness with extra scaffolding a real caller wouldn't have. A harness that
quietly differs from a real caller (e.g. linking against the build tree instead of the packaged
prefix, or skipping a driver) can mask a real defect; if the harness needs to change, ask whether
a real consumer would hit the same change first.

Relocatability has a repair step *and* an assertion (`scripts/relocatability.sh`). If the
assertion fires, extend the repair — never weaken the assertion. The assertion is only meaningful
when `relocatability_assert` is invoked with the **container-internal** build and source paths
(e.g. `/work/iree-build-default`, `/iree`), not host paths — `build-runtime.sh` passes
`$BUILD_DIR`/`$IREE_SRC` resolved from inside the container, and that's deliberate: checking for
leaked *host* paths (which never appear in the build in the first place) would make the assertion
pass trivially without proving anything. Run the recipe inside the container end to end so the
paths the assertion checks are the ones that could actually leak.

## Conventions

- `set -euo pipefail` in every script. `grep` exits 1 on no-match and aborts under `set -e`; guard
  with `|| true`.
- The recipe is idempotent: re-runs must not fail on existing build trees or already-patched
  export files (see the `grep -q` idempotency guards in `build-runtime.sh` Phase 1).
- Design docs and plans live in `docs/superpowers/{specs,plans}/`.
