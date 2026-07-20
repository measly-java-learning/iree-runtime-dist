# iree-runtime-dist Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the IREE runtime from stable tag `v3.11.0` inside a manylinux container and publish it as an attested, hash-pinned, relocatable tarball that `djl-iree-engine` consumes via `find_package(IREERuntime)`.

**Architecture:** A single `build-runtime.sh` entrypoint runs four phases (build+install, relocatability repair+verify, generate metadata, pair with the compiler). Shell libraries under `scripts/lib/` are the single source of truth for anything both the build and CI need, so the two cannot drift. Two test layers: hermetic `test/*.test.sh` unit tests that need no build, and a consumer end-to-end test that proves the tarball is usable in a container that has never seen the build tree.

**Tech Stack:** Bash (`set -euo pipefail`), CMake, Ninja, clang/lld 21.1.8, CPython 3.12, Docker (`quay.io/pypa/manylinux_2_28_x86_64`), GitHub Actions.

**Design doc:** `docs/superpowers/specs/2026-07-19-iree-runtime-dist-design.md`

## Global Constraints

- **IREE source version:** stable tag `v3.11.0` (commit `e4a3b0405d7d23554da26403658d0e8c3c5ecf25`). Never `main`.
- **Paired compiler:** pip `iree-base-compiler==3.11.0` (stable). Never built from source, never shipped.
- **Compiler is out of contract:** always configure with `-DIREE_BUILD_COMPILER=OFF`.
- **Build container:** `quay.io/pypa/manylinux_2_28_x86_64`. clang/lld 21.1.8 installed into it. CPython 3.12 (`/opt/python/cp312-cp312/bin`).
- **v1 matrix:** variant `default`, platform `linux-x86_64`. One tarball.
- **Static only:** `BUILD_SHARED_LIBS=OFF`, `CMAKE_BUILD_TYPE=Release`, PIC on.
- **Recipe never clones IREE.** The caller always supplies `--iree-src`.
- **Recipe is idempotent.** Re-runs must not fail on existing build trees or already-patched files.
- **Shell:** `set -euo pipefail` in every script. `grep` exits 1 on no-match and aborts under `set -e`; guard with `|| true`.
- **Asset naming:** `iree-runtime-<version>-<variant>-<platform>.tar.gz`.
- **Upstream CMake files ship unmodified.** Dist additions go in `lib/cmake/IreeRuntimeDist/`, never edited into `lib/cmake/IREE/`.

---

## File Structure

| Path | Responsibility |
|---|---|
| `build-runtime.sh` | Single build entrypoint; orchestrates the four phases. No logic that belongs in `scripts/lib/`. |
| `scripts/lib/submodules.sh` | `IREE_REQUIRED_SUBMODULES` — the minimal submodule set. |
| `scripts/lib/naming.sh` | Asset/tarball/sha naming. |
| `scripts/lib/variants.sh` | variant → cmake flags. |
| `scripts/lib/cmakeflags.sh` | Common flags + `effective_cmake_flags` (composes and dedupes). |
| `scripts/derive-version.sh` | Release tag → IREE tag + compiler version. |
| `scripts/relocatability.sh` | Repair and assert relocatability of a staged prefix. |
| `scripts/gen-constants.sh` | Build and run the constant emitter. |
| `scripts/gen-manifest.sh` | `manifest.json` + `BUILDINFO`. |
| `scripts/gen-notices.sh` | Third-party notices scoped to the actual link surface. |
| `scripts/gen-addvmfb.sh` | Install paired compiler, compile `add.vmfb`. |
| `scripts/package.sh` | Tarball + `.sha256`. |
| `scripts/gen-pin.sh` | `IreeRuntimePin.cmake`. |
| `emit/emit_constants.c` | Emits element types + status codes as JSON. |
| `emit/add.mlir` | Smoke module source. |
| `cmake/IreeRuntimeDist.cmake.in` | Umbrella target + manifest vars template. |
| `test/assert.sh` | Assertion harness. |
| `test/run.sh` | Runs all `*.test.sh`. |
| `test/*.test.sh` | Hermetic unit tests. |
| `test/consumer/` | Consumer e2e: `CMakeLists.txt`, `consumer.c`, `run.sh`. |
| `.github/workflows/release.yml` | Tag-triggered release pipeline. |

---

### Task 1: Repo scaffolding and the empirical submodule set

This task is first because its finding shapes CI. The hypothesis — that a runtime-only build needs `third_party/flatcc` alone — is well-grounded but unproven, so **Step 3 discovers the truth rather than assuming it**.

**Files:**
- Modify: `.gitignore`
- Create: `test/assert.sh`, `test/run.sh`
- Create: `scripts/lib/submodules.sh`
- Test: `test/lib_submodules.test.sh`

**Interfaces:**
- Produces: `IREE_REQUIRED_SUBMODULES` (space-separated string of submodule paths), `required_submodules()` (prints it). `assert_eq <actual> <expected> <msg>` and `assert_contains <haystack> <needle> <msg>`, both incrementing `$ASSERT_FAILS`.

- [ ] **Step 1: Replace the carried-over `.gitignore`**

The current file is verbatim from `executorch-runtime-dist` and ignores paths this project never creates. Replace its entire contents with:

```gitignore
out/
out-*/
iree-build/
iree-build-*/
dist/
spike/*.log
__pycache__/
*.pyc
.superpowers/
```

- [ ] **Step 2: Create the test harness**

`test/assert.sh`:

```bash
#!/usr/bin/env bash
# Minimal dependency-free assertion harness. Source me; check $ASSERT_FAILS at end.
ASSERT_FAILS=0
assert_eq() { # <actual> <expected> <msg>
  if [ "$1" = "$2" ]; then printf 'ok: %s\n' "$3"
  else printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$3" "$2" "$1" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
}
assert_contains() { # <haystack> <needle> <msg>
  case "$1" in *"$2"*) printf 'ok: %s\n' "$3" ;;
  *) printf 'FAIL: %s\n  missing: [%s]\n  in: [%s]\n' "$3" "$2" "$1" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;; esac
}
```

`test/run.sh`:

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
fails=0
for t in "$here"/*.test.sh; do
  echo "== $t =="
  bash "$t" || fails=$((fails+1))
done
if [ "$fails" -eq 0 ]; then echo "ALL UNIT TESTS PASS"; else echo "$fails test file(s) FAILED" >&2; exit 1; fi
```

- [ ] **Step 3: Determine the real minimal submodule set (the experiment)**

Do not skip to Step 4. Run this and record the actual outcome:

```bash
cd /tmp/claude-1000/-home-corey-workspace-iree-runtime-dist/*/scratchpad
rm -rf iree-probe
git clone --filter=blob:none --depth 1 --branch v3.11.0 \
  https://github.com/iree-org/iree.git iree-probe
cd iree-probe
git submodule update --init --depth 1 third_party/flatcc
cmake -G Ninja -B ../probe-build -S . \
  -DIREE_BUILD_COMPILER=OFF -DIREE_BUILD_TESTS=OFF -DIREE_BUILD_SAMPLES=OFF \
  -DIREE_BUILD_BINDINGS_TFLITE=OFF -DIREE_BUILD_BINDINGS_TFLITE_JAVA=OFF \
  -DIREE_HAL_DRIVER_DEFAULTS=OFF -DIREE_HAL_DRIVER_LOCAL_SYNC=ON -DIREE_HAL_DRIVER_LOCAL_TASK=ON \
  -DIREE_HAL_EXECUTABLE_LOADER_DEFAULTS=OFF \
  -DIREE_HAL_EXECUTABLE_LOADER_EMBEDDED_ELF=ON -DIREE_HAL_EXECUTABLE_LOADER_SYSTEM_LIBRARY=ON \
  -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -30
```

Two possible outcomes, both useful:

- **Configure succeeds** → the hypothesis holds; `IREE_REQUIRED_SUBMODULES="third_party/flatcc"`.
- **Configure fails** → the error names a missing path (e.g. `third_party/cpuinfo` or a missing `CMakeLists.txt` under some `third_party/<name>`). Add that submodule with `git submodule update --init --depth 1 third_party/<name>`, re-run the configure, and repeat until it succeeds. The accumulated list is the answer.

Then confirm the build itself works, not just configure:

```bash
cmake --build ../probe-build --target iree_runtime_unified 2>&1 | tail -20
```

If the build fails on a missing submodule that configure tolerated, add it too and re-run.

Record the final list — Step 4 hard-codes it.

- [ ] **Step 4: Write the failing test**

`test/lib_submodules.test.sh` — substitute the list you actually determined in Step 3 for `third_party/flatcc`:

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/submodules.sh"

assert_eq "$IREE_REQUIRED_SUBMODULES" "third_party/flatcc" "required submodule set"
assert_eq "$(required_submodules)" "third_party/flatcc" "required_submodules prints the set"

# llvm-project is 2.6 GB and unnecessary with IREE_BUILD_COMPILER=OFF.
# This assertion is the whole point of the allowlist -- do not relax it.
case "$IREE_REQUIRED_SUBMODULES" in
  *llvm-project*) echo "FAIL: llvm-project must not be required" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) echo "ok: llvm-project excluded" ;;
esac
exit "$ASSERT_FAILS"
```

- [ ] **Step 5: Run test to verify it fails**

Run: `bash test/lib_submodules.test.sh`
Expected: FAIL — `scripts/lib/submodules.sh: No such file or directory`

- [ ] **Step 6: Write the implementation**

`scripts/lib/submodules.sh` — again substituting the real list from Step 3:

```bash
#!/usr/bin/env bash
# The minimal IREE submodule set a runtime-only build needs. Single source of truth.
#
# Determined empirically (see docs/superpowers/plans/2026-07-19-iree-runtime-dist.md Task 1):
# with -DIREE_BUILD_COMPILER=OFF, third_party/llvm-project (2.6 GB) is not needed.
# CI must use `submodules: false` plus an explicit init of this list -- never `recursive`.
#
# third_party/tracy (24 MB) gets added here when the devtools variant lands.
IREE_REQUIRED_SUBMODULES="third_party/flatcc"

required_submodules() { printf '%s' "$IREE_REQUIRED_SUBMODULES"; }
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `bash test/run.sh`
Expected: `ok:` lines for each assertion, then `ALL UNIT TESTS PASS`

- [ ] **Step 8: Commit**

```bash
git add .gitignore test/assert.sh test/run.sh test/lib_submodules.test.sh scripts/lib/submodules.sh
git commit -m "feat: test harness and empirically-determined submodule allowlist"
```

---

### Task 2: Asset naming and version derivation

**Files:**
- Create: `scripts/lib/naming.sh`, `scripts/derive-version.sh`
- Test: `test/lib_naming.test.sh`, `test/derive_version.test.sh`

**Interfaces:**
- Consumes: `test/assert.sh` from Task 1.
- Produces: `asset_stem <version> <variant> <platform>`, `tarball_name`, `sha_name` (same three args). `scripts/derive-version.sh <tag>` prints three `KEY=value` lines: `IREE_VERSION`, `IREE_TAG`, `COMPILER_VERSION`.

- [ ] **Step 1: Write the failing tests**

`test/lib_naming.test.sh`:

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/naming.sh"
assert_eq "$(asset_stem 3.11.0 default linux-x86_64)"   "iree-runtime-3.11.0-default-linux-x86_64"           "asset_stem"
assert_eq "$(tarball_name 3.11.0 default linux-x86_64)" "iree-runtime-3.11.0-default-linux-x86_64.tar.gz"    "tarball_name"
assert_eq "$(sha_name 3.11.0 default linux-x86_64)"     "iree-runtime-3.11.0-default-linux-x86_64.tar.gz.sha256" "sha_name"
exit "$ASSERT_FAILS"
```

`test/derive_version.test.sh`:

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
d="$here/../scripts/derive-version.sh"

out="$(bash "$d" v3.11.0-1)"
assert_contains "$out" "IREE_VERSION=3.11.0"      "derives IREE version"
assert_contains "$out" "IREE_TAG=v3.11.0"          "derives IREE tag"
assert_contains "$out" "COMPILER_VERSION=3.11.0"   "compiler version matches runtime version"

# pkgrev only re-rolls the same version; it must not leak into the version itself.
out2="$(bash "$d" v3.11.0-7)"
assert_contains "$out2" "IREE_VERSION=3.11.0"      "pkgrev does not change version"

