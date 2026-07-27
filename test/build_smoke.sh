#!/usr/bin/env bash
# Structural smoke check of an already-built prefix. Usage: build_smoke.sh <prefix>
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
prefix="${1:?usage: build_smoke.sh <prefix>}"

# Archive naming and the symbol tool differ by platform. Measured: every file in
# a Windows prefix's lib/ ends in .lib with no `lib` prefix (plain MSVC
# defaults), and llvm-nm reads COFF with output structurally identical to GNU nm.
if ls "$prefix"/lib/*.lib >/dev/null 2>&1; then
  AR_EXT="lib"; AR_PRE=""
  # Debian/Ubuntu (and most distro packaging of LLVM) ship llvm-nm under a
  # versioned name -- bare `llvm-nm` is frequently absent even when LLVM is
  # installed (see scripts/relocatability.sh's coff_strip_tool resolution for
  # the same problem with llvm-objcopy). Honour an explicit override first,
  # then fall back through plausible versioned names. NM stays unresolved if
  # nothing matches, so the existing `command -v "$NM"` guard below fails
  # loudly instead of silently skipping the symbol checks.
  if [ -n "${NM:-}" ] && command -v "${NM}" >/dev/null 2>&1; then
    :
  else
    NM=""
    for _nm_cand in llvm-nm llvm-nm-18 llvm-nm-17; do
      if command -v "$_nm_cand" >/dev/null 2>&1; then
        NM="$_nm_cand"
        break
      fi
    done
    NM="${NM:-llvm-nm}"
  fi
else
  AR_EXT="a";   AR_PRE="lib"; NM="${NM:-nm}"
fi

# Guard against the highest-risk silent-failure defect: if detection picked
# the wrong branch, the archive glob below matches nothing, every loop over
# "$prefix"/lib/*."$AR_EXT" runs zero iterations, and the script could report
# success having checked nothing. Fail loudly before that can happen.
if ! ls "$prefix"/lib/*."$AR_EXT" >/dev/null 2>&1; then
  echo "FAIL: no lib/*.$AR_EXT archives found in $prefix -- archive-convention detection picked the wrong branch or the prefix is empty" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
  exit "$ASSERT_FAILS"
fi

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
if ls "$prefix"/lib/*."$AR_EXT" >/dev/null 2>&1; then echo "ok: static archives present"
else echo "FAIL: no static archives in lib/" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

# The unified runtime archive specifically -- this is the target a downstream
# consumer links against. IREE's install rules are EXCLUDE_FROM_ALL (see
# build-runtime.sh comments), so a bare `cmake --install` produces a complete
# looking export set that points at archives which were never actually copied.
# Check the archive a downstream consumer actually links exists and is non-empty.
unified="$prefix/lib/${AR_PRE}iree_runtime_unified.$AR_EXT"
if [ -s "$unified" ]; then echo "ok: $(basename "$unified") present and non-empty"
else echo "FAIL: $unified missing or empty" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

# flatcc is a bundled transitive dependency (IREEBundledLibraries component);
# it must be installed too or the link surface is incomplete.
for f in ${AR_PRE}flatcc_runtime.$AR_EXT ${AR_PRE}flatcc_parsing.$AR_EXT; do
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

# PIC: non-PIC x86-64 CODE shows R_X86_64_32/32S relocations. Scope this to
# code/data sections only -- DWARF debug sections (.debug_*) legitimately use
# 32-bit absolute offsets into .debug_str/.debug_info in EVERY -g build, and
# they say nothing about whether .text is position-independent. The sanitizer
# variant builds with -g, so a naive scan of all relocations false-positives on
# its debug info; only relocations in non-.debug sections indicate non-PIC code.
#
# ELF-only: readelf cannot parse COFF (.lib) archives at all, and PIC/PIE is
# not a meaningful concept for MSVC-produced code in the first place (CLAUDE.md
# records that -DCMAKE_POSITION_INDEPENDENT_CODE=ON is a harmless no-op on
# MSVC) -- so on the COFF path there is genuinely nothing to check, not merely
# something unverifiable. Gate the whole block on AR_EXT and skip explicitly
# rather than either faking a pass (readelf silently no-op'ing on every
# archive, "bad" staying 0, printing a false "ok:") or failing a check that
# doesn't apply to the platform.
if [ "$AR_EXT" = "a" ]; then
  bad=0
  for a in "$prefix"/lib/*."$AR_EXT"; do
    if readelf -r "$a" 2>/dev/null | awk '
        /^Relocation section/ { indbg = ($0 ~ /\.debug/) }
        !indbg && /R_X86_64_(32|32S)[[:space:]]/ { found=1 }
        END { exit(found ? 0 : 1) }'; then
      echo "FAIL: non-PIC relocations in code section of $(basename "$a")" >&2; bad=1
    fi
  done
  if [ "$bad" -eq 0 ]; then echo "ok: archives are PIC (code sections; DWARF debug relocs ignored)"; else ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
else
  echo "skip: PIC check is ELF-only; PIC/PIE has no meaning for COFF archives (MSVC)"
fi

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
if command -v "$NM" >/dev/null 2>&1; then
  unified="$prefix/lib/${AR_PRE}iree_runtime_unified.$AR_EXT"

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
      defined_kind="$("$NM" "$unified" 2>/dev/null | awk -v s="$sym" '$3 == s && $2 ~ /^[TtDd]$/ {print $2; found=1} END{if(!found) print ""}' | head -1)"
      if [ -n "$defined_kind" ]; then
        echo "ok: $sym is defined ($defined_kind) in $(basename "$unified")"
      else
        echo "FAIL: $sym is not defined in $(basename "$unified") (only undefined, or entirely absent)" >&2
        ASSERT_FAILS=$((ASSERT_FAILS+1))
      fi
    done
  else
    echo "FAIL: $unified missing or empty, cannot check for expected symbols" >&2
    ASSERT_FAILS=$((ASSERT_FAILS+1))
  fi

  # EXPECTED ABSENT. Scan every shipped archive (all of lib/*.$AR_EXT, not just
  # the unified one) -- with 198 archives this is empirically ~2s with nm,
  # cheap enough that narrowing the scope buys nothing. Case-insensitive
  # substring match on both raw (mangled) and c++filt-demangled symbol names:
  # verified against the real shipped archives below that "llvm" and "mlir" do
  # not appear as a substring of any other defined symbol name here (0 hits
  # either way), so there is no known false-positive source in this archive
  # set to guard against with a narrower anchor -- a plain substring match is
  # the strongest, simplest check available and it is what actually ran.
  llvm_hits="$(
    for a in "$prefix"/lib/*."$AR_EXT"; do
      "$NM" "$a" 2>/dev/null
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
  echo "FAIL: $NM not available, cannot run expected/unexpected symbol checks" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

# Every variant ships the share/ README documenting the layout + JSON schema
# for non-CMake consumers (consumer report #6).
if [ -s "$prefix/share/iree-runtime-dist/README.md" ]; then
  echo "ok: ships share/iree-runtime-dist/README.md"
else
  echo "FAIL: missing share/iree-runtime-dist/README.md" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

# Sanitizer variants ship the TSan runbook; default variants ship none. Key off
# the prefix's own BUILDINFO sanitizer= line so this works for both.
if grep -q '^sanitizer=thread' "$prefix/BUILDINFO" 2>/dev/null; then
  if [ -s "$prefix/share/iree-runtime-dist/TSAN.md" ]; then
    echo "ok: tsan prefix ships TSAN.md runbook"
  else
    echo "FAIL: tsan prefix is missing share/iree-runtime-dist/TSAN.md" >&2
    ASSERT_FAILS=$((ASSERT_FAILS+1))
  fi
elif [ -e "$prefix/share/iree-runtime-dist/TSAN.md" ]; then
  echo "FAIL: non-sanitizer prefix must not ship TSAN.md" >&2
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok: non-sanitizer prefix ships no TSAN.md"
fi

# Every variant ships the enriched constants metadata + their JSON schemas
# (content is checked by constants.test.sh; this is presence only).
for f in \
  "element_types.json" \
  "status_codes.json" \
  "element_types.schema.json" \
  "status_codes.schema.json"
do
  if [ -s "$prefix/share/iree-runtime-dist/$f" ]; then
    echo "ok: ships share/iree-runtime-dist/$f"
  else
    echo "FAIL: missing share/iree-runtime-dist/$f" >&2
    ASSERT_FAILS=$((ASSERT_FAILS+1))
  fi
done

exit "$ASSERT_FAILS"
