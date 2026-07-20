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
  local rc=0 hits needle escaped

  for needle in "$build" "$src"; do
    # Match the needle only at a genuine path boundary (not preceded by an
    # identifier/path character). Without this, a short mount point like
    # "/iree" false-positives constantly: IREE's own tree nests a directory
    # literally named iree (.../src/iree/async/foo.c, already relative
    # thanks to -ffile-prefix-map, still contains the substring "/iree/"),
    # doc comments link to https://github.com/iree-org/iree/..., and archive
    # string tables pad entries with runs of '/' that can precede an
    # otherwise-correctly-relative path. None of those are an absolute
    # build-machine path leaking into the prefix; a real leak is preceded by
    # a delimiter (quote, whitespace, NUL, start-of-line), never by another
    # path/word character. Escape the needle so it's matched literally.
    escaped="$(printf '%s' "$needle" | sed -E 's/[][(){}.*+?^$|\\]/\\&/g')"
    hits="$(grep -rlE -- "(^|[^A-Za-z0-9_./-])${escaped}" "$prefix" 2>/dev/null || true)"
    if [ -n "$hits" ]; then
      echo "error: build-machine path '$needle' leaked into the staged prefix:" >&2
      printf '  %s\n' $hits >&2
      rc=1
    fi
  done
  return "$rc"
}