# Malformed tags must fail loudly, not silently produce garbage.
if bash "$d" 3.11.0 >/dev/null 2>&1; then
  echo "FAIL: tag without v prefix should be rejected" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else echo "ok: rejects tag without v prefix"; fi
if bash "$d" v3.11.0 >/dev/null 2>&1; then
  echo "FAIL: tag without pkgrev should be rejected" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else echo "ok: rejects tag without pkgrev"; fi
exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash test/lib_naming.test.sh; bash test/derive_version.test.sh`
Expected: both FAIL with "No such file or directory"

- [ ] **Step 3: Write the implementations**

`scripts/lib/naming.sh`:

```bash
#!/usr/bin/env bash
# Asset naming. Single source of truth. Source me.
asset_stem()   { printf 'iree-runtime-%s-%s-%s' "$1" "$2" "$3"; }   # <version> <variant> <platform>
tarball_name() { printf '%s.tar.gz' "$(asset_stem "$@")"; }
sha_name()     { printf '%s.sha256' "$(tarball_name "$@")"; }
```

`scripts/derive-version.sh`:

```bash
#!/usr/bin/env bash
# Release tag -> IREE tag + paired compiler version.
#
# v1 anchors on IREE *stable* releases, where the pip iree-base-compiler version
# equals the IREE version. That is what makes pairing correct by construction and
# keeps this script trivial. Tracking `main` would key on a nightly compiler
# version instead and require resolving it to a commit -- deliberately not done here.
set -euo pipefail

tag="${1:-}"
if [ -z "$tag" ]; then
  echo "usage: derive-version.sh <tag>   e.g. v3.11.0-1" >&2
  exit 2
fi

# v<major>.<minor>.<patch>-<pkgrev>
if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$'; then
  echo "error: tag '$tag' does not match v<major>.<minor>.<patch>-<pkgrev> (e.g. v3.11.0-1)" >&2
  exit 2
fi

version="${tag#v}"       # 3.11.0-1
version="${version%-*}"  # 3.11.0

echo "IREE_VERSION=${version}"
echo "IREE_TAG=v${version}"
echo "COMPILER_VERSION=${version}"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/naming.sh scripts/derive-version.sh test/lib_naming.test.sh test/derive_version.test.sh
git commit -m "feat: asset naming and release-tag version derivation"
```

---

### Task 3: Variant flags, common flags, and `--print-flags`

The point of `effective_cmake_flags` is that the build, `--print-flags`, and `BUILDINFO` provenance all go through one function, so recorded provenance cannot diverge from the build that produced it.

**Files:**
- Create: `scripts/lib/variants.sh`, `scripts/lib/cmakeflags.sh`, `build-runtime.sh`
- Test: `test/lib_variants.test.sh`, `test/print_flags.test.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks except the test harness.
- Produces: `variant_flags <variant>` (prints newline-separated `-D...` flags, exits 2 on unknown variant), `common_flags` (same format), `effective_cmake_flags <variant>` (common + variant, deduped by flag name, variant wins). `build-runtime.sh --print-flags --variant <v>`.

- [ ] **Step 1: Write the failing tests**

`test/lib_variants.test.sh`:

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/lib/variants.sh"
. "$here/../scripts/lib/cmakeflags.sh"

df="$(variant_flags default)"
assert_contains "$df" "-DIREE_HAL_DRIVER_LOCAL_SYNC=ON"  "default has local-sync"
assert_contains "$df" "-DIREE_HAL_DRIVER_LOCAL_TASK=ON"  "default has local-task"
assert_contains "$df" "-DIREE_ENABLE_RUNTIME_TRACING=OFF" "default has tracing off"

cf="$(common_flags)"
assert_contains "$cf" "-DIREE_BUILD_COMPILER=OFF"        "compiler is out of contract"
assert_contains "$cf" "-DBUILD_SHARED_LIBS=OFF"          "static only"
assert_contains "$cf" "-DCMAKE_BUILD_TYPE=Release"       "release build"
assert_contains "$cf" "-DCMAKE_POSITION_INDEPENDENT_CODE=ON" "PIC on"
assert_contains "$cf" "-DIREE_ALLOCATOR_SYSTEM=libc"     "libc allocator"

ef="$(effective_cmake_flags default)"
assert_contains "$ef" "-DIREE_BUILD_COMPILER=OFF"        "effective includes common"
assert_contains "$ef" "-DIREE_HAL_DRIVER_LOCAL_TASK=ON"  "effective includes variant"

# No flag may appear twice -- a duplicate means common and variant disagree silently.
dupes="$(printf '%s\n' "$ef" | sed 's/=.*//' | sort | uniq -d)"
assert_eq "$dupes" "" "no duplicate flag names in effective set"

if variant_flags nonesuch >/dev/null 2>&1; then
  echo "FAIL: unknown variant should be rejected" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else echo "ok: rejects unknown variant"; fi
exit "$ASSERT_FAILS"
```

`test/print_flags.test.sh`:

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"

out="$(bash "$here/../build-runtime.sh" --print-flags --variant default)"
assert_contains "$out" "-DIREE_BUILD_COMPILER=OFF"       "print-flags shows compiler off"
assert_contains "$out" "-DIREE_HAL_DRIVER_LOCAL_TASK=ON" "print-flags shows variant flags"

# --print-flags must not need a source tree or a container.
if bash "$here/../build-runtime.sh" --print-flags --variant default >/dev/null 2>&1; then
  echo "ok: print-flags works with no --iree-src"
else echo "FAIL: print-flags must not require --iree-src" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash test/lib_variants.test.sh; bash test/print_flags.test.sh`
Expected: both FAIL with "No such file or directory"

- [ ] **Step 3: Write `scripts/lib/variants.sh`**

```bash
#!/usr/bin/env bash
# variant -> cmake flags. Single source of truth. Source me.
#
# Only `default` exists in v1. The wishlist's minimal/perf split was collapsed:
# local-sync and local-task both compile into one build and the consumer selects
# between them at runtime by device URI, so a build-time fork bought nothing.
# `devtools` (Tracy + allocation statistics) is a real future variant -- tracing
# overhead must stay out of the ship default.
variant_flags() { # <variant>
  case "${1:-}" in
    default)
      cat <<'EOF'
-DIREE_HAL_DRIVER_DEFAULTS=OFF
-DIREE_HAL_DRIVER_LOCAL_SYNC=ON
-DIREE_HAL_DRIVER_LOCAL_TASK=ON
-DIREE_HAL_EXECUTABLE_LOADER_DEFAULTS=OFF
-DIREE_HAL_EXECUTABLE_LOADER_EMBEDDED_ELF=ON
-DIREE_HAL_EXECUTABLE_LOADER_SYSTEM_LIBRARY=ON
-DIREE_ENABLE_RUNTIME_TRACING=OFF
EOF
      ;;
    *)
      echo "error: unknown variant '${1:-}' (known: default)" >&2
      return 2
      ;;
  esac
}

known_variants() { printf 'default'; }
```

- [ ] **Step 4: Write `scripts/lib/cmakeflags.sh`**

```bash
#!/usr/bin/env bash
# Variant-independent cmake flags + the composer. Single source of truth. Source me.
# Requires variants.sh to be sourced first.

common_flags() {
  cat <<'EOF'
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
EOF
}

# common + variant, deduped by flag name with the variant winning.
# The build, --print-flags, and BUILDINFO provenance all call this, so recorded
# provenance cannot drift from the build that produced it.
effective_cmake_flags() { # <variant>
  local variant="${1:?variant required}" vflags cflags name
  vflags="$(variant_flags "$variant")" || return 2
  cflags="$(common_flags)"

  # Emit variant flags first, then any common flag whose name the variant didn't set.
  printf '%s\n' "$vflags"
  while IFS= read -r flag; do
    [ -n "$flag" ] || continue
    name="${flag%%=*}"
    if ! printf '%s\n' "$vflags" | grep -q "^${name}="; then
      printf '%s\n' "$flag"
    fi
  done <<EOF
$cflags
EOF
}
```

- [ ] **Step 5: Write `build-runtime.sh` (argument parsing and `--print-flags` only)**

Later tasks extend this file; this step establishes the skeleton and the one flag that works without a source tree.

```bash
#!/usr/bin/env bash
# Single entrypoint for the IREE runtime dist build recipe.
#
# Must run inside quay.io/pypa/manylinux_2_28_x86_64. Never clones IREE --
# the caller always supplies --iree-src (CI via actions/checkout, locally a mount).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/scripts/lib/variants.sh"
. "$HERE/scripts/lib/cmakeflags.sh"

VARIANT="default"
PREFIX=""
IREE_SRC=""
BUILD_DIR=""
PRINT_FLAGS=0

usage() {
  cat <<'EOF'
usage: build-runtime.sh --variant <default> --prefix <dir> --iree-src <checkout> [--build-dir <dir>]
       build-runtime.sh --print-flags [--variant <default>]

  --variant      runtime variant (default: default)
  --prefix       install prefix for the staged tree
  --iree-src     checkout of iree-org/iree at the target tag, with required submodules
  --build-dir    cmake build tree (default: <dirname of prefix>/iree-build-<variant>)
  --print-flags  print the effective cmake flags and exit; needs no source tree
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --variant)     VARIANT="$2"; shift 2 ;;
    --prefix)      PREFIX="$2"; shift 2 ;;
    --iree-src)    IREE_SRC="$2"; shift 2 ;;
    --build-dir)   BUILD_DIR="$2"; shift 2 ;;
    --print-flags) PRINT_FLAGS=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$PRINT_FLAGS" -eq 1 ]; then
  effective_cmake_flags "$VARIANT"
  exit 0
fi

[ -n "$PREFIX" ]   || { echo "error: --prefix is required" >&2; exit 2; }
[ -n "$IREE_SRC" ] || { echo "error: --iree-src is required (this recipe never clones IREE)" >&2; exit 2; }
[ -d "$IREE_SRC" ] || { echo "error: --iree-src '$IREE_SRC' is not a directory" >&2; exit 2; }

if [ -z "$BUILD_DIR" ]; then
  BUILD_DIR="$(dirname "$PREFIX")/iree-build-${VARIANT}"
fi

echo "build-runtime.sh: variant=$VARIANT prefix=$PREFIX build-dir=$BUILD_DIR"
echo "error: build phases not yet implemented" >&2
exit 1
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `chmod +x build-runtime.sh && bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/variants.sh scripts/lib/cmakeflags.sh build-runtime.sh \
        test/lib_variants.test.sh test/print_flags.test.sh
git commit -m "feat: variant/common cmake flags and build-runtime.sh --print-flags"
```

---

### Task 4: Build and install phase

This is the phase whose absence caused the consumer's pain: the walking skeleton never ran `cmake --install`, so no CMake package existed and the link surface had to be reconstructed by hand.

**Files:**
- Modify: `build-runtime.sh` (replace the `exit 1` stub from Task 3)
- Test: `test/build_smoke.sh` (structural check of a built prefix; not part of `run.sh` since it needs a real build)

**Interfaces:**
- Consumes: `effective_cmake_flags` (Task 3), `IREE_REQUIRED_SUBMODULES` (Task 1).
- Produces: a staged prefix containing `lib/`, `include/`, `lib/cmake/IREE/IREERuntimeConfig.cmake`, `lib/cmake/IREE/IREETargets-Runtime.cmake`.

- [ ] **Step 1: Write the failing structural test**

`test/build_smoke.sh`:

```bash
#!/usr/bin/env bash
# Structural smoke check of an already-built prefix. Usage: build_smoke.sh <prefix>
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
prefix="${1:?usage: build_smoke.sh <prefix>}"

for f in \
  "lib/cmake/IREE/IREERuntimeConfig.cmake" \
  "lib/cmake/IREE/IREETargets-Runtime.cmake" \
  "include/iree/runtime/api.h" \
  "include/iree/base/api.h"
do
  if [ -e "$prefix/$f" ]; then echo "ok: $f present"
  else echo "FAIL: $f missing from prefix" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
done

# The compiler is out of contract; its config must not ship.
if [ -e "$prefix/lib/cmake/IREE/IREECompilerConfig.cmake" ]; then
  echo "FAIL: IREECompilerConfig.cmake must not ship (compiler is out of contract)" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else echo "ok: no compiler config shipped"; fi

