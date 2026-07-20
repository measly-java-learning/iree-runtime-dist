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
