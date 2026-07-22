# IREE Runtime Dist

CI infrastructure that builds the [IREE](https://github.com/iree-org/iree) **runtime** from
source and publishes it as attested, hash-pinned, relocatable tarballs for JNI and other native
consumers.

Consumers (e.g. `djl-iree-engine`) do not build IREE. They `FetchContent` a pinned tarball and
`find_package` it.

**No release has been cut yet.** No GitHub repo exists for this project either — the pin file
generator (`scripts/gen-pin.sh`) has only ever been run against a placeholder org slug. Nothing
below that references a release URL should be read as "this resolves today."

## Why this isn't a thin wrapper

Upstream IREE already ships a CMake package (`IREERuntimeConfig.cmake` + `install(EXPORT)`), so
the naive plan — `cmake --install` and tar it up — looks like it should just work. It doesn't:

- **A bare `cmake --install` ships zero archives and zero headers.** IREE's own
  `iree_install_support.cmake` marks every library install rule `EXCLUDE_FROM_ALL`. The export
  set still gets generated and still looks complete (~198 `IMPORTED_LOCATION` entries), but every
  entry points at a file that was never installed — `find_package` succeeds and the first
  downstream *link* fails instead. `build-runtime.sh` installs three components by name
  (`IREEDevLibraries-Runtime`, `IREEBundledLibraries`, `IREECMakeExports`) to get real content.
- Four separate upstream packaging gaps still have to be repaired even after that:
  1. `build_tools/third_party/printf` is its own `EXCLUDE_FROM_ALL` subdirectory whose
     `cmake_install.cmake` never chains into the parent install, so its archive needs an
     explicit second `cmake --install --component`.
  2. `build_tools/third_party/libbacktrace` has no `install(TARGETS ...)` rule for its archive at
     all, and the target the export set references (`libbacktrace_libbacktrace`) is never
     declared as an importable target upstream. The recipe copies the archive in by hand and
     writes the missing `add_library(... IMPORTED)` + `IMPORTED_LOCATION` block itself.
  3. `IREERuntimeConfig.cmake` never calls `find_package(Threads)` before including the targets
     file, so a bare consumer `find_package(IREERuntime)` fails to even *configure* — it errors
     on `Threads::Threads` not being found. The recipe patches the config to re-find its own
     external dependency.
  4. Several public headers (e.g. `iree/base/status.h`, `iree/hal/buffer.h`) are listed in a
     target's `HDRS` but never get an `install(FILES ...)` rule generated for them. The recipe
     walks the real `#include` graph from the installed headers and copies what's missing
     straight from source.
- Upstream also omits a CMake package version file, so `find_package(IREERuntime 3.11.0)` with a
  version constraint fails outright; the recipe writes one.
- The install tree leaks absolute build-machine paths (the staging prefix, system library paths,
  a flatcc-generated `-I` flag) into the exported `.cmake` files. A repair pass rewrites them, and
  an assertion pass fails loudly — never silently — if any survive.

None of this is "reconstruct IREE's build." It's fixing genuine gaps in what upstream's own
export machinery emits, verified against the actual built tree rather than assumed.

## What this ships

`iree-runtime-3.11.0-default-linux-x86_64.tar.gz` — measured 2.4 MB compressed, unpacks to one
top-level directory:

```
lib/                        # 198 static archives (PIC)
  cmake/IREE/                # upstream IREERuntimeConfig.cmake + targets, unmodified
                              # (+ a generated IREERuntimeConfigVersion.cmake upstream omits)
  cmake/IreeRuntimeDist/      # umbrella target + manifest as CMake vars
include/                    # 367 public headers (374 files under include/, counting .inl)
share/iree-runtime-dist/
  manifest.json              # schema_version 2: pairing + build-config attestation
  element_types.json         # IREE_HAL_ELEMENT_TYPE_* generated from IREE headers
  status_codes.json          # iree_status_code_t generated from IREE headers
  add.vmfb                   # smoke module, compiled by the paired compiler
LICENSE
THIRD-PARTY-NOTICES/
  flatcc/  printf/  libbacktrace/
BUILDINFO
```

`THIRD-PARTY-NOTICES/` covers exactly the third-party code actually *linked* into the shipped
archives (determined empirically from the CMake export set's transitive link closure and cross-
checked against undefined symbols in the built `.a` files) — not the larger set of submodules
IREE's checkout gate requires, and not LLVM, which is never linked since this build always sets
`-DIREE_BUILD_COMPILER=OFF`.

## The compiler is not in the contract

This dist builds with `-DIREE_BUILD_COMPILER=OFF`. It never builds or ships `iree-compile`. To
produce loadable `.vmfb` files, install the paired compiler recorded in `manifest.json`:

```bash
pip install iree-base-compiler==3.11.0
```

Mismatched compiler and runtime versions fail at VM context creation with a cryptic import
signature mismatch. The shipped `add.vmfb` lets you smoke-test the runtime without installing a
compiler at all.

Note: the pip **`iree-base-runtime` wheel is not linkable** — no headers, no static libraries, at
any version. Only a from-source build or this dist yields a linkable runtime.

## Consuming downstream

Two consumption paths are both supported and covered by the acceptance test
(`test/consumer/`):

**1. The curated umbrella target** (recommended — one target, upstream's transitive properties
carried through by rename, not re-derivation):

```cmake
include(IreeRuntimePin.cmake)   # generated per-release by scripts/gen-pin.sh; not published yet

include(FetchContent)
FetchContent_Declare(iree_runtime
  URL      "${IREE_RUNTIME_URL_default_linux-x86_64}"
  URL_HASH "SHA256=${IREE_RUNTIME_SHA256_default_linux-x86_64}"
)
FetchContent_MakeAvailable(iree_runtime)

find_package(IreeRuntimeDist REQUIRED
  PATHS "${iree_runtime_SOURCE_DIR}/lib/cmake/IreeRuntimeDist" NO_DEFAULT_PATH)

target_link_libraries(my_jni_lib PRIVATE iree-runtime-dist::runtime)
```

**2. Direct upstream, unmodified**, if you'd rather not take the dist's umbrella target:

```cmake
find_package(IREERuntime 3.11.0 REQUIRED
  PATHS "${iree_runtime_SOURCE_DIR}/lib/cmake/IREE" NO_DEFAULT_PATH)

target_link_libraries(my_jni_lib PRIVATE iree_runtime_unified)
```

The generated version file honors version constraints correctly:
`find_package(IREERuntime 3.11.0)` succeeds; `find_package(IREERuntime 99.0.0)` fails with
CMake's normal "no compatible configuration file" error, not a silent success.

Because the pin records both URL and SHA-256, `FetchContent` re-verifies the tarball on every
build.

### Choosing a HAL driver

Both CPU drivers ship in one tarball; you select at runtime by **exact driver name**, not a URI.
`iree_runtime_instance_try_create_default_device` compares the name you pass against the
registered driver name with an exact string match — `"local-sync://"` will fail to resolve.

| Driver name | Behavior |
|---|---|
| `local-sync` | Inline, single-threaded. No IREE-internal threads. |
| `local-task` | Worker pool for CPU intra-op parallelism. |

## Cutting a release

Pushing a version tag is the only trigger (`.github/workflows/release.yml`, `on: push: tags:
v*.*.*-*`).

```bash
git tag v3.11.0-1
git push origin v3.11.0-1
```

`<pkgrev>` (the trailing `-1`) bumps re-roll the same IREE version after a recipe fix.

No workflow run has ever happened against a real repo, so nothing above has been exercised
end-to-end outside of the unit tests and the local build described below.

## Building locally

The required submodule set is **11 paths**, not one — IREE's own
`build_tools/scripts/git/check_submodule_init.py --runtime_only` hard-requires every path listed
in `runtime_submodules.txt` regardless of which HAL drivers/loaders you enable. The full,
authoritative list is `scripts/lib/submodules.sh`. `third_party/llvm-project` (2.6 GB) is not in
that list and is not needed — that exclusion is most of the win. Never use
`submodule update --init --recursive`.

```bash
git clone --filter=blob:none --depth 1 --branch v3.11.0 \
  https://github.com/iree-org/iree.git /path/to/iree

# Full required set — see scripts/lib/submodules.sh for the single source of truth.
git -C /path/to/iree submodule update --init --depth 1 \
  third_party/benchmark third_party/flatcc third_party/googletest \
  third_party/hip-build-deps third_party/hsa-runtime-headers third_party/musl \
  third_party/printf third_party/spirv_cross third_party/tracy \
  third_party/vulkan_headers third_party/webgpu-headers
```

Build the pinned toolchain image once (`docker/linux-x86_64.Dockerfile`, tagged
`iree-runtime-dist-build:linux-x86_64`; ~50s saved on every later invocation versus installing
clang/lld/ninja fresh each time). The tag and Dockerfile are named by the platform token, so a
future arch is just a sibling `docker/<platform>.Dockerfile`:

```bash
bash scripts/build-image.sh   # builds every known platform; prints resolved tool versions
```

Then build:

```bash
docker run --rm -v "$PWD":/work -v /path/to/iree:/iree \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  -w /work iree-runtime-dist-build:linux-x86_64 \
  bash -lc 'export PATH=/opt/python/cp312-cp312/bin:$PATH; \
    ./build-runtime.sh --variant default --prefix /work/out --iree-src /iree'
```

This mirrors what `.github/workflows/release.yml`'s `build` job does, except CI builds the
per-platform Dockerfile itself via `docker/build-push-action` with GitHub Actions layer caching (a
locally built image is invisible to GH runners, so CI can't just `docker run` the local tag).
Because that cache is ref-scoped, `.github/workflows/warm-build-image.yml` re-warms it on `main`
whenever the Dockerfile changes, so each tag release reads a cache hit instead of rebuilding.

Inspect the effective cmake flags without building or needing an IREE checkout at all:

```bash
./build-runtime.sh --print-flags --variant default
```

which prints (verified against this repo):

```
-DIREE_HAL_DRIVER_DEFAULTS=OFF
-DIREE_HAL_DRIVER_LOCAL_SYNC=ON
-DIREE_HAL_DRIVER_LOCAL_TASK=ON
-DIREE_HAL_EXECUTABLE_LOADER_DEFAULTS=OFF
-DIREE_HAL_EXECUTABLE_LOADER_EMBEDDED_ELF=ON
-DIREE_HAL_EXECUTABLE_LOADER_SYSTEM_LIBRARY=ON
-DIREE_ENABLE_RUNTIME_TRACING=OFF
-DIREE_BUILD_COMPILER=OFF
-DIREE_BUILD_TESTS=OFF
-DIREE_BUILD_SAMPLES=OFF
-DIREE_BUILD_BINDINGS_TFLITE=OFF
-DIREE_BUILD_BINDINGS_TFLITE_JAVA=OFF
-DIREE_BUILD_PYTHON_BINDINGS=OFF
-DBUILD_SHARED_LIBS=OFF
-DCMAKE_BUILD_TYPE=Release
-DCMAKE_POSITION_INDEPENDENT_CODE=ON
-DIREE_ALLOCATOR_SYSTEM=libc
-DIREE_ENABLE_THREADING=ON
```

## Testing

```bash
bash test/run.sh                                    # hermetic unit tests; no build, no container
bash test/build_smoke.sh out                         # structural check of a built prefix
bash test/consumer/run.sh out                        # consumer e2e (run in a clean container in CI)
```

`test/run.sh` and `test/consumer/run.sh out` both pass against this repo's current state (the
latter runs both `local-sync` and `local-task` end to end against the shipped `add.vmfb`).

## Verifying an artifact

```bash
sha256sum -c iree-runtime-3.11.0-default-linux-x86_64.tar.gz.sha256
gh attestation verify iree-runtime-3.11.0-default-linux-x86_64.tar.gz \
  --repo <owner>/iree-runtime-dist
```

`manifest.json`'s `glibc_build` field (2.28 today) records the glibc of the container these
archives were *compiled against* — not a detected compatibility floor. Static archives carry
unversioned undefined libc symbols; glibc symbol-version resolution happens at the consumer's own
final link, so scanning the `.a` files for `GLIBC_x.y` version strings is structurally incapable
of answering "what's the minimum glibc this needs." Treat the field as build provenance, not a
guarantee.