# Static archives only.
if ls "$prefix"/lib/*.a >/dev/null 2>&1; then echo "ok: static archives present"
else echo "FAIL: no static archives in lib/" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

# PIC: a non-PIC x86-64 archive shows R_X86_64_32/32S relocations.
bad=0
for a in "$prefix"/lib/*.a; do
  if readelf -r "$a" 2>/dev/null | grep -qE 'R_X86_64_(32|32S)[[:space:]]'; then
    echo "FAIL: non-PIC relocations in $(basename "$a")" >&2; bad=1
  fi
done
if [ "$bad" -eq 0 ]; then echo "ok: archives are PIC"; else ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run it against nothing to verify it fails**

Run: `bash test/build_smoke.sh /tmp/nonexistent-prefix`
Expected: FAIL lines for each missing file; non-zero exit.

- [ ] **Step 3: Implement the build phase**

In `build-runtime.sh`, replace these two lines from Task 3:

```bash
echo "error: build phases not yet implemented" >&2
exit 1
```

with:

```bash
# --- Phase 1: configure, build, install -------------------------------------

# Verify the caller supplied the submodules the runtime build needs. Failing here
# with a clear message beats a confusing CMake error 30 seconds in.
. "$HERE/scripts/lib/submodules.sh"
for sm in $IREE_REQUIRED_SUBMODULES; do
  if [ ! -e "$IREE_SRC/$sm/CMakeLists.txt" ]; then
    echo "error: required submodule '$sm' is not initialized in $IREE_SRC" >&2
    echo "hint: git -C '$IREE_SRC' submodule update --init --depth 1 $sm" >&2
    exit 2
  fi
done

mapfile -t FLAGS < <(effective_cmake_flags "$VARIANT")

# -ffile-prefix-map keeps __FILE__ (which IREE embeds in status strings) and DWARF
# DW_AT_comp_dir relative, so published artifacts carry no build-machine paths.
PREFIX_MAP="-ffile-prefix-map=${IREE_SRC}=iree"

echo "==> configuring"
cmake -G Ninja -B "$BUILD_DIR" -S "$IREE_SRC" \
  "${FLAGS[@]}" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_C_FLAGS="$PREFIX_MAP" \
  -DCMAKE_CXX_FLAGS="$PREFIX_MAP"

echo "==> building"
cmake --build "$BUILD_DIR"

echo "==> installing to $PREFIX"
# The step the walking skeleton skipped. Running it is what makes the export set
# real -- and with it the flatcc transitives, the IREE_ALLOCATOR_SYSTEM_CTL define,
# the merged include dirs, and link ordering all come free as target properties.
cmake --install "$BUILD_DIR"

echo "==> phase 1 complete"
```

- [ ] **Step 4: Run a real build and verify the test passes**

```bash
docker run --rm -v "$PWD":/work -v /home/corey/workspace/iree:/iree \
  -w /work quay.io/pypa/manylinux_2_28_x86_64 \
  bash -lc 'export PATH=/opt/python/cp312-cp312/bin:$PATH; \
    ./build-runtime.sh --variant default --prefix /work/out --iree-src /iree'
bash test/build_smoke.sh out
```

Expected: `ok:` for every check, exit 0.

If the container lacks clang 21.1.8, install it first (`dnf install -y clang lld` or a pinned tarball) and record what was needed — Task 13 bakes it into CI.

- [ ] **Step 5: Commit**

```bash
git add build-runtime.sh test/build_smoke.sh
git commit -m "feat: configure/build/install phase producing a real CMake package"
```

---

### Task 5: Relocatability repair and assertion

Repair is a step; the assertion is the contract. Without the assertion, a future IREE bump can silently reintroduce an absolute path.

**Files:**
- Create: `scripts/relocatability.sh`
- Modify: `build-runtime.sh` (call it after install)
- Test: `test/relocatability.test.sh`

**Interfaces:**
- Consumes: a staged prefix from Task 4.
- Produces: `relocatability_repair <prefix>`, `relocatability_assert <prefix> <build_path> <src_path>` (exits non-zero listing every offending file).

- [ ] **Step 1: Write the failing test**

`test/relocatability.test.sh` — hermetic; builds a fake prefix rather than needing a real build:

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
. "$here/../scripts/relocatability.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/lib/cmake/IREE"

# A config leaking an absolute install prefix, as CMake sometimes emits.
cat > "$tmp/lib/cmake/IREE/IREETargets-Runtime.cmake" <<EOF
set_target_properties(iree_base_base PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES "$tmp/include"
  INTERFACE_LINK_LIBRARIES "/usr/lib64/libm.so;/usr/lib64/libdl.so"
)
EOF
# Build-tree metadata that must never ship.
touch "$tmp/CMakeCache.txt" "$tmp/compile_commands.json"

relocatability_repair "$tmp"

got="$(cat "$tmp/lib/cmake/IREE/IREETargets-Runtime.cmake")"
assert_contains "$got" '${PACKAGE_PREFIX_DIR}/include' "absolute prefix rewritten"
assert_contains "$got" "-lm"  "absolute libm normalized to -lm"
assert_contains "$got" "-ldl" "absolute libdl normalized to -ldl"

if [ -e "$tmp/CMakeCache.txt" ]; then
  echo "FAIL: CMakeCache.txt must be removed" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else echo "ok: CMakeCache.txt removed"; fi
if [ -e "$tmp/compile_commands.json" ]; then
  echo "FAIL: compile_commands.json must be removed" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else echo "ok: compile_commands.json removed"; fi

# A clean prefix passes the assertion.
if relocatability_assert "$tmp" "/nonexistent/build" "/nonexistent/src" >/dev/null 2>&1; then
  echo "ok: clean prefix passes assertion"
else echo "FAIL: clean prefix should pass" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

# A prefix with a leaked build path fails it.
mkdir -p "$tmp/lib/cmake/IREE"
echo 'set(X "/build/tree/here")' > "$tmp/lib/cmake/IREE/leak.cmake"
if relocatability_assert "$tmp" "/build/tree" "/nonexistent/src" >/dev/null 2>&1; then
  echo "FAIL: leaked build path should fail the assertion" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else echo "ok: leaked build path fails the assertion"; fi

exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/relocatability.test.sh`
Expected: FAIL — `scripts/relocatability.sh: No such file or directory`

- [ ] **Step 3: Write the implementation**

`scripts/relocatability.sh`:

```bash
#!/usr/bin/env bash
# Make a staged prefix relocatable, then prove it. Source me.
#
# The consumer's escape hatch (IREE_INSTALL pointing at a build tree) is fragile
# precisely because of absolute-path leakage. Repair handles the known sources;
# the assertion catches anything an IREE bump introduces later.

relocatability_repair() { # <prefix>
  local prefix="${1:?prefix required}"
  local abs; abs="$(cd "$prefix" && pwd)"

  # Rewrite the leaked absolute prefix to CMake's relocatable variable.
  if [ -d "$prefix/lib/cmake" ]; then
    grep -rl "$abs" "$prefix/lib/cmake" 2>/dev/null | while IFS= read -r f; do
      sed -i "s|${abs}|\${PACKAGE_PREFIX_DIR}|g" "$f"
    done || true

    # Absolute system library paths break consumers on Debian/Ubuntu multiarch,
    # where these live somewhere else. Normalize to bare -l<name>.
    find "$prefix/lib/cmake" -type f -name '*.cmake' -print0 2>/dev/null \
      | xargs -0 -r sed -i -E 's#/usr/lib(64)?/lib([a-zA-Z0-9_+-]+)\.(so|a)#-l\2#g'
  fi

  # Build-tree metadata must never ship.
  rm -f "$prefix/CMakeCache.txt" "$prefix/compile_commands.json"

  # Scrub RPATH/RUNPATH from any shared object. v1 ships static archives only,
  # so this is normally a no-op -- it exists so adding a .so later cannot leak.
  if command -v patchelf >/dev/null 2>&1; then
    find "$prefix" -type f -name '*.so*' -print0 2>/dev/null \
      | xargs -0 -r -n1 patchelf --remove-rpath 2>/dev/null || true
  fi
}

# Fails loudly, listing every offender. Never narrow this to "just lib/cmake".
relocatability_assert() { # <prefix> <build_path> <src_path>
  local prefix="${1:?prefix required}" build="${2:?build path required}" src="${3:?src path required}"
  local rc=0 hits

  for needle in "$build" "$src"; do
    hits="$(grep -rl -- "$needle" "$prefix" 2>/dev/null || true)"
    if [ -n "$hits" ]; then
      echo "error: build-machine path '$needle' leaked into the staged prefix:" >&2
      printf '  %s\n' $hits >&2
      rc=1
    fi
  done
  return "$rc"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/relocatability.test.sh`
Expected: `ok:` for every assertion, exit 0.

- [ ] **Step 5: Wire it into the build**

Append to `build-runtime.sh` after the `echo "==> phase 1 complete"` line:

```bash
# --- Phase 2: relocatability repair, then proof ------------------------------
. "$HERE/scripts/relocatability.sh"

echo "==> repairing relocatability"
relocatability_repair "$PREFIX"

echo "==> asserting relocatability"
relocatability_assert "$PREFIX" "$(cd "$BUILD_DIR" && pwd)" "$(cd "$IREE_SRC" && pwd)"

echo "==> phase 2 complete"
```

- [ ] **Step 6: Verify against a real prefix**

Run the Docker build command from Task 4 Step 4 again.
Expected: `==> phase 2 complete` with no leak report.

If it reports leaks, that is the assertion doing its job — extend `relocatability_repair` to handle the specific leak, then re-run. Do not weaken the assertion.

- [ ] **Step 7: Commit**

```bash
git add scripts/relocatability.sh test/relocatability.test.sh build-runtime.sh
git commit -m "feat: relocatability repair with a hard assertion gate"
```

---

### Task 6: Generated element-type and status-code constants

The consumer hard-coded `FLOAT_32 = 0x00000120` when the real value is `0x21000020`, and it silently "worked" for six tasks. Generating from IREE's own headers makes that class of bug structurally impossible.

**Files:**
- Create: `emit/emit_constants.c`, `scripts/gen-constants.sh`
- Modify: `build-runtime.sh`
- Test: `test/constants.test.sh`

**Interfaces:**
- Consumes: a built prefix (Task 4).
- Produces: `scripts/gen-constants.sh <prefix>` → `<prefix>/share/iree-runtime-dist/element_types.json` and `status_codes.json`. Both are flat JSON objects mapping name → integer.

- [ ] **Step 1: Write the failing test**

`test/constants.test.sh` — asserts the known-correct values from the consumer's findings:

```bash
#!/usr/bin/env bash
# Validates generated constants. Usage: constants.test.sh <prefix>
# Skips (exit 0) when no prefix is given, so test/run.sh stays hermetic.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
prefix="${1:-}"
if [ -z "$prefix" ]; then echo "skip: constants.test.sh needs a built prefix"; exit 0; fi

et="$prefix/share/iree-runtime-dist/element_types.json"
sc="$prefix/share/iree-runtime-dist/status_codes.json"

for f in "$et" "$sc"; do
  if [ -e "$f" ]; then echo "ok: $(basename "$f") present"
  else echo "FAIL: $(basename "$f") missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
done

python3 -c "import json,sys; json.load(open(sys.argv[1])); json.load(open(sys.argv[2]))" "$et" "$sc" \
  && echo "ok: both files are valid JSON" \
  || { echo "FAIL: invalid JSON" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# The exact bug the consumer paid for: FLOAT_32 is 0x21000020, not 0x00000120.
v="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['FLOAT_32'])" "$et")"
assert_eq "$v" "553648160" "FLOAT_32 == 0x21000020"
v="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['SINT_32'])" "$et")"
assert_eq "$v" "285212704" "SINT_32 == 0x11000020"

v="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['OK'])" "$sc")"
assert_eq "$v" "0" "status OK == 0"
v="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['INVALID_ARGUMENT'])" "$sc")"
assert_eq "$v" "3" "status INVALID_ARGUMENT == 3"

exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash test/constants.test.sh out`
Expected: FAIL — both JSON files missing.

- [ ] **Step 3: Write the emitter**

`emit/emit_constants.c` — includes IREE's own headers so the values cannot be transcribed wrong:

```c
// Emits IREE runtime constants as JSON, read from IREE's own headers.
// Downstream consumers must never hand-transcribe these: the walking skeleton
// hard-coded FLOAT_32 as 0x00000120 when it is 0x21000020, and the error stayed
// invisible until an output type was mapped back.
#include <stdio.h>
#include <string.h>

#include "iree/base/api.h"
#include "iree/hal/api.h"

static int emit_element_types(const char* path) {
  FILE* f = fopen(path, "w");
  if (!f) return 1;
  fprintf(f, "{\n");
  int first = 1;
#define E(sym)                                                            \
  do {                                                                    \
    fprintf(f, "%s  \"%s\": %llu", first ? "" : ",\n", #sym,              \
            (unsigned long long)IREE_HAL_ELEMENT_TYPE_##sym);             \
    first = 0;                                                            \
  } while (0)
  E(NONE); E(OPAQUE_8); E(OPAQUE_16); E(OPAQUE_32); E(OPAQUE_64);
  E(BOOL_8);
  E(INT_8); E(INT_16); E(INT_32); E(INT_64);
  E(SINT_8); E(SINT_16); E(SINT_32); E(SINT_64);
  E(UINT_8); E(UINT_16); E(UINT_32); E(UINT_64);
  E(FLOAT_16); E(FLOAT_32); E(FLOAT_64);
  E(BFLOAT_16);
  E(COMPLEX_FLOAT_64); E(COMPLEX_FLOAT_128);
#undef E
  fprintf(f, "\n}\n");
  fclose(f);
  return 0;
}

static int emit_status_codes(const char* path) {
  FILE* f = fopen(path, "w");
  if (!f) return 1;
  fprintf(f, "{\n");
  int first = 1;
#define E(sym)                                                            \
  do {                                                                    \
    fprintf(f, "%s  \"%s\": %llu", first ? "" : ",\n", #sym,              \
            (unsigned long long)IREE_STATUS_##sym);                       \
    first = 0;                                                            \
  } while (0)
  E(OK); E(CANCELLED); E(UNKNOWN); E(INVALID_ARGUMENT); E(DEADLINE_EXCEEDED);
  E(NOT_FOUND); E(ALREADY_EXISTS); E(PERMISSION_DENIED); E(RESOURCE_EXHAUSTED);
  E(FAILED_PRECONDITION); E(ABORTED); E(OUT_OF_RANGE); E(UNIMPLEMENTED);
  E(INTERNAL); E(UNAVAILABLE); E(DATA_LOSS); E(UNAUTHENTICATED);
  E(DEFERRED); E(INCOMPATIBLE);
#undef E
  fprintf(f, "\n}\n");
  fclose(f);
  return 0;
}

int main(int argc, char** argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: emit_constants <element_types.json> <status_codes.json>\n");
    return 2;
  }
  if (emit_element_types(argv[1])) return 1;
  if (emit_status_codes(argv[2])) return 1;
  return 0;
}
```

If a listed enumerator does not exist at IREE `v3.11.0`, the compile fails naming it — delete that line and note it. Do not guess a value.

- [ ] **Step 4: Write the generator script**

`scripts/gen-constants.sh`:

```bash
#!/usr/bin/env bash
# Compile and run the constant emitter against a built prefix.
set -euo pipefail

PREFIX="${1:?usage: gen-constants.sh <prefix>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

OUT_DIR="$PREFIX/share/iree-runtime-dist"
mkdir -p "$OUT_DIR"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Configure a tiny CMake project against the installed package, so the emitter
# compiles with exactly the include dirs and defines a consumer would get.
cat > "$work/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.21)
project(emit_constants C)
find_package(IREERuntime REQUIRED)
add_executable(emit_constants emit_constants.c)
target_link_libraries(emit_constants PRIVATE iree_runtime_unified)
EOF
cp "$HERE/../emit/emit_constants.c" "$work/"

cmake -G Ninja -B "$work/b" -S "$work" \
  -DCMAKE_PREFIX_PATH="$PREFIX/lib/cmake/IREE" \
  -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$work/b" >/dev/null

"$work/b/emit_constants" "$OUT_DIR/element_types.json" "$OUT_DIR/status_codes.json"
echo "==> generated element_types.json and status_codes.json"
```

If `iree_runtime_unified` is not the exported target name at `v3.11.0`, list the real names with `grep -o 'add_library([a-z_]*' "$PREFIX/lib/cmake/IREE/IREETargets-Runtime.cmake"` and use the unified runtime target. Record the correct name — Task 10 needs it too.

- [ ] **Step 5: Wire into the build and verify**

Append to `build-runtime.sh`:

```bash
# --- Phase 3: generated metadata --------------------------------------------
echo "==> generating constants"
bash "$HERE/scripts/gen-constants.sh" "$PREFIX"
```

Run the Docker build, then: `bash test/constants.test.sh out`
Expected: `ok: FLOAT_32 == 0x21000020` and every other assertion passing.

- [ ] **Step 6: Commit**

```bash
git add emit/emit_constants.c scripts/gen-constants.sh test/constants.test.sh build-runtime.sh
git commit -m "feat: generate element-type and status-code constants from IREE headers"
```

---

### Task 7: `manifest.json` and `BUILDINFO`

**Files:**
- Create: `scripts/gen-manifest.sh`
- Modify: `build-runtime.sh`
- Test: `test/manifest.test.sh`

**Interfaces:**
- Consumes: `effective_cmake_flags` (Task 3), a built prefix (Task 4).
- Produces: `<prefix>/share/iree-runtime-dist/manifest.json` with keys `schema_version`, `variant`, `platform`, `iree_version`, `iree_tag`, `runtime_commit`, `iree_compile_version`, `build_config` (object), `glibc_floor`. Plus `<prefix>/BUILDINFO` (plain text).

- [ ] **Step 1: Write the failing test**

`test/manifest.test.sh`:

```bash
#!/usr/bin/env bash
# Usage: manifest.test.sh <prefix>. Skips when no prefix given.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
prefix="${1:-}"
if [ -z "$prefix" ]; then echo "skip: manifest.test.sh needs a built prefix"; exit 0; fi

m="$prefix/share/iree-runtime-dist/manifest.json"
if [ -e "$m" ]; then echo "ok: manifest.json present"
else echo "FAIL: manifest.json missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); exit "$ASSERT_FAILS"; fi

get() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d$2)" "$m"; }

assert_eq "$(get "$m" "['schema_version']")"       "1"        "schema_version"
assert_eq "$(get "$m" "['variant']")"              "default"  "variant"
assert_eq "$(get "$m" "['platform']")"             "linux-x86_64" "platform"
assert_eq "$(get "$m" "['iree_version']")"         "3.11.0"   "iree_version"
assert_eq "$(get "$m" "['iree_tag']")"             "v3.11.0"  "iree_tag"
assert_eq "$(get "$m" "['iree_compile_version']")" "3.11.0"   "paired compiler version"

# runtime_commit must be a real 40-char sha, not a placeholder.
c="$(get "$m" "['runtime_commit']")"
if printf '%s' "$c" | grep -qE '^[0-9a-f]{40}$'; then echo "ok: runtime_commit is a full sha"
else echo "FAIL: runtime_commit '$c' is not a 40-char sha" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

# Build-config attestation (wishlist #7).
assert_eq "$(get "$m" "['build_config']['IREE_BUILD_COMPILER']")"    "OFF" "compiler off attested"
assert_eq "$(get "$m" "['build_config']['BUILD_SHARED_LIBS']")"      "OFF" "static attested"
assert_eq "$(get "$m" "['build_config']['CMAKE_BUILD_TYPE']")"       "Release" "release attested"
assert_eq "$(get "$m" "['build_config']['IREE_HAL_DRIVER_LOCAL_TASK']")" "ON" "local-task attested"

if [ -e "$prefix/BUILDINFO" ]; then echo "ok: BUILDINFO present"
else echo "FAIL: BUILDINFO missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash test/manifest.test.sh out`
Expected: FAIL — manifest.json missing.

- [ ] **Step 3: Write the implementation**

`scripts/gen-manifest.sh`:

```bash
#!/usr/bin/env bash
# Emit manifest.json + BUILDINFO. Build config comes from effective_cmake_flags,
# so recorded provenance cannot diverge from the build that produced it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/variants.sh"
. "$HERE/lib/cmakeflags.sh"

PREFIX="${1:?usage: gen-manifest.sh <prefix> <variant> <platform> <iree-src> <iree-version> <compiler-version>}"
VARIANT="${2:?variant required}"
PLATFORM="${3:?platform required}"
IREE_SRC="${4:?iree-src required}"
IREE_VERSION="${5:?iree-version required}"
COMPILER_VERSION="${6:?compiler-version required}"

OUT_DIR="$PREFIX/share/iree-runtime-dist"
mkdir -p "$OUT_DIR"

RUNTIME_COMMIT="$(git -C "$IREE_SRC" rev-parse HEAD)"
GLIBC_FLOOR="$(
  find "$PREFIX/lib" -name '*.a' -print0 2>/dev/null \
    | xargs -0 -r readelf -sW 2>/dev/null \
    | grep -oE 'GLIBC_[0-9]+\.[0-9]+' \
    | sort -uV | tail -1 || true
)"
[ -n "$GLIBC_FLOOR" ] || GLIBC_FLOOR="none"

# build_config comes from the same function the build used.
BUILD_CONFIG_JSON="$(
  effective_cmake_flags "$VARIANT" | python3 -c '
import json, sys
cfg = {}
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("-D") or "=" not in line:
        continue
    k, v = line[2:].split("=", 1)
    cfg[k] = v
print(json.dumps(cfg, indent=4, sort_keys=True))
'
)"

python3 - "$OUT_DIR/manifest.json" <<EOF
import json, sys
manifest = {
    "schema_version": 1,
    "variant": "$VARIANT",
    "platform": "$PLATFORM",
    "iree_version": "$IREE_VERSION",
    "iree_tag": "v$IREE_VERSION",
    "runtime_commit": "$RUNTIME_COMMIT",
    "iree_compile_version": "$COMPILER_VERSION",
    "glibc_floor": "$GLIBC_FLOOR",
    "build_config": $BUILD_CONFIG_JSON,
    "notes": {
        "compiler": "The IREE compiler is out of contract: built with IREE_BUILD_COMPILER=OFF and never shipped. Install iree-base-compiler==$COMPILER_VERSION to produce loadable .vmfb files.",
        "pip_runtime_wheel": "The pip iree-base-runtime wheel is NOT linkable at any version -- no headers, no static libs. Only a from-source build or this dist yields a linkable runtime."
    },
}
json.dump(manifest, open(sys.argv[1], "w"), indent=2, sort_keys=True)
open(sys.argv[1], "a").write("\n")
EOF

cat > "$PREFIX/BUILDINFO" <<EOF
iree-runtime-dist
variant=$VARIANT
platform=$PLATFORM
iree_version=$IREE_VERSION
runtime_commit=$RUNTIME_COMMIT
iree_compile_version=$COMPILER_VERSION
glibc_floor=$GLIBC_FLOOR
cmake_flags=$(effective_cmake_flags "$VARIANT" | tr '\n' ' ')
EOF

echo "==> generated manifest.json and BUILDINFO"
```

- [ ] **Step 4: Wire into the build**

In `build-runtime.sh`, add near the top after argument validation:

```bash
PLATFORM="linux-x86_64"
IREE_VERSION="$(git -C "$IREE_SRC" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "unknown")"
COMPILER_VERSION="${COMPILER_VERSION:-$IREE_VERSION}"
```

and append to Phase 3, after the `gen-constants.sh` call:

```bash
echo "==> generating manifest"
bash "$HERE/scripts/gen-manifest.sh" "$PREFIX" "$VARIANT" "$PLATFORM" \
  "$IREE_SRC" "$IREE_VERSION" "$COMPILER_VERSION"
```

- [ ] **Step 5: Verify**

Run the Docker build, then: `bash test/manifest.test.sh out`
Expected: every `ok:`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add scripts/gen-manifest.sh test/manifest.test.sh build-runtime.sh
git commit -m "feat: manifest.json pairing + build-config attestation and BUILDINFO"
```

---

### Task 8: Third-party notices scoped to the actual link surface

The wishlist assumed LLVM notices were needed. With `IREE_BUILD_COMPILER=OFF`, LLVM is never linked — bundling its notices would over-claim. Notices are derived from what actually ships.

**Files:**
- Create: `scripts/gen-notices.sh`
- Modify: `build-runtime.sh`
- Test: `test/notices.test.sh`

**Interfaces:**
- Consumes: a built prefix (Task 4).
- Produces: `<prefix>/LICENSE` and `<prefix>/THIRD-PARTY-NOTICES/<component>/LICENSE`. Also `scripts/lib/linked-components.sh` defining `IREE_LINKED_COMPONENTS`.

**IMPORTANT — do not use `IREE_REQUIRED_SUBMODULES` as the notices input.** Task 1
established empirically that it is a *checkout gate*: IREE's
`check_submodule_init.py --runtime_only` demands all 11 paths in
`runtime_submodules.txt` be initialized regardless of what the build actually uses.
Most of them (`tracy`, `spirv_cross`, `vulkan_headers`, `webgpu-headers`,
`hip-build-deps`, `hsa-runtime-headers`, `benchmark`, `googletest`) are **not linked**
into a local-sync/local-task CPU runtime. Generating a notice for each would over-claim
what the artifact contains — the exact error the design forbids for LLVM. Notices must
be derived from what is actually linked, which is a separate, smaller list.

- [ ] **Step 1: Write the failing test**

`test/notices.test.sh`:

```bash
#!/usr/bin/env bash
# Usage: notices.test.sh <prefix>. Skips when no prefix given.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
prefix="${1:-}"
if [ -z "$prefix" ]; then echo "skip: notices.test.sh needs a built prefix"; exit 0; fi

if [ -s "$prefix/LICENSE" ]; then echo "ok: IREE LICENSE present and non-empty"
else echo "FAIL: LICENSE missing or empty" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

if [ -d "$prefix/THIRD-PARTY-NOTICES" ]; then echo "ok: THIRD-PARTY-NOTICES present"
else echo "FAIL: THIRD-PARTY-NOTICES missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

# flatcc is linked into the runtime, so its notice must ship.
if [ -s "$prefix/THIRD-PARTY-NOTICES/flatcc/LICENSE" ]; then echo "ok: flatcc notice shipped"
else echo "FAIL: flatcc notice missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

# Nothing unlinked may be claimed. llvm-project is excluded by IREE_BUILD_COMPILER=OFF.
# The rest are submodules IREE's checkout gate demands but that a local-sync/local-task
# CPU runtime never links -- claiming them would misrepresent the artifact's contents.
for unlinked in llvm-project tracy spirv_cross vulkan_headers webgpu-headers \
                hip-build-deps hsa-runtime-headers benchmark googletest; do
  if [ -e "$prefix/THIRD-PARTY-NOTICES/$unlinked" ]; then
    echo "FAIL: $unlinked notice must not ship -- it is not linked into this artifact" >&2
    ASSERT_FAILS=$((ASSERT_FAILS+1))
  else echo "ok: no $unlinked notice (correctly not claimed)"; fi
done

# Every notice directory must correspond to something actually shipped.
for d in "$prefix"/THIRD-PARTY-NOTICES/*/; do
  [ -d "$d" ] || continue
  if [ -s "$d/LICENSE" ]; then echo "ok: $(basename "$d") notice non-empty"
  else echo "FAIL: $(basename "$d") notice is empty" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
