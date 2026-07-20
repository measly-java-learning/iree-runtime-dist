#!/usr/bin/env bash
# Install the paired compiler and compile the canonical smoke module.
#
# The runtime and the .vmfb must agree on VM import signatures. Pairing a stable
# runtime with the same-numbered stable compiler makes them agree by construction;
# the walking skeleton's load failure came from mixing a main-branch runtime
# (3.12.0.dev) with a stable 3.11.0 compiler.
#
# Flag spelling was determined empirically for iree-base-compiler==3.11.0 by
# installing it and inspecting `iree-compile --help`:
#   --iree-hal-target-device=local
#   --iree-hal-local-target-device-backends=llvm-cpu
# (the "modern" form). This is the form that actually compiled emit/add.mlir
# with this compiler version -- the older `--iree-hal-target-backends=llvm-cpu`
# spelling was not needed as a fallback.
#
# --iree-llvmcpu-target-cpu=generic is set explicitly: without it, iree-compile
# warns that it is "defaulting to targeting a generic CPU" anyway, but an
# explicit generic target is what makes the resulting embedded-ELF executable
# portable to a consumer machine whose CPU may differ from the one that ran
# this script (as opposed to cpu=host, which would bake in host-only ISA
# extensions and could crash elsewhere).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${1:?usage: gen-addvmfb.sh <prefix> <compiler-version>}"
COMPILER_VERSION="${2:?compiler-version required}"

OUT_DIR="$PREFIX/share/iree-runtime-dist"
mkdir -p "$OUT_DIR"

venv="$(mktemp -d)/venv"
trap 'rm -rf "$(dirname "$venv")"' EXIT

python3 -m venv "$venv"
"$venv/bin/pip" install --quiet "iree-base-compiler==${COMPILER_VERSION}"

"$venv/bin/iree-compile" "$HERE/../emit/add.mlir" \
  --iree-hal-target-device=local \
  --iree-hal-local-target-device-backends=llvm-cpu \
  --iree-llvmcpu-target-cpu=generic \
  -o "$OUT_DIR/add.vmfb"

echo "==> compiled add.vmfb with iree-base-compiler==${COMPILER_VERSION}"
