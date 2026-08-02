#!/usr/bin/env bash
# Structural checks against a BUILT prefix. Usage: structural.sh <prefix>
#
# Deliberately not named *.test.sh: test/run.sh's glob must stay hermetic, and
# every check here needs a real installed prefix. This is the prefix-taking
# sibling of test/run.sh.
#
# Single-sourced because both release.yml build jobs (container Linux, native
# Windows) run exactly this list. When it lived inline in the workflow it was
# duplicated per job, which is how a check gets added on one platform and
# silently skipped on the other.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${1:?usage: structural.sh <prefix>}"

for t in build_smoke manifest.test constants.test notices.test cmake_additions.test; do
  echo "== $t =="
  bash "$here/$t.sh" "$PREFIX"
done

echo "ALL STRUCTURAL CHECKS PASS"