done

exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash test/notices.test.sh out`
Expected: FAIL — LICENSE and THIRD-PARTY-NOTICES missing.

- [ ] **Step 3: Determine what is actually linked (the experiment)**

Do not assume. Inspect the built archives and find which third-party components
contributed object files:

```bash
for a in out/lib/*.a; do
  echo "== $(basename "$a")"
  ar t "$a" 2>/dev/null | head -5
done | head -60
```

Then check specifically for each candidate. flatcc is the known one:

```bash
nm -o out/lib/*.a 2>/dev/null | grep -c "flatcc" || true
nm -o out/lib/*.a 2>/dev/null | grep -ciE "tracy|spirv|vulkan|webgpu|hsa_|benchmark|gtest" || true
```

Also check for components vendored in-tree rather than as submodules — IREE bundles
some sources directly (e.g. `cpuinfo`, `libbacktrace`) that are linked and therefore
DO need notices even though they are not submodules:

```bash
ls out/lib/*.a | sed 's|.*/lib||; s|\.a$||'
grep -rn "third_party" out/lib/cmake/IREE/IREETargets-Runtime.cmake | head
```

Record the components with a nonzero linked footprint. That list — not the submodule
list — is what Step 4 hard-codes. A component vendored in-tree still needs its license
located under `$IREE_SRC/third_party/<name>/` or wherever IREE keeps it.

- [ ] **Step 4: Write the linked-components list**

`scripts/lib/linked-components.sh` — substitute the list you determined in Step 3:

```bash
#!/usr/bin/env bash
# Third-party components ACTUALLY LINKED into the shipped artifact. Source me.
#
# Deliberately NOT IREE_REQUIRED_SUBMODULES. That list is a checkout gate: IREE's
# check_submodule_init.py --runtime_only demands all 11 paths in
# runtime_submodules.txt be initialized regardless of what the build uses. Most are
# never linked into a local-sync/local-task CPU runtime, and shipping a license
# notice for an unlinked component misrepresents what the artifact contains --
# the same error as claiming LLVM, which IREE_BUILD_COMPILER=OFF excludes entirely.
#
# Determined empirically by inspecting the built archives (see Task 8 Step 3).
# When the driver/loader set changes, re-run that inspection -- this list is not
# derivable from the build flags alone.
IREE_LINKED_COMPONENTS="flatcc"

