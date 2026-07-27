# IREE runtime — Windows de-risking spike runbook

**Goal:** answer, cheaply and manually on `winbox`, whether the IREE runtime recipe can produce a
usable Windows artifact — before spending any CI cycles or writing a platform-add spec. This is
reconnaissance: the deliverable is *findings*, not a shippable build.

**Execution:** run each probe by hand on `winbox`. Every probe ends with a clear GO / NO-GO and a
**"If this breaks, ask the agent"** hint that names the likely cause, so a help request starts three
steps ahead instead of cold.

**Record as you go:** open a tracking issue ("Windows platform de-risking spike") with W1/W2/W3 as a
checklist and paste each probe's outcome under it. Per the repo's working rule, a measured unknown
becomes tracked work — don't let a finding live only in your terminal scrollback.

---

## What's already known (don't re-derive)

The sibling repo `executorch-runtime-dist` ran the equivalent spike and **shipped** Windows artifacts.
Its host-orchestration lessons transfer verbatim (they're OS-level, not framework-level). Source docs
if you want the originals: `executorch-runtime-dist/spike/windows-msvc-spike.md` and
`executorch-runtime-dist/docs/handover-windows-static-cxx17.md`.

What IREE does **not** inherit: ET's flag set, its `flatc_ep` bug, its kernel/torch findings. Those
are ET-specific. IREE has its own analogs, which is exactly what W1–W3 surface.

---

## Ground rules (read once — these cost ET real debugging time)

- **WSL is a trap.** Anything you run under WSL builds *Linux* — ELF, glibc — and gives a false
  green. Every command below runs in **native Windows Git-Bash** driving **native** MSVC/CMake/Ninja.
- **Toolchain must be on PATH via the VS dev shell.** MSVC, `cmake`, `ninja`, and `dumpbin` only
  exist after `Launch-VsDevShell.ps1 -Arch amd64`. `python` = the project `.venv`.
- **Single-config Ninja + MSVC, flat `-D` flags.** Do not reach for any vendor "windows" CMake
  preset — on ET that pinned clang-cl + the multi-config VS generator and broke Ninja. Plain
  `-G Ninja` lets CMake auto-detect `cl.exe`; that's what we want.
- **The MSYS `/`-flag trap.** Under Git-Bash a leading `/` in a tool flag gets path-converted
  (`/nologo` → `C:\Program Files\Git\nologo`) and silently feeds garbage. Use dash forms
  (`-nologo -directives`) or prefix the command with `MSYS_NO_PATHCONV=1`. This can fail on *every*
  invocation while a naive check still prints PASS.
- **Driving over SSH:** run native tools via `cmd /c "<cmd> > log 2>&1"` then `type log` to read the
  result. Raw stdout piped back over SSH gets CLIXML-mangled by PowerShell. If you script the
  activation, base64 `-EncodedCommand` is the robust form.

**Scope note:** this spike is the **`default` variant only** (no tsan — that's a Linux/clang concern;
ASLR/`vm.mmap_rnd_bits` is irrelevant here). CRT choice (`/MD` vs `/MT`), packaging, the CI
runner, and porting `relocatability.sh` are all **out of scope** — see "Deferred" at the end.

---

## W0 — Prerequisites (recon, ~10 min)

Confirm the toolchain and lay down an IREE source tree pinned to the version this recipe assumes.

```powershell
# In a VS dev shell (Launch-VsDevShell.ps1 -Arch amd64), confirm the tools exist:
cl ; cmake --version ; ninja --version ; dumpbin -nologo -? ; python --version
```

IREE source — **v3.11.0, never main** (mixing a main runtime with the stable compiler is the exact
ABI-mismatch this project exists to prevent):

```bash
# Git-Bash. Pick any path; C:/iree used throughout this runbook.
git clone --depth 1 --branch v3.11.0 https://github.com/iree-org/iree.git /c/iree
cd /c/iree
# The 11 required submodules ONLY — never `--recursive` (that drags in llvm-project, 2.6 GB, unused).
git submodule update --init --depth 1 \
  third_party/benchmark third_party/flatcc third_party/googletest \
  third_party/hip-build-deps third_party/hsa-runtime-headers third_party/musl \
  third_party/printf third_party/spirv_cross third_party/tracy \
  third_party/vulkan_headers third_party/webgpu-headers
```

> **If this breaks, ask the agent:** a submodule path that 404s or a checkout-gate error from IREE's
> `check_submodule_init.py --runtime_only` — the authoritative list lives in
> `scripts/lib/submodules.sh` and may have moved between IREE versions.

**GO when:** all five tools report versions and the submodule init exits clean.

---

## W1 — Does the runtime configure + build under MSVC? (the big one)

The exact flag set the Linux recipe uses, minus `-ffile-prefix-map==iree` — that's a clang/gcc flag
MSVC rejects, and it's only a reproducibility nicety, not needed to answer "does it build." (These
flags are `effective_cmake_flags` from `scripts/lib/variants.sh` + the fixed set in `build-runtime.sh`;
regenerate anytime with `./build-runtime.sh --print-flags --variant default`.)

