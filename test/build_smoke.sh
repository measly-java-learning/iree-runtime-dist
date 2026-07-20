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

# The shipped IREERuntimeConfig.cmake must re-find its own external deps.
# Upstream's config is a 3-line stub that only includes the targets file, but
# IREETargets-Runtime.cmake references the imported target Threads::Threads
# (e.g. via iree_vm_impl) without defining it. Without a find_package(Threads)
# call BEFORE the include, a naive consumer's bare find_package(IREERuntime)
# fails to even configure with:
#   "The link interface of target ... contains: Threads::Threads
#    but the target was not found."
# See scripts/config-deps.sh for the full explanation and the repair.
runtime_config="$prefix/lib/cmake/IREE/IREERuntimeConfig.cmake"
if [ -e "$runtime_config" ] && grep -q 'find_package(Threads' "$runtime_config"; then
  echo "ok: IREERuntimeConfig.cmake re-finds Threads before including targets"
else
  echo "FAIL: IREERuntimeConfig.cmake missing find_package(Threads) -- naive consumers cannot configure" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

# Broader check: no INTERFACE_LINK_LIBRARIES entry in the exported targets file
# may reference an imported target -- Foo::Bar-style OR a bare name like
# "libbacktrace_libbacktrace" -- that isn't either (a) defined by this same
# export set (add_library(<tok> ... IMPORTED)) or (b) resolved by a
# find_package(...) call this config file makes (namespaced tokens only) or
# (c) a known-safe reference: a real system library allowlisted by name, an
# unresolved generator-expression artifact (contains "$<"), or an
# already-normalized bare linker flag (e.g. "-lm", from relocatability
# repair's absolute-system-path normalization).
#
# This is a general version of the Threads check above -- it would have caught
# the Threads gap without needing to know "Threads" by name, and it will catch
# the next such gap if an IREE version bump introduces one. It would ALSO have
# caught the worst gap this project found: a bare name
# ("libbacktrace_libbacktrace") in iree_base_base's link interface with no
# corresponding add_library(...IMPORTED) anywhere in the export set, which
# resolves at a downstream consumer's link step to "-llibbacktrace_libbacktrace"
# with no matching -L search path and fails there -- silently, since
# find_package(IREERuntime) itself succeeds. An earlier version of this check
# filtered tokens to only those containing "::", which is why it never caught
# that gap: of 239 INTERFACE_LINK_LIBRARIES tokens in the real export set,
# exactly two contain "::" (both Threads::Threads), so the filter skipped
# every bare-name token including the one that mattered. Implemented as a
# Python-free, awk/grep pass: collect every token appearing in any
# INTERFACE_LINK_LIBRARIES property, subtract the ones this export set itself
# defines via "add_library(<tok> ... IMPORTED)", and for whatever remains,
# either require the config file to name-check for it via
# find_package(<Namespace-ish-name>) (namespaced tokens; the mapping from
# "Foo::Bar" to the find_package name is approximated as the namespace segment
# before "::" -- good enough for CMake's own find modules (Threads, OpenSSL,
# ZLIB, ...)) or require it to be on the system-library allowlist (bare
# tokens).
#
# Two more artifact shapes turn up once the "::" filter is gone, both handled
# above: some INTERFACE_LINK_LIBRARIES entries wrap a dependency in a
# generator expression CMake writes with a literal backslash before the "$"
# (observed: `\$<LINK_ONLY:rt>`), so the unwrap sed strips an optional leading
# backslash too; and nested generator expressions like
# `$<TARGET_PROPERTY:tgt,PROP>` only partially unwrap in one sed pass, leaving
# either a literal "$<" (caught by the existing genex filter) or, one level
# deeper, a bare "tgt,PROP" string with a comma in it that no real target or
# library name ever contains -- skipped explicitly.
targets_runtime="$prefix/lib/cmake/IREE/IREETargets-Runtime.cmake"
if [ -e "$targets_runtime" ]; then
  dangling=""
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    case "$tok" in
      *'$<'*) continue ;;   # unresolved (possibly nested) generator-expression artifact
      *','*)  continue ;;   # $<TARGET_PROPERTY:tgt,PROP>-style artifact left after unwrap
                             # (a real target/library name never contains a comma)
      -l*)    continue ;;   # already-normalized bare linker flag
    esac
    if grep -qF "add_library($tok " "$targets_runtime"; then
      continue
    fi
    case "$tok" in
      *::*)
        ns="${tok%%::*}"
        if [ -e "$runtime_config" ] && grep -qE "find_package\([[:space:]]*${ns}[[:space:]]" "$runtime_config"; then
          continue
        fi
        ;;
      dl|rt|m|pthread)
        continue
        ;;
    esac
    dangling="$dangling $tok"
  done < <(grep -oE 'INTERFACE_LINK_LIBRARIES[[:space:]]+"[^"]*"' "$targets_runtime" \
              | sed -E 's/^INTERFACE_LINK_LIBRARIES[[:space:]]+"(.*)"$/\1/' \
              | tr ';' '\n' \
              | sed -E 's/\\?\$<[A-Z_]+:(.*)>/\1/' \
              | sort -u)
  if [ -n "$dangling" ]; then
    echo "FAIL: INTERFACE_LINK_LIBRARIES references imported target(s) neither exported, find_package'd, nor allowlisted:$dangling" >&2
    ASSERT_FAILS=$((ASSERT_FAILS+1))
  else
    echo "ok: no dangling imported-target references in IREETargets-Runtime.cmake"
  fi
