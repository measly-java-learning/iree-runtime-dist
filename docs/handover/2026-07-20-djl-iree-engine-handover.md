# Handover to `djl-iree-engine`: what `iree-runtime-dist` actually ships

**Date:** 2026-07-20
**From:** the `iree-runtime-dist` build
**To:** whoever owns the Java/JNI consumer (author of `iree-runtime-dist-wishlist.md`)
**Status:** `v3.11.0-3` published and independently verified end to end

Everything below was read off the published artifact, not from the design docs. Where I could
not verify something, it says so explicitly.

---

## 0. The one-paragraph version

The wishlist is satisfied in substance, but **three of its structural assumptions were wrong**,
and each changes consumer code:

1. **Nothing ships as a `.so`.** The artifact is 198 static archives. Every RPATH / `patchelf` /
   "glibc floor of the shipped `.so`" concern in the wishlist is moot — *you* build the only
   shared object in the system.
2. **`glibc_build` is not a floor** and must never be read as one.
3. **One variant ships (`default`), not four**, and it is not the wishlist's `minimal`.

Plus one correction to a factual claim the wishlist makes about libstdc++ (§6).

---

## 1. Get it

```
https://github.com/measly-java-learning/iree-runtime-dist/releases/tag/v3.11.0-3
```

Three assets: the tarball, its `.sha256`, and `IreeRuntimePin.cmake`. The pin drops straight into
`native/cmake/IreeRuntimePin.cmake` — it is the stub seam wishlist #1 described, and it is
verified: I downloaded the published pin, followed its URL, and its recorded SHA-256 matches the
2.43 MB tarball byte-for-byte.