```bash
# Git-Bash, inside the activated VS dev shell.
cmake -G Ninja -B /c/iree-build -S /c/iree \
  -DIREE_HAL_DRIVER_DEFAULTS=OFF \
  -DIREE_HAL_DRIVER_LOCAL_SYNC=ON \
  -DIREE_HAL_DRIVER_LOCAL_TASK=ON \
  -DIREE_HAL_EXECUTABLE_LOADER_DEFAULTS=OFF \
  -DIREE_HAL_EXECUTABLE_LOADER_EMBEDDED_ELF=ON \
  -DIREE_HAL_EXECUTABLE_LOADER_SYSTEM_LIBRARY=ON \
  -DIREE_ENABLE_RUNTIME_TRACING=OFF \
  -DIREE_BUILD_COMPILER=OFF \
  -DIREE_BUILD_TESTS=OFF \
  -DIREE_BUILD_SAMPLES=OFF \
  -DIREE_BUILD_BINDINGS_TFLITE=OFF \
  -DIREE_BUILD_BINDINGS_TFLITE_JAVA=OFF \
  -DIREE_BUILD_PYTHON_BINDINGS=OFF \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DIREE_ALLOCATOR_SYSTEM=libc \
  -DIREE_ENABLE_THREADING=ON

# Go/no-go: build just the umbrella target first — it's the whole link surface a consumer sees.
cmake --build /c/iree-build --target iree_runtime_unified
```

Notes on specific flags for Windows:
- `-DCMAKE_POSITION_INDEPENDENT_CODE=ON` is a **harmless no-op** on MSVC (PIC/PIE is a Unix concept);
  leave it for parity.
- `-DBUILD_SHARED_LIBS=OFF` → static `.lib` archives, matching the Linux `.a` model. Good.
- `-DIREE_ALLOCATOR_SYSTEM=libc` and `-DIREE_ENABLE_THREADING=ON` are portable.

> **If this breaks, ask the agent:**
> - **configure error naming a driver/loader** → an IREE HAL option that doesn't port to Windows as-is
>   (most likely `SYSTEM_LIBRARY` loader assumptions). Paste the CMake error; the agent maps it to the
>   flag to drop or swap.
> - **an ExternalProject/byproduct "missing and no known rule to make it" from Ninja** → IREE's analog
>   of ET's `flatc_ep` `.exe`-byproduct bug. Workaround pattern: build the offending sub-target
>   directly first (e.g. `cmake --build /c/iree-build --target <dep>`), then re-run. The agent can
>   identify the target from the error.
> - **`cl` not found / wrong arch** → the dev shell wasn't activated `-Arch amd64` in *this* Git-Bash.

**GO when:** `configure 0`, umbrella target links `0`. Record the object/lib count. **NO-GO** (and a
genuinely valuable finding for the cost of an afternoon) if a capability flag can't produce a Windows
runtime — capture exactly which one.

---

## W2 — Does install produce a coherent prefix, and do our four repairs port?

This is the repo's actual reason to exist: IREE's bare install ships almost nothing
(`EXCLUDE_FROM_ALL` on every library rule), so the recipe installs three named components and then
applies four hand-repairs. The question here is **which of those four recur, vanish, or mutate on
Windows.**

```bash
# Build everything (not just the umbrella), then install the three components the recipe uses.
cmake --build /c/iree-build
for c in IREEDevLibraries-Runtime IREEBundledLibraries IREECMakeExports; do
  cmake --install /c/iree-build --component "$c" --prefix /c/iree-prefix
done
# Repair 1: the printf subdir's install never chains into the parent.
cmake --install /c/iree-build/build_tools/third_party/printf \
  --component IREEBundledLibraries --prefix /c/iree-prefix

# Now inspect what landed:
find /c/iree-prefix -name '*.lib' | sort
ls /c/iree-prefix/lib/cmake/IREE/
```

Then walk the four Linux repairs and note each one's Windows status (compare against the prose in
`build-runtime.sh` Phase 1):

| Linux repair | What to check on Windows |
|---|---|
| **libbacktrace** (no install rule; hand-copy archive + hand-write imported target) | Does the `libbacktrace_impl` target even exist? `cmake --build /c/iree-build --target libbacktrace_impl`. IREE may use **`dbghelp`** on Windows instead → the whole repair is **N/A** (a simplification). If it exists, its path literals (`liblibbacktrace_impl.a` → `liblibbacktrace_libbacktrace.a`) are Unix `.a` names that won't port. |
| **printf subdir install** (done above) | Did `libprintf_printf.lib` (or similar) land in `/c/iree-prefix/lib`? |
| **`find_package(Threads)` missing from `IREERuntimeConfig.cmake`** | **NEEDED.** `grep -r 'Threads::Threads' /c/iree-prefix/lib/cmake/IREE/` shows it throughout the targets file. The same one-line `find_package(Threads)` insertion into `IREERuntimeConfig.cmake` that the Linux recipe applies is required. |
| **missing public headers** (`scripts/install-headers.sh` walks the `#include` graph) | After install, is `iree/runtime/api.h` and its transitive includes present under `/c/iree-prefix/include`? The gap may differ on Windows. |

> **If this breaks, ask the agent:**
> - **prefix missing archives you expected** → a component name differs on Windows, or a target is
>   `EXCLUDE_FROM_ALL` in a way the Linux install worked around differently. The agent can diff the
>   installed manifest against the documented Linux prefix.
> - **`liblibbacktrace_impl.a` not found** → almost certainly the dbghelp path above; confirm with the
>   agent whether `IREE_ENABLE_LIBBACKTRACE` is off on Windows and the repair drops entirely.
> - **archive naming (`.lib` vs `lib*.a`, no `lib` prefix)** → expected; note it. The Linux repair's
>   hardcoded names are the thing that needs a Windows branch later, not a blocker now.

**GO when:** the prefix has a populated `lib/` and `lib/cmake/IREE/`, and you've written a one-line
verdict for each of the four repairs (ports / N-A / needs-Windows-names).

