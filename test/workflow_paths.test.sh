#!/usr/bin/env bash
# Thin wrapper so test/run.sh's *.test.sh glob picks up workflow_paths.py.
# The checks themselves (and why they exist) live in that file.
#
# PyYAML is the one non-stdlib dependency in the hermetic suite. A missing
# module SKIPS rather than fails: a contributor's python3 is theirs, and
# nothing in this repo installs into it. The skip cannot hide a regression,
# because release.yml's setup job installs PyYAML before running test/run.sh --
# so the guard is guaranteed to run on the one path that gates a release.
set -u
here="$(cd "$(dirname "$0")" && pwd)"

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "skip: workflow_paths -- PyYAML not importable from the python3 on PATH"
  echo "      (to run this guard locally: activate a virtualenv that provides"
  echo "       PyYAML, or install your distro's python3-yaml)"
  exit 0
fi

exec python3 "$here/workflow_paths.py" "$here/.."
