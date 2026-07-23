#!/usr/bin/env bash
# Compile and run the constant emitter against a built prefix.
set -euo pipefail

PREFIX="${1:?usage: gen-constants.sh <prefix>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# CMake's find_package does not resolve a relative CMAKE_PREFIX_PATH reliably, and
# the failure is a cryptic "package not found" rather than anything pointing at the
# path. Normalize to absolute so a standalone `gen-constants.sh out` works the same
# as build-runtime.sh's always-absolute $PREFIX.
[ -d "$PREFIX" ] || { echo "error: prefix '$PREFIX' is not a directory" >&2; exit 2; }
PREFIX="$(cd "$PREFIX" && pwd)"

OUT_DIR="$PREFIX/share/iree-runtime-dist"
mkdir -p "$OUT_DIR"

work="$(mktemp -d)"
raw="$(mktemp -d)"
trap 'rm -rf "$work" "$raw"' EXIT

# Configure a tiny CMake project against the installed package, so the emitter
# compiles with exactly the include dirs and defines a consumer would get.
cat > "$work/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.21)
project(emit_constants C)
find_package(IREERuntime REQUIRED)
add_executable(emit_constants emit_constants.c)
target_link_libraries(emit_constants PRIVATE iree_runtime_unified)
EOF
cp "$HERE/../emit/emit_constants.c" "$work/"

cmake -G Ninja -B "$work/b" -S "$work" \
  -DCMAKE_PREFIX_PATH="$PREFIX/lib/cmake/IREE" \
  -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$work/b" >/dev/null

"$work/b/emit_constants" "$raw/element_types.json" "$raw/status_codes.json" "$raw/numerical_types.json"
python3 "$HERE/enrich-constants.py" \
  "$raw/element_types.json" "$raw/status_codes.json" "$raw/numerical_types.json" "$OUT_DIR"
echo "==> generated enriched element_types.json, status_codes.json + schemas"
