#!/usr/bin/env bash
# Emit manifest.json + BUILDINFO. Build config comes from effective_cmake_flags,
# so recorded provenance cannot diverge from the build that produced it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/variants.sh"
. "$HERE/lib/cmakeflags.sh"

PREFIX="${1:?usage: gen-manifest.sh <prefix> <variant> <platform> <iree-src> <iree-version> <compiler-version>}"
VARIANT="${2:?variant required}"
PLATFORM="${3:?platform required}"
IREE_SRC="${4:?iree-src required}"
IREE_VERSION="${5:?iree-version required}"
COMPILER_VERSION="${6:?compiler-version required}"

OUT_DIR="$PREFIX/share/iree-runtime-dist"
mkdir -p "$OUT_DIR"

RUNTIME_COMMIT="$(git -C "$IREE_SRC" rev-parse HEAD)"

# Scan installed static archives for the highest GLIBC symbol-version requirement.
# `grep` under set -e would abort the whole script on a no-match page (e.g. no
# archives found, or none reference glibc symbol versioning), so every stage of
# this pipe is tolerant and the final fallback to "none" is explicit.
GLIBC_FLOOR="$(
  find "$PREFIX/lib" -name '*.a' -print0 2>/dev/null \
    | xargs -0 -r readelf -sW 2>/dev/null \
    | grep -oE 'GLIBC_[0-9]+\.[0-9]+' \
    | sort -uV | tail -1 || true
)"
[ -n "$GLIBC_FLOOR" ] || GLIBC_FLOOR="none"

# build_config comes from the same function the build used.
BUILD_CONFIG_JSON="$(
  effective_cmake_flags "$VARIANT" | python3 -c '
import json, sys
cfg = {}
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("-D") or "=" not in line:
        continue
    k, v = line[2:].split("=", 1)
    cfg[k] = v
print(json.dumps(cfg, indent=4, sort_keys=True))
'
)"

# Pass every value as argv rather than interpolating into the heredoc's Python
# source directly -- interpolation would let a value containing a quote or
# backslash (e.g. an unusual IREE_SRC path) break the heredoc's Python syntax or
# smuggle content into the JSON. Reading from sys.argv keeps each value an opaque
# string as far as the Python parser is concerned.
python3 - "$OUT_DIR/manifest.json" "$VARIANT" "$PLATFORM" "$IREE_VERSION" \
  "$RUNTIME_COMMIT" "$COMPILER_VERSION" "$GLIBC_FLOOR" "$BUILD_CONFIG_JSON" <<'EOF'
import json, sys

(_, out_path, variant, platform, iree_version, runtime_commit,
 compiler_version, glibc_floor, build_config_json) = sys.argv

manifest = {
    "schema_version": 1,
    "variant": variant,
    "platform": platform,
    "iree_version": iree_version,
    "iree_tag": "v" + iree_version,
    "runtime_commit": runtime_commit,
    "iree_compile_version": compiler_version,
    "glibc_floor": glibc_floor,
    "build_config": json.loads(build_config_json),
    "notes": {
        "compiler": (
            "The IREE compiler is out of contract: built with "
            "IREE_BUILD_COMPILER=OFF and never shipped. Install "
            "iree-base-compiler==" + compiler_version + " to produce loadable "
            ".vmfb files."
        ),
        "pip_runtime_wheel": (
            "The pip iree-base-runtime wheel is NOT linkable at any version -- "
            "no headers, no static libs. Only a from-source build or this dist "
            "yields a linkable runtime."
        ),
    },
}

with open(out_path, "w") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
EOF

cat > "$PREFIX/BUILDINFO" <<EOF
iree-runtime-dist
variant=$VARIANT
platform=$PLATFORM
iree_version=$IREE_VERSION
runtime_commit=$RUNTIME_COMMIT
iree_compile_version=$COMPILER_VERSION
glibc_floor=$GLIBC_FLOOR
cmake_flags=$(effective_cmake_flags "$VARIANT" | tr '\n' ' ')
EOF

echo "==> generated manifest.json and BUILDINFO"