---

## W3 — Consumer `find_package` + link + load `add.vmfb` (the acceptance gate)

Proves the export surface, compile-define propagation, and — the hardest Windows unknown — whether
the embedded executable inside `add.vmfb` loads on Windows.

**Reuse an existing `add.vmfb`.** It's IREE VM bytecode wrapping an **embedded-ELF** executable, which
the embedded-ELF loader maps OS-independently *by design* — so the same file a Linux build produced
should load on Windows. Grab one from a published release tarball or a local `out/` and copy it to
winbox (e.g. `/c/add.vmfb`). Do **not** try to compile a fresh one on Windows for this spike.

> **Note on the two loaders:** `add.vmfb` targets **embedded-ELF** (portable). The `SYSTEM_LIBRARY`
> loader (which would load a `.dll` on Windows, `.so` on Linux) is *enabled* but *not exercised* by
> this module — so W3 tests embedded-ELF portability, which is the point.

The repo's `test/consumer/consumer.c` is the real consumer — copy it to winbox as
`/c/spike-consumer/consumer.c` **unmodified**. For the spike, point `find_package` at
**IREE's own** package (the thin `IreeRuntimeDist` wrapper is generated in a later build
phase and isn't part of what we're de-risking). Write this `CMakeLists.txt` next to it:

```cmake
cmake_minimum_required(VERSION 3.21)
project(iree_win_spike C)
find_package(IREERuntime REQUIRED)
add_executable(consumer consumer.c)
# MSVC's default C mode predates C11 and rejects _Generic (used throughout IREE's
# atomics headers). /std:c17 is the whole Windows delta — no source changes.
set_source_files_properties(consumer.c PROPERTIES COMPILE_FLAGS "/std:c17")
target_link_libraries(consumer PRIVATE iree_runtime_unified)
```

**No edits to `consumer.c`.** Keep compiling it as C. Switching it to C++ to dodge
`_Generic` cascades into three further errors (C7555, C4576, C7560) that are artifacts of
C++ semantics, not Windows portability problems — see the W3 findings below.

```bash
# CMake 4.x (VS 2026) does NOT search <prefix>/lib/cmake/ from CMAKE_PREFIX_PATH.
# Use IREERuntime_DIR to point directly at the config-file directory.
cmake -G Ninja -B /c/spike-consumer/b -S /c/spike-consumer \
  -DIREERuntime_DIR=/c/iree-prefix/lib/cmake/IREE \
  -DCMAKE_BUILD_TYPE=Release
cmake --build /c/spike-consumer/b

# W3b — load + run. consumer takes <add.vmfb> <driver-name>; expected output includes 11, 22, 33, 44.
/c/spike-consumer/b/consumer.exe /c/add.vmfb local-sync
/c/spike-consumer/b/consumer.exe /c/add.vmfb local-task
```

> **If this breaks, ask the agent:**
> - **`find_package(IREERuntime)` can't find the config file** → CMake 4.x (VS 2026) changed its
>   prefix-path search; `CMAKE_PREFIX_PATH` no longer reaches `lib/cmake/`. Use
>   `-DIREERuntime_DIR=/c/iree-prefix/lib/cmake/IREE` instead (all caps `_DIR`).
> - **`find_package(IREERuntime)` finds the config file but fails on `Threads::Threads`** → the
>   missing `find_package(Threads)` repair (W2, repair 3). Insert `find_package(Threads REQUIRED)`
>   into `IREERuntimeConfig.cmake` before the `include()` line.
> - **link error: unresolved `iree_runtime_unified` / wrong target name** → grep the installed
>   `IREETargets-*.cmake` for the real imported-target name; MSVC static import uses `IMPORTED_LOCATION`
>   pointing at a `.lib`. Paste the targets file and the agent gives the exact `target_link_libraries`.
> - **compile error on `iree_allocator_system()`** → the `IREE_ALLOCATOR_SYSTEM_CTL` compile-define
>   didn't propagate through the export (a real defect W3 exists to catch, per `consumer.c`'s comment).
> - **C2275/C2059 `iree_atomic_int32_t: expected an expression instead of a type`** → `_Generic`
>   under MSVC's default (pre-C11) C mode. Add `COMPILE_FLAGS "/std:c17"`. Do **not** reach for
>   `LANGUAGE CXX` — see next.
> - **C7555 / C4576 / C7560** (designated initializers need `/std:c++20`; parenthesized type
>   followed by an initializer list; designators must appear in declaration order) → you are
>   compiling `consumer.c` as **C++**. All three come from the C99 compound literal at
>   `consumer.c:73`/`:85` and vanish in C mode. Go back to `/std:c17` rather than editing the
>   source; the acceptance gate is only meaningful if the consumer stays what a real consumer
>   would write.
> - **`add.vmfb` fails to load with a VM import-signature / driver-not-found error** → driver **names**
>   not URIs (`local-sync`, not `local-sync://`); if the *load* itself fails, that's the embedded-ELF
>   portability question answered NO — a headline finding. Capture the full `iree_status` print.

**GO when:** consumer compiles, links, loads `add.vmfb`, and prints the correct sum under **both**
drivers. That single run transitively proves the Windows export surface, define propagation, and
executable-format portability.

---

## Deferred — explicitly NOT in this spike (each is its own follow-on)

Naming these keeps the spike honest about what a GO does and doesn't prove. ET has shipped templates
for the first two.

