# Extract static cache variables into `CMakePresets.json`

> **Status (2026-07-29): mechanism superseded, findings retained.** See
> [2026-07-29-package-port-regime.md](2026-07-29-package-port-regime.md), which reframes this work
> as a package port and replaces `CMakePresets.json` with `cmake -C` (presets are readable only
> from the source directory, which here is a pristine IREE checkout we do not own). That note's
> "What carries over" section records precisely which parts of this document survive — principle 2
> and the static/dynamic inventory do; the preset file, the `FLAGS_INIT` toolchain files, and
> `resolve-preset.py` do not. This document is kept unedited as the reasoning that got us there.

## Guiding principles

1. **CMake owns build configuration.** CMake is already the build system. It has presets for
   configuration, toolchain files for compiler/platform initialization, and cache variables
   that compose correctly across inheritance and command-line overrides. Every flag we
   assemble in shell or Python is a flag CMake could own — and when CMake owns it,
   composition, discoverability, and correctness come from the tool designed for the job
   rather than from defensive shell logic. Shell should handle only what is genuinely dynamic
   at invocation time: path resolution (`$IREE_SRC`), host-arch detection, runtime source
   patches. Everything static or platform-canonical belongs in CMake's own mechanisms.

2. **No Python inline in shell.** Embedding Python code in bash heredocs is an anti-pattern:
   it can't be independently linted, tested, or edited in a syntax-aware editor. Python
   scripts live as standalone files alongside shell code and are invoked by shell when
   needed. This applies to the preset resolver, the manifest JSON builder, and any other
   Python that currently exists inline in `gen-manifest.sh`.

## Summary

All `-D` cache variables in the build recipe are static — they don't depend on paths, don't vary
by variant, and don't require shell computation. Moving them into a `CMakePresets.json` eliminates
`scripts/lib/cmakeflags.sh` entirely and simplifies `scripts/lib/variants.sh`.

## What's static vs. dynamic