else
  echo "FAIL: $targets_runtime missing, cannot check for dangling imported targets" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

if [ -s "$prefix/share/iree-runtime-dist/add.vmfb" ]; then echo "ok: add.vmfb present"
else echo "FAIL: add.vmfb missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

# --- Structural symbol assertions (design doc section 7) -------------------
# "Expected and unexpected symbols" was listed as a structural assertion in
# the design but never implemented; PIC-via-relocations and
# absolute-path-absence were. Two real checks, not token ones:
#
#   EXPECTED PRESENT: key public runtime API entry points must be DEFINED
#   (nm code T/t or data D/d, never only U) in the shipped archives -- if a
#   symbol a consumer calls were only ever undefined, find_package() would
#   still succeed and the failure would only surface at the consumer's link
#   step, which is exactly the failure mode this whole test file exists to
#   catch early instead.
#
#   EXPECTED ABSENT: no LLVM or MLIR symbol may be DEFINED anywhere in the
#   shipped archives. This is not a token check -- it is the direct proof of
#   this project's central claim that IREE_BUILD_COMPILER=OFF means LLVM is
#   never linked into what ships, which is also the justification for not
#   shipping an LLVM license notice under THIRD-PARTY-NOTICES/. Without this
#   assertion, that claim rested only on the build flag and on which
#   components were installed; this makes it evidence, re-checked on every
#   build.
if command -v nm >/dev/null 2>&1; then
  unified="$prefix/lib/libiree_runtime_unified.a"

  # EXPECTED PRESENT. At minimum: instance/session lifecycle, the buffer-view
  # allocation entry point, and iree_hal_device_allocator -- the allocator
  # accessor test/consumer/consumer.c actually calls (iree_allocator_system()
  # is a header-only static-inline macro wrapper with no linkable symbol of
  # its own, so it is not a valid choice here -- checked and confirmed absent
  # from nm output entirely, present or not, which is why device_allocator is
  # used instead: it is the actual linkable API surface the consumer's calls
  # resolve through).
  if [ -s "$unified" ]; then
    for sym in \
      iree_runtime_instance_create \
      iree_runtime_session_create_with_device \
      iree_hal_buffer_view_allocate_buffer_copy \
      iree_hal_device_allocator
    do
      defined_kind="$(nm "$unified" 2>/dev/null | awk -v s="$sym" '$3 == s && $2 ~ /^[TtDd]$/ {print $2; found=1} END{if(!found) print ""}' | head -1)"
      if [ -n "$defined_kind" ]; then
        echo "ok: $sym is defined ($defined_kind) in libiree_runtime_unified.a"
      else
        echo "FAIL: $sym is not defined in libiree_runtime_unified.a (only undefined, or entirely absent)" >&2
        ASSERT_FAILS=$((ASSERT_FAILS+1))
      fi
    done
  else
    echo "FAIL: $unified missing or empty, cannot check for expected symbols" >&2
    ASSERT_FAILS=$((ASSERT_FAILS+1))
  fi

  # EXPECTED ABSENT. Scan every shipped archive (all of lib/*.a, not just the
  # unified one) -- with 198 archives this is empirically ~2s with nm, cheap
  # enough that narrowing the scope buys nothing. Case-insensitive substring
  # match on both raw (mangled) and c++filt-demangled symbol names: verified
  # against the real shipped archives below that "llvm" and "mlir" do not
  # appear as a substring of any other defined symbol name here (0 hits
  # either way), so there is no known false-positive source in this archive
  # set to guard against with a narrower anchor -- a plain substring match is
  # the strongest, simplest check available and it is what actually ran.
  llvm_hits="$(
    for a in "$prefix"/lib/*.a; do
      nm "$a" 2>/dev/null
    done \
      | awk '$2 ~ /^[TtDd]$/ {print $3}' \
      | { command -v c++filt >/dev/null 2>&1 && c++filt || cat; } \
      | grep -Ei 'llvm|mlir' || true
  )"
  if [ -z "$llvm_hits" ]; then
    echo "ok: no defined LLVM or MLIR symbol in any shipped archive (IREE_BUILD_COMPILER=OFF proven, not just asserted)"
  else
    echo "FAIL: defined LLVM/MLIR-looking symbol(s) shipped:" >&2
    printf '  %s\n' "$llvm_hits" >&2
    ASSERT_FAILS=$((ASSERT_FAILS+1))
  fi
else
  echo "FAIL: nm not available, cannot run expected/unexpected symbol checks" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

exit "$ASSERT_FAILS"
