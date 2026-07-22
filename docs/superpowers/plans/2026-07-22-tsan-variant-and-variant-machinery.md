# TSan variant + multi-variant machinery — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a ThreadSanitizer-instrumented `tsan` runtime variant proven under a real TSan
gate, and the multi-variant machinery (matrix fan-out, pin selector, provenance, opt-in fetch)
that makes adding variants a few lines. Closes #9, #10; resolves the pin-naming scale concern #3.

**Architecture:** Extend the existing single-sourced variant plumbing (`scripts/lib/variants.sh` →
`cmakeflags.sh`) to a `default tsan` matrix. TSan instrumentation enters as a compiler flag via a
new `variant_cflags` seam (not a `-D` cache option); the umbrella target propagates
`-fsanitize=thread` as an INTERFACE flag so consumers cannot mismatch. The pin becomes a helper
function over generated data. Everything else (commit, glibc, attestation, umbrella target name)
stays identical across variants.

**Tech Stack:** Bash (`set -euo pipefail`), CMake, GitHub Actions, clang/lld 21.1.8 in
manylinux_2_28, ThreadSanitizer (compiler-rt), Python 3 (manifest JSON).

## Global Constraints

- **The compiler stays out of contract:** `-DIREE_BUILD_COMPILER=OFF` for every variant. Never
  build or ship `iree-compile`.
