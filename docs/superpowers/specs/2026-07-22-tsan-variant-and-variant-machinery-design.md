# TSan variant + multi-variant machinery — design

**Date:** 2026-07-22
**Status:** Approved design, pre-implementation
**Closes:** #9 (publish a ThreadSanitizer-instrumented runtime variant), #10 (consumer-side
packaging requirements for a variant matrix). Also resolves the pin-naming scaling concern in #3.
**Supersedes for the variant axis:** the single-`default`-variant assumption in
`2026-07-19-iree-runtime-dist-design.md`.

---

## 1. Motivation

The project ships exactly one runtime variant (`default`: Release, uninstrumented). The
consumer `djl-iree-engine` added `local-task` (multithreaded) support to its JNI shim and wants a
ThreadSanitizer gate over the submit→execute handoff between its calling thread and IREE's
`iree-worker-N` threads. That gate is unusable today: TSan against the uninstrumented `default`
runtime reports only false positives, because TSan cannot observe IREE's internal happens-before
edges (`iree_atomic_*`, the task executor's semaphores/notifications, resource-set refcount
release/acquire) when those live in uninstrumented archives. Confirmed from the shipped artifact:
`BUILDINFO` records `variant=default`, `CMAKE_BUILD_TYPE=Release`, and `nm` over `lib/*.a` finds
zero `__tsan_*` symbols; the consumer's race reports print `<null>` frames precisely because TSan
has no instrumentation for them.

The fix is a `tsan` variant built with `-fsanitize=thread`, so a consumer's full-program TSan
build is instrumented end-to-end and the runtime's synchronization carries visible happens-before
edges. Adding a second (and soon third) variant also forces the packaging/selector work in #10.

## 2. Grounding findings

- **TSan builds and links in the current image with no new packages.** A `-fsanitize=thread`
  program compiles and links inside `iree-runtime-dist-build:linux-x86_64` (clang 21.1.8, glibc
  2.28). So the `tsan` variant is a new flag set, not toolchain work.
- **TSan runs cleanly in CI — the §7 spike (CLOSED) confirmed no ASLR workaround is needed.** The
  `unexpected memory mapping` failures (~65%, 39/60) seen during design were specific to the local
  dev host, which runs `vm.mmap_rnd_bits=32`. The GitHub-hosted runner measured in the spike
  (kernel 6.17-azure) already defaults to `mmap_rnd_bits=28`, where TSan ran clean **200/200** with
  no fix — the earlier assumption that GitHub runners ship 32 was wrong. §4.3's gate keeps an
  idempotent `sudo sysctl -w vm.mmap_rnd_bits=28` step only as belt-and-suspenders insurance
  against a future runner-default change. See `docs/superpowers/notes/2026-07-22-tsan-ci-spike.md`.
- **The variant plumbing is already single-sourced.** `scripts/lib/variants.sh`
  (`variant_flags`, `known_variants`) → `scripts/lib/cmakeflags.sh`
  (`common_flags`, `effective_cmake_flags`, deduped by flag name with the variant winning). The
  same abstraction extends to more variants cleanly.
- **Two gaps the machinery must close.** (a) The release matrix hardcodes `variant: [default]` in
  the `build` and `verify` jobs, rather than sourcing from `variants.sh` the way the platform
  matrix sources `platforms_json` from `naming.sh`. (b) `-fsanitize=thread` is a compiler flag,
  not a `-D` cache option, so it needs an injection point into `CMAKE_C_FLAGS`/`CXX_FLAGS`
  (currently carrying only `$PREFIX_MAP`), which `variant_flags` does not provide.
- **Current pin format is the thing #10 wants replaced.** `IreeRuntimePin.cmake` emits
  `IREE_RUNTIME_URL_default_linux-x86_64` / `..._SHA256_...` and expects the consumer to
  string-build those names to select a variant.

## 3. Scope

**In:** the variant machinery (matrix fan-out from `variants.sh`, pin selector, BUILDINFO/manifest
build-mode, opt-in fetch) and the `tsan` variant, proven under a real TSan acceptance gate.

**Out, explicitly:**
- **`asan`** — #10 §4: the consumer's leak gate is LSan-based and already catches leaks against
  `default` (LSan/ASan intercept libc `malloc`/`free` regardless of runtime instrumentation). An
  ASan variant would only add use-after-free detection *inside* IREE, which the consumer does not
  currently need. Not built.