linked_components() { printf '%s' "$IREE_LINKED_COMPONENTS"; }
```

- [ ] **Step 5: Write the implementation**

`scripts/gen-notices.sh`:

```bash
#!/usr/bin/env bash
# Collect license notices for what is ACTUALLY in the shipped artifact.
#
# Scoped to the real link surface, not a listing of IREE's third_party/ dir.
# With IREE_BUILD_COMPILER=OFF, LLVM is never linked -- shipping its notice
# would over-claim what this artifact contains.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/linked-components.sh"

PREFIX="${1:?usage: gen-notices.sh <prefix> <iree-src>}"
IREE_SRC="${2:?iree-src required}"

# IREE's own license.
cp "$IREE_SRC/LICENSE" "$PREFIX/LICENSE"

NOTICES="$PREFIX/THIRD-PARTY-NOTICES"
rm -rf "$NOTICES"
mkdir -p "$NOTICES"

# One notice per component actually LINKED into the artifact -- deliberately not
# IREE_REQUIRED_SUBMODULES, which is a checkout gate demanding paths this build
# never links (see scripts/lib/linked-components.sh).
for sm in $IREE_LINKED_COMPONENTS; do
  name="$(basename "$sm")"
  found=""
  for cand in LICENSE LICENSE.txt LICENSE.md COPYING NOTICE; do
    if [ -f "$IREE_SRC/$sm/$cand" ]; then found="$IREE_SRC/$sm/$cand"; break; fi
  done
  if [ -z "$found" ]; then
    echo "error: no license file found for required component '$sm'" >&2
    echo "hint: shipping a dependency without its license is a compliance failure" >&2
    exit 1
  fi
  mkdir -p "$NOTICES/$name"
  cp "$found" "$NOTICES/$name/LICENSE"
  echo "  notice: $name <- $(basename "$found")"
done