| Category | Examples | Where it belongs |
|---|---|---|
| Capability flags (`-D` cache vars) | `IREE_BUILD_COMPILER=OFF`, `IREE_HAL_DRIVER_LOCAL_SYNC=ON`, `CMAKE_BUILD_TYPE=Release` | `CMakePresets.json` — `base` preset, all platforms. |
| Platform-specific cache vars | `CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded` (Windows only) | `CMakePresets.json` — per-platform preset override. |
| Compiler selection | `clang`/`clang++` vs `cl` | Toolchain file — `find_program` in `cmake/<platform>-toolchain.cmake`, wired via `toolchainFile` in the preset. |
| Compiler flag initialization | `-ffile-prefix-map=`, `/d1trimfile:`, MSVC defaults (`/EHsc`, `/GR`) | Toolchain file — `CMAKE_<LANG>_FLAGS_INIT` in the same toolchain file. |
| Variant cflags | `-fsanitize=thread -g` | Shell — passed as `-DCMAKE_C_FLAGS="$VARIANT_CFLAGS"` on the command line alongside `--preset`. Path-independent but not a cache var (it's a compiler flag). |
| Source mutations | aarch64+tsan `atomics.h` patch | Shell — not a flag at all. |

## User preset (not project preset)

`CMakePresets.json` is the upstream project's file — we can't write into IREE's source tree
without risking a collision if IREE ever ships its own presets. The standard CMake answer is
`CMakeUserPresets.json`: it lives alongside `CMakePresets.json`, is gitignored by convention,
and can inherit from the project's presets. We copy ours into `$IREE_SRC/` before configure,
along with the toolchain files it references via relative paths.

**`CMakeUserPresets.json`** (lives in our repo, copied to `$IREE_SRC/` at build time):

```json
{
  "version": 6,
  "configurePresets": [
    {
      "name": "base",
      "hidden": true,
      "cacheVariables": {
        "IREE_BUILD_COMPILER": "OFF",
        "IREE_BUILD_TESTS": "OFF",
        "IREE_BUILD_SAMPLES": "OFF",
        "IREE_BUILD_BINDINGS_TFLITE": "OFF",
        "IREE_BUILD_BINDINGS_TFLITE_JAVA": "OFF",
        "IREE_BUILD_PYTHON_BINDINGS": "OFF",
        "BUILD_SHARED_LIBS": "OFF",
        "CMAKE_BUILD_TYPE": "Release",
        "CMAKE_POSITION_INDEPENDENT_CODE": "ON",
        "IREE_ALLOCATOR_SYSTEM": "libc",
        "IREE_ENABLE_THREADING": "ON",
        "IREE_HAL_DRIVER_DEFAULTS": "OFF",
        "IREE_HAL_DRIVER_LOCAL_SYNC": "ON",
        "IREE_HAL_DRIVER_LOCAL_TASK": "ON",
        "IREE_HAL_EXECUTABLE_LOADER_DEFAULTS": "OFF",
        "IREE_HAL_EXECUTABLE_LOADER_EMBEDDED_ELF": "ON",
        "IREE_HAL_EXECUTABLE_LOADER_SYSTEM_LIBRARY": "ON",
        "IREE_ENABLE_RUNTIME_TRACING": "OFF"
      }
    },
    {
      "name": "linux-x86_64",
      "inherits": "base",
      "toolchainFile": "cmake/linux-clang-toolchain.cmake"
    },
    {
      "name": "linux-aarch64",
      "inherits": "base",
      "toolchainFile": "cmake/linux-clang-toolchain.cmake"
    },
    {
      "name": "windows-x86_64",
      "inherits": "base",
      "toolchainFile": "cmake/windows-msvc-toolchain.cmake",
      "cacheVariables": {
        "CMAKE_MSVC_RUNTIME_LIBRARY": "MultiThreaded"
      }
    }
  ]
}
```

Before configure, `build-runtime.sh` copies the user preset and toolchain files into the
IREE source tree. The toolchain files land in `$IREE_SRC/cmake/` so the preset's relative
`toolchainFile` paths resolve correctly. This is a one-time copy per build — no sed, no
templating. The IREE source is a CI clone or a local mount; we own the build lifecycle and
clean up after ourselves.

## Files deleted

- **`scripts/lib/cmakeflags.sh`** — `common_flags()`, `platform_cmake_flags()`, and
  `effective_cmake_flags()` with its hand-rolled dedup composer (~58 lines). The preset file
  handles cache-variable inheritance; CMake itself handles "last one wins" override when
  command-line `-D` arguments supplement the preset.

## Files simplified

- **`scripts/lib/variants.sh`** — loses `_runtime_capability_flags()` and `variant_flags()`
  (~18 lines). Keeps `variant_cflags()` (compiler flags, still path-dependent),
  `variant_sanitizer()` (provenance string), and `known_variants()` (CI matrix).

## Changes to `build-runtime.sh`

### 1. cmake configure invocation

Before configure, copy the user preset and toolchain files into the IREE source tree. Then
replace `effective_cmake_flags` + `mapfile` with `--preset`:

```bash
# Copy user preset + toolchain files into the IREE source tree.
# CMakeUserPresets.json is gitignored by convention; no risk of dirtying the checkout.
cp "$HERE/CMakeUserPresets.json" "$IREE_SRC/"
cp "$HERE/cmake/linux-clang-toolchain.cmake" "$IREE_SRC/cmake/"
cp "$HERE/cmake/windows-msvc-toolchain.cmake" "$IREE_SRC/cmake/"

cmake -G Ninja -B "$BUILD_DIR" -S "$IREE_SRC" \
  --preset "$PLATFORM" \
  -DIREE_SRC="$IREE_SRC" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_C_FLAGS="$VARIANT_CFLAGS" \
  -DCMAKE_CXX_FLAGS="$VARIANT_CFLAGS"
```

`VARIANT_CFLAGS` is empty for `default`, `-fsanitize=thread -g` for `tsan`.

### 2. `--print-flags` path

Emits an inventory of where flags live, not the flags themselves. Flags are spread across
three locations; the output tells the reader which file to open for each:

```bash
if [ "$PRINT_FLAGS" -eq 1 ]; then
  echo "user_preset: CMakeUserPresets.json (copied to IREE source)"
  echo "platform_preset: $PLATFORM (inherits from base)"
  echo "toolchain: cmake/$(platform_toolchain_file "$PLATFORM")"
  echo "variant_cflags: ${VARIANT_CFLAGS:-<empty>}"
  echo "command_line: -DIREE_SRC=... -DCMAKE_INSTALL_PREFIX=... -DCMAKE_INSTALL_LIBDIR=lib"
  exit 0
fi
```

### 3. gen-manifest.sh call

No change to the argument list. Gen-manifest doesn't need `$BUILD_DIR` — it resolves the
preset JSON directly (same python helper used by `--print-flags`).

## Changes to `gen-manifest.sh`

Replace all three consumers of `effective_cmake_flags` with calls to
`scripts/resolve-preset.py` (see "Python extracted from shell" below). The scope stays the
same: only the cache variables we explicitly set in the preset, not everything CMake
discovers.

### 1. CRT derivation

```bash
# Before:
_crt_flag="$(effective_cmake_flags "$VARIANT" "$PLATFORM" | grep -E '^-DCMAKE_MSVC_RUNTIME_LIBRARY=' || true)"
_crt_value="${_crt_flag#*=}"

# After:
_crt_value="$(python3 "$HERE/resolve-preset.py" "$PLATFORM" | grep -E '^CMAKE_MSVC_RUNTIME_LIBRARY=' | cut -d= -f2 || true)"
```

### 2. build_config JSON for manifest.json

```bash
# Before:
BUILD_CONFIG_JSON="$(
  effective_cmake_flags "$VARIANT" "$PLATFORM" | python3 -c '... -D prefix parsing ...'
)"

# After:
BUILD_CONFIG_JSON="$(python3 "$HERE/resolve-preset.py" "$PLATFORM" | python3 "$HERE/build-config-json.py")"
```

### 3. BUILDINFO cmake_flags line

```bash
# Before:
cmake_flags=$(effective_cmake_flags "$VARIANT" "$PLATFORM" | tr '\n' ' ')

# After:
cmake_flags=$(python3 "$HERE/resolve-preset.py" "$PLATFORM" | while IFS= read -r line; do printf -- '-D%s ' "$line"; done)
```

## Net delta

| What | Lines |
|---|---|
| Delete `cmakeflags.sh` | −58 |
| Delete from `variants.sh` (`_runtime_capability_flags` + `variant_flags`) | −18 |
| Delete from `build-runtime.sh` (compiler flag assembly block, `TOOLCHAIN_ARGS`, `mapfile` + `effective_cmake_flags` call) | ~−95 |
| Add `CMakeUserPresets.json` | +45 |
| Add `cmake/linux-clang-toolchain.cmake` | +7 |
| Add `cmake/windows-msvc-toolchain.cmake` | +7 |
| Add `scripts/resolve-preset.py` | +20 |
| Add `scripts/build-config-json.py` | +12 |
| Change in `build-runtime.sh` (`--preset` + `--print-flags` + `VARIANT_CFLAGS`) | net −80 |
| Change in `gen-manifest.sh` (three call sites, inline Python → script calls) | net −40 |

The flag-dedup composer in `effective_cmake_flags` — a hand-rolled merge algorithm that sorts,
dedupes by name, and resolves variant-over-common priority — disappears. CMake's own preset
inheritance handles that. The compiler flag assembly block (~90 lines of platform-conditional
shell that restates MSVC defaults defensively) disappears. Two toolchain files (~7 lines each)
let CMake's platform module compose flags as it was designed to.

## What stays in shell

Everything that's genuinely dynamic at invocation time or not expressible as a CMake
mechanism:

- **Platform detection** — `uname -m` → platform token (`linux-x86_64`, etc.), which then
  selects the preset (`--preset "$PLATFORM"`).
- **`variant_cflags`** — passed as `-DCMAKE_C_FLAGS="$VARIANT_CFLAGS"` on the command line
  alongside `--preset`. Empty for `default`, `-fsanitize=thread -g` for `tsan`.
- **`MSYS2_ARG_CONV_EXCL`** — Windows Git-Bash path mangling guard. Not a CMake concern.
- **aarch64+tsan `atomics.h` patch** — source mutation, not a flag.
- **`variant_sanitizer` / `known_variants`** — provenance metadata and CI matrix gating.
  No cache-variable content.

## Compiler + flag initialization: toolchain files

Two things the current shell handles that CMake can own:

1. **Compiler selection** — `clang`/`clang++` for Linux, `cl` for Windows.
2. **Compiler flag initialization** — `-ffile-prefix-map` on Linux, `/d1trimfile:` plus
   MSVC platform defaults on Windows.

Both are platform-determined, not discovered at invocation time. So both belong in a CMake
toolchain file, wired directly into the preset via the `toolchainFile` field. No shell
passthrough needed.

### The toolchain files

A toolchain file runs *before* `project()`. It sets the compiler and seeds
`CMAKE_<LANG>_FLAGS_INIT`. The platform module then appends its own defaults on top —
composition rather than replacement.

**`cmake/linux-clang-toolchain.cmake`** (new file):

```cmake
# iree-runtime-dist Linux toolchain file.
find_program(CMAKE_C_COMPILER   clang   REQUIRED)
find_program(CMAKE_CXX_COMPILER clang++ REQUIRED)
set(CMAKE_C_FLAGS_INIT   "-ffile-prefix-map=${IREE_SRC}=iree")
set(CMAKE_CXX_FLAGS_INIT "-ffile-prefix-map=${IREE_SRC}=iree")
```

**`cmake/windows-msvc-toolchain.cmake`** (new file):

```cmake
# iree-runtime-dist Windows toolchain file.
find_program(CMAKE_C_COMPILER   cl REQUIRED)
find_program(CMAKE_CXX_COMPILER cl REQUIRED)
set(CMAKE_C_FLAGS_INIT   "/DWIN32 /D_WINDOWS /d1trimfile:${IREE_SRC}\\")
set(CMAKE_CXX_FLAGS_INIT "/DWIN32 /D_WINDOWS /GR /EHsc /d1trimfile:${IREE_SRC}\\")
```

The Windows file restates MSVC's platform defaults (`/EHsc`, `/GR`) in `FLAGS_INIT` so they
compose with the platform module's additions rather than being clobbered. The
`find_program` with `REQUIRED` replaces the shell's `command -v cl` assertion. Both files
receive `IREE_SRC` from a `-DIREE_SRC=...` on the cmake command line.

### Resulting cmake invocation

The preset's `toolchainFile` field wires the toolchain in, so the shell doesn't need to pass
`-DCMAKE_TOOLCHAIN_FILE=...` or `-DCMAKE_C_COMPILER=...`:

```bash
cmake -G Ninja -B "$BUILD_DIR" -S "$IREE_SRC" \
  --preset "$PLATFORM" \
  -DIREE_SRC="$IREE_SRC" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_C_FLAGS="$VARIANT_CFLAGS" \
  -DCMAKE_CXX_FLAGS="$VARIANT_CFLAGS"
```

`VARIANT_CFLAGS` is empty for `default`, `-fsanitize=thread -g` for `tsan`. The variant
flags compose on top of the toolchain file's `FLAGS_INIT` and the platform module's defaults.

### What this eliminates from shell

- The `if platform_toolchain = container` / `elif` / `else` block (~90 lines) handling
  compiler selection, `-ffile-prefix-map` vs `/d1trimfile:`, MSVC platform default
  restatement, and the `command -v cl` assertion.
- The `TOOLCHAIN_ARGS` array.

Replaced by two small `.cmake` files (~7 lines each) and the `toolchainFile` field in the
preset. The real win isn't line count — it's that platform-specific compiler knowledge lives
in CMake where composition happens naturally, rather than in shell where every assignment
must defensively restate what CMake would otherwise drop.

## Resolved questions

1. **`--print-flags` compatibility.**  Resolved: point to the CMake files. The flags are
   spread across three locations, which `--print-flags` should inventory:

   - `CMakeUserPresets.json` — the user preset (copied to IREE source); the platform preset
     and its inherited `base` preset (cache variables).
   - `cmake/<platform>-toolchain.cmake` — compiler selection and `FLAGS_INIT` (prefix-map,
     platform defaults).
   - Command line — `CMAKE_INSTALL_PREFIX`, `CMAKE_INSTALL_LIBDIR`, `CMAKE_C_FLAGS`/
     `CMAKE_CXX_FLAGS` (variant cflags), and `IREE_SRC`.

   `--print-flags` output becomes something like:

   ```
   preset: linux-x86_64 (see CMakePresets.json)
   toolchain: cmake/linux-clang-toolchain.cmake
   variant_cflags: <empty for default, -fsanitize=thread -g for tsan>
   ```

   A consumer tracing a flag knows which file to open.

2. **CMakeCache.txt key scope.**  Resolved: `build_config` stays scoped to the flags we
   explicitly set — the preset's resolved cache variables — not everything CMake discovers.
   Gen-manifest uses `scripts/resolve-preset.py` rather than scraping `CMakeCache.txt`.
   This keeps the manifest's provenance at "what we asked for" rather than "everything
   CMake inferred," which is the same scope as today.

3. **`cmake --preset` availability.**  Resolved: the build container ships CMake 4.3.2, and
   GitHub's `windows-2022` runner includes CMake 4.3+ by default. `--preset` works
   everywhere.

4. **Toolchain file vs. shell for compiler flags.**  Resolved: toolchain files. They work
   *with* CMake's platform module rather than restating its defaults defensively in shell,
   and the guiding principle is that CMake mechanisms should own what they're designed to
   own. Two small, commented `.cmake` files replace ~90 lines of shell flag assembly.

## Python extracted from shell

Following principle 2, the Python currently inline in `gen-manifest.sh` (and any new Python
for preset resolution) should move to standalone scripts:

- **`scripts/resolve-preset.py`** — resolves a platform preset from `CMakeUserPresets.json`,
  emitting `KEY=VALUE` lines. Replaces the `resolve_preset` shell function / inline heredoc
  described above for `--print-flags` and gen-manifest's three consumers.
- **`scripts/build-config-json.py`** — reads `KEY=VALUE` lines from stdin, emits a JSON
  object with sorted keys. Replaces the inline python in gen-manifest's `build_config` step.
- **`scripts/build-manifest.py`** — the larger manifest JSON assembly currently inline at
  the end of `gen-manifest.sh`. Receives values as argv, writes `manifest.json`.

Each is independently lintable, testable, and editable. Shell invokes them with pipes and
arguments as it would any other tool.