- **`tracy`** — a fast follow, not this round. The machinery is designed so `tracy` lands as a new
  `variant_flags`/`variant_cflags` entry plus its own symbol-containment check (#10 §4's
  `-Wl,--exclude-libs,ALL` question), with no structural change. Its open questions (listen-port
  model, compiler debug-flag coupling for symbolization) are deferred with it.

## 4. Design

### 4.1 Variant machinery

`scripts/lib/variants.sh` becomes the single source of truth for the variant axis, mirroring
`naming.sh` for platforms:

- `known_variants()` → `default tsan`.
- Add `variants_json()` (JSON array, for the Actions matrix via `fromJson()`), mirroring
  `platforms_json()`.
- Add **`variant_cflags <variant>`** — extra compiler flags a variant contributes to
  `CMAKE_C_FLAGS`/`CXX_FLAGS`. Empty for `default`; `-fsanitize=thread -g` for `tsan`. This is the
  new injection point for flags that are not `-D` cache options.

`build-runtime.sh` composes the compiler-flags string from both sources:
`CMAKE_C_FLAGS="$PREFIX_MAP $(variant_cflags "$VARIANT")"` (same for CXX). `variant_cflags` flows
into the recorded provenance, so BUILDINFO/`manifest.json` cannot diverge from the build.

The release matrix threads `variants_json` through the `setup` job's outputs (new
`variants` output), and the `build`/`verify` job matrices consume it via
`fromJson(needs.setup.outputs.variants)` — deleting the two hardcoded `variant: [default]` lists.

`CMAKE_BUILD_TYPE`: **`Release` for every variant**, including `tsan`. Symbolized TSan frames come
from `-g` in `variant_cflags`, not from `RelWithDebInfo`. This is deliberate and load-bearing:
switching `tsan` to `RelWithDebInfo` would make CMake emit the export under a different config name
(`IREETargets-Runtime-relwithdebinfo.cmake`, `IMPORTED_LOCATION_RELWITHDEBINFO`), silently breaking
the recipe's libbacktrace repair and the relocatability assertion, both hardcoded to the `RELEASE`
config. `Release` + `-g` yields optimized code with debug info and keeps the export config name
`release`, so every existing repair applies unchanged. (Discovered during plan grounding; this
supersedes an earlier draft that used `RelWithDebInfo`.)

### 4.2 The `tsan` variant

- **Flags:** common set (compiler OFF, static, PIC, threading ON, `local-sync`+`local-task`,
  `embedded-elf`+`system-library`, `Release`) + `variant_cflags` = `-fsanitize=thread -g`. Same
  `CMAKE_BUILD_TYPE` as `default` — see §4.1 for why not `RelWithDebInfo`.
- **Same everything else as `default`:** `runtime_commit`, `iree_version`, `vm_bytecode_version`,
  glibc floor, platform set, and the *same manylinux 2.28 image* (#10 §3 — no ABI skew, no
  consumer container breakage, `gh attestation` on every variant tarball unchanged).
