# Sourceable helper: decide the consumer e2e run mode from an extracted
# prefix's BUILDINFO. Pure/no side effects so it can be unit-tested without
# compiling anything (see test/consumer_mode.test.sh).
#
# consumer_run_mode <prefix>
#   echoes "tsan" if BUILDINFO has a `sanitizer=thread` line, else "default".
consumer_run_mode() {
  local prefix="${1:?usage: consumer_run_mode <prefix>}"
  local sanitizer
  sanitizer="$(grep -oE '^sanitizer=.*' "$prefix/BUILDINFO" 2>/dev/null | cut -d= -f2 || true)"
  if [ "$sanitizer" = "thread" ]; then
    echo "tsan"
  else
    echo "default"
  fi
}
