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

# The compiler target files must not ship either. These are separate from IREECompilerConfig.cmake
# and contain dangling IMPORTED_LOCATION entries pointing to compiler archives that were never
# installed. Shipping them would cause find_package(IREERuntime) to succeed, then fail at link time.
for compiler_target in \
  "lib/cmake/IREE/IREETargets-Compiler.cmake" \
  "lib/cmake/IREE/IREETargets-Compiler-release.cmake"
do
  if [ -e "$prefix/$compiler_target" ]; then
    echo "FAIL: $compiler_target must not ship (compiler targets out of contract)" >&2
    ASSERT_FAILS=$((ASSERT_FAILS+1))
  else echo "ok: no compiler target $compiler_target shipped"; fi
done

# Static archives only.
if ls "$prefix"/lib/*.a >/dev/null 2>&1; then echo "ok: static archives present"
else echo "FAIL: no static archives in lib/" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

# The unified runtime archive specifically -- this is the target a downstream
# consumer links against. IREE's install rules are EXCLUDE_FROM_ALL (see
# build-runtime.sh comments), so a bare `cmake --install` produces a complete
# looking export set that points at archives which were never actually copied.
# Check the archive a downstream consumer actually links exists and is non-empty.
unified="$prefix/lib/libiree_runtime_unified.a"
if [ -s "$unified" ]; then echo "ok: libiree_runtime_unified.a present and non-empty"
else echo "FAIL: $unified missing or empty" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

# flatcc is a bundled transitive dependency (IREEBundledLibraries component);
# it must be installed too or the link surface is incomplete.
for f in libflatcc_runtime.a libflatcc_parsing.a; do
  if [ -s "$prefix/lib/$f" ]; then echo "ok: $f present and non-empty"
  else echo "FAIL: $prefix/lib/$f missing or empty" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
done

# Every IMPORTED_LOCATION_RELEASE path in the generated export set must actually
# exist on disk. This is the assertion that catches an EXCLUDE_FROM_ALL-induced
# partial install directly: a bare `cmake --install` leaves the export set
# complete-looking (every target defined, every property set) while every
# IMPORTED_LOCATION points at a file that was never copied -- so find_package()
# succeeds and the failure only shows up later, at a downstream consumer's link
# step. Catch it here instead.
targets_release="$prefix/lib/cmake/IREE/IREETargets-Runtime-release.cmake"
if [ -e "$targets_release" ]; then
  checked=0
  missing=0
  while IFS= read -r rel_path; do
    [ -n "$rel_path" ] || continue
    checked=$((checked+1))
    abs_path="$prefix/${rel_path#\$\{_IMPORT_PREFIX\}/}"
    if [ ! -e "$abs_path" ]; then
      echo "FAIL: exported IMPORTED_LOCATION_RELEASE missing on disk: $abs_path" >&2
      missing=$((missing+1))
    fi
  done < <(grep -o 'IMPORTED_LOCATION_RELEASE "[^"]*"' "$targets_release" \
              | sed -E 's/^IMPORTED_LOCATION_RELEASE "(.*)"$/\1/')
  if [ "$missing" -eq 0 ] && [ "$checked" -gt 0 ]; then
    echo "ok: all $checked exported IMPORTED_LOCATION_RELEASE paths exist on disk"
  else
    echo "FAIL: $missing of $checked exported IMPORTED_LOCATION_RELEASE paths missing" >&2
    ASSERT_FAILS=$((ASSERT_FAILS+1))
  fi
else
  echo "FAIL: $targets_release missing, cannot verify exported paths" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

# PIC: a non-PIC x86-64 archive shows R_X86_64_32/32S relocations.
bad=0
for a in "$prefix"/lib/*.a; do
  if readelf -r "$a" 2>/dev/null | grep -qE 'R_X86_64_(32|32S)[[:space:]]'; then
    echo "FAIL: non-PIC relocations in $(basename "$a")" >&2; bad=1
  fi
done
if [ "$bad" -eq 0 ]; then echo "ok: archives are PIC"; else ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

# Header closure: every header #include "iree/..."-ed directly by the three public
# entry points a consumer #includes must actually exist under include/. This is the
# regression test for the defect where api.h #included headers that IREE's generated
# cmake_install.cmake never installed (see scripts/install-headers.sh) -- a consumer's
# very first #include "iree/runtime/api.h" would fail to compile. Only checks the direct
# #includes of the three entry points (not the full transitive closure) -- cheap, and
# sufficient to catch a regression: any newly-missing header reachable from these three
# roots shows up here directly, or shows up when *its* header is later added as a fourth
# entry point.
checked_headers=0
missing_headers=0
for entry in iree/runtime/api.h iree/base/api.h iree/hal/api.h; do
  entry_path="$prefix/include/$entry"
  if [ ! -e "$entry_path" ]; then
    echo "FAIL: entry point $entry missing from prefix, cannot check its header closure" >&2
    ASSERT_FAILS=$((ASSERT_FAILS+1))
    continue
  fi
  while IFS= read -r inc; do
    [ -n "$inc" ] || continue
    checked_headers=$((checked_headers+1))
    if [ ! -e "$prefix/include/$inc" ]; then
      echo "FAIL: $entry includes \"$inc\" but $prefix/include/$inc does not exist" >&2
      missing_headers=$((missing_headers+1))
    fi
  done < <(grep -ohE '#include[[:space:]]*"iree/[^"]+"' "$entry_path" \
              | sed -E 's/^#include[[:space:]]*"(.*)"$/\1/')
done
if [ "$missing_headers" -eq 0 ] && [ "$checked_headers" -gt 0 ]; then
  echo "ok: all $checked_headers #include \"iree/...\" references from runtime/api.h, base/api.h, hal/api.h resolve under include/"
else
  echo "FAIL: $missing_headers of $checked_headers #include \"iree/...\" references from the public entry points are missing under include/" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

exit "$ASSERT_FAILS"
