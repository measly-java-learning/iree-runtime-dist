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
