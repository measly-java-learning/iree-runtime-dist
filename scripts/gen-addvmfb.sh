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
IREE_COMPILER_VERSION="${2:?compiler-version required}"

OUT_DIR="$PREFIX/share/iree-runtime-dist"
mkdir -p "$OUT_DIR"
# Resolve to an absolute path now, before we cd elsewhere below -- PREFIX may
# have been passed as a relative path.
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

venv="$(mktemp -d)/venv"
trap 'rm -rf "$(dirname "$venv")"' EXIT

# `python3` is not a universal spelling: it is the only one on the manylinux
# build image, but Git-Bash on a Windows runner sees the CPython install's
# `python.exe` and may have no `python3` at all. Resolve explicitly and fail
# loudly if neither exists -- an unresolved interpreter must not become a
# skipped add.vmfb, because Phase 4 producing nothing is precisely how an
# unpaired tarball would ship.
PYTHON=""
for _py in python3 python; do
  if command -v "$_py" >/dev/null 2>&1; then PYTHON="$_py"; break; fi
done
[ -n "$PYTHON" ] || { echo "error: no python3/python on PATH -- cannot install the paired compiler" >&2; exit 1; }

"$PYTHON" -m venv "$venv"

# venv's script directory is `bin/` on POSIX and `Scripts/` on Windows. Probe
# for the one that exists rather than assuming, and fail loudly if neither
# does; a missing directory here would otherwise surface as a confusing
# "command not found" three lines later.
if   [ -d "$venv/bin" ];     then VENV_BIN="$venv/bin"
elif [ -d "$venv/Scripts" ]; then VENV_BIN="$venv/Scripts"
else echo "error: venv at '$venv' has neither bin/ nor Scripts/" >&2; exit 1
fi

"$VENV_BIN/pip" install --quiet "iree-base-compiler==${IREE_COMPILER_VERSION}"

# iree-compile embeds its INPUT path (as MLIR location info) into the compiled
# module -- an absolute input path therefore leaks the build machine's
# directory layout straight into add.vmfb. cd into emit/ and pass a bare
# relative filename so nothing absolute ever reaches the compiler. The output
# path (-o) is not embedded, so it can stay absolute.
(
  cd "$HERE/../emit"
  "$VENV_BIN/iree-compile" "add.mlir" \
    --iree-hal-target-device=local \
    --iree-hal-local-target-device-backends=llvm-cpu \
    --iree-llvmcpu-target-cpu=generic \
    -o "$OUT_DIR/add.vmfb"
)

echo "==> compiled add.vmfb with iree-base-compiler==${IREE_COMPILER_VERSION}"
