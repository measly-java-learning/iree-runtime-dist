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
    # $abs is a literal filesystem path, not a pattern -- it may contain
    # regex metacharacters (a "." in a version-numbered directory, etc.),
    # so it must not be used unescaped as a grep pattern or a sed LHS (a "|"
    # in the path would also break the sed delimiter outright). Match it
    # with `grep -F` (fixed string, no regex) and escape it for sed's BRE
    # pattern side (., *, ^, $, [, \), then use a delimiter (SOH, \x01) that
    # cannot appear in a filesystem path so nothing in $abs needs escaping
    # for the delimiter itself.
    abs_sed_escaped="$(printf '%s' "$abs" | sed -e 's/[.*^$[\]/\\&/g')"
    grep -rlF -- "$abs" "$prefix/lib/cmake" 2>/dev/null | while IFS= read -r f; do
      sed -i $'s\x01'"${abs_sed_escaped}"$'\x01${PACKAGE_PREFIX_DIR}\x01g' "$f"
    done || true

    # Absolute system library paths break consumers on Debian/Ubuntu multiarch,
    # where these live somewhere else. Normalize to bare -l<name>.
    find "$prefix/lib/cmake" -type f -name '*.cmake' -print0 2>/dev/null \
      | xargs -0 -r sed -i -E 's#/usr/lib(64)?/lib([a-zA-Z0-9_+-]+)\.(so|a)#-l\2#g'

    # flatcc schema (*_c_fbs) targets bake their generator's include path in
    # as raw "-I/abs/path" tokens inside INTERFACE_COMPILE_OPTIONS, e.g.
    # "-I/iree/third_party/flatcc/include/". That is the build container's
    # source mount, which does not exist on a consumer's machine -- and
    # unlike INTERFACE_INCLUDE_DIRECTORIES, CMake never treats a raw compile
    # option as a path to relocate, so the ${PACKAGE_PREFIX_DIR} rewrite above
    # never touches it. Empirically, the public runtime API surface (transitively
    # #including iree/runtime/api.h) never reaches a flatcc header, and these
    # *_c_fbs targets are not reachable from iree_runtime_unified's
    # INTERFACE_LINK_LIBRARIES closure -- so the flags are dead weight rather
    # than a real compile requirement. Strip any absolute -I flag out of
    # exported INTERFACE_COMPILE_OPTIONS; if that empties the property value,
    # drop the whole property line (harmless no-op set_target_properties
    # argument otherwise, but this keeps output tidy and the repair
    # idempotent -- a second pass finds nothing left to strip).
    find "$prefix/lib/cmake" -type f -name '*.cmake' -print0 2>/dev/null \
      | xargs -0 -r sed -i -E '/INTERFACE_COMPILE_OPTIONS/s#-I/[^;"]*;?##g'
    find "$prefix/lib/cmake" -type f -name '*.cmake' -print0 2>/dev/null \
      | xargs -0 -r sed -i -E '/INTERFACE_COMPILE_OPTIONS[[:space:]]*""[[:space:]]*$/d'
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
relocatability_assert() { # <prefix> <build_path> <src_path> [extra_needle...]
  local prefix="${1:?prefix required}" build="${2:?build path required}" src="${3:?src path required}"
  shift 3
  local rc=0 hits needle escaped

  for needle in "$build" "$src" "$@"; do
    # Match the needle only at a genuine path boundary (not preceded by an
    # identifier/path character), OR immediately after a compiler flag
    # prefix that concatenates directly onto its argument. Without the
    # boundary rule, a short mount point like "/iree" false-positives
    # constantly: IREE's own tree nests a directory literally named iree
    # (.../src/iree/async/foo.c, already relative thanks to
    # -ffile-prefix-map, still contains the substring "/iree/"), doc
    # comments link to https://github.com/iree-org/iree/..., and archive
    # string tables pad entries with runs of '/' that can precede an
    # otherwise-correctly-relative path. None of those are an absolute
    # build-machine path leaking into the prefix; a real leak is preceded by
    # a delimiter (quote, whitespace, '=', ':', NUL, start-of-line) -- or,
    # critically, by a flag like -I/-L/-isystem/-F/-iquote/-isysroot with no
    # space before the absolute path, which is exactly how CMake bakes
    # include/lib dirs into generated config files (e.g.
    # "-I/iree/runtime/src", "-iquote/iree/...", "-isysroot/iree"). The
    # generic boundary class alone rejects that case because the flag's own
    # letter (I, L, ...) is a word character, so the flag prefixes are
    # enumerated explicitly as additional, non-generic boundaries. Escape the
    # needle so it's matched literally.
    escaped="$(printf '%s' "$needle" | sed -E 's/[][(){}.*+?^$|\\]/\\&/g')"
    local pattern="(^|[^A-Za-z0-9_./-]|-I|-L|-isystem|-F|-iquote|-isysroot)${escaped}"
    hits="$(grep -rlE -- "$pattern" "$prefix" 2>/dev/null || true)"

    # RELOC_ALLOW_DEBUG_PATHS: sanitizer variants build with -g, whose DWARF
    # embeds the (neutral, container-internal) build directory in DW_AT_comp_dir.
    # That is debug metadata, not link surface -- it does not affect whether or
    # where the archive links. When this is set, a hit in an object/archive is
    # re-checked with debug sections stripped; if the path survives stripping it
    # is a REAL leak (a link-relevant string, a baked -I flag, an INTERFACE
    # option) and still fails. Only debug-section-only paths are exempted. Text
    # files (e.g. *.cmake) are never exempted -- a leak there is always real.
    if [ -n "$hits" ] && [ "${RELOC_ALLOW_DEBUG_PATHS:-0}" = 1 ]; then
      local surviving="" f tmp
      for f in $hits; do
        case "$f" in
          *.a|*.o|*.so|*.so.*)
            tmp="$(mktemp)"
            if objcopy --strip-debug "$f" "$tmp" 2>/dev/null \
                 && ! grep -qE -- "$pattern" "$tmp"; then
              : # path was debug-only -> exempt
            else
              surviving="$surviving $f"   # survives strip (or strip failed) -> real
            fi
            rm -f "$tmp"
            ;;
          *) surviving="$surviving $f" ;;  # non-object -> always real
        esac
      done
      hits="$(printf '%s' "${surviving# }")"
    fi

    if [ -n "$hits" ]; then
      echo "error: build-machine path '$needle' leaked into the staged prefix:" >&2
      printf '  %s\n' $hits >&2
      rc=1
    fi
  done
  return "$rc"
}