- **Every variant is the same IREE:** identical `runtime_commit`, `iree_version`,
  `vm_bytecode_version`, glibc floor, platform set, and the *same manylinux_2_28 build image*. A
  variant changes build flags only — never the source revision. (spec §4.2, #10 §3)
- **The umbrella target is invariant:** `find_package(IreeRuntimeDist)` +
  `iree-runtime-dist::runtime` are byte-for-byte identical across variants except the tsan
  INTERFACE sanitizer flag. No hand-listed archives, no `--start-group`. (#10 §1)
- **Never weaken the TSan assertion:** the gate is B (run under TSan over `local-task`, assert
  zero reports); the only sanctioned fallback is a shipped, CMake-discoverable suppressions file
  (C). Never degrade to build-only. (spec §4.3)
- **Single source of truth:** `variants.sh` is the only place the variant list/flags live, the way
  `naming.sh` owns platforms. The release matrix sources it, never hardcodes it.
- `set -euo pipefail` in every script; guard `grep` no-match with `|| true`. The recipe stays
  idempotent. Stage explicit paths in git (never `git add -A`).
- **v1 is stable `v3.11.0` only.** `--iree-src` is the pinned probe checkout, never
  `/home/corey/workspace/iree`.
- **`asan` and `tracy` are out of scope** this plan. The machinery must not preclude `tracy` as a
  later `variant_flags`/`variant_cflags` entry.

## Deviation from the spec (discovered during plan grounding)

**Spec §4.1 says `tsan` sets `-DCMAKE_BUILD_TYPE=RelWithDebInfo`. This plan keeps `Release` and
adds `-g` via `variant_cflags` instead.** Rationale: the recipe's libbacktrace repair and the
exported targets file are hardcoded to the **Release** config
(`IREETargets-Runtime-release.cmake`, `IMPORTED_LOCATION_RELEASE`). Switching the build type would
make CMake emit `...-relwithdebinfo.cmake` and `IMPORTED_LOCATION_RELWITHDEBINFO`, silently
breaking those repairs and the relocatability assertion. `Release` + `-g` yields optimized code
with symbolized TSan frames and keeps the export config name `release`, so all existing repairs
apply unchanged. Update spec §4.1 to match after this plan is approved.

## File Structure

- `scripts/lib/variants.sh` — MODIFY: add `tsan`, `variants_json`, `variant_cflags`,
  `variant_sanitizer`, shared capability-flags helper.
- `scripts/lib/cmakeflags.sh` — unchanged (dedup already handles it).
- `build-runtime.sh` — MODIFY: compose `variant_cflags` into `CMAKE_C_FLAGS`/`CXX_FLAGS`;
  `--print-flags` reports the composed compiler flags.
- `scripts/gen-manifest.sh` — MODIFY: emit `sanitizer` in manifest.json + BUILDINFO.
- `cmake/IreeRuntimeDist.cmake.in` — MODIFY: tsan INTERFACE flag, suppressions discovery var,
  `IREE_RUNTIME_DIST_SANITIZER`.
- `scripts/gen-pin.sh` — REWRITE: data lines + `iree_runtime_dist_url` helper (clean break).
- `scripts/gen-tsan-docs.sh` — CREATE: ship `TSAN.md` (+ `tsan.supp` if present) for tsan only.
- `.github/workflows/release.yml` — MODIFY: variant matrix from `variants.sh`; verify applies the
  Task-0 ASLR mechanism and runs the tsan gate.
- `test/consumer/run.sh` — MODIFY: adapt to the variant's `sanitizer` mode.
- Tests: `test/lib_variants.test.sh`, `test/print_flags.test.sh`, `test/manifest.test.sh`,
  `test/cmake_additions.test.sh`, `test/gen_pin.test.sh`, `test/workflow_paths.test.sh` — MODIFY.
- `docs/`, `CLAUDE.md`, `README.md` — MODIFY.

---

### Task 0: Spike — prove the TSan gate can run in CI (BLOCKING, Step 0)

**Not TDD — a throwaway probe.** Resolves spec §7. Every tsan-specific task downstream assumes the
mechanism this selects. Do not build the real variant here.

**Files:** none permanent. A scratch branch + a throwaway workflow, deleted after.

- [ ] **Step 1: Reproduce the failure on a real GitHub-hosted runner.** Push a scratch workflow
  (`workflow_dispatch`) that, inside `iree-runtime-dist-build:linux-x86_64` via `docker run`,
  compiles the toy race (`pthread` double-write) with `-fsanitize=thread -g` and runs it 200×,
  counting `unexpected memory mapping` failures. Expected: a high failure rate at the runner's
  default `vm.mmap_rnd_bits`.

- [ ] **Step 2: Apply and measure the candidate fix.** Add a step `sudo sysctl -w
  vm.mmap_rnd_bits=28` on the runner host **before** `docker run`; confirm the container sees the
  lowered value (`cat /proc/sys/vm/mmap_rnd_bits`) and rerun 200×. Expected: **0** failures.
  Record the exact numbers.

- [ ] **Step 3: If the fix fails, walk the spec §7 fallbacks in order** (in-container `setarch -R`;
  gate on bare runner; documented-limitation) and record which holds.

- [ ] **Step 4: Capture the outcome.** Write the selected mechanism (exact commands, measured
  failure→0 evidence, runner OS/kernel/`mmap_rnd_bits`) into
  `docs/superpowers/notes/2026-07-22-tsan-ci-spike.md`. This text is the seed for `TSAN.md`
  (Task 8) and the mechanism Task 6's verify job uses. Delete the scratch workflow/branch.

- [ ] **Step 5: Commit** the note.
```bash
git add docs/superpowers/notes/2026-07-22-tsan-ci-spike.md
git commit -m "spike: resolve TSan-in-CI ASLR mechanism (spec §7)"
```

**Exit criteria:** the note states either "host-sysctl → 0/200 failures, gate is B/C as designed"
or a named fallback with its trade-off. STOP and escalate if all fallbacks fail — that changes the
gate's meaning and the human decides.

---

### Task 1: Variant matrix + `tsan` definition in `variants.sh`

**Files:**
- Modify: `scripts/lib/variants.sh`
- Test: `test/lib_variants.test.sh`

**Interfaces:**
- Produces: `known_variants()` → `default tsan`; `variants_json()` → JSON array;
  `variant_cflags <variant>` → extra compiler flags (empty|`-fsanitize=thread -g`);
  `variant_sanitizer <variant>` → ``|`thread`. `variant_flags <variant>` gains a `tsan` case.

- [ ] **Step 1: Write failing tests.** Append to `test/lib_variants.test.sh` before the final
`exit`:
```bash
# --- variant matrix ---
assert_eq "$(known_variants)" "default tsan" "known_variants lists default and tsan"
assert_contains "$(variants_json)" '"tsan"' "variants_json includes tsan"
assert_contains "$(variants_json)" '"default"' "variants_json includes default"

# --- variant_cflags: the compiler-flag injection point (not -D cache options) ---
assert_eq "$(variant_cflags default)" "" "default contributes no extra cflags"
assert_contains "$(variant_cflags tsan)" "-fsanitize=thread" "tsan cflags instrument"
assert_contains "$(variant_cflags tsan)" "-g" "tsan cflags carry debug info for symbolized frames"

# --- variant_sanitizer: provenance value ---
assert_eq "$(variant_sanitizer default)" "" "default has no sanitizer"
assert_eq "$(variant_sanitizer tsan)" "thread" "tsan sanitizer is thread"

# --- tsan is the SAME runtime capabilities as default (spec §4.2), Release kept (plan deviation) ---
tf="$(variant_flags tsan)"
assert_contains "$tf" "-DIREE_HAL_DRIVER_LOCAL_TASK=ON" "tsan keeps local-task"
assert_contains "$tf" "-DIREE_HAL_DRIVER_LOCAL_SYNC=ON" "tsan keeps local-sync"
assert_contains "$tf" "-DIREE_HAL_EXECUTABLE_LOADER_EMBEDDED_ELF=ON" "tsan keeps embedded-elf"
# The driver/loader/tracing set MUST be identical to default -- assert it structurally:
assert_eq "$(variant_flags tsan)" "$(variant_flags default)" "tsan runtime capabilities identical to default"
assert_eq "$(variant_cflags tsan)" "-fsanitize=thread -g" "tsan differs from default only in cflags"
```

- [ ] **Step 2: Run, verify failure.** `bash test/lib_variants.test.sh` → FAILs (`variants_json`,
`variant_cflags`, `variant_sanitizer` undefined; `tsan` rejected).

- [ ] **Step 3: Implement.** Replace `variants.sh` body so `default` and `tsan` share one
capability block (structurally prevents drift — spec §4.2 "same everything else"):
```bash
#!/usr/bin/env bash
# variant -> cmake flags. Single source of truth. Source me.
#
# `default` and `tsan` build the SAME runtime (same drivers, loaders, tracing-off);
# they differ ONLY in compiler flags: tsan adds -fsanitize=thread -g via
# variant_cflags. Keeping the -D capability set in one shared helper makes that
# sameness structural -- the two cannot drift (spec §4.2). CMAKE_BUILD_TYPE stays
# Release for both: switching tsan to RelWithDebInfo would rename the exported
# config (IMPORTED_LOCATION_RELEASE -> _RELWITHDEBINFO) and break the libbacktrace
# and relocatability repairs; -g via variant_cflags gives symbolized frames without
# that. `tracy` will later be a third case here + its own variant_cflags.

# Drivers/loaders/tracing shared by every runtime variant.
_runtime_capability_flags() {
  cat <<'EOF'
-DIREE_HAL_DRIVER_DEFAULTS=OFF
-DIREE_HAL_DRIVER_LOCAL_SYNC=ON
-DIREE_HAL_DRIVER_LOCAL_TASK=ON
-DIREE_HAL_EXECUTABLE_LOADER_DEFAULTS=OFF
-DIREE_HAL_EXECUTABLE_LOADER_EMBEDDED_ELF=ON
-DIREE_HAL_EXECUTABLE_LOADER_SYSTEM_LIBRARY=ON
-DIREE_ENABLE_RUNTIME_TRACING=OFF
EOF
}

variant_flags() { # <variant>
  case "${1:-}" in
    default|tsan) _runtime_capability_flags ;;
    *) echo "error: unknown variant '${1:-}' (known: default tsan)" >&2; return 2 ;;
  esac
}

# Extra compiler flags a variant contributes to CMAKE_C_FLAGS/CXX_FLAGS -- the
# injection point for flags that are not -D cache options.
variant_cflags() { # <variant>
  case "${1:-}" in
    default) : ;;
    tsan)    printf '%s' '-fsanitize=thread -g' ;;
    *) echo "error: unknown variant '${1:-}'" >&2; return 2 ;;
  esac
}

# Sanitizer provenance value recorded in manifest.json / BUILDINFO.
variant_sanitizer() { # <variant>
  case "${1:-}" in
    default) : ;;
    tsan)    printf 'thread' ;;
    *) echo "error: unknown variant '${1:-}'" >&2; return 2 ;;
  esac
}

known_variants() { printf 'default tsan'; }

variants_json() { python3 -c "import json,sys; print(json.dumps(sys.argv[1].split()))" "$(known_variants)"; }
```

- [ ] **Step 4: Run, verify pass.** `bash test/lib_variants.test.sh` → all ok, including the
existing dedup/prefix subshell tests (unchanged).

- [ ] **Step 5: Commit.**
```bash
git add scripts/lib/variants.sh test/lib_variants.test.sh
git commit -m "feat(variants): add tsan variant, variants_json, variant_cflags/sanitizer"
```

---

### Task 2: Compose `variant_cflags` into the build; `--print-flags` reports it

**Files:**
- Modify: `build-runtime.sh` (the `CMAKE_C_FLAGS`/`CXX_FLAGS` lines ~149-150 and the
  `--print-flags` path ~54-56)
- Test: `test/print_flags.test.sh`

**Interfaces:**
- Consumes: `variant_cflags` (Task 1).
- Produces: `--print-flags` output gains a `compiler_flags:` line so the composed
  `CMAKE_C_FLAGS` is inspectable and testable without a build.

- [ ] **Step 1: Write failing test.** Append to `test/print_flags.test.sh`:
```bash
out_default="$(bash "$here/../build-runtime.sh" --print-flags --variant default)"
assert_contains "$out_default" "compiler_flags:" "print-flags reports compiler flags"
case "$out_default" in *"-fsanitize=thread"*) echo "FAIL: default must not be instrumented" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1));; *) echo "ok: default not instrumented";; esac

out_tsan="$(bash "$here/../build-runtime.sh" --print-flags --variant tsan)"
assert_contains "$out_tsan" "-fsanitize=thread" "tsan print-flags shows the sanitizer"
assert_contains "$out_tsan" "-ffile-prefix-map=" "tsan still carries the relocatability prefix-map"
```

- [ ] **Step 2: Run, verify failure.** FAILs — no `compiler_flags:` line; tsan not shown.

- [ ] **Step 3: Implement.** In `build-runtime.sh`, where `--print-flags` prints (near the
`effective_cmake_flags "$VARIANT"` call), also print the composed compiler flags; and change the
real configure to compose them. Concretely, define near the existing `PREFIX_MAP`:
```bash
PREFIX_MAP="-ffile-prefix-map=${IREE_SRC}=iree"
# variant_cflags is the injection point for non-cache-var compiler flags (e.g.
# tsan's -fsanitize=thread -g). Compose once so the build, --print-flags, and any
# provenance use the identical string.
VARIANT_CFLAGS="$(variant_cflags "$VARIANT")"
COMPILER_FLAGS="$PREFIX_MAP${VARIANT_CFLAGS:+ $VARIANT_CFLAGS}"
```
Use `-DCMAKE_C_FLAGS="$COMPILER_FLAGS"` / `-DCMAKE_CXX_FLAGS="$COMPILER_FLAGS"` in the configure.
In the `--print-flags` branch add, after the `-D` flags are printed:
```bash
echo "compiler_flags: $COMPILER_FLAGS"
```
(Note: `--print-flags` must resolve `COMPILER_FLAGS` without a real `$IREE_SRC`; keep the
`PREFIX_MAP` computation tolerant when `--print-flags` runs — it already uses whatever `IREE_SRC`
default the flag path sets. If `--print-flags` currently short-circuits before `PREFIX_MAP`, move
the `VARIANT_CFLAGS`/`COMPILER_FLAGS` composition before that branch.)

- [ ] **Step 4: Run, verify pass.** `bash test/print_flags.test.sh` → ok. Also
`bash test/run.sh` stays green.

- [ ] **Step 5: Commit.**
```bash
git add build-runtime.sh test/print_flags.test.sh
git commit -m "feat(build): compose variant_cflags into CMAKE_C/CXX_FLAGS; report via --print-flags"
```

---

### Task 3: Record `sanitizer` in manifest.json and BUILDINFO

**Files:**
- Modify: `scripts/gen-manifest.sh`
- Test: `test/manifest.test.sh`

**Interfaces:**
- Consumes: `variant_sanitizer` (Task 1).
- Produces: manifest.json top-level `sanitizer` (`thread`) present for tsan, **absent** for
  default; `notes.sanitizer` explanatory string when present; BUILDINFO `sanitizer=thread` line
  for tsan (omitted for default).

- [ ] **Step 1: Write failing tests.** In `test/manifest.test.sh`, guarded by the prefix argument
(the test already skips without one), add assertions that key off the prefix's own BUILDINFO
`variant=`:
```bash
variant="$(grep -oE '^variant=.*' "$PREFIX/BUILDINFO" | cut -d= -f2)"
san="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sanitizer",""))' "$MANIFEST")"
if [ "$variant" = "tsan" ]; then
  assert_eq "$san" "thread" "tsan manifest records sanitizer=thread"
  assert_contains "$(cat "$PREFIX/BUILDINFO")" "sanitizer=thread" "tsan BUILDINFO records sanitizer"
else
  assert_eq "$san" "" "default manifest omits sanitizer"
fi
```

- [ ] **Step 2: Run, verify failure** against a tsan prefix (available after Task 9; until then
this assertion is exercised in the acceptance task — note in the dispatch that Step 2's red state
is confirmed there). Against the existing default prefix it already passes (field absent).

- [ ] **Step 3: Implement** in `gen-manifest.sh`. After the `effective_cmake_flags` block, add:
```bash
SANITIZER="$(variant_sanitizer "$VARIANT")"
```
Pass `SANITIZER` into the Python argv, and in the manifest dict add it conditionally:
```python
if sanitizer:
    manifest["sanitizer"] = sanitizer
    manifest["notes"]["sanitizer"] = (
        "This variant is built with -fsanitize=" + sanitizer + ". The umbrella "
        "target propagates the sanitizer flag as an INTERFACE option, so linking "
        "it instruments the whole consumer program. See share/iree-runtime-dist/"
        "TSAN.md for how to run it (ASLR/mmap_rnd_bits) and any suppressions."
    )
```
(add `sanitizer` to the argv unpacking). In the BUILDINFO heredoc, add a conditional line — emit
`sanitizer=$SANITIZER` only when non-empty, e.g. append after writing the heredoc:
```bash
[ -n "$SANITIZER" ] && echo "sanitizer=$SANITIZER" >> "$PREFIX/BUILDINFO"
```

- [ ] **Step 4: Verify** via the acceptance task's tsan prefix (Task 9). Hermetic coverage of the
value itself is Task 1's `variant_sanitizer` test.

- [ ] **Step 5: Commit.**
```bash
git add scripts/gen-manifest.sh test/manifest.test.sh
git commit -m "feat(manifest): record sanitizer field in manifest.json and BUILDINFO"
```

---

### Task 4: TSan INTERFACE flag + suppressions discovery in the dist config

**Files:**
- Modify: `cmake/IreeRuntimeDist.cmake.in`
- Test: `test/cmake_additions.test.sh`

**Interfaces:**
- Consumes: the `@VARIANT@` substitution already done by `build-runtime.sh`.
- Produces: for tsan, `iree-runtime-dist::runtime` carries INTERFACE `-fsanitize=thread`
  (compile + link); `IREE_RUNTIME_DIST_SANITIZER`; and `IREE_RUNTIME_DIST_TSAN_SUPPRESSIONS` iff
  the file ships. Default renders none of these.

- [ ] **Step 1: Write failing tests.** Add to `test/cmake_additions.test.sh` a hermetic
render-and-grep (no build — just `sed` the template like `build-runtime.sh` does):
```bash
render() { sed -e "s|@IREE_VERSION@|3.11.0|g" -e "s|@COMPILER_VERSION@|3.11.0|g" \
  -e "s|@VARIANT@|$1|g" -e "s|@PLATFORM@|linux-x86_64|g" -e "s|@RUNTIME_COMMIT@|abc|g" \
  "$here/../cmake/IreeRuntimeDist.cmake.in"; }
d="$(render default)"; t="$(render tsan)"
case "$t" in *"-fsanitize=thread"*) echo "ok: tsan config propagates sanitizer";; *) echo "FAIL: tsan missing INTERFACE sanitizer" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1));; esac
case "$d" in *"-fsanitize=thread"*) echo "FAIL: default must not carry sanitizer" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1));; *) echo "ok: default config has no sanitizer";; esac
assert_contains "$t" "IREE_RUNTIME_DIST_TSAN_SUPPRESSIONS" "tsan exposes suppressions discovery var"
assert_contains "$t" "IREE_RUNTIME_DIST_SANITIZER" "tsan exposes sanitizer var"
```

- [ ] **Step 2: Run, verify failure.**

- [ ] **Step 3: Implement.** Append to `cmake/IreeRuntimeDist.cmake.in`, after the umbrella target
block (keys off the already-substituted `IREE_RUNTIME_DIST_VARIANT`, so no new sed var):
```cmake
# Sanitizer variants propagate their flag as an INTERFACE option so a consumer
# linking iree-runtime-dist::runtime instruments their whole program and cannot
# mismatch flags (spec §4.2). The target name/semantics are otherwise identical
# to the default variant.
if(IREE_RUNTIME_DIST_VARIANT STREQUAL "tsan")
  set(IREE_RUNTIME_DIST_SANITIZER "thread")
  target_compile_options(iree-runtime-dist::runtime INTERFACE -fsanitize=thread)
  target_link_options(iree-runtime-dist::runtime INTERFACE -fsanitize=thread)
  # Present iff the recipe shipped a suppressions file (gate C). Its presence is
  # itself the fail-fast signal that suppressions are required; absence means none.
  if(EXISTS "${_IRD_PREFIX}/share/iree-runtime-dist/tsan.supp")
    set(IREE_RUNTIME_DIST_TSAN_SUPPRESSIONS
        "${_IRD_PREFIX}/share/iree-runtime-dist/tsan.supp")
  endif()
endif()
```

- [ ] **Step 4: Run, verify pass.** `bash test/cmake_additions.test.sh` (with no prefix arg for
the render tests; existing prefix-arg checks unchanged). Real CMake application is proven in
Task 9 (consumer binary contains `__tsan_` symbols).

- [ ] **Step 5: Commit.**
```bash
git add cmake/IreeRuntimeDist.cmake.in test/cmake_additions.test.sh
git commit -m "feat(cmake): propagate tsan INTERFACE flag + suppressions discovery var"
```

---

### Task 5: Pin selector — clean break to `iree_runtime_dist_url` helper

**Files:**
- Rewrite: `scripts/gen-pin.sh`
- Test: `test/gen_pin.test.sh`

**Interfaces:**
- Produces `IreeRuntimePin.cmake` with `set(IREE_RUNTIME_DIST_<variant>_<platform>_URL/_SHA256 …)`
  data lines + a fixed `iree_runtime_dist_url(variant platform out_url out_sha)` helper. Old flat
  `IREE_RUNTIME_URL_*` variables removed.

- [ ] **Step 1: Rewrite the test** `test/gen_pin.test.sh` to assert the new contract. Build fake
assets for both variants, generate, then drive the helper with `cmake -P`:
```bash
for v in default tsan; do
  f="iree-runtime-3.11.0-$v-linux-x86_64.tar.gz"
  echo "payload-$v" > "$tmp/assets/$f"
  ( cd "$tmp/assets" && sha256sum "$f" > "$f.sha256" )
done
bash "$here/../scripts/gen-pin.sh" "org/iree-runtime-dist" "v3.11.0-1" "3.11.0" "$tmp/assets" "$tmp/IreeRuntimePin.cmake"
got="$(cat "$tmp/IreeRuntimePin.cmake")"

assert_contains "$got" "function(iree_runtime_dist_url" "defines the selector helper"
assert_contains "$got" "IREE_RUNTIME_DIST_tsan_linux-x86_64_URL" "has tsan data line"
case "$got" in *"IREE_RUNTIME_URL_default_linux-x86_64"*) echo "FAIL: old flat var still present" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1));; *) echo "ok: clean break, no old flat vars";; esac

# Helper resolves a known combo (cmake -P if available; else grep the data line).
if command -v cmake >/dev/null; then
  cat > "$tmp/probe.cmake" <<EOF
include("$tmp/IreeRuntimePin.cmake")
iree_runtime_dist_url(tsan linux-x86_64 U S)
message(STATUS "URL=\${U}")
message(STATUS "SHA=\${S}")
EOF
  probe="$(cmake -P "$tmp/probe.cmake" 2>&1)"
  assert_contains "$probe" "releases/download/v3.11.0-1/iree-runtime-3.11.0-tsan-linux-x86_64.tar.gz" "helper resolves tsan url"
  # fail-fast on an unbuilt combo -> FATAL_ERROR -> nonzero exit
  cat > "$tmp/bad.cmake" <<EOF
include("$tmp/IreeRuntimePin.cmake")
iree_runtime_dist_url(nope linux-x86_64 U S)
EOF
  if cmake -P "$tmp/bad.cmake" >/dev/null 2>&1; then echo "FAIL: unknown combo should FATAL_ERROR" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); else echo "ok: unknown combo fails fast"; fi
fi
```

- [ ] **Step 2: Run, verify failure.**

- [ ] **Step 3: Rewrite `gen-pin.sh`.** Replace the emission loop and add the fixed helper:
```bash
{
  echo "# Generated by iree-runtime-dist gen-pin.sh -- do not edit."
  echo "# Release: $TAG"
  echo "#"
  echo "# Select a variant with the helper below; FetchContent only the pair it"
  echo "# returns, so unused variants download nothing:"
  echo "#   iree_runtime_dist_url(\"\${IREE_RUNTIME_VARIANT}\" \"\${platform}\" url sha)"
  echo ""
  for variant in $(known_variants); do
    for platform in $PLATFORMS; do
      tb="$(tarball_name "$VERSION" "$variant" "$platform")"
      shafile="$ASSETS/$(sha_name "$VERSION" "$variant" "$platform")"
      [ -f "$shafile" ] || { echo "error: missing sha file $shafile" >&2; exit 1; }
      sha="$(cut -d' ' -f1 < "$shafile")"
      echo "set(IREE_RUNTIME_DIST_${variant}_${platform}_URL"
      echo "    \"https://github.com/${REPO}/releases/download/${TAG}/${tb}\")"
      echo "set(IREE_RUNTIME_DIST_${variant}_${platform}_SHA256 \"${sha}\")"
      echo ""
    done
  done
  cat <<'EOF'
# Fixed selector -- the consumer calls this, never string-builds a variable name.
function(iree_runtime_dist_url variant platform out_url out_sha)
  set(_k "${variant}_${platform}")
  if(NOT DEFINED IREE_RUNTIME_DIST_${_k}_URL)
    message(FATAL_ERROR
      "iree-runtime-dist: no artifact for variant='${variant}' platform='${platform}'")
  endif()
  set(${out_url} "${IREE_RUNTIME_DIST_${_k}_URL}" PARENT_SCOPE)
  set(${out_sha} "${IREE_RUNTIME_DIST_${_k}_SHA256}" PARENT_SCOPE)
endfunction()
EOF
} > "$OUTFILE"
```

- [ ] **Step 4: Run, verify pass.** `bash test/gen_pin.test.sh` → ok.

- [ ] **Step 5: Commit.**
```bash
git add scripts/gen-pin.sh test/gen_pin.test.sh
git commit -m "feat(pin): clean-break variant selector helper (closes #3 naming scale)"
```

---

### Task 6: Release workflow — variant matrix + TSan gate wiring

**Files:**
- Modify: `.github/workflows/release.yml`
- Test: `test/workflow_paths.test.sh` (must stay green), `actionlint`

**Interfaces:**
- Consumes: `variants_json` (Task 1), the Task-0 ASLR mechanism, the tsan-aware `run.sh` (Task 7).

- [ ] **Step 1: Add the `variants` output to `setup`.** Mirror the `platforms` step:
```yaml
      - id: variants
        run: |
          . scripts/lib/variants.sh
          echo "list=$(variants_json)" >> "$GITHUB_OUTPUT"
```
and add `variants: ${{ steps.variants.outputs.list }}` to `setup.outputs`.

- [ ] **Step 2: Fan the build and verify matrices over variants.** In both jobs replace
`variant: [default]` with `variant: ${{ fromJson(needs.setup.outputs.variants) }}`.

- [ ] **Step 3: Apply the Task-0 ASLR mechanism in the verify job**, before the containerized
consumer e2e (use the exact command Task 0 selected; shown here as the candidate):
```yaml
      - name: Lower ASLR entropy for in-container TSan (host-level, not namespaced)
        run: sudo sysctl -w vm.mmap_rnd_bits=28
```
The consumer e2e step is otherwise unchanged — `run.sh` (Task 7) self-selects TSan behavior from
the prefix's BUILDINFO, so the workflow needs no per-variant branching here.

- [ ] **Step 4: Verify.** `actionlint` clean; `bash test/workflow_paths.test.sh` passes (the
BUILD_DOCKERFILE/context checks are unaffected — the image is per-platform, not per-variant, so
variants share one toolchain image). Add one assertion to `workflow_paths.test.sh` or a note that
the matrices are sourced (`fromJson(needs.setup.outputs.variants)`) not hardcoded.

- [ ] **Step 5: Commit.**
```bash
git add .github/workflows/release.yml test/workflow_paths.test.sh
git commit -m "ci: fan release matrix over variants; apply TSan ASLR mechanism in verify"
```

---

### Task 7: Consumer e2e adapts to the variant's sanitizer mode

**Files:**
- Modify: `test/consumer/run.sh`
- Test: covered by Task 9's real tsan run; a hermetic unit for the mode-selection parsing here.

**Interfaces:**
- Consumes: the extracted prefix's `BUILDINFO` (`sanitizer=`), the config's
  `IREE_RUNTIME_DIST_TSAN_SUPPRESSIONS`.

- [ ] **Step 1: Write a hermetic unit** `test/consumer_mode.test.sh` for the pure decision (given
a BUILDINFO with/without `sanitizer=thread`, the script selects the tsan path):
```bash
# factor the decision into a sourceable helper consumer/run.sh uses:
. "$here/../test/consumer/run.sh" --print-mode-only <<< ""  # or a small extracted function
```
(Extract `consumer_run_mode <prefix>` → `default|tsan` into a tiny sourceable snippet so it can be
tested without compiling. Assert `tsan` when BUILDINFO has `sanitizer=thread`, else `default`.)

- [ ] **Step 2: Run, verify failure.**

- [ ] **Step 3: Implement in `run.sh`.** After resolving `$PREFIX`, read the mode and, for tsan,
run the `local-task` invocation under TSan and assert zero reports. Keep it exactly what a real
consumer writes — read BUILDINFO, wire the discovery variable:
```bash
sanitizer="$(grep -oE '^sanitizer=.*' "$PREFIX/BUILDINFO" 2>/dev/null | cut -d= -f2 || true)"
if [ "$sanitizer" = "thread" ]; then
  # The umbrella target already linked -fsanitize=thread into the consumer binary
  # (INTERFACE flag). Drive the worker pool and require a clean TSan run.
  supp=""; [ -f "$PREFIX/share/iree-runtime-dist/tsan.supp" ] && supp="suppressions=$PREFIX/share/iree-runtime-dist/tsan.supp"
  out="$(TSAN_OPTIONS="halt_on_error=1 $supp" "$build/consumer" "$vmfb" local-task 2>&1)" || {
    echo "$out"; echo "FAIL: consumer crashed under tsan"; exit 1; }
  if echo "$out" | grep -q "ThreadSanitizer:"; then
    echo "$out"; echo "FAIL: tsan reported a race over local-task"; exit 1; fi
  echo "$out" | grep -q "11, 22, 33, 44" || { echo "FAIL: wrong result under tsan"; exit 1; }
  echo "ok: tsan clean over local-task"
fi
```
(Guard so the `default` path runs both drivers exactly as today.)

- [ ] **Step 4: Verify** the hermetic mode unit passes; full behavior in Task 9.

- [ ] **Step 5: Commit.**
```bash
git add test/consumer/run.sh test/consumer_mode.test.sh
git commit -m "feat(consumer): run the tsan gate over local-task when the prefix is thread-sanitized"
```

---

### Task 8: Ship the TSan runbook (and suppressions plumbing)

**Files:**
- Create: `scripts/gen-tsan-docs.sh`, `docs/TSAN.md.in` (source text from the Task-0 note)
- Modify: `build-runtime.sh` (Phase 3, tsan only), `test/build_smoke.sh` or `manifest.test.sh`
  (structural check)

- [ ] **Step 1: Write a structural test** (prefix-arg, runs in acceptance): for a tsan prefix,
`share/iree-runtime-dist/TSAN.md` exists and `manifest.json` `notes.sanitizer` references it; for a
default prefix, `TSAN.md` is absent.

- [ ] **Step 2: Author `docs/TSAN.md.in`** from the Task-0 note: the INTERFACE-flag build behavior
(consumer adds nothing), the exact runner ASLR command the spike selected + the symptom it
prevents, suppressions wiring via `IREE_RUNTIME_DIST_TSAN_SUPPRESSIONS`, and what our gate proves.

- [ ] **Step 3: Implement `gen-tsan-docs.sh`** — copy `TSAN.md` into
`$PREFIX/share/iree-runtime-dist/` and, if a `tsan.supp` was produced by Task 9, copy it too. Call
it from `build-runtime.sh` Phase 3 **only when** `variant_sanitizer "$VARIANT"` is non-empty.

- [ ] **Step 4: Verify** in Task 9 against real prefixes (tsan ships it, default doesn't).

- [ ] **Step 5: Commit.**
```bash
git add scripts/gen-tsan-docs.sh docs/TSAN.md.in build-runtime.sh test/build_smoke.sh
git commit -m "feat(tsan): ship TSAN.md runbook (and tsan.supp) with the tsan variant"
```

---

### Task 9: End-to-end acceptance — build tsan, run the gate, resolve B vs C

**Files:** none new; this is the integration gate that resolves the empirical B/C question and
finalizes `tsan.supp`/`TSAN.md` content. Runs in the container, end to end.

- [ ] **Step 1: Build the tsan variant** in the container, exactly as CI will:
```bash
docker run --rm -v "$PWD":/work -v "$IREE_SRC":/iree \
  -e COMPILER_VERSION=3.11.0 -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  -w /work iree-runtime-dist-build:linux-x86_64 \
  bash -lc 'export PATH=/opt/python/cp312-cp312/bin:$PATH;
    ./build-runtime.sh --variant tsan --prefix /work/out-tsan --iree-src /iree'
```
- [ ] **Step 2: Assert the artifact is instrumented.** `nm` over `out-tsan/lib/*.a` finds
`__tsan_*` symbols (default has none); BUILDINFO `variant=tsan`, `sanitizer=thread`; manifest
`sanitizer=thread`; `TSAN.md` present; relocatability assert passes for the tsan prefix.
- [ ] **Step 3: Run the gate** under the Task-0 ASLR mechanism: package `out-tsan`, extract in a
clean container, `find_package`, build the consumer (auto-instrumented via INTERFACE flag; confirm
`__tsan_` in the consumer binary), run `add.vmfb` over `local-task` with `TSAN_OPTIONS`, N iterations.
- [ ] **Step 4: Resolve B vs C.** If clean → gate B, no `tsan.supp`. If IREE blind-spot false
positives appear → author `share/iree-runtime-dist/tsan.supp` covering only IREE's own primitives
(justify each entry from the report frames), rerun to clean, and finalize `TSAN.md`. If a *genuine*
race appears → STOP, escalate (spec §4.3 named risk), do not suppress.
- [ ] **Step 5: Confirm the full suite** green in-container: `build_smoke`, `manifest`,
`constants`, `notices`, `cmake_additions` for the tsan prefix, plus the consumer gate for both
variants.
- [ ] **Step 6: Commit** any `tsan.supp`/`TSAN.md` finalization and the recorded gate outcome.
```bash
git add docs/TSAN.md.in scripts/gen-tsan-docs.sh   # + tsan.supp source if created
git commit -m "test(tsan): end-to-end gate resolved to B$( : or C); finalize runbook/suppressions"
```

---

### Task 10: Docs and issue closure

**Files:** `CLAUDE.md`, `README.md`, `docs/handover/2026-07-20-djl-iree-engine-handover.md`

- [ ] **Step 1: CLAUDE.md** — document the variant matrix (`variants.sh` as the source of truth,
`variant_cflags` seam, Release-not-RelWithDebInfo rationale) and the TSan gate.
- [ ] **Step 2: README.md** — a `tsan` usage note: select via the pin helper, link the umbrella
target (auto-instrumented), run with the ASLR workaround, see `TSAN.md`.
- [ ] **Step 3: Handover** — add a section pointing djl-iree-engine at the `tsan` variant, the
`IREE_RUNTIME_VARIANT` selector, the `sanitizer` fail-fast field, and (by link, not restated) the
shipped `TSAN.md`.
- [ ] **Step 4: Close issues** — comment #9 and #10 with the delivered mapping (traceability table
from spec §6), note #3 resolved by the pin helper. Do not close until the first tag release
actually publishes tsan assets.
- [ ] **Step 5: Commit.**
```bash
git add CLAUDE.md README.md docs/handover/2026-07-20-djl-iree-engine-handover.md
git commit -m "docs: variant matrix + tsan consumer guidance; cross-ref #9/#10/#3"
```

---

## Self-Review

- **Spec coverage:** machinery (§4.1) → T1,T2,T6; tsan variant (§4.2) → T1,T2,T4; gate (§4.3) →
  T7,T9; pin (§4.4) → T5; provenance/suppressions (§4.5) → T3,T4; runbook (§4.6) → T8; spike (§7)
  → T0. All covered.
- **Placeholder scan:** every code step carries real code or an exact command; the one empirical
  fork (B vs C) is explicitly deferred to T9 with both branches specified, not left vague.
- **Type/name consistency:** `variant_cflags`, `variant_sanitizer`, `variants_json`,
  `iree_runtime_dist_url`, `IREE_RUNTIME_DIST_TSAN_SUPPRESSIONS`, `IREE_RUNTIME_DIST_SANITIZER`
  used consistently across tasks.
- **Ordering:** T0 blocks T6–T9 (mechanism). T1 precedes all (defines the vocabulary). T9
  integrates and resolves B/C. T10 closes out and must not close issues before a real tsan release.
- **Known deviation from spec:** Release+`-g` instead of RelWithDebInfo (documented above with
  rationale; spec §4.1 to be updated on approval).