- **CRT `/MD` vs `/MT`.** ET ships *both* rows (`windows-x86_64` dynamic for CPython, `-static` `/MT`
  for the JNI DLL). Since the IREE consumer is `djl-iree-engine` (JNI), a `/MT` static row is the
  likely production need. The linker does **not** catch a CRT mismatch (measured — clean link, no
  `LNK4098`); verify with `dumpbin -nologo -directives <lib> | grep -i defaultlib` (expect
  `LIBCMT/LIBCPMT` for `/MT`). Reusable: `executorch-runtime-dist/scripts/check-windows-crt.sh`,
  `test/check_windows_crt.test.sh`. Spec templates: ET's `2026-07-18-windows-static-crt-design.md`.
- **C++17 propagation.** ET found its headers require C++17 but *don't* export
  `INTERFACE_COMPILE_FEATURES`, so MSVC (C++14 default) hits a hard `#error`. `consumer.c` is C-only so
  W3 won't surface it — but any C++ consumer (the JNI shim) will. Worth a grep of IREE's headers for
  the same unstated-standard gap before shipping.
- **Packaging.** ~~`.tar.gz` → almost certainly `.zip` on Windows~~ — **withdrawn; this was an
  untested assumption and it is wrong.** Windows stays `.tar.gz`. ET, which actually shipped
  Windows artifacts, kept a single unbranched `tarball_name()` emitting `.tar.gz` and extracts
  it on its Windows jobs via Git-Bash (`executorch-runtime-dist/.github/workflows/release.yml`,
  the relocatability-smoke step). The one capability where the formats differ — symlink and
  POSIX-mode fidelity — is irrelevant here: this prefix contains **zero** symlinks and ships
  only static archives, headers, and CMake files. `tar.exe` (bsdtar) has been in-box since
  Windows 10 1803, and every path that touches the artifact already goes through Git-Bash
  anyway. Switching would force a branch into `naming.sh` (`tarball_name`/`sha_name`),
  `gen-pin.sh`, two extract steps and the upload globs in `release.yml`, and
  `test/consumer/run.sh` — five currently-unbranched paths bought with nothing but convention.
  (The repo is not zip-averse: it already ships `iree-runtime-metadata-*.zip`. Format is per
  artifact *kind*, not per platform.)
