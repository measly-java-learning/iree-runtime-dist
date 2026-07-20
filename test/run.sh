#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
fails=0
for t in "$here"/*.test.sh; do
  echo "== $t =="
  bash "$t" || fails=$((fails+1))
done
if [ "$fails" -eq 0 ]; then echo "ALL UNIT TESTS PASS"; else echo "$fails test file(s) FAILED" >&2; exit 1; fi
