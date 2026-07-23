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
ets="$prefix/share/iree-runtime-dist/element_types.schema.json"
scs="$prefix/share/iree-runtime-dist/status_codes.schema.json"
for f in "$et" "$sc" "$ets" "$scs"; do
  [ -e "$f" ] && echo "ok: $(basename "$f") present" \
    || { echo "FAIL: $(basename "$f") missing" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
done
g() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))$2)" "$1"; }
assert_eq "$(g "$et" "['element_types']['FLOAT_32']['value']")" "553648160" "FLOAT_32 value"
assert_eq "$(g "$et" "['element_types']['FLOAT_32']['category']")" "float"   "FLOAT_32 category"
assert_eq "$(g "$et" "['element_types']['SINT_32']['signed']")"  "True"      "SINT_32 signed"
assert_eq "$(g "$et" "['element_types']['INT_32']['signed']")"   "None"      "INT_32 sign-agnostic"
assert_eq "$(g "$sc" "['status_codes']['OK']['value']")" "0" "status OK"
assert_eq "$(g "$sc" "['status_codes']['INVALID_ARGUMENT']['value']")" "3" "status INVALID_ARGUMENT"
# data validates against the shipped schemas (skip cleanly if jsonschema absent)
python3 - "$et" "$ets" "$sc" "$scs" <<'PY' && echo "ok: constants validate against schemas" || { echo "FAIL: schema validation" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
import json,sys
try: import jsonschema
except ImportError: print("skip: jsonschema"); sys.exit(0)
jsonschema.validate(json.load(open(sys.argv[1])), json.load(open(sys.argv[2])))
jsonschema.validate(json.load(open(sys.argv[3])), json.load(open(sys.argv[4])))
PY

exit "$ASSERT_FAILS"