- **INTERFACE flag propagation (#10 §2):** in the tsan build's generated
  `IreeRuntimeDistConfig.cmake`, the `iree-runtime-dist::runtime` umbrella target carries
  `INTERFACE` `-fsanitize=thread` on **both** compile options and link options. Linking the tsan
  variant instruments the consumer's whole program automatically — they cannot mismatch flags.
  The target **name and semantics stay byte-for-byte identical to `default`** (#10 §1); only this
  interface flag differs. No hand-listed archives, no `--start-group`, unchanged.

### 4.3 The TSan acceptance gate

**§7 spike CLOSED (2026-07-23): TSan runs cleanly on GitHub-hosted runners with no workaround**
(runner default is `mmap_rnd_bits=28`, 200/200 clean). The gate below runs as designed; the verify
job keeps an idempotent `sudo sysctl -w vm.mmap_rnd_bits=28` step only as insurance against a
future runner-default change. B-vs-C (suppressions) is still resolved empirically in Task 9.

The `verify` job stays a matrix over variants; the consumer e2e (`test/consumer/`) adapts based on
the variant's recorded `sanitizer` mode — which is exactly what a real consumer running a TSan
gate would do, so the harness stays "what a real consumer writes":

- **`default`:** unchanged — build, load `add.vmfb`, run under `local-sync` and `local-task`,
  assert `[11, 22, 33, 44]`.
- **`tsan`:** the harness links the tsan target (auto-instrumented via the INTERFACE flag), runs
  `add.vmfb` under **`local-task`** with `TSAN_OPTIONS=halt_on_error=1`, and asserts **zero** TSan
  reports in addition to the correct result. `local-task` is the meaningful driver — it is the
  worker pool whose handoff the consumer races against.

**B-or-suppressions, decided empirically (never build-only):**
- The default target is gate **B**: run the harness under TSan over `local-task` and require it
  clean. This is the only outcome that proves what #9 asks for.
- If IREE's custom futex/atomic primitives (`iree/base/internal/synchronization.c`) produce TSan
  *blind-spot* false positives that instrumentation cannot resolve, the fallback is **C**: ship a
  curated `share/iree-runtime-dist/tsan.supp`, run the gate with it, and expose its path to the
  consumer (§4.5). This *extends the mechanism*; it never weakens the assertion to build-only.
- Which of B/C applies is resolved during implementation by actually building IREE under TSan and
  running the harness. The plan carries both paths.

**Named risk (not hidden):** if the harness surfaces a *genuine* internal race on the `local-task`
path (not a blind spot), no suppressions file honestly covers it. The correct outcome is reporting
it upstream, not shipping a variant that claims TSan-clean when it is not. Judged unlikely given
the consumer's evidence (500 iterations, correct golden results, ASan/LSan-clean under
`local-sync`), but the gate must surface it rather than paper over it.

### 4.4 Pin selector — clean break

`gen-pin.sh` emits generated **data lines** plus a **fixed helper**:

```cmake
# generated: one pair per built variant × platform
set(IREE_RUNTIME_DIST_default_linux-x86_64_URL     "https://.../iree-runtime-<v>-default-linux-x86_64.tar.gz")
set(IREE_RUNTIME_DIST_default_linux-x86_64_SHA256  "<sha>")
set(IREE_RUNTIME_DIST_tsan_linux-x86_64_URL        "https://.../iree-runtime-<v>-tsan-linux-x86_64.tar.gz")
set(IREE_RUNTIME_DIST_tsan_linux-x86_64_SHA256     "<sha>")

# fixed helper — the consumer calls this, never builds a variable name itself
function(iree_runtime_dist_url variant platform out_url out_sha)
  set(_k "${variant}_${platform}")
  if(NOT DEFINED IREE_RUNTIME_DIST_${_k}_URL)
    message(FATAL_ERROR
      "iree-runtime-dist: no artifact for variant='${variant}' platform='${platform}'")
  endif()
  set(${out_url} "${IREE_RUNTIME_DIST_${_k}_URL}" PARENT_SCOPE)
  set(${out_sha} "${IREE_RUNTIME_DIST_${_k}_SHA256}" PARENT_SCOPE)
endfunction()
```

This delivers #10 §1 in full: a single selector (the consumer sets `IREE_RUNTIME_VARIANT`, passes
it to the helper), **opt-in fetch** (only the resolved pair is `FetchContent`ed; the other
variants' `set()` lines are inert data that download nothing — #10 §5), and **fail-fast** on an
unbuilt combo. `find_package(IreeRuntimeDist)` and the umbrella target are unchanged across
variants — a variant only changes which tarball is fetched.

**Clean break:** the old flat `IREE_RUNTIME_URL_<variant>_<platform>` variables are removed, not
kept alongside. Nothing has consumed the old format in anger; `v3.11.0-3` will be pulled once the
next release proves out, so no downstream lands in a half-and-half state.

### 4.5 Provenance, fail-fast, and suppressions discovery

- **`sanitizer` field** in `manifest.json` and `BUILDINFO`: `thread` for `tsan`, absent for
  `default`. It is also implicit in the `cmake_flags` provenance line (which now carries
  `-fsanitize=thread` for tsan), but is surfaced explicitly so the consumer can fail-fast when
  `IREE_DJL_TSAN=ON` but the fetched variant is not thread-sanitized (#10 §2).
- **Suppressions discovery variable.** If and only if a `tsan.supp` ships, the tsan variant's
  `IreeRuntimeDistConfig.cmake` sets:
  ```cmake
  set(IREE_RUNTIME_DIST_TSAN_SUPPRESSIONS "${_IRD_PREFIX}/share/iree-runtime-dist/tsan.supp")
  ```
  `${_IRD_PREFIX}`-relative, so it stays relocatable like the other `IREE_RUNTIME_DIST_*`
  discovery variables (`ADD_VMFB`, `MANIFEST`, `ELEMENT_TYPES`, …). The consumer wires it into a
  test's `TSAN_OPTIONS=suppressions=...` with no path knowledge. Two properties follow: the
  variable's *presence* is itself a fail-fast signal (`if(NOT DEFINED ...)` ⇒ none needed), and our
  own e2e gate consumes the same variable — dogfooding the discovery path exactly as the consumer
  would. If the gate lands on pure B, no file and no variable ship; nothing vestigial.

### 4.6 Consumer TSan runbook (shipped deliverable)

Getting TSan to *run* against this artifact took real investigation (the ASLR/`mmap_rnd_bits`
finding in §2, plus the linking/flag details). The consumer must not have to relearn it. Because
the consumer owns the same pinned toolchain (same clang/lld/manylinux — a fair assumption, one
owner), the exact procedure transfers verbatim; this is a documentation deliverable, not a
"your mileage may vary" note.

Ship `share/iree-runtime-dist/TSAN.md` **with the tsan variant** (so it is versioned with the
artifact and cannot drift from the pin), containing the reproduced, minimal recipe:

- **Build/link:** nothing to do — linking `iree-runtime-dist::runtime` from the `tsan` variant
  applies `-fsanitize=thread` to the whole program via the INTERFACE flag (§4.2). State this so the
  consumer does not redundantly add or, worse, mismatch the flag.
- **Run environment:** the exact ASLR workaround the §7 spike selects (candidate: `sudo sysctl -w
  vm.mmap_rnd_bits=28` on the CI runner host *before* the containerized test, since the setting is
  host-level and not namespaced), with the measured symptom it prevents (`unexpected memory
  mapping`, intermittent). This is the single most expensive lesson to rediscover.
- **Suppressions, if shipped:** wire `IREE_RUNTIME_DIST_TSAN_SUPPRESSIONS` (§4.5) into
  `TSAN_OPTIONS=suppressions=...`; note its *absence* means none are needed.
- **What the gate proves and where its edge is:** that our CI runs exactly this recipe and asserts
  zero reports over `local-task`, so the consumer inherits a known-good procedure rather than a
  claim.

The doc is generated/copied by the recipe for the tsan variant only (alongside `tsan.supp` if
present), and `manifest.json`'s `notes` references it. The djl-iree-engine handover
(`docs/handover/`) links to it rather than restating it, so there is one authoritative copy.

## 5. Testing strategy

**Hermetic (`test/*.test.sh`, via `test/run.sh`, no build):**
- `variants.sh`: `known_variants` = `default tsan`; `variants_json` is a valid JSON array;
  `variant_cflags default` empty, `variant_cflags tsan` = `-fsanitize=thread -g`;
  `variant_sanitizer tsan` = `thread`; `tsan`'s capability flags are identical to `default`'s
  (same `Release`, same drivers/loaders) — the two differ only in `variant_cflags`.
- Pin helper: generated `IreeRuntimePin.cmake` defines `iree_runtime_dist_url`, resolves a known
  variant/platform to the right URL+SHA, and `FATAL_ERROR`s on an unknown combo. Mutation-checked
  so the fail-fast branch has teeth.
- Manifest/BUILDINFO: `sanitizer` field present+`thread` for a tsan prefix, absent for default.

**Acceptance (`test/consumer/`, per variant):**
- `default`: unchanged gate.
- `tsan`: build under the INTERFACE flag, run `add.vmfb` under `local-task` with TSan, assert zero
  reports + correct result. Consumes `IREE_RUNTIME_DIST_TSAN_SUPPRESSIONS` if defined.

**Structural (tsan prefix):** `share/iree-runtime-dist/TSAN.md` ships (§4.6), and `manifest.json`'s
`notes` references it — a `default` prefix ships neither.

**Invariants that must keep passing per variant:** relocatability repair+assert over the tsan
prefix (DWARF from `-g` is scrubbed by the existing `-ffile-prefix-map`); the structural
`build_smoke`/`manifest`/`constants`/`notices`/`cmake_additions` checks; `gh attestation` on the
tsan tarball.

## 6. Requirement traceability

| Issue | Requirement | Where satisfied |
|---|---|---|
| #9 | `-fsanitize=thread` runtime variant | §4.2 |
| #9 | full-program instrumentation, real gate | §4.2 INTERFACE flag, §4.3 gate B |
| #9 | same `runtime_commit`/`iree_version` pairing | §4.2 |
| #10 §1 | single variant selector, no string-built names | §4.4 helper |
| #10 §1 | umbrella target byte-for-byte identical | §4.2, §4.4 |
| #10 §2 | build-mode in BUILDINFO, fail-fast | §4.5 `sanitizer` field |
| #10 §2 | INTERFACE sanitizer flag on the target | §4.2 |
| #10 §3 | same commit/glibc/attestation across matrix | §4.2 |
| #10 §4 | asan optional (skip), tracy dev-only (defer) | §3 |
| #10 §5 | opt-in fetch, only chosen variant | §4.4 |
| #3 | pin variable naming won't scale | §4.4 replaces it |
| (new) | CMake discovery path for suppressions | §4.5 |
| (new) | Shipped TSan build/run runbook so consumers don't relearn it | §4.6, §7 |

## 7. Blocking spike (Step 0 of the plan)

**Question:** can the TSan acceptance gate (§4.3) actually run in CI — an unprivileged container
on a GitHub-hosted runner whose kernel has `vm.mmap_rnd_bits=32`?

**Why it is Step 0:** the measured ~65% `unexpected memory mapping` failure rate makes a naive
in-container TSan run a flaky gate, which is worse than none. Every other task in the plan (the
variant, the pin selector, BUILDINFO) is wasted effort against `tsan` specifically if we cannot
gate it, so this resolves first. It is scoped to a throwaway probe (the toy race binary already
used for grounding, plus a minimal workflow on a branch), not the real recipe.

**Candidate fix, to prove or refute:** `vm.mmap_rnd_bits` is a **host** kernel setting, not
namespaced, and GitHub-hosted runners grant passwordless `sudo` on the host. So a workflow step
`sudo sysctl -w vm.mmap_rnd_bits=28` **before** `docker run` should lower entropy for the container
too, with the container itself unprivileged. This is the documented remedy for the same Ubuntu
24.04 sanitizer breakage. Prove it drives the failure rate to 0 over many runs on a real runner.

**Fallbacks if the host-sysctl path fails, in preference order:**
1. `setarch -R` (or `personality(ADDR_NO_RANDOMIZE)`) inside the container — works only if the
   runner's default Docker seccomp permits it; the consumer's report suggests their policy does
   not, so verify on the actual runner.
2. Run the gate on the bare runner (which has `sudo`) rather than in the container — cost: the
   consumer build no longer uses the pinned container clang, weakening the "clean container"
   property; acceptable only if 0 and the host-sysctl path both fail.
3. If TSan genuinely cannot be gated in CI: still ship the `tsan` variant (it is what the consumer
   needs on *their* infrastructure), but record honestly that our CI proves build+load+correct
   result only, and that the TSan-clean claim is the consumer's to make in their environment.
   This is the one case where §4.3's gate degrades — and it degrades to a *documented limitation*,
   never to a silent build-only gate dressed up as a race gate.

**Exit criteria:** a documented, reproduced answer on a real GitHub-hosted runner — either
"host-sysctl drives failures to 0 over N≥100 runs, gate is B/C as designed" or a named fallback
with its trade-off accepted. The plan's remaining tasks assume whichever mechanism the spike
selects. **The selected mechanism is captured verbatim into the shipped `TSAN.md` runbook (§4.6)**
— closing the spike produces that documentation, so the consumer inherits the recipe rather than
rediscovering it.

## 8. Non-goals restated

No `asan`. No `tracy` (fast follow). No change to the `default` variant's contract, the compiler
exclusion, the glibc-floor semantics, or the relocatability assertion. No new packages in the
build image.
