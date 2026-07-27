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

# Which variants a platform builds. NOT platform-independent: tsan is
# -fsanitize=thread under clang, which the MSVC/Windows toolchain does not
# provide. release.yml fans out a full variant x platform cross-product, so
# without this a windows tsan job would be scheduled and fail. The exclusion
# lives here rather than in an `exclude:` block because a variant list is never
# hardcoded in a workflow -- YAML can't source this file, so it goes through the
# setup job's step output instead.
known_variants() { # <platform>
  case "${1:-}" in
    linux-*)   printf 'default tsan' ;;
    windows-*) printf 'default' ;;
    *) echo "error: unknown platform '${1:-}'" >&2; return 2 ;;
  esac
}

variants_json() { # <platform>, JSON array for GitHub Actions' fromJson()
  python3 -c "import json,sys; print(json.dumps(sys.argv[1].split()))" "$(known_variants "$1")"
}