echo "==> collected $(find "$NOTICES" -name LICENSE | wc -l) third-party notice(s)"
```

- [ ] **Step 6: Wire into the build**

Append to Phase 3 in `build-runtime.sh`:

```bash
echo "==> collecting license notices"
bash "$HERE/scripts/gen-notices.sh" "$PREFIX" "$IREE_SRC"
```

- [ ] **Step 7: Verify**

Run the Docker build, then: `bash test/notices.test.sh out`
Expected: `ok: flatcc notice shipped` plus an `ok: no <name> notice` line for every
unlinked component, exit 0.

- [ ] **Step 8: Commit**

```bash
git add scripts/lib/linked-components.sh scripts/gen-notices.sh test/notices.test.sh build-runtime.sh
git commit -m "feat: third-party notices scoped to the actual link surface"
```

---

### Task 9: The paired `add.vmfb` smoke artifact

Because only the dist has the matching compiler, only the dist can ship an artifact guaranteed to load. This is what lets a consumer smoke-test the runtime with no compiler at all.

**Files:**
- Create: `emit/add.mlir`, `scripts/gen-addvmfb.sh`
- Modify: `build-runtime.sh`
- Test: covered by the consumer e2e (Task 11); this task adds a presence check to `test/build_smoke.sh`

**Interfaces:**
- Consumes: `COMPILER_VERSION` (Task 7).
- Produces: `<prefix>/share/iree-runtime-dist/add.vmfb`, an `@add` entry point taking two `4xf32` tensors and returning their elementwise sum.

- [ ] **Step 1: Write the smoke module source**

`emit/add.mlir`:

```mlir
// Canonical smoke module. Entry point @add: (4xf32, 4xf32) -> 4xf32, elementwise.
// Shipped precompiled by the paired compiler so a consumer can prove "the runtime
// loads and runs a known module" without installing a compiler.
func.func @add(%lhs: tensor<4xf32>, %rhs: tensor<4xf32>) -> tensor<4xf32> {
  %result = arith.addf %lhs, %rhs : tensor<4xf32>
  return %result : tensor<4xf32>
}
```

- [ ] **Step 2: Discover the correct compile flags for 3.11.0**

The target-backend flag spelling changed across IREE versions. Determine the right one rather than guessing:

```bash
python3 -m venv /tmp/claude-1000/-home-corey-workspace-iree-runtime-dist/*/scratchpad/cvenv
/tmp/claude-1000/-home-corey-workspace-iree-runtime-dist/*/scratchpad/cvenv/bin/pip install iree-base-compiler==3.11.0
/tmp/claude-1000/-home-corey-workspace-iree-runtime-dist/*/scratchpad/cvenv/bin/iree-compile --help 2>&1 | grep -iE 'target-device|target-backends' | head
```

Try the modern spelling first:

```bash
.../cvenv/bin/iree-compile emit/add.mlir \
  --iree-hal-target-device=local \
  --iree-hal-local-target-device-backends=llvm-cpu \
  -o /tmp/add.vmfb && echo MODERN_OK
```

If that errors, fall back to the older spelling:

```bash
.../cvenv/bin/iree-compile emit/add.mlir \
  --iree-hal-target-backends=llvm-cpu -o /tmp/add.vmfb && echo LEGACY_OK
```

Record which worked — Step 3 hard-codes it.

- [ ] **Step 3: Write the generator**

`scripts/gen-addvmfb.sh` — substitute the flags that worked in Step 2:

```bash
#!/usr/bin/env bash
# Install the paired compiler and compile the canonical smoke module.
#
# The runtime and the .vmfb must agree on VM import signatures. Pairing a stable
# runtime with the same-numbered stable compiler makes them agree by construction;
# the walking skeleton's load failure came from mixing a main-branch runtime
# (3.12.0.dev) with a stable 3.11.0 compiler.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${1:?usage: gen-addvmfb.sh <prefix> <compiler-version>}"
COMPILER_VERSION="${2:?compiler-version required}"

OUT_DIR="$PREFIX/share/iree-runtime-dist"
mkdir -p "$OUT_DIR"

venv="$(mktemp -d)/venv"
trap 'rm -rf "$(dirname "$venv")"' EXIT

python3 -m venv "$venv"
"$venv/bin/pip" install --quiet "iree-base-compiler==${COMPILER_VERSION}"

"$venv/bin/iree-compile" "$HERE/../emit/add.mlir" \
  --iree-hal-target-device=local \
  --iree-hal-local-target-device-backends=llvm-cpu \
  -o "$OUT_DIR/add.vmfb"

echo "==> compiled add.vmfb with iree-base-compiler==${COMPILER_VERSION}"
```

- [ ] **Step 4: Add a presence check to the structural smoke test**

In `test/build_smoke.sh`, add before the final `exit`:

```bash
if [ -s "$prefix/share/iree-runtime-dist/add.vmfb" ]; then echo "ok: add.vmfb present"
else echo "FAIL: add.vmfb missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
```

- [ ] **Step 5: Wire into the build and verify**

Append to `build-runtime.sh`:

```bash
# --- Phase 4: pair with the compiler ----------------------------------------
echo "==> compiling paired smoke artifact"
bash "$HERE/scripts/gen-addvmfb.sh" "$PREFIX" "$COMPILER_VERSION"

echo "==> build complete: $PREFIX"
```

Run the Docker build, then: `bash test/build_smoke.sh out`
Expected: `ok: add.vmfb present`.

- [ ] **Step 6: Commit**

```bash
git add emit/add.mlir scripts/gen-addvmfb.sh build-runtime.sh test/build_smoke.sh
git commit -m "feat: ship a paired add.vmfb smoke artifact"
```

---

### Task 10: Dist CMake additions

Upstream's config ships unmodified so the link surface tracks upstream. The dist adds only what upstream omits.

**Files:**
- Create: `cmake/IreeRuntimeDist.cmake.in`
- Modify: `build-runtime.sh`
- Test: `test/cmake_additions.test.sh`

**Interfaces:**
- Consumes: a built prefix (Task 4), `manifest.json` (Task 7).
- Produces: `<prefix>/lib/cmake/IreeRuntimeDist/IreeRuntimeDistConfig.cmake` defining target `iree-runtime-dist::runtime` and variables `IREE_RUNTIME_DIST_VERSION`, `IREE_RUNTIME_DIST_COMPILER_VERSION`, `IREE_RUNTIME_DIST_ADD_VMFB`. Plus `<prefix>/lib/cmake/IREE/IREERuntimeConfigVersion.cmake`.

- [ ] **Step 1: Write the failing test**

`test/cmake_additions.test.sh`:

```bash
#!/usr/bin/env bash
# Usage: cmake_additions.test.sh <prefix>. Skips when no prefix given.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
prefix="${1:-}"
if [ -z "$prefix" ]; then echo "skip: cmake_additions.test.sh needs a built prefix"; exit 0; fi

v="$prefix/lib/cmake/IREE/IREERuntimeConfigVersion.cmake"
if [ -s "$v" ]; then echo "ok: version file present (upstream omits it)"
else echo "FAIL: IREERuntimeConfigVersion.cmake missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

d="$prefix/lib/cmake/IreeRuntimeDist/IreeRuntimeDistConfig.cmake"
if [ -s "$d" ]; then echo "ok: dist config present"
else echo "FAIL: IreeRuntimeDistConfig.cmake missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

got="$(cat "$d" 2>/dev/null || true)"
assert_contains "$got" "iree-runtime-dist::runtime"        "umbrella target defined"
assert_contains "$got" "IREE_RUNTIME_DIST_VERSION"          "version variable exposed"
assert_contains "$got" "IREE_RUNTIME_DIST_COMPILER_VERSION" "paired compiler variable exposed"
assert_contains "$got" "IREE_RUNTIME_DIST_ADD_VMFB"         "smoke artifact path exposed"

# Dist additions must live beside upstream's config, never be edited into it.
up="$prefix/lib/cmake/IREE/IREERuntimeConfig.cmake"
if grep -q "iree-runtime-dist" "$up" 2>/dev/null; then
  echo "FAIL: upstream IREERuntimeConfig.cmake was modified" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1))
else echo "ok: upstream config unmodified"; fi

exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash test/cmake_additions.test.sh out`
Expected: FAIL — both files missing.

- [ ] **Step 3: Write the template**

`cmake/IreeRuntimeDist.cmake.in` — substitute the real unified runtime target name from Task 6 Step 4 if it differs:

```cmake
# iree-runtime-dist additions.
#
# Upstream's IREERuntimeConfig.cmake and IREETargets-Runtime.cmake ship unmodified
# so the link surface tracks upstream. This file adds only what upstream omits:
# one curated umbrella target and the manifest as CMake variables.

get_filename_component(_IRD_PREFIX "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)

find_package(IREERuntime REQUIRED
  PATHS "${_IRD_PREFIX}/lib/cmake/IREE" NO_DEFAULT_PATH)

set(IREE_RUNTIME_DIST_VERSION          "@IREE_VERSION@")
set(IREE_RUNTIME_DIST_COMPILER_VERSION "@COMPILER_VERSION@")
set(IREE_RUNTIME_DIST_VARIANT          "@VARIANT@")
set(IREE_RUNTIME_DIST_PLATFORM         "@PLATFORM@")
set(IREE_RUNTIME_DIST_RUNTIME_COMMIT   "@RUNTIME_COMMIT@")
set(IREE_RUNTIME_DIST_PREFIX           "${_IRD_PREFIX}")
set(IREE_RUNTIME_DIST_ADD_VMFB         "${_IRD_PREFIX}/share/iree-runtime-dist/add.vmfb")
set(IREE_RUNTIME_DIST_MANIFEST         "${_IRD_PREFIX}/share/iree-runtime-dist/manifest.json")
set(IREE_RUNTIME_DIST_ELEMENT_TYPES    "${_IRD_PREFIX}/share/iree-runtime-dist/element_types.json")
set(IREE_RUNTIME_DIST_STATUS_CODES     "${_IRD_PREFIX}/share/iree-runtime-dist/status_codes.json")

# One target to link. Upstream's export set carries the transitive archives,
# compile definitions (including IREE_ALLOCATOR_SYSTEM_CTL), include dirs, and
# link ordering -- this is a rename, not a re-derivation.
if(NOT TARGET iree-runtime-dist::runtime)
  add_library(iree-runtime-dist::runtime INTERFACE IMPORTED)
  target_link_libraries(iree-runtime-dist::runtime INTERFACE iree_runtime_unified)
endif()

message(STATUS
  "iree-runtime-dist ${IREE_RUNTIME_DIST_VERSION} (${IREE_RUNTIME_DIST_VARIANT}/${IREE_RUNTIME_DIST_PLATFORM}), "
  "pair with iree-base-compiler==${IREE_RUNTIME_DIST_COMPILER_VERSION}")
```

- [ ] **Step 4: Generate both files in the build**

Append to Phase 3 in `build-runtime.sh`, after the manifest step:

```bash
echo "==> installing dist cmake additions"
RUNTIME_COMMIT="$(git -C "$IREE_SRC" rev-parse HEAD)"
mkdir -p "$PREFIX/lib/cmake/IreeRuntimeDist"
sed -e "s|@IREE_VERSION@|${IREE_VERSION}|g" \
    -e "s|@COMPILER_VERSION@|${COMPILER_VERSION}|g" \
    -e "s|@VARIANT@|${VARIANT}|g" \
    -e "s|@PLATFORM@|${PLATFORM}|g" \
    -e "s|@RUNTIME_COMMIT@|${RUNTIME_COMMIT}|g" \
    "$HERE/cmake/IreeRuntimeDist.cmake.in" \
    > "$PREFIX/lib/cmake/IreeRuntimeDist/IreeRuntimeDistConfig.cmake"

# Upstream has no write_basic_package_version_file, so find_package(IREERuntime 3.11)
# with a version argument fails today. Supply the file it omits.
cat > "$PREFIX/lib/cmake/IREE/IREERuntimeConfigVersion.cmake" <<EOF
set(PACKAGE_VERSION "${IREE_VERSION}")
if(PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
  if(PACKAGE_FIND_VERSION STREQUAL PACKAGE_VERSION)
    set(PACKAGE_VERSION_EXACT TRUE)
  endif()
endif()
EOF
```

- [ ] **Step 5: Verify**

Run the Docker build, then: `bash test/cmake_additions.test.sh out`
Expected: every `ok:` including `ok: upstream config unmodified`.

- [ ] **Step 6: Commit**

```bash
git add cmake/IreeRuntimeDist.cmake.in test/cmake_additions.test.sh build-runtime.sh
git commit -m "feat: dist cmake additions (version file + umbrella target)"
```

---

### Task 11: Consumer end-to-end test — the acceptance gate

This is the test that matters. Passing in a container that has never seen the build tree is exactly the property the consumer's `IREE_INSTALL`-points-at-a-build-tree escape hatch lacks.

**Files:**
- Create: `test/consumer/CMakeLists.txt`, `test/consumer/consumer.c`, `test/consumer/run.sh`

**Interfaces:**
- Consumes: an extracted tarball or staged prefix with everything from Tasks 4–10.
- Produces: `test/consumer/run.sh <prefix>`, exit 0 on success.

- [ ] **Step 1: Write the consumer program**

`test/consumer/consumer.c`:

```c
// Consumer acceptance test. Proves, in one run: the CMake package resolves, the
// link surface is complete, compile definitions propagate, the shipped add.vmfb
// loads against this runtime (compiler/runtime ABI pairing), and the requested
// HAL driver works.
//
// Usage: consumer <add.vmfb> <device-uri>
#include <stdio.h>
#include <string.h>

#include "iree/runtime/api.h"

#define CHECK(expr)                                              \
  do {                                                           \
    iree_status_t _s = (expr);                                   \
    if (!iree_status_is_ok(_s)) {                                \
      fprintf(stderr, "FAIL at %s:%d\n", __FILE__, __LINE__);    \
      iree_status_fprint(stderr, _s);                            \
      iree_status_free(_s);                                      \
      return 1;                                                  \
    }                                                            \
  } while (0)

int main(int argc, char** argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: consumer <add.vmfb> <device-uri>\n");
    return 2;
  }
  const char* module_path = argv[1];
  const char* device_uri = argv[2];

  // iree_allocator_system() is only declared when IREE_ALLOCATOR_SYSTEM_CTL is
  // defined. If the export set failed to propagate that define, this will not
  // compile -- which is the point.
  iree_allocator_t host_allocator = iree_allocator_system();

  iree_runtime_instance_options_t instance_options;
  iree_runtime_instance_options_initialize(&instance_options);
  iree_runtime_instance_options_use_all_available_drivers(&instance_options);

  iree_runtime_instance_t* instance = NULL;
  CHECK(iree_runtime_instance_create(&instance_options, host_allocator, &instance));

  iree_hal_device_t* device = NULL;
  CHECK(iree_runtime_instance_try_create_default_device(
      instance, iree_make_cstring_view(device_uri), &device));

  iree_runtime_session_options_t session_options;
  iree_runtime_session_options_initialize(&session_options);
  iree_runtime_session_t* session = NULL;
  CHECK(iree_runtime_session_create_with_device(
      instance, &session_options, device,
      iree_runtime_instance_host_allocator(instance), &session));

  // The load step is where a compiler/runtime VM import signature mismatch
  // surfaces. A shipped, paired add.vmfb makes this pass by construction.
  CHECK(iree_runtime_session_append_bytecode_module_from_file(session, module_path));

  iree_runtime_call_t call;
  CHECK(iree_runtime_call_initialize_by_name(
      session, iree_make_cstring_view("module.add"), &call));

  const float lhs_data[4] = {1.0f, 2.0f, 3.0f, 4.0f};
  const float rhs_data[4] = {10.0f, 20.0f, 30.0f, 40.0f};
  const iree_hal_dim_t shape[1] = {4};

  iree_hal_buffer_view_t* lhs = NULL;
  CHECK(iree_hal_buffer_view_allocate_buffer_copy(
      device, iree_hal_device_allocator(device), 1, shape,
      IREE_HAL_ELEMENT_TYPE_FLOAT_32, IREE_HAL_ENCODING_TYPE_DENSE_ROW_MAJOR,
      (iree_hal_buffer_params_t){
          .type = IREE_HAL_MEMORY_TYPE_DEVICE_LOCAL,
          .usage = IREE_HAL_BUFFER_USAGE_DEFAULT,
      },
      iree_make_const_byte_span(lhs_data, sizeof(lhs_data)), &lhs));
  CHECK(iree_runtime_call_inputs_push_back_buffer_view(&call, lhs));
  iree_hal_buffer_view_release(lhs);

  iree_hal_buffer_view_t* rhs = NULL;
  CHECK(iree_hal_buffer_view_allocate_buffer_copy(
      device, iree_hal_device_allocator(device), 1, shape,
      IREE_HAL_ELEMENT_TYPE_FLOAT_32, IREE_HAL_ENCODING_TYPE_DENSE_ROW_MAJOR,
      (iree_hal_buffer_params_t){
          .type = IREE_HAL_MEMORY_TYPE_DEVICE_LOCAL,
          .usage = IREE_HAL_BUFFER_USAGE_DEFAULT,
      },
      iree_make_const_byte_span(rhs_data, sizeof(rhs_data)), &rhs));
  CHECK(iree_runtime_call_inputs_push_back_buffer_view(&call, rhs));
  iree_hal_buffer_view_release(rhs);

  CHECK(iree_runtime_call_invoke(&call, /*flags=*/0));

  iree_hal_buffer_view_t* result = NULL;
  CHECK(iree_runtime_call_outputs_pop_front_buffer_view(&call, &result));

  float out[4] = {0};
  CHECK(iree_hal_device_transfer_d2h(
      device, iree_hal_buffer_view_buffer(result), 0, out, sizeof(out),
      IREE_HAL_TRANSFER_BUFFER_FLAG_DEFAULT, iree_infinite_timeout()));

  const float expected[4] = {11.0f, 22.0f, 33.0f, 44.0f};
  int rc = 0;
  for (int i = 0; i < 4; ++i) {
    if (out[i] != expected[i]) {
      fprintf(stderr, "FAIL: out[%d] = %f, expected %f\n", i, out[i], expected[i]);
      rc = 1;
    }
  }
  if (rc == 0) printf("ok: add.vmfb ran on %s and produced the expected result\n", device_uri);

  iree_hal_buffer_view_release(result);
  iree_runtime_call_deinitialize(&call);
  iree_runtime_session_release(session);
  iree_hal_device_release(device);
  iree_runtime_instance_release(instance);
  return rc;
}
```

- [ ] **Step 2: Write the consumer CMake project**

`test/consumer/CMakeLists.txt` — deliberately uses the dist umbrella target, exactly as `djl-iree-engine` will:

```cmake
cmake_minimum_required(VERSION 3.21)
project(iree_runtime_dist_consumer C)

