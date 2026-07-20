#!/usr/bin/env bash
# Minimal dependency-free assertion harness. Source me; check $ASSERT_FAILS at end.
ASSERT_FAILS=0
assert_eq() { # <actual> <expected> <msg>
  if [ "$1" = "$2" ]; then printf 'ok: %s\n' "$3"
  else printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$3" "$2" "$1" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
}
assert_contains() { # <haystack> <needle> <msg>
  case "$1" in *"$2"*) printf 'ok: %s\n' "$3" ;;
  *) printf 'FAIL: %s\n  missing: [%s]\n  in: [%s]\n' "$3" "$2" "$1" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;; esac
}
