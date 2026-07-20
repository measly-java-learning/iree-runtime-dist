#!/usr/bin/env bash
# Validates generated constants. Usage: constants.test.sh <prefix>
# Skips (exit 0) when no prefix is given, so test/run.sh stays hermetic.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
prefix="${1:-}"
if [ -z "$prefix" ]; then echo "skip: constants.test.sh needs a built prefix"; exit 0; fi

et="$prefix/share/iree-runtime-dist/element_types.json"
sc="$prefix/share/iree-runtime-dist/status_codes.json"

for f in "$et" "$sc"; do
  if [ -e "$f" ]; then echo "ok: $(basename "$f") present"
  else echo "FAIL: $(basename "$f") missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
done

python3 -c "import json,sys; json.load(open(sys.argv[1])); json.load(open(sys.argv[2]))" "$et" "$sc" \
  && echo "ok: both files are valid JSON" \
  || { echo "FAIL: invalid JSON" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# The exact bug the consumer paid for: FLOAT_32 is 0x21000020, not 0x00000120.
v="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['FLOAT_32'])" "$et")"
assert_eq "$v" "553648160" "FLOAT_32 == 0x21000020"
v="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['SINT_32'])" "$et")"
assert_eq "$v" "285212704" "SINT_32 == 0x11000020"

v="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['OK'])" "$sc")"
assert_eq "$v" "0" "status OK == 0"
v="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['INVALID_ARGUMENT'])" "$sc")"
assert_eq "$v" "3" "status INVALID_ARGUMENT == 3"

exit "$ASSERT_FAILS"