# This is the downstream consumption path, verbatim. If this resolves, the
# consumer's hand-rolled ResolveIree.cmake is obsolete.
find_package(IreeRuntimeDist REQUIRED)

add_executable(consumer consumer.c)
target_link_libraries(consumer PRIVATE iree-runtime-dist::runtime)
```

- [ ] **Step 3: Write the runner**

`test/consumer/run.sh`:

```bash
#!/usr/bin/env bash
# Consumer acceptance gate. Usage: run.sh <prefix>
#
# Run this in a container with NO build tree and NO IREE source. Passing here is
# the property the "point IREE_INSTALL at a build tree" escape hatch never had.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="$(cd "${1:?usage: run.sh <prefix>}" && pwd)"

build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

echo "==> configuring consumer against $PREFIX"
cmake -G Ninja -B "$build" -S "$HERE" \
  -DCMAKE_PREFIX_PATH="$PREFIX/lib/cmake/IreeRuntimeDist" \
  -DCMAKE_BUILD_TYPE=Release

echo "==> building consumer"
cmake --build "$build"

vmfb="$PREFIX/share/iree-runtime-dist/add.vmfb"

# Both drivers ship in one tarball and the consumer picks at runtime, so both
# must work. The local-task pass is where a TSan leg lands later.
fails=0
for uri in "local-sync" "local-task"; do
  echo "==> running with $uri"
  if "$build/consumer" "$vmfb" "$uri"; then
    echo "ok: $uri"
  else
    echo "FAIL: consumer failed with $uri" >&2
    fails=$((fails + 1))
  fi
done

if [ "$fails" -ne 0 ]; then
  echo "CONSUMER E2E FAILED ($fails driver(s))" >&2
  exit 1
fi
echo "CONSUMER E2E PASSED"
```

- [ ] **Step 4: Run it in a clean container and verify it passes**

The clean container is the point — do not run this on the build host.

```bash
docker run --rm -v "$PWD":/work:ro -v "$PWD/out":/prefix:ro \
  -w /tmp quay.io/pypa/manylinux_2_28_x86_64 \
  bash -lc 'export PATH=/opt/python/cp312-cp312/bin:$PATH; \
    cp -r /work/test /tmp/test && cp -r /prefix /tmp/prefix && \
    bash /tmp/test/consumer/run.sh /tmp/prefix'
```

Expected:
```
ok: add.vmfb ran on local-sync and produced the expected result
ok: local-sync
ok: add.vmfb ran on local-task and produced the expected result
ok: local-task
CONSUMER E2E PASSED
```

If the build fails on a missing `iree_allocator_system()` declaration, the `IREE_ALLOCATOR_SYSTEM_CTL` define is not propagating through the export set — fix that in the install, not by adding the define to the consumer. Adding it downstream is exactly the workaround this project exists to eliminate.

- [ ] **Step 5: Commit**

```bash
git add test/consumer/
git commit -m "feat: consumer e2e acceptance gate"
```

---

### Task 12: Packaging and pin generation

**Files:**
- Create: `scripts/package.sh`, `scripts/gen-pin.sh`
- Test: `test/package.test.sh`, `test/gen_pin.test.sh`

**Interfaces:**
- Consumes: `naming.sh` (Task 2), a verified prefix.
- Produces: `scripts/package.sh <prefix> <version> <variant> <platform> <outdir>` → tarball + `.sha256`. `scripts/gen-pin.sh <owner/repo> <tag> <version> <assets-dir> <outfile>` → `IreeRuntimePin.cmake` defining `IREE_RUNTIME_URL_<variant>_<platform>` and `IREE_RUNTIME_SHA256_<variant>_<platform>`.

- [ ] **Step 1: Write the failing tests**

`test/package.test.sh`:

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/prefix/lib" "$tmp/out"
echo "fake" > "$tmp/prefix/lib/libfake.a"
echo "lic"  > "$tmp/prefix/LICENSE"

bash "$here/../scripts/package.sh" "$tmp/prefix" 3.11.0 default linux-x86_64 "$tmp/out"

tb="$tmp/out/iree-runtime-3.11.0-default-linux-x86_64.tar.gz"
if [ -s "$tb" ]; then echo "ok: tarball created"
else echo "FAIL: tarball missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
if [ -s "$tb.sha256" ]; then echo "ok: sha256 created"
else echo "FAIL: sha256 missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

# The sha file must verify from its own directory.
( cd "$tmp/out" && sha256sum -c "$(basename "$tb").sha256" >/dev/null 2>&1 ) \
  && echo "ok: sha256 verifies" \
  || { echo "FAIL: sha256 does not verify" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# Must unpack to exactly one top-level directory.
top="$(tar tzf "$tb" | cut -d/ -f1 | sort -u | wc -l)"
assert_eq "$top" "1" "single top-level directory"
assert_eq "$(tar tzf "$tb" | cut -d/ -f1 | sort -u)" \
  "iree-runtime-3.11.0-default-linux-x86_64" "top-level dir is the asset stem"

exit "$ASSERT_FAILS"
```

`test/gen_pin.test.sh`:

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/assets"
echo "payload" > "$tmp/assets/iree-runtime-3.11.0-default-linux-x86_64.tar.gz"
( cd "$tmp/assets" && sha256sum iree-runtime-3.11.0-default-linux-x86_64.tar.gz \
    > iree-runtime-3.11.0-default-linux-x86_64.tar.gz.sha256 )

bash "$here/../scripts/gen-pin.sh" "org/iree-runtime-dist" "v3.11.0-1" "3.11.0" \
  "$tmp/assets" "$tmp/IreeRuntimePin.cmake"

got="$(cat "$tmp/IreeRuntimePin.cmake")"
assert_contains "$got" "IREE_RUNTIME_URL_default_linux-x86_64"    "url variable"
assert_contains "$got" "IREE_RUNTIME_SHA256_default_linux-x86_64" "sha variable"
assert_contains "$got" "https://github.com/org/iree-runtime-dist/releases/download/v3.11.0-1/" "release url"

expected_sha="$(cd "$tmp/assets" && sha256sum iree-runtime-3.11.0-default-linux-x86_64.tar.gz | cut -d' ' -f1)"
assert_contains "$got" "$expected_sha" "records the real sha256"

exit "$ASSERT_FAILS"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash test/package.test.sh; bash test/gen_pin.test.sh`
Expected: both FAIL with "No such file or directory"

- [ ] **Step 3: Write `scripts/package.sh`**

```bash
#!/usr/bin/env bash
# Tarball a staged prefix + emit its .sha256.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/naming.sh"

PREFIX="${1:?usage: package.sh <prefix> <version> <variant> <platform> <outdir>}"
VERSION="${2:?version required}"
VARIANT="${3:?variant required}"
PLATFORM="${4:?platform required}"
OUTDIR="${5:?outdir required}"

mkdir -p "$OUTDIR"
stem="$(asset_stem "$VERSION" "$VARIANT" "$PLATFORM")"
tarball="$(tarball_name "$VERSION" "$VARIANT" "$PLATFORM")"

# Stage under the asset stem so the tarball unpacks to one predictable directory.
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -a "$PREFIX" "$staging/$stem"

tar -czf "$OUTDIR/$tarball" -C "$staging" "$stem"

# The sha file must verify from its own directory, so store a bare basename.
( cd "$OUTDIR" && sha256sum "$tarball" > "$(sha_name "$VERSION" "$VARIANT" "$PLATFORM")" )

echo "==> packaged $OUTDIR/$tarball"
```

- [ ] **Step 4: Write `scripts/gen-pin.sh`**

```bash
#!/usr/bin/env bash
# Generate IreeRuntimePin.cmake -- URL + SHA-256 per variant/platform.
#
# This replaces the consumer's stub seam native/cmake/IreeRuntimePin.cmake.
# Recording the hash means FetchContent re-verifies the tarball on every build,
# which is the supply-chain review gate.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/naming.sh"
. "$HERE/lib/variants.sh"

REPO="${1:?usage: gen-pin.sh <owner/repo> <tag> <version> <assets-dir> <outfile>}"
TAG="${2:?tag required}"
VERSION="${3:?version required}"
ASSETS="${4:?assets dir required}"
OUTFILE="${5:?outfile required}"

PLATFORMS="linux-x86_64"

{
  echo "# Generated by iree-runtime-dist gen-pin.sh -- do not edit."
  echo "# Release: $TAG"
  echo "#"
  echo "# Paste into a consuming project and FetchContent the pinned tarball;"
  echo "# the recorded SHA-256 is re-verified on every build."
  echo ""
  for variant in $(known_variants); do
    for platform in $PLATFORMS; do
      tb="$(tarball_name "$VERSION" "$variant" "$platform")"
      shafile="$ASSETS/$(sha_name "$VERSION" "$variant" "$platform")"
      if [ ! -f "$shafile" ]; then
        echo "error: missing sha file $shafile" >&2
        exit 1
      fi
      sha="$(cut -d' ' -f1 < "$shafile")"
      echo "set(IREE_RUNTIME_URL_${variant}_${platform}"
      echo "    \"https://github.com/${REPO}/releases/download/${TAG}/${tb}\")"
      echo "set(IREE_RUNTIME_SHA256_${variant}_${platform}"
      echo "    \"${sha}\")"
      echo ""
    done
  done
} > "$OUTFILE"

echo "==> generated $OUTFILE"
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash test/run.sh`
Expected: `ALL UNIT TESTS PASS`

- [ ] **Step 6: Commit**

```bash
git add scripts/package.sh scripts/gen-pin.sh test/package.test.sh test/gen_pin.test.sh
git commit -m "feat: tarball packaging and IreeRuntimePin.cmake generation"
```

---

### Task 13: Release workflow

`verify` gating `release` is the structural expression of test-first: no artifact publishes without proving itself consumable.

**Files:**
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: every script from Tasks 1–12.
- Produces: a GitHub Release with the tarball, its `.sha256`, and `IreeRuntimePin.cmake`.

- [ ] **Step 1: Write the workflow**

`.github/workflows/release.yml`:

```yaml
name: release

# Pushing a version tag is the ONLY release trigger.
on:
  push:
    tags:
      - "v*.*.*-*"

permissions:
  contents: write
  id-token: write
  attestations: write

