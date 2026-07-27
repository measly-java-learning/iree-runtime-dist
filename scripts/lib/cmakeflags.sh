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

# Platform-specific -D cache flags. Windows needs a static CRT (/MT) because the
# consumer is a JNI shim linking into a DLL; a dynamic CRT would push a VC++
# redistributable requirement onto every downstream user.
# CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded is the supported CMake spelling for
# /MT -- deliberately routed through the cache variable (not smuggled in via a
# raw CMAKE_C_FLAGS string) so it is greppable in effective_cmake_flags' output.
# The next task derives manifest.json's `crt` field from this same output rather
# than hardcoding "MT" a second time, so this is the single source of truth for
# that value too.
platform_cmake_flags() { # <platform>
  case "${1:-}" in
    windows-*) printf -- '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded\n' ;;
    linux-*)   : ;;
    *) echo "error: unknown platform '${1:-}'" >&2; return 2 ;;
  esac
}

# common + variant + platform, deduped by flag name with variant, then platform,
# winning over common. The build, --print-flags, and BUILDINFO provenance all
# call this, so recorded provenance cannot drift from the build that produced it.
effective_cmake_flags() { # <variant> <platform>
  local variant="${1:?variant required}" platform="${2:?platform required}"
  local vflags cflags pflags emitted name
  vflags="$(variant_flags "$variant")" || return 2
  cflags="$(common_flags)"
  pflags="$(platform_cmake_flags "$platform")" || return 2

  # Emit variant flags first, then platform flags, then any common flag whose
  # name neither of those already set.
  printf '%s\n' "$vflags"
  [ -n "$pflags" ] && printf '%s\n' "$pflags"
  emitted="$vflags
$pflags"
  while IFS= read -r flag; do
    [ -n "$flag" ] || continue
    name="${flag%%=*}"
    if ! printf '%s\n' "$emitted" | grep -q "^${name}="; then
      printf '%s\n' "$flag"
    fi
  done <<EOF
$cflags
EOF
}
