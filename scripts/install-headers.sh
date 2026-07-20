#!/usr/bin/env bash
# Fill gaps in the installed public header set. Source me.
#
# WHY THIS EXISTS (do not delete as "redundant" with the component installs
# in build-runtime.sh Phase 1): IREE's generated
# <build>/runtime/src/iree/base/cmake_install.cmake -- and the equivalent
# generated install scripts for iree/hal, iree/vm, etc. -- only emit an
# `install(FILES ...)` rule for a subset of the headers each target *declares*
# in its CMakeLists.txt HDRS list. Headers like iree/base/status.h or
# iree/hal/buffer.h are real, required, public API (iree/runtime/api.h
# transitively #includes them) and ARE listed in HDRS, but upstream never
# generates an install rule for them. This is not a component-selection bug:
# every rule that DOES exist is already in the IREEDevLibraries-Runtime
# component we install. It is a gap in what IREE's build generates. Until
# that is fixed upstream, this script copies the missing headers straight
# from the pinned source tree into the prefix after the component installs
# run, so the header set that DOES get generated correctly is filled out
# to match the full transitive #include closure a consumer actually needs.
#
# Approach: walk the real #include "iree/...” graph starting from the public
# entry points, at build time, against whatever actually landed in
# $PREFIX/include -- not a hard-coded list. That way this keeps working
# unmodified if IREE adds/removes/renames transitive headers in a future
# version bump; only headers genuinely missing after the component install
# get pulled from source.

# install_missing_headers <prefix> <iree_src>
#   prefix    staged install prefix (contains include/iree/... after the
#             component installs from build-runtime.sh Phase 1 have run)
#   iree_src  pinned IREE checkout; headers are copied from
#             <iree_src>/runtime/src/iree/... preserving the iree/... path
install_missing_headers() {
  local prefix="${1:?prefix required}"
  local iree_src="${2:?iree_src required}"
  local runtime_src="$iree_src/runtime/src"

  [ -d "$runtime_src/iree" ] || {
    echo "error: install_missing_headers: '$runtime_src/iree' not found -- wrong --iree-src?" >&2
    exit 1
  }

  # Public entry points a consumer #includes directly. Everything else in the
  # closure is reached transitively from these via #include "iree/...".
  local -a queue=(iree/runtime/api.h iree/base/api.h iree/hal/api.h)
  local -A seen=()
  local filled=0 rel dest src inc

  while [ "${#queue[@]}" -gt 0 ]; do
    rel="${queue[-1]}"
    unset 'queue[-1]'

    [ -n "${seen[$rel]:-}" ] && continue
    seen[$rel]=1

    dest="$prefix/include/$rel"

    if [ -f "$dest" ]; then
      : # Already installed by the component step (or a previous run of this
        # function) -- leave it alone. Never overwrite an installed header;
        # doing so would mask the day upstream actually fixes the install
        # rule, instead of us noticing it's no longer needed.
    else
      src="$runtime_src/$rel"
      if [ ! -f "$src" ]; then
        # Fail loudly: a header reachable from the public API closure that
        # exists in neither the installed prefix nor the pinned source tree
        # means either IREE_SRC is wrong or the header truly went away --
        # either way, silently continuing is exactly how this defect shipped
        # in the first place.
        echo "error: install_missing_headers: '$rel' is required by the public header closure but was found neither in '$prefix/include' nor in '$src'" >&2
        exit 1
      fi
      mkdir -p "$(dirname "$dest")"
      cp "$src" "$dest"
      filled=$((filled + 1))
    fi

    while IFS= read -r inc; do
      [ -n "$inc" ] || continue
      [ -n "${seen[$inc]:-}" ] || queue+=("$inc")
    done < <(grep -ohE '#include[[:space:]]*"iree/[^"]+"' "$dest" 2>/dev/null \
                | sed -E 's/^#include[[:space:]]*"(.*)"$/\1/' || true)
  done

  echo "install-headers: header closure has ${#seen[@]} file(s); filled ${filled} missing from source"
}