jobs:
  setup:
    runs-on: ubuntu-latest
    outputs:
      iree_version: ${{ steps.derive.outputs.iree_version }}
      iree_tag: ${{ steps.derive.outputs.iree_tag }}
      compiler_version: ${{ steps.derive.outputs.compiler_version }}
      submodules: ${{ steps.submodules.outputs.list }}
    steps:
      - uses: actions/checkout@v4
      - id: derive
        run: bash scripts/derive-version.sh "${GITHUB_REF_NAME}" | tr 'A-Z' 'a-z' >> "$GITHUB_OUTPUT"
      - id: submodules
        run: |
          . scripts/lib/submodules.sh
          echo "list=$(required_submodules)" >> "$GITHUB_OUTPUT"
      - run: bash test/run.sh

  build:
    needs: setup
    runs-on: ubuntu-latest
    strategy:
      matrix:
        variant: [default]
        platform: [linux-x86_64]
    steps:
      - uses: actions/checkout@v4
        with:
          path: dist

      # NEVER use submodules: recursive -- third_party/llvm-project alone is 2.6 GB
      # and is unnecessary with IREE_BUILD_COMPILER=OFF. The required set is the
      # tested constant in scripts/lib/submodules.sh.
      - uses: actions/checkout@v4
        with:
          repository: iree-org/iree
          ref: ${{ needs.setup.outputs.iree_tag }}
          path: iree
          submodules: false
          fetch-depth: 1
      - name: Init required submodules only
        working-directory: iree
        run: git submodule update --init --depth 1 ${{ needs.setup.outputs.submodules }}

      - name: Build in manylinux
        run: |
          docker run --rm \
            -v "${PWD}/dist":/work -v "${PWD}/iree":/iree \
            -e COMPILER_VERSION="${{ needs.setup.outputs.compiler_version }}" \
            -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
            -w /work quay.io/pypa/manylinux_2_28_x86_64 \
            bash -lc '
              set -euo pipefail
              export PATH=/opt/python/cp312-cp312/bin:$PATH
              dnf install -y clang lld ninja-build patchelf >/dev/null
              ./build-runtime.sh --variant ${{ matrix.variant }} \
                --prefix /work/out --iree-src /iree
              chown -R "$HOST_UID:$HOST_GID" /work/out
            '

      - name: Structural checks
        working-directory: dist
        run: |
          bash test/build_smoke.sh out
          bash test/manifest.test.sh out
          bash test/constants.test.sh out
          bash test/notices.test.sh out
          bash test/cmake_additions.test.sh out

      - name: Package
        working-directory: dist
        run: |
          bash scripts/package.sh out \
            "${{ needs.setup.outputs.iree_version }}" \
            "${{ matrix.variant }}" "${{ matrix.platform }}" assets

      - uses: actions/attest-build-provenance@v1
        with:
          subject-path: dist/assets/*.tar.gz

      - uses: actions/upload-artifact@v4
        with:
          name: assets-${{ matrix.variant }}-${{ matrix.platform }}
          path: dist/assets/

  verify:
    # The acceptance gate. Runs in a container that has never seen the build tree
    # or the IREE source -- exactly the consumer's situation.
    needs: [setup, build]
    runs-on: ubuntu-latest
    strategy:
      matrix:
        variant: [default]
        platform: [linux-x86_64]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          name: assets-${{ matrix.variant }}-${{ matrix.platform }}
          path: assets

      - name: Verify checksum
        working-directory: assets
        run: sha256sum -c ./*.sha256

      - name: Consumer e2e in a clean container
        run: |
          mkdir -p extracted
          tar -xzf assets/*.tar.gz -C extracted
          prefix="$(find extracted -maxdepth 1 -mindepth 1 -type d)"
          docker run --rm \
            -v "${PWD}/test":/test:ro -v "${PWD}/${prefix}":/prefix:ro \
            -w /tmp quay.io/pypa/manylinux_2_28_x86_64 \
            bash -lc '
              set -euo pipefail
              export PATH=/opt/python/cp312-cp312/bin:$PATH
              dnf install -y clang lld ninja-build >/dev/null
              cp -r /test /tmp/t && cp -r /prefix /tmp/p
              bash /tmp/t/consumer/run.sh /tmp/p
            '

  pin:
    needs: [setup, verify]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          path: downloaded
          merge-multiple: true
      - run: |
          bash scripts/gen-pin.sh \
            "${GITHUB_REPOSITORY}" "${GITHUB_REF_NAME}" \
            "${{ needs.setup.outputs.iree_version }}" \
            downloaded IreeRuntimePin.cmake
      - uses: actions/upload-artifact@v4
        with:
          name: pin
          path: IreeRuntimePin.cmake

  release:
    needs: [setup, verify, pin]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with:
          path: release
          merge-multiple: true
      - uses: softprops/action-gh-release@v2
        with:
          files: |
            release/*.tar.gz
            release/*.sha256
            release/IreeRuntimePin.cmake
          body: |
            IREE runtime ${{ needs.setup.outputs.iree_version }} (variant `default`, `linux-x86_64`).

            **Pair with `iree-base-compiler==${{ needs.setup.outputs.compiler_version }}`.**
            Modules compiled by a different compiler version may fail to load with a VM
            import signature mismatch. See `share/iree-runtime-dist/manifest.json`.

            The pip `iree-base-runtime` wheel is not linkable at any version; use this artifact.

            Verify before consuming:
            ```
            sha256sum -c iree-runtime-${{ needs.setup.outputs.iree_version }}-default-linux-x86_64.tar.gz.sha256
            gh attestation verify iree-runtime-${{ needs.setup.outputs.iree_version }}-default-linux-x86_64.tar.gz --repo ${{ github.repository }}
            ```
```

- [ ] **Step 2: Validate the workflow parses**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml')); print('ok: valid YAML')"`
Expected: `ok: valid YAML`

- [ ] **Step 3: Verify the derive-version output format matches the workflow**

`scripts/derive-version.sh` emits uppercase `KEY=value`; the workflow lowercases them into `$GITHUB_OUTPUT`. Confirm the mapping:

Run: `bash scripts/derive-version.sh v3.11.0-1 | tr 'A-Z' 'a-z'`
Expected:
```
iree_version=3.11.0
iree_tag=v3.11.0
compiler_version=3.11.0
```

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "feat: tag-triggered release workflow with a consumer e2e gate"
```

---

### Task 14: Documentation

**Files:**
- Create: `README.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: everything.

- [ ] **Step 1: Write `README.md`**

```markdown
# IREE Runtime Dist

CI infrastructure that builds the [IREE](https://github.com/iree-org/iree) **runtime**
from source and publishes it as attested, hash-pinned, relocatable tarballs for JNI and
other native consumers.

Consumers (e.g. `djl-iree-engine`) do not build IREE. They `FetchContent` a pinned
tarball and `find_package(IreeRuntimeDist)`.

## What this ships

`iree-runtime-3.11.0-default-linux-x86_64.tar.gz` unpacks to one directory:

```
lib/                      # static archives (PIC)
  cmake/IREE/             # upstream IREERuntimeConfig.cmake + targets, unmodified
  cmake/IreeRuntimeDist/  # umbrella target + manifest as CMake vars
include/
share/iree-runtime-dist/
  manifest.json           # pairing + build-config attestation
  element_types.json      # IREE_HAL_ELEMENT_TYPE_* generated from IREE headers
  status_codes.json       # iree_status_code_t generated from IREE headers
  add.vmfb                # smoke module, compiled by the paired compiler
LICENSE
THIRD-PARTY-NOTICES/
BUILDINFO
```

## The compiler is not in the contract

This dist builds with `-DIREE_BUILD_COMPILER=OFF`. It never builds or ships
`iree-compile`. To produce loadable `.vmfb` files, install the paired compiler
recorded in `manifest.json`:

```bash
pip install iree-base-compiler==3.11.0
```

Mismatched compiler and runtime versions fail at VM context creation with a cryptic
import signature mismatch. The shipped `add.vmfb` lets you smoke-test the runtime
without installing a compiler at all.

Note: the pip **`iree-base-runtime` wheel is not linkable** — no headers, no static
libraries, at any version. Only a from-source build or this dist yields a linkable runtime.

## Consuming downstream

```cmake
include(cmake/IreeRuntimePin.cmake)

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

Because the pin records both URL and SHA-256, `FetchContent` re-verifies the tarball
on every build.

### Choosing a HAL driver

Both CPU drivers ship in one tarball; you select at runtime by device URI:

| URI | Behavior |
|---|---|
| `local-sync` | Inline, single-threaded. No IREE-internal threads. |
| `local-task` | Worker pool for CPU intra-op parallelism. |

## Cutting a release

Pushing a version tag is the only trigger.

```bash
git tag v3.11.0-1
git push origin v3.11.0-1
```

`<pkgrev>` bumps re-roll the same IREE version after a recipe fix.

## Building locally

```bash
git clone --filter=blob:none --depth 1 --branch v3.11.0 \
  https://github.com/iree-org/iree.git /path/to/iree
git -C /path/to/iree submodule update --init --depth 1 third_party/flatcc

docker run --rm -v "$PWD":/work -v /path/to/iree:/iree \
  -w /work quay.io/pypa/manylinux_2_28_x86_64 \
  bash -lc 'export PATH=/opt/python/cp312-cp312/bin:$PATH; \
    dnf install -y clang lld ninja-build patchelf; \
    ./build-runtime.sh --variant default --prefix /work/out --iree-src /iree'
```

Inspect the effective cmake flags without building:

```bash
./build-runtime.sh --print-flags --variant default
```

## Verifying an artifact

```bash
sha256sum -c iree-runtime-3.11.0-default-linux-x86_64.tar.gz.sha256
gh attestation verify iree-runtime-3.11.0-default-linux-x86_64.tar.gz \
  --repo <owner>/iree-runtime-dist
```
```

- [ ] **Step 2: Write `CLAUDE.md`**

```markdown
# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this repo is

CI infrastructure that builds the IREE **runtime** and publishes attested, hash-pinned
tarballs. It produces *artifacts*, not a library — a build recipe plus packaging plus CI.

Design: `docs/superpowers/specs/2026-07-19-iree-runtime-dist-design.md`.

## Key commands

```bash
bash test/run.sh                                  # hermetic unit tests; no build, no container
./build-runtime.sh --print-flags --variant default # effective cmake flags without building
bash test/build_smoke.sh out                       # structural check of a built prefix
bash test/consumer/run.sh out                      # consumer e2e (run in a clean container)
```

## Hard constraints

- **The compiler is out of contract.** `-DIREE_BUILD_COMPILER=OFF` always. Never build
  or ship `iree-compile`. It appears only as a version string in `manifest.json` and a
  CI-time pip wheel for `add.vmfb`.
- **Never `submodules: recursive`.** `third_party/llvm-project` is 2.6 GB and unnecessary.
  The required set lives in `scripts/lib/submodules.sh` and is asserted by a test.
- **Upstream CMake files ship unmodified.** Dist additions go in `lib/cmake/IreeRuntimeDist/`.
  Editing `lib/cmake/IREE/` is a test failure.
- **v1 is stable `v3.11.0` only.** Never `main` — mixing a main-branch runtime with a
  stable compiler is what caused the consumer's VM import signature mismatch.

## Architecture

`build-runtime.sh` runs four phases: build+install, relocatability repair+assert,
generate metadata, pair with the compiler. Phase 1's `cmake --install` is load-bearing:
running it is what makes the export set real, and with it the transitive archives,
the `IREE_ALLOCATOR_SYSTEM_CTL` define, merged include dirs, and link ordering all
come free as CMake target properties.

`scripts/lib/*.sh` are sourced by both the build and CI so the two cannot drift. When
changing what they define, change it there, not at a call site. `effective_cmake_flags`
in particular feeds the build, `--print-flags`, and `BUILDINFO` provenance, so recorded
provenance cannot diverge from the build that produced it.

## Testing

Two layers. Hermetic `test/*.test.sh` need no build and run via `test/run.sh`. Tests
taking a `<prefix>` argument skip when given none, so `run.sh` stays hermetic.

`test/consumer/` is the acceptance gate: extract the tarball in a container with no
build tree and no IREE source, `find_package`, compile, load `add.vmfb`, run it, assert
the result — once per device URI. It transitively proves relocatability, link surface,
compile-define propagation, ABI pairing, and glibc floor.

Relocatability has a repair step *and* an assertion. If the assertion fires, extend the
repair — never weaken the assertion.

## Conventions

- `set -euo pipefail` in every script. `grep` exits 1 on no-match and aborts under
  `set -e`; guard with `|| true`.
- The recipe is idempotent: re-runs must not fail on existing build trees.
- Design docs and plans live in `docs/superpowers/{specs,plans}/`.
```

- [ ] **Step 3: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: README and CLAUDE.md"
```

---

## Deferred (not in this plan)

Each is a milestone with its own spec/plan cycle:

- **`devtools` variant** — Tracy tracing + allocation statistics. Adds `third_party/tracy` to the submodule set and a second matrix cell.
- **TSan leg** — meaningful now only against `local-task`, since threading became a runtime selection.
- **`windows-x86_64`** — MSVC, CRT `/MD` vs `/MT` matrix.
- **GPU axis** — CUDA/Vulkan/HIP drivers. Not a flag flip: needs GPU-target compilation, matching loaders, and breaks the consumer's CPU-coherent-memory assumption.
- **Tracking IREE `main`** — keys releases on a nightly compiler version and resolves it to a runtime commit.
- **Tiered PR gate** — worth building once there is a published release to gate against.
