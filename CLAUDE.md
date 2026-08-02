# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this repo is

CI infrastructure that builds the IREE **runtime** and publishes attested, hash-pinned tarballs.
It produces *artifacts*, not a library — a build recipe plus packaging plus CI. The repo lives at
`measly-java-learning/iree-runtime-dist`. The first successful release is `v3.11.0-10`, which
publishes `default` and `tsan` tarballs for both `linux-x86_64` and `linux-aarch64` (plus the
metadata zip and `IreeRuntimePin.cmake`). Release URLs under that tag resolve; earlier `v3.11.0-*`
tags did not publish assets, so don't write or imply commands against those.

Design: `docs/superpowers/specs/2026-07-19-iree-runtime-dist-design.md`.

## Key commands

```bash
bash test/run.sh                                    # hermetic unit tests; no build, no container
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
what they define, change it there, not at a call site.

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

Not every platform's toolchain is containerised. Linux toolchains come from
`docker/<platform>.Dockerfile` (clang/lld/ninja NEVRAs, a known-old glibc); Windows has no
Dockerfile — the toolchain comes from a pinned GitHub runner image (`windows-2022`, never
`windows-latest`) plus a VS dev-shell activation. The runner label is pinned for the same reason
the Dockerfile pins NEVRAs: `msvc_toolset` is attested provenance and must not drift silently.

A prebuilt build image (`docker/<platform>.Dockerfile` → `iree-runtime-dist-build:<platform>`,
built by `scripts/build-image.sh`) pins the toolchain (clang/lld/ninja NEVRAs) and saves the
`dnf install` tax on every invocation. The image tag and its Dockerfile are both named by the
platform token — `iree-runtime-dist-build:<platform>` from `docker/<platform>.Dockerfile` — one
token, so tag, Dockerfile, and artifact platform cannot drift. CI cannot pull this local
image — a GH runner never sees it — so `release.yml` instead builds the per-platform Dockerfile
itself in every job that needs it, backed by GitHub Actions' layer cache
(`cache-from`/`cache-to: type=gha`). That cache is ref-scoped, so a separate `warm-build-image.yml`
rebuilds it on `main` (the one scope tag runs can read) whenever the Dockerfile changes; for
container platforms, the Dockerfile stays the single source of truth for the toolchain pins and
the `glibc_build` value `manifest.json` attests
to, with no second copy to drift.

## Variant matrix

Variants are single-sourced in two places, split by kind. `scripts/lib/variants.sh` owns
`known_variants <platform>` — the one genuinely platform-dependent piece of logic, not expressible
as a static file: `linux-*` builds `default tsan`, but `windows-*` builds `default` only, because
TSan is `-fsanitize=thread` under clang and the MSVC toolchain does not provide it. This list is
what `test/cmake_init.test.sh` walks to demand a `cmake/variant-<variant>.cmake` per platform ×
variant, so it must not claim `tsan` on Windows.

The release matrix does **not** read it. `release.yml` fans out `[default, tsan]` × the Linux
`PLATFORMS` literal in `build`, and keeps Windows in a separate `build-windows` job declaring
`variant: [default]` — the unbuildable `windows` × `tsan` leg is prevented by that job split, not
by a declared list.

The flags themselves are declared in `cmake/variant-<variant>.cmake`. `default` and `tsan` differ
**only** there: `variant-default.cmake` declares no compiler flags (present-and-empty on purpose —
`build-runtime.sh` passes the file unconditionally, so absent would be a configure error), and
`variant-tsan.cmake` appends `-fsanitize=thread -g`. Every capability entry lives in
`cmake/common.cmake`, which no variant file can reach, so the two cannot drift on what runtime they
build. A new variant (e.g. a future `tracy`) is a new `cmake/variant-*.cmake`, a `known_variants`
case, and — since the matrix is declared in the workflow — a `release.yml` edit.

`default` and `tsan` share every capability entry in `cmake/common.cmake` (drivers, loaders,
tracing-off) so the two cannot drift apart on capability — they differ **only** in the flags each
`cmake/variant-<variant>.cmake` declares: empty for `default`, `-fsanitize=thread -g` for `tsan`.
`CMAKE_BUILD_TYPE` stays `Release` for both variants, **never `RelWithDebInfo`** — switching `tsan`
to `RelWithDebInfo` renames the exported config (`IMPORTED_LOCATION_RELEASE` → `_RELWITHDEBINFO`),
silently breaking the Release-hardcoded libbacktrace and relocatability repairs. `-g` via
`variant-tsan.cmake` gives TSan symbolized frames without that config rename.

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

`schema_version: 2`. Provenance keys are platform-conditional, following the same conditional
idiom as `sanitizer`: `glibc_build` appears only on `linux-*` manifests, and `msvc_toolset` +
`crt` appear only on `windows-*` manifests — each absent (not `null`, not `"n/a"`) on the other
platform, so the two provenance models can never silently merge. `schema_version` stays `2` for
both; this is purely additive and breaks no existing consumer.

`glibc_build` records the glibc of the container the archives were *compiled against* (2.28) —
it is not a compatibility floor and must never be described as one. Static archives carry
unversioned undefined libc symbols; glibc symbol-version resolution happens at the *consumer's*
final link, not in the archive, so scanning `.a` files for `GLIBC_x.y` strings is structurally
incapable of producing a floor. `gen-manifest.sh` documents this in the manifest's own
`notes.glibc_build` field — keep that note in sync with any future change to how this value is
computed.

`msvc_toolset` records the `cl.exe` version the Windows archives were compiled with (detected
from `cl`'s own version banner, `"unknown"` when `cl` isn't on `PATH`) — provenance, not a
compatibility claim. `crt` records the C runtime model (`MT` = static `/MT`, `MD` = dynamic
`/MD`), read from the build tree's `CMakeCache.txt` `CMAKE_MSVC_RUNTIME_LIBRARY` entry rather
than hardcoded, so the manifest cannot claim a CRT the build didn't actually use. Same honesty
standard as `glibc_build`: the archives carry only `/DEFAULTLIB:LIBCMT` directives, and the CRT
itself is resolved at the *consumer's* final link, not embedded in the archive — `crt` is the
CRT a consumer must match to avoid a mixed-CRT link, not a compatibility floor. `gen-manifest.sh`
documents this in `notes.crt`, kept in sync the same way.

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

`build_config` is observed, then **path-normalized**: the build machine's IREE source root and
build directory are rewritten to `@IREE_SOURCE_ROOT@` / `@IREE_BUILD_DIR@`, and nothing else is
touched. `CMAKE_C_FLAGS`/`CMAKE_CXX_FLAGS` are path-dependent by construction — clang's
`-ffile-prefix-map=$IREE_SRC=iree`, MSVC's `-d1trimfile:$IREE_SRC_NATIVE\` — and both
`manifest.json` and `BUILDINFO` ship *inside the prefix*, so publishing the cache verbatim leaks
the builder's mount point into two shipped files and `relocatability_assert` fails the build (from
Phase 4, the pass that covers Phase 3 outputs). The normalization lives in `emit-manifest.py`, the
single point that feeds both files, rather than in `relocatability_repair` — and it is a token
rewrite, not a rewrite to a plausible-looking value, so the manifest never claims a flag the build
did not use. Toolchain paths (`CMAKE_C_COMPILER`, the resolved `cl.exe`) are deliberately left
absolute: naming the exact compiler is the provenance, and it is not a path the artifact asks a
consumer to resolve. Never add a toolchain prefix to the normalized roots, and never fix a leak
here by narrowing the assertion.

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

`test/cmake_init.test.sh` is hermetic and asserts two things about the `cmake/` layer: that a
cache-init file exists for every `known_platforms` entry and every variant each platform builds
(so "added a platform, forgot the file" fails in a second rather than at configure time on one
platform), and that `cmake/windows-x86_64.cmake` restates `-GR -EHsc` in the C++ flags and not in
the C flags. The second is a deletion guard, not a value check — the only other thing that catches
a dropped `-EHsc` is a 40-minute Windows build failing 322 objects in.

## Conventions

- `set -euo pipefail` in every script. `grep` exits 1 on no-match and aborts under `set -e`; guard
  with `|| true`.
- The recipe is idempotent: re-runs must not fail on existing build trees or already-patched
  export files (see the `grep -q` idempotency guards in `build-runtime.sh` Phase 1).
- Design docs and plans live in `docs/superpowers/{specs,plans}/`.