**The pin is coordinates-only (consumer report #2).** `IreeRuntimePin.cmake` defines *data* — a
URL/SHA helper — and nothing else. It does not fetch, extract, or `find_package`. Dropping it in
and `include()`-ing it is step one of three; your `CMakeLists.txt` still performs the fetch and
points `find_package` at the extracted prefix. The full chain:

```cmake
include(IreeRuntimePin.cmake)                        # 1. coordinates only

set(IREE_RUNTIME_VARIANT default)   # or "tsan" -- see "TSan variant" below
iree_runtime_dist_url("${IREE_RUNTIME_VARIANT}" linux-x86_64 _url _sha)

include(FetchContent)                                # 2. you fetch + extract
FetchContent_Declare(iree_runtime_dist URL "${_url}" URL_HASH "SHA256=${_sha}")
FetchContent_MakeAvailable(iree_runtime_dist)

list(APPEND CMAKE_PREFIX_PATH "${iree_runtime_dist_SOURCE_DIR}")
find_package(IreeRuntimeDist REQUIRED)               # 3. then find_package
```

**Clean break from what this doc originally showed you.** The pin used to define flat
`IREE_RUNTIME_URL_default_linux-x86_64` / `IREE_RUNTIME_SHA256_default_linux-x86_64` variables
directly. Those are gone as of the variant-matrix release — do not grep your build for them.
`iree_runtime_dist_url(variant, platform, out_url, out_sha)` is the fixed selector now: pass it
the variant and platform, it sets your two output variables and `FATAL_ERROR`s if that combo was
never built. Only the variant you resolve gets `FetchContent`ed — the other variant's `set()`
lines in the pin are inert data, so picking `default` never downloads `tsan` or vice versa.

### TSan variant

A `tsan` variant now ships alongside `default`, built with `-fsanitize=thread`. Select it by
setting `IREE_RUNTIME_VARIANT=tsan` before calling `iree_runtime_dist_url` above — everything
else in your `find_package`/`target_link_libraries` stays identical, since the umbrella target
propagates `-fsanitize=thread` as an `INTERFACE` flag automatically. `manifest.json` and
`BUILDINFO` record a `sanitizer` field (`thread` for `tsan`, absent for `default`) so you can
fail fast at configure time if `IREE_DJL_TSAN=ON` but the fetched variant isn't sanitized. Your
TSan build itself must use clang (`-DCMAKE_C_COMPILER=clang` / `-DCMAKE_CXX_COMPILER=clang++`) to
match the toolchain this variant was compiled with. The `tsan` prefix ships
`share/iree-runtime-dist/TSAN.md` with the full recipe (build/link notes, the ASLR/`mmap_rnd_bits`
workaround, suppressions wiring) — read that rather than re-deriving it here.

---

## 2. How you consume it — delete `ResolveIree.cmake`

Wishlist #2 asked for a real install tree with `IREERuntimeConfig.cmake`. You get that, **plus a
thin dist layer on top**. Use the dist layer, not upstream's config directly:

```cmake
find_package(IreeRuntimeDist REQUIRED)
target_link_libraries(your_jni_shim PRIVATE iree-runtime-dist::runtime)
```

That is the entire link surface. This exact two-line form is what the project's acceptance test
compiles and runs on every release, deliberately — a harness that differs from a real caller is
how a real defect got masked once during this build (§7).

Every item wishlist #2 listed as hand-derived guesswork is now carried as target properties:

| Wishlist pain | Status |
|---|---|
| `libiree_runtime_impl.a` is only 3 objects; real target is `libiree_runtime_unified.a` | Handled — the umbrella target resolves to the right closure |
| Hand-adding `libflatcc_parsing.a` / `libflatcc_runtime.a` | Handled — transitive |
| Injecting `IREE_ALLOCATOR_SYSTEM_CTL=iree_allocator_libc_ctl` | Handled — propagated as an `INTERFACE` compile definition |
| Split source/build include dirs | Handled — merged by the install |
| `--start-group` / `--end-group` ordering | Handled — do **not** add these yourself |

**Do not hand-list archives.** `lib/` contains 198 `.a` files; only the closure of
`iree_runtime_unified` is yours to link. Two of the others actively hurt (§6).

The dist config also exposes the manifest as CMake variables, so you can fail fast at configure
time instead of at load time:

```cmake
IREE_RUNTIME_DIST_VERSION           "3.11.0"
IREE_RUNTIME_DIST_COMPILER_VERSION  "3.11.0"
IREE_RUNTIME_DIST_RUNTIME_COMMIT    "e4a3b040..."
IREE_RUNTIME_DIST_ADD_VMFB          <prefix>/share/iree-runtime-dist/add.vmfb
IREE_RUNTIME_DIST_ELEMENT_TYPES     <prefix>/share/iree-runtime-dist/element_types.json
IREE_RUNTIME_DIST_STATUS_CODES      <prefix>/share/iree-runtime-dist/status_codes.json
IREE_RUNTIME_DIST_MANIFEST          <prefix>/share/iree-runtime-dist/manifest.json
```

---

## 3. Changes to the wishlist you must absorb

### 3.1 Static archives only — there is no shipped `.so`

**Verified: 0 `.so` files, 198 `.a` files.**

The wishlist repeatedly reasons about "the shipped `.so`" — RPATH/RUNPATH scrubbing with
`patchelf`/`chrpath` (#2), the glibc floor "the shipped `.so` holds" (#8). None of that applies.
There is no shared object in the artifact. **Your JNI shim is the only `.so`**, which means:

- RPATH/RUNPATH hygiene is entirely yours; nothing to scrub in what we ship.
- PIC matters, and it is on. **Verified** — sampled objects from `libiree_runtime_unified.a`
  carry GOTPCREL/PLT32 relocations, and `manifest.json` attests
  `CMAKE_POSITION_INDEPENDENT_CODE: ON`. Static archives link into your shared object cleanly.
- Symbol visibility — **answered, measured (consumer report #4).** Link the umbrella target into
  your `.so` with `-Wl,--exclude-libs,ALL` (GNU ld / LLD): on the resulting `libiree_djl.so`,
  1348 IREE symbols are linked in and **0 are exported** — the dynamic table is just the 4 JNI
  entry points, the 2 JNI lifecycle hooks, and a few weak C++ template symbols from the shim's own
  TUs. `--exclude-libs,ALL` suppresses symbols from static archives specifically, which is exactly
  this dist's shape (0 `.so`, 198 `.a`), so it is the right tool. Caveats: it does not suppress
  the consumer's own weak/vague-linkage symbols (add a version script or `-fvisibility=hidden` if
  you want a truly minimal table), and it is linker-specific — a different linker (or Windows, once
  that platform ships) needs the equivalent.

### 3.2 `glibc_build` is not a floor — this replaces wishlist #8's framing

`manifest.json` records `"glibc_build": "2.28"`. That is **the glibc of the container the
archives were compiled against**, and it is *not* a compatibility floor.

Static archives carry *unversioned* undefined libc symbols. glibc symbol-version resolution
happens at **your** final link, not in the archive. So scanning our `.a` files for `GLIBC_x.y`
strings cannot produce a floor — the technique is structurally incapable of it. The manifest says
this in its own `notes.glibc_build` field; please propagate that wording rather than
re-deriving it.

Practical consequence: **your JNI `.so`'s glibc floor is set by the container you link in**, not
by us. The wishlist's instinct — build in manylinux — is right, but it applies to *your* link
step now.

The wishlist's other two glibc observations survive intact: the floor is unconstrained by any
torch wheel, and clang is independent of the container's glibc.

### 3.3 One variant ships, and it is not `minimal`

The wishlist proposed `minimal` / `default`(`perf`) / `devtools` / `gpu`. **Only `default`
ships**, and it is a merge of the first two:

```
IREE_HAL_DRIVER_LOCAL_SYNC:              ON
IREE_HAL_DRIVER_LOCAL_TASK:              ON
IREE_HAL_EXECUTABLE_LOADER_EMBEDDED_ELF: ON
IREE_HAL_EXECUTABLE_LOADER_SYSTEM_LIBRARY: ON
IREE_ENABLE_RUNTIME_TRACING:             OFF
IREE_ENABLE_THREADING:                   ON
```

So one artifact gives you both the single-threaded and multithreaded execution paths — selected
**at runtime by driver name**, not at build time. This is better than the wishlist's plan for
you: no variant switch needed to A/B `local-sync` against `local-task`.

`IREE_ENABLE_THREADING=ON` and `local-task` is compiled in, so the `minimal` target's
TSan-free-*by-construction* property is gone. But the TSan-clean leg survives *empirically*
(consumer report #7, measured): selecting `local-sync` at runtime spawns **zero** threads even
with `local-task`'s worker pool linked in — verified two ways during an active
load/invoke run (`strace` saw no `clone`/`clone3`; `/proc/<pid>/status` showed `Threads: 1`),
with zero TSan data races over 100 cycles. So a consumer that only ever creates `local-sync`
devices gets the same thread-free execution the old `minimal` build gave — as a fact about IREE's
driver implementation, not a linker-enforced guarantee. This closes the "your call, untested"
gap for TSan purposes. (Not tested: `local-task` itself, which spawns workers by design and needs
real TSan coverage of concurrent invokes; and thread-count stability inside a long-running
JVM-embedded process.) Note this argues against needing a `minimal` variant *for TSan* — it does
not address `minimal`'s other possible motivations (binary size, symbol count).

Separately, if you want a genuinely instrumented TSan build of the runtime itself (to race-test
`local-task`, or your own code that calls into it), that is now the **`tsan` variant** — see §1's
"TSan variant" and the shipped `TSAN.md`.

Not shipped: `devtools` (tracing is OFF — wishlist's Tracy/allocation-stats variant does not
exist yet) and `gpu`. Both remain open requests.

### 3.4 The compiler is out of contract — and the version story resolved differently

The wishlist (#3) asked us to "ideally pin/ship" a matching `iree-compile`. **We never ship it.**
`IREE_BUILD_COMPILER=OFF` always; it appears only as a version string.

What you get instead is a pairing contract:

```json
"iree_compile_version": "3.11.0",
"vm_bytecode_version": "17.0",
"runtime_commit": "e4a3b0405d7d23554da26403658d0e8c3c5ecf25",
"iree_tag": "v3.11.0"
```

Install `iree-base-compiler==3.11.0` from pip and your `.vmfb`s load by construction.

**This dissolves the version-alignment saga rather than solving it.** The skeleton chased a
nightly (`3.12.0rc20260717`) to match a from-source `main` runtime at `a869dc3`. This project
anchors on **stable `v3.11.0`** and never `main` — mixing a main-branch runtime with a stable
compiler is precisely the import-signature mismatch that cost you that detour. Both sides of the
pair are now stable, tagged, and recorded. Do not point the consumer at a `main` checkout.

`vm_bytecode_version: "17.0"` is the fail-fast axis wishlist #3 asked for: compare it before
loading a `.vmfb` built elsewhere and emit a clear error instead of a cryptic signature mismatch.

The wishlist's note that **the pip `iree-base-runtime` wheel is not linkable at any version** is
confirmed and recorded in `manifest.json` so it is not rediscovered.

### 3.5 Third-party notices: three entries, and no LLVM

Wishlist #9 says "IREE vendors LLVM, flatcc, and more." `THIRD-PARTY-NOTICES/` contains exactly:

```
flatcc/  libbacktrace/  printf/
```

**No LLVM** — because with `IREE_BUILD_COMPILER=OFF` no LLVM code is in the artifact. This is
measured, not inferred: a release-gating check scans all 198 archives and finds **zero** defined
LLVM/MLIR symbols. Claiming an LLVM license here would over-claim.

`libbacktrace` is the entry you would not have predicted — it arrives through
`iree_base_base`. For the classifier JAR's `META-INF/licenses/`, copy the directory as-is; do
not derive the list from IREE's submodule list, which is a different and much larger set that
includes code never linked.

---

## 4. Generated constants — wishlist #4 and #5, delivered

`share/iree-runtime-dist/element_types.json` (24 entries) and `status_codes.json` (19 entries),
emitted by a program compiled against the shipped headers, then enriched by
`scripts/enrich-constants.py` into a self-describing shape. **Your hard-won value checks out**,
now as one field of a richer entry:

```json
"FLOAT_32": { "value": 553648160, "hex": "0x21000020", "numerical_type": "FLOAT_IEEE",
              "category": "float", "signed": null, "bit_count": 32 }
```

(`553648160` / `0x21000020` is the wishlist's corrected value, confirmed — `SINT_32` is
`285212704` / `0x11000020`, `INT_32` is `268435488` / `0x10000020`, `BFLOAT_16` is `570425360` /
`0x22000010`, same as before.) `numerical_type`, `category`, `signed`, and `bit_count` are decoded
from `value` itself (IREE packs `value = (numerical_type << 24) | bit_count`) against IREE's own
enum, not a hand-copied table.

Generate `IreeDataTypes.java` from this JSON at build time. Do not transcribe it — the whole
reason this file exists is that `FLOAT_32` was hard-coded as `0x00000120` and stayed invisible
through six tasks.

`status_codes.json` gives you typed Java exceptions (`OK=0`, `INVALID_ARGUMENT=3`, …) instead of
a `RuntimeException` carrying only a message string; each entry is now `{ "value": <int>,
"description": "<curated one-line meaning>" }` rather than a bare integer.

**Schema, the boundary, and non-CMake discovery (consumer report #6).** Both files carry a
top-level `schema_version` and are no longer a flat `{ "NAME": <int> }` map — see the entry shape
above. `element_types.schema.json` and `status_codes.schema.json` (JSON Schema 2020-12, per-field
`description`s) ship alongside the data for validation and codegen. **This removes only the
objective half of the mapping problem.** Each type's value, numerical-type category, signedness,
and bit width are now authoritative, no-judgment data straight from IREE's headers. But *which*
IREE type best fits one of your own native types is still your call: IREE offers `INT_32`
(sign-agnostic, `signed: null`), `SINT_32` (`signed: true`), and `UINT_32` (`signed: false`) as
genuinely distinct types, and there is no IREE-authoritative "canonical signed 32-bit" — choosing
one for your Java `int` is policy, not a fact this data can resolve for you. Enrichment shrinks
and de-risks that integration work; it does not eliminate it.

The **stable path convention** is `share/iree-runtime-dist/<name>` under the extraction/install
prefix, for *every* artifact in that dir (`element_types.json`, `element_types.schema.json`,
`status_codes.json`, `status_codes.schema.json`, `manifest.json`, `add.vmfb`, and — tsan only —
`TSAN.md`). That relative layout is a contract, not an accident of how
`IreeRuntimeDistConfig.cmake` is written, so a Gradle/Python/Rust consumer can hardcode it without
going through CMake variables or `FetchContent` internals. The tarball also ships
`share/iree-runtime-dist/README.md` documenting exactly this, so non-CMake consumers have it
in-artifact rather than having to reverse-engineer it.

**A second, CMake-free path starting with the next tagged release:** the `release` job also
uploads `iree-runtime-metadata-<version>.zip` as its own release asset — the same four JSON/schema
files plus a README, built once per release (the constants are variant-independent). One stable
URL, unzip, read: no `FetchContent`, no CMake, no `build.sh:97`-style copy-and-restage across
Gradle/CI jobs. This is not published yet as of `v3.11.0-3`; it lands with the next tag.

---

## 5. `add.vmfb` — wishlist #6, delivered

`share/iree-runtime-dist/add.vmfb`, compiled by `iree-base-compiler==3.11.0`, guaranteed to load
against this runtime. Path available as `IREE_RUNTIME_DIST_ADD_VMFB`.

Use it exactly as intended: a post-link smoke test that the runtime loads and runs a known
module, **with no compiler installed anywhere in your build**. Its signature is
`@add(tensor<4xf32>, tensor<4xf32>) -> tensor<4xf32>` — **four `f32` inputs**, elementwise sum
(source: `emit/add.mlir`, `arith.addf`). Our acceptance test asserts `[11, 22, 33, 44]`. The
element-type tag baked into the module is `FLOAT_32` (`0x21000020`); passing `i32` inputs is
rejected at the buffer-view assert with `INVALID_ARGUMENT ... expected f32 (21000020)`. (Corrected
per consumer report #5 — an earlier revision of this doc wrongly said `int32`; the golden values
were always right, only the element-type claim was wrong.)

---

## 6. Correction: IREE *does* contribute C++ symbols — but not to your link

Wishlist #8 states: *"IREE's runtime is C; the only libstdc++ dependency in the shipped `.so` is
the engine's own C++ shim, so libstdc++ versioning is a shim-toolchain choice and IREE adds
nothing to it."*

**The conclusion holds; the premise as stated does not.** Scanning all 198 shipped archives finds
**385 undefined C++ symbols** (`std::`, `__cxa_`, `operator new`). They are confined to exactly
two archives:

```
libbenchmark.a               371
libiree_testing_benchmark.a   14
```

Neither is in `iree_runtime_unified`'s link closure, so `iree-runtime-dist::runtime` pulls in no
C++ and your libstdc++ story really is yours alone. But the claim "IREE's runtime is C" is only
true *of what you link* — if anyone hand-lists archives from `lib/` (§2), they can drag
libstdc++ in by accident. One more reason to link the umbrella target and nothing else.

---

## 7. Hard-won linking lessons

These cost real time. In rough order of how likely you are to hit them:

**Driver names are exact strings, not URIs.** `iree_runtime_instance_try_create_default_device`
does an exact string compare against the registered driver name. Use `"local-sync"` and
`"local-task"`. **`"local-sync://"` fails to resolve.** This looks like a URI scheme and is not.

The working sequence, verbatim from our acceptance test:

```c
iree_runtime_instance_options_initialize(&instance_options);
iree_runtime_instance_options_use_all_available_drivers(&instance_options);
iree_runtime_instance_create(&instance_options, host_allocator, &instance);
iree_runtime_instance_try_create_default_device(
    instance, iree_make_cstring_view("local-task"), &device);   // exact name
iree_runtime_session_create_with_device(...);
iree_runtime_session_append_bytecode_module_from_file(session, module_path);
iree_runtime_call_initialize_by_name(...);
```

**`find_package(IREERuntime)` alone used to fail at *configure* time.** Upstream's
`IREERuntimeConfig.cmake` never calls `find_package(Threads)` before including its targets file,
so a bare `find_package` died before you ever reached a link. We repair this in the shipped
config, so you will not see it — but if you ever consume an unrepaired IREE install tree, that is
the symptom, and it is a configure-time error, not a link error.

This one is worth dwelling on: it was **missed by an agent's own test harness** and caught only
by an independent test using the exact minimal `CMakeLists.txt` a real user writes. The harness
had extra scaffolding that happened to satisfy Threads. If your JNI test harness differs from
what a real consumer writes, it can mask exactly this class of defect.

**Do not add `--start-group`/`--end-group`.** The export set carries correct link ordering for the
mutually-recursive archives. Adding your own grouping is at best redundant.

**`libiree_runtime_impl.a` is still a 3-object trap.** It is in `lib/`. It is not what you want.
Link the umbrella target.

**Relocatability is asserted, not assumed.** No absolute build or source paths survive in the
shipped prefix — there is both a repair step and a gate that fails the release. If you ever see
a `/work/...` or `/iree/...` path in a status message or CMake variable, that is our bug; report
it.

---

## 8. What is still open

Things the wishlist asked for that do **not** exist yet, so you can plan around them:

- **`devtools` variant** — Tracy tracing and allocation statistics. `IREE_ENABLE_RUNTIME_TRACING`
  is OFF. This blocks the latency/footprint observability work.
- **`gpu` variant** — as the wishlist correctly framed it, a milestone, not a flag flip.
- **`windows-x86_64`** — `linux-x86_64` only. `platforms_json` is the single source of truth for
  the matrix, so adding one is mechanical on our side.
- **A `minimal` (TSan-free-by-construction) variant** — see §3.3; currently you get runtime driver
  selection instead.

If you want any of these, file against `measly-java-learning/iree-runtime-dist`. Variant and
platform lists are single-sourced, so additions are cheap.

---

## 9. Confidence

**Verified by running it**, not by reading code:

- The published pin resolves; SHA-256 matches the downloaded tarball exactly.
- Extract into a container with no build tree and no IREE source, `find_package`, compile, load
  `add.vmfb`, run, assert `[11, 22, 33, 44]` — passing on **both** `local-sync` and `local-task`.
- 0 `.so`, 198 `.a`, PIC relocations present, 0 LLVM/MLIR symbols, C++ symbols confined to two
  unlinked archives.
- All 24 element-type and 19 status-code values read from the shipped JSON.

**Both originally-open questions are now answered by the consumer, measured** (reports #4, #7):
- **Symbol visibility (§3.1):** `-Wl,--exclude-libs,ALL` exports 0 IREE symbols from the JNI `.so`.
- **`local-sync` TSan-clean leg (§3.3):** runtime `local-sync` selection spawns 0 threads and
  reports 0 races even with `local-task` linked in.

Still genuinely untested here: co-loading alongside another DJL native engine in one JVM (though
a zero-IREE-symbol export table makes a collision structurally implausible), and `local-task`'s
own thread behavior under TSan — which is what the new **`tsan` variant** exists to let you
race-test (§1).