- **Provenance** (glibc floor is Linux-only; UCRT is the Windows analog — do not carry
  `glibc_build` onto a Windows manifest; note that `glibc_build` is *not* a compatibility floor
  and must not be described as one — see CLAUDE.md and `gen-manifest.sh`'s `notes.glibc_build`),
  the **CI runner** (`runs-on: windows-latest`, matrix `runs-on` derived from platform token;
  Windows is runner-native rather than containerised — the Linux container exists to pin a
  known-old compile environment and the toolchain NEVRAs, which has no Windows analog), and
  porting the **relocatability** measure/assert (ET has `test/relocatability-windows.sh` as a
  reference; there's no RPATH/patchelf on Windows, but W4 found a real absolute-path leak via
  `-natvis:`, so this is not merely a lighter check).

---

## Findings log

_(Append outcomes here as you run each probe — this section becomes the spike's deliverable.)_

- **W0:** Skipped (answered by W1).

- **W1: GO.** Default variant configures and builds without error using the same flags
  minus `-ffile-prefix-map` (clang-only). `-DCMAKE_POSITION_INDEPENDENT_CODE=ON` is a
  harmless no-op on MSVC. The umbrella target `iree_runtime_unified` links successfully.

- **W2: 3 of 4 repairs needed.**
  - **libbacktrace:** **N/A.** `cmake --build /c/iree-build --target libbacktrace_impl`
    succeeds but CMake produces no install rule for it, so the hand-copy +
    hand-write-imported-target repair is unnecessary. (An earlier draft of this log guessed
    IREE substitutes `dbghelp` on Windows. W4 disproved that — see below. libbacktrace is
    dropped outright, not replaced.)
  - **printf:** **PORTS AS-IS.** The extra `cmake --install` on the printf subdirectory
    *is* the Linux repair (`build-runtime.sh:274`) — there is nothing more to it. It is
    required on Windows exactly as on Linux; `libprintf_printf.lib` lands in
    `/c/iree-prefix/lib` only because of it. Dropping it would leave the export set
    referencing an archive the prefix doesn't contain.
  - **Threads:** **NEEDED.** `Threads::Threads` appears throughout
    `IREETargets-Runtime.cmake`. Insert `find_package(Threads REQUIRED)` into
    `IREERuntimeConfig.cmake` before the `include()` line — same one-line patch as Linux.
  - **Headers:** **NEEDED.** `iree/base/allocator.h` and 10 other headers transitively
    included from `iree/base/api.h` are missing from the prefix — the same class of gap as
    Linux. Unblocked in the spike with a blanket
    `cp -rn /c/iree/runtime/src/iree/* /c/iree-prefix/include/iree/`, which is a
    **spike expedient, not a port**: it drags `.c` files and private headers into the
    prefix, where `scripts/install-headers.sh` deliberately walks the real `#include` graph
    and copies only what's reachable. Open question for the spec: does
    `install-headers.sh` run unmodified on Windows?
  - **Archive naming (measured):** every file under `<prefix>/lib` ends in `.lib` and none
    carries a `lib` prefix — plain MSVC defaults, no surprises. Naming itself is closed. The
    tooling that hardcodes the Unix forms still needs a branch: `test/build_smoke.sh`
    (`lib/*.a`, `libiree_runtime_unified.a`, `libflatcc_*.a`). It fails loudly on a Windows
    prefix rather than producing a false green. The libbacktrace repair's `.a` literals are
    moot (repair is N/A on Windows).
  - **`llvm-nm` on COFF (measured):** reads `iree_runtime_unified.lib` fine and emits
    BSD 3-column output structurally identical to GNU nm. x86-64 COFF does not
    underscore-prefix C symbols, so identifiers appear verbatim and substring matching ports
    unchanged; undefined symbols print a blank address (2 fields) exactly as on ELF, so
    `build_smoke.sh:283`'s `$3 == s && $2 ~ /^[TtDd]$/` still selects defined-only correctly.
    New noise (MSVC-mangled literals `??_C@...`, absolute `@comp.id`/`@feat.00`) doesn't
    collide with the C identifiers being matched. **Verdict: `NM=${NM:-nm}` tool swap, not a
    rewrite.**

- **W3: GO — `consumer.c` unmodified. Two build-system deltas, zero source changes.**

  The consumer compiles, links, loads `add.vmfb`, and prints the correct sum under **both**
  `local-sync` and `local-task`. This transitively proves the Windows export surface,
  compile-define propagation, and — the headline result — that the **embedded-ELF executable
  inside a Linux-produced `add.vmfb` loads on Windows**. That was the spike's biggest unknown
  and it came back positive; no per-OS module rebuild is implied.

  - **`/std:c17` on the consumer source.** MSVC's default C mode predates C11 and rejects
    `_Generic`, which IREE's atomics headers use throughout (`iree_atomic_int32_t: expected an
    expression instead of a type`). `set_source_files_properties(consumer.c PROPERTIES
    COMPILE_FLAGS "/std:c17")` clears it. This is the entire source-language delta.
  - **CMake 4.x config-file search.** `CMAKE_PREFIX_PATH` no longer searches
    `<prefix>/lib/cmake/` under CMake 4.x (VS 2026). Use
    `-DIREERuntime_DIR=<prefix>/lib/cmake/IREE` instead (all-caps `_DIR`).

  **Dead end, recorded so it isn't rediscovered:** switching `consumer.c` to `LANGUAGE CXX`
  also clears `_Generic`, but cascades into three further errors — C7555 (designated
  initializers need `/std:c++20`), C4576 (`(Type){...}` is not C++ syntax), C7560 (C++20
  designators must follow declaration order, and `iree_hal_buffer_params_t` declares `usage`
  before `type`). All three originate from the single C99 compound literal at
  `test/consumer/consumer.c:73`/`:85` and are artifacts of C++ semantics, **not** Windows
  portability findings. Reverting to C + `/std:c17` cleared all of them at once. Per
  CLAUDE.md, the acceptance gate is only meaningful while `consumer.c` remains exactly what a
  real downstream consumer would write, so the C++ route should not be revived.

  **THIRD-PARTY-NOTICES needs re-deriving for Windows (new, found while checking the above).**
  `scripts/lib/linked-components.sh` is not automated — it is a hardcoded
  `IREE_LINKED_COMPONENTS="flatcc printf libbacktrace"` plus 58 lines of prose recording how
  that list was verified by hand; `gen-notices.sh:44` iterates it to generate the notices
  tree. Since W2 found **libbacktrace is N/A on Windows**, a Windows artifact built with the
  current list would ship a libbacktrace license for code that isn't in the artifact — the
  over-claiming failure CLAUDE.md warns about, inverted. The Windows list is therefore a
  re-derivation, not a port. **Done — see W4 below**, which confirms `flatcc` and `printf` are
  link-reachable on Windows and that libbacktrace is dropped outright (and *not* displaced by
  `dbghelp`, contrary to the guess in the W2 entry above).

  **Not exercised by W3:** C++17 propagation — `consumer.c` is C-only, so W3 never compiles a
  line of C++ and does not test whether IREE's headers export `INTERFACE_COMPILE_FEATURES`.
  Probed separately in **W5** below; the answer is negative (not a blocker).

---

## W4 — THIRD-PARTY-NOTICES re-derivation for Windows

Run after the fact against the winbox prefix
(`/c/Users/cored/workspace/iree-prefix`, 191 `.lib` archives), using the same two-step
method `scripts/lib/linked-components.sh` documents for the Linux list: (1) transitive
`INTERFACE_LINK_LIBRARIES` closure from `iree_runtime_impl`, (2) `nm` symbol cross-check.
Archives were copied to a Linux host and read with `llvm-nm`, which is toolchain-independent —
`llvm-nm` was not on winbox's PATH.

`iree_runtime_unified`'s own `INTERFACE_LINK_LIBRARIES` is a generator expression delegating to
`iree_runtime_impl`, so the closure must be rooted at `iree_runtime_impl` — same as Linux.

**Result: `IREE_LINKED_COMPONENTS="flatcc printf"` for Windows** (libbacktrace drops).

The closure from `iree_runtime_impl` is 72 targets, of which exactly five are non-IREE:

| Entry | Verdict |
|---|---|
| `flatcc_parsing` | **ACCEPT** — link-reachable; 10 `flatcc_verify_*` symbols defined in `flatcc_parsing.lib` and referenced undefined from `iree_vm_bytecode_module.lib` and `iree_runtime_unified.lib`. Identical to Linux. |
| `printf_printf` | **ACCEPT** — link-reachable; `vfctprintf`/`vsnprintf_` referenced undefined from `iree_base_base.lib` and `iree_runtime_unified.lib`. Identical to Linux. |
| `Threads::Threads` | System dependency, not a bundled component — no notice. This is what the W2 `find_package(Threads)` repair exists to satisfy. |
| `-natvis:C:/Users/cored/workspace/iree/runtime/iree.natvis` | Linker flag, not a component. **But see the relocatability note below.** |
| `-pdbpagesize:32768` | Linker flag. Harmless. |

**libbacktrace — REJECT, four independent confirmations:** no install rule (W2); no
`libbacktrace*.lib` anywhere in the prefix; zero `backtrace_create_state`/`_full`/`_pcinfo`/
`_simple`/`_syminfo` symbols across all 191 archives; and absent from `iree_base_base`'s
`INTERFACE_LINK_LIBRARIES`, where the Linux build carries it. **It is not displaced by
`dbghelp`** — the string `dbghelp` appears zero times in `IREETargets-Runtime.cmake`, and
`iree_runtime_unified.lib` references no `SymInitialize`/`SymFromAddr`/`StackWalk`/
`CaptureStackBackTrace` symbol. The symbolization path is simply not enabled in this
configuration. Shipping a libbacktrace notice on a Windows artifact would claim a license for
code that is not present in any form.

**Also rejected (physically present in `lib/`, not link-reachable — same category as Linux's
`benchmark` rejection):**
- `benchmark.lib` — 4143 defined symbols, **0** referenced undefined from
  `iree_runtime_unified.lib`. Matches the Linux finding.
- `iree_builtins_musl_bin_libmusl.lib` — **not named in either list in
  `linked-components.sh`**, so flagged here for a human decision. Not in the closure, 0
  symbols referenced from unified. The archive holds one object containing only two embedded
  wasm bitcode blobs as read-only data (`libmusl_wasm32_generic.bc`,
  `libmusl_wasm64_generic.bc`) — precompiled builtins, not linked into the CPU runtime. Same
  disposition as `benchmark`, but worth confirming the Linux prefix behaves identically rather
  than assuming.
- tracy, spirv_cross, vulkan_headers, webgpu-headers, hip-build-deps, hsa-runtime-headers,
  googletest, llvm-project — no archive in `lib/` at all. Matches Linux.

> **New relocatability finding (Windows).** The installed export set contains an absolute
> path into the *source* tree: `-natvis:C:/Users/cored/workspace/iree/runtime/iree.natvis`, in
> `iree_runtime_impl`'s `INTERFACE_LINK_LIBRARIES`. A consumer on any other machine gets a
> dangling `-natvis:` flag on their link line. This is exactly the class of leak
> `scripts/relocatability.sh` asserts against on Linux, and it means the deferred "port
> relocatability to Windows" item is **not** merely lighter than Linux as previously assumed —
> there is at least one real leak to repair. Not fixed here; recorded for the spec.

---

## W5 — C++17 propagation (the deferred item), and an upstream bug it exposed

**Verdict: NEGATIVE — ET's failure mode does not reproduce. Not a blocker for Windows.**

ET found its headers require C++17 but don't export `INTERFACE_COMPILE_FEATURES`, so MSVC
(C++14 by default) hits a hard `#error`. The export gap is real here too — **neither** the
Windows nor the Linux `IREETargets-Runtime.cmake` contains a single
`INTERFACE_COMPILE_FEATURES` entry or any `cxx_std_*` value — but it is **harmless**, because
IREE's runtime headers do not require C++17:

| Probe | Result |
|---|---|
| `iree/runtime/api.h` as C++ at MSVC **default** standard (VS 2026, cl 19.51.36248) | **compiles, exit 0** |
| same, Linux `g++ -std=c++14` | **compiles, exit 0** |

IREE's one C++17 touchpoint is a graceful feature-detect, not a requirement —
`native_module_packing.h:23`, `#if __has_include(<string_view>) && __cplusplus >= 201703L`,
gates `IREE_HAVE_STD_STRING_VIEW` and degrades to `iree_string_view_t` otherwise. (Note for
anyone re-testing: MSVC reports `__cplusplus` as `199711L` unless `/Zc:__cplusplus` is passed,
so that block stays off even under `/std:c++17`. It degrades silently rather than erroring,
which is the designed behavior.)

So the JNI-shim consumer needs no standard-version handling from us, and adding
`INTERFACE_COMPILE_FEATURES` to the export set is **not** required for Windows support.

### Unrelated pre-existing bug found while probing: `native_module_cc.h` is not self-contained

`iree/vm/native_module_packing.h` references `iree_vm_buffer_t` (8 occurrences, first at
`:589`) but includes only `base/api.h`, `base/internal/span.h`, `vm/module.h`, `vm/ref.h`,
`vm/stack.h` — **never `iree/vm/buffer.h`**. Any translation unit whose first IREE include is
`iree/vm/native_module_cc.h` fails to compile.

This is **not** a Windows issue, **not** a C++17 issue, and **not** an install-headers gap:

- `iree/vm/buffer.h` is present in *both* prefixes — it installs fine.
- Fails identically under MSVC at default, `/std:c++17`, and `/std:c++17 /Zc:__cplusplus`
  (three probes, byte-identical diagnostics), so it is standard-independent.
- **Reproduces on Linux** with `g++ -std=c++17` against `out/include`:
  `error: 'iree_vm_buffer_t' was not declared in this scope`.
- Adding `#include "iree/vm/buffer.h"` ahead of it compiles clean (exit 0) — confirming a
  missing include and nothing more.

It is an upstream IREE v3.11.0 header defect that **affects the currently shipping
`v3.11.0-10` Linux artifacts**, not something Windows introduces. No test catches it because
`test/consumer/consumer.c` is C-only and never includes a `_cc.h` header — the entire C++
header surface is untested on every platform. Consumer workaround today: include
`iree/vm/buffer.h` first.

Two decisions this raises, both out of scope for this spike: whether to report it upstream,
and whether the consumer gate should grow a C++ translation unit so the `_cc.h` surface is
covered at all.

---

## W6 — Relocatability: the leak is far larger than `-natvis:`, and MSVC has a fix

Run after W4 flagged the `-natvis:` path. **W4's "at least one real leak" materially understated
the problem.** Measured against the winbox prefix's 191 archives:

**Every archive embeds absolute build- and source-tree paths.** All 191 contain
`C:\Users\cored\...`. Taking `iree_base_base.lib` as the sample: 22 occurrences before
stripping, and **9 survive `llvm-objcopy --strip-debug`**. The survivors are all source paths:

```
C:\Users\cored\workspace\iree\runtime\src\iree\base\allocator.c
C:\Users\cored\workspace\iree\runtime\src\iree\base\string_view.c
...
```

These are `__FILE__` expansions baked in by IREE's status/assert macros — string-table content
in the link surface, which is exactly why they survive stripping. They do **not** appear on
Linux because the recipe passes `-ffile-prefix-map==iree`. W1 dropped that flag on Windows as
"a clang/gcc flag MSVC rejects… only a reproducibility nicety." That was the right call for
answering *does it build*, and the wrong assumption to carry forward: it is the direct cause of
these leaks.

### The DWARF exemption does not and must not cover this

`RELOC_ALLOW_DEBUG_PATHS` is the wrong tool here, three times over:

1. **It never fires on Windows.** `build-runtime.sh:417` gates it on `variant_sanitizer` being
   non-empty. Windows is `default`-only, so it is off by construction.
2. **It cannot see these files.** The exemption's case pattern is `*.a|*.o|*.so|*.so.*`
   (`scripts/relocatability.sh:107`). `.lib` falls to the `*)` branch and is treated as a real
   leak. Its tool is `objcopy`, which would need to be `llvm-objcopy` for COFF.
3. **It should not exempt them anyway.** 9 of 22 survive stripping, so by the assertion's own
   logic they are real. Widening the exemption to swallow them is exactly the "weaken the
   assertion" move CLAUDE.md forbids. The exemption stays gated to sanitizer variants.

### MSVC's `-ffile-prefix-map` analog works: `/d1trimfile:`

Measured on cl 19.51.36248 (VS 2026), compiling a TU by absolute path as CMake/Ninja does:

| Invocation | resulting `__FILE__` |
|---|---|
| baseline, no flag | `C:/Users/cored/trimtest/sub/foo.c` |
| `-d1trimfile:C:\Users\cored\trimtest\` | `sub/foo.c` |

Exit 0, with no warning, error, or "unrecognized flag" diagnostic.

Two caveats to carry into implementation:

- It **trims a prefix** rather than remapping to a token, so it yields `sub/foo.c` where Linux's
  `-ffile-prefix-map==iree` yields `iree/...`. Relocatability only cares that the absolute path
  is gone, but the two platforms' `__FILE__` strings will not be identical. Generated sources
  under the build tree likely need a second trim prefix.
- It is an **undocumented `/d1` flag** and could disappear in a future toolset. The mitigation is
  that the relocatability assertion is the backstop: if the flag ever stops working, the
  assertion fails loudly rather than silently shipping leaks. This argues for wiring the Windows
  assertion *before* depending on the flag.

**Net:** relocatability is the **largest** item in the Windows platform add, not the lighter
check the Deferred section originally assumed — but the fix is prevention at compile time, not a
post-hoc repair of 191 binaries.

---

## W7 — install-headers.sh on Windows

**Verdict: RAN UNMODIFIED.** No repair needed.

`scripts/install-headers.sh` was copied byte-for-byte (`scp`) to winbox and sourced from Git-Bash
under `C:\Program Files\Git\bin\bash.exe` (never the WSL `bash.exe` under `System32`, which would
build against glibc and prove nothing about this port). It uses only `grep -ohE`, `sed -E`,
`mkdir -p`, `cp`, associative-array bash builtins, and relative `iree/...` path strings — no
`find -path`, no `realpath`/`readlink -f`, no explicit `/` rewriting, and no case-sensitivity-
dependent comparison, so none of the failure points the brief flagged as plausible were actually
present in the script.

One detour: the brief's Step 2 example assumed `install-headers.sh` reads `$PREFIX`/`$BUILD_DIR`
env vars directly, but the real script only defines the `install_missing_headers` function (it's
`source`d, matching `build-runtime.sh:397-398`) and takes `<prefix>` `<iree_src>` as positional
args — so the probe driver sources it and calls `install_missing_headers "$PREFIX" "$IREE_SRC"`
explicitly, mirroring the real call site.

Second detour: the existing `/c/Users/cored/workspace/iree-prefix` (from the earlier manual
spike) was **not** used as the seed for this probe. Copying its `include/` turned up 495 `.c`
files sitting alongside 586 `.h` files — i.e. that prefix is itself contaminated by the spike's
blanket `cp -rn` workaround the brief warns about, and starting from it would validate nothing
(any `.c` files present beforehand would just persist untouched, since the script only fills
gaps and never deletes). That prefix is scratch from a manual session, not a build output this
plan owns, and was left untouched. The probe instead ran `install_missing_headers` against a
**fresh empty prefix** (`/c/Users/cored/hdr-probe`, `include/` present but empty), forcing every
header in the closure to be freshly resolved and copied from `IREE_SRC` — a strictly harder test
of the walk logic than the brief's "fill the gaps in an already-populated prefix" scenario, since
nothing was pre-seeded to short-circuit the `[ -f "$dest" ]` check.

**Run 1 — fresh empty prefix (copy path):**

```
$ "C:\Program Files\Git\bin\bash.exe" probe_run.sh
install-headers: header closure has 69 file(s); filled 69 missing from source
exit=0
H_COUNT=69
C_COUNT=0
api.h=present
allocator.h=present
```

- `.h` count: **69** (all copied fresh, since the seed prefix was empty)
- `.c` count: **0**
- `iree/runtime/api.h`: present
- `iree/base/allocator.h`: present
- exit code: **0**

The copy path alone leaves the `[ -f "$dest" ]` **already-installed skip branch** unexercised —
every one of the 69 headers hit the `cp` side of that check, none hit the skip side. That branch
is the one most exposed to Windows path and case-sensitivity quirks (it's a filesystem existence
test against a path string built by the script itself, not by an `ls`/`find` that could disagree
case-wise), so it's the one most worth measuring, not just reasoning about.

**Run 2 — same populated prefix, re-run without wiping it (skip path):**

```
$ "C:\Program Files\Git\bin\bash.exe" probe_rerun.sh
pre-rerun H_COUNT=69
pre-rerun C_COUNT=0
install-headers: header closure has 69 file(s); filled 0 missing from source
exit=0
H_COUNT=69
C_COUNT=0
api.h=present
allocator.h=present
```

All 69 headers already present in `$PREFIX/include` from Run 1; the script's own summary line
reports `filled 0 missing from source` — every one of the 69 took the `[ -f "$dest" ]` skip
branch this time, none were re-copied. `.h` count unchanged at 69 (a higher count would mean
re-copy, a lower one would mean something got removed), `.c` count still 0, exit 0, both required
headers still present.

Conclusion: the `#include`-graph walk in `install-headers.sh` is portable as written, **and** the
already-installed skip branch — the one most exposed to Windows-specific path/case quirks — was
directly exercised and is idempotent on this platform: re-running against an already-populated
prefix neither re-copies nor drops anything. No Windows-specific repair is needed for Task 2;
`scripts/install-headers.sh` is unchanged in this commit.

## W8 — `/d1trimfile:` on the CI toolset (cl 19.44)

The earlier W6 measurement of `/d1trimfile:` was taken on `winbox`'s cl **19.51** (VS 2026),
which is not the toolset CI actually uses. `winbox` has no VS 2022 install alongside 2026
(`vswhere -products *` on the host lists only `C:\Program Files\Microsoft Visual Studio\18\Community`,
i.e. the "18"/2026 line), so this measurement was taken on a real `windows-2022` GitHub Actions
runner via a throwaway `workflow_dispatch`/`push`-triggered workflow
(`.github/workflows/probe-d1trimfile.yml`, pushed and removed in this same commit range — final
green run: https://github.com/measly-java-learning/iree-runtime-dist/actions/runs/30227472685).

**Toolset measured:** `Microsoft (R) C/C++ Optimizing Compiler Version 19.44.35228 for x64` —
matches the pinned CI toolset (cl 19.44.35228.0, VS 2022 Enterprise, toolset 14.44.35207) exactly.

**Probe (`cmd` shell, no `MSYS_NO_PATHCONV` needed — this is a native `cmd` step, not Git-Bash, so
there is no leading-`/` path conversion to guard against):**

```
mkdir C:\trimtest\sub
cd /D C:\trimtest
echo const char* f(void){ return __FILE__; } > sub\foo.c

cl -nologo -c -Fo:base.obj C:\trimtest\sub\foo.c
  BASE_EXIT=0
  strings(base.obj) match: C:\trimtest\sub\foo.c

cl -nologo -c -d1trimfile:C:\trimtest\ -Fo:trim.obj C:\trimtest\sub\foo.c
  TRIM_EXIT=0
  strings(trim.obj) match: sub\foo.c

cl -nologo -c -d1trimfile:C:\trimtest\ -Fo:t2.obj C:\trimtest\sub\foo.c 2> diag.txt
  DIAG_EXIT=0
  diag.txt: empty (no warning/error/unrecognized text)
```

Two bugs surfaced and were fixed before this reading, both ordinary friction, not trip
conditions: (1) plain `cd C:\trimtest` on a `D:`-rooted GH Windows runner updates only `C:`'s
remembered directory without switching the active drive — needs `cd /D`; (2) a trailing backslash
immediately before a closing double-quote (`"-d1trimfile:C:\trimtest\"`) is consumed by CRT argv
parsing as an escaped quote, silently absorbing the rest of the command line into one argument
(`D8003: missing source filename`) — since the flag has no embedded spaces, the fix is to drop
the quoting entirely rather than escape it.

**Before/after `__FILE__`:**

| Build | `__FILE__` string embedded in the `.obj` |
|---|---|
| baseline (no flag) | `C:\trimtest\sub\foo.c` (absolute) |
| `-d1trimfile:C:\trimtest\` | `sub\foo.c` (relative to the trim prefix) |

**Verdict: parity holds.** Baseline is absolute, the trimmed build is relative, both compiles
exit 0, and `diag.txt` carries no warning/error/unrecognized-flag text on cl 19.44.35228 — exactly
the CI toolset. None of the fallback trip conditions in the design's "Fallback policy" section
fire. Tasks 8–9 proceed on the Linux-parity path: the string-scan assertion plus `/d1trimfile:`
as compile-time prevention, ported to `.lib`/`.obj` via `llvm-objcopy` for COFF, same as W6
already scoped.
