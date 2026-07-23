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
# data validates against the shipped schemas. If jsonschema is importable, do
# full schema validation; otherwise fall back to the structural check spec
# section 5 mandates -- required keys must be present -- rather than silently
# skipping (skipping here means this named requirement never runs in CI,
# which has no jsonschema).
python3 - "$et" "$ets" "$sc" "$scs" <<'PY' && echo "ok: constants validate against schemas" || { echo "FAIL: schema validation" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
import json,sys
et_path, ets_path, sc_path, scs_path = sys.argv[1:5]
try:
    import jsonschema
    have_jsonschema = True
except ImportError:
    have_jsonschema = False

if have_jsonschema:
    jsonschema.validate(json.load(open(et_path)), json.load(open(ets_path)))
    jsonschema.validate(json.load(open(sc_path)), json.load(open(scs_path)))
else:
    et = json.load(open(et_path))
    for key in ("schema_version", "encoding", "element_types"):
        assert key in et, f"element_types.json missing top-level key {key!r}"
    enc = et["encoding"]
    for key in ("formula", "numerical_types"):
        assert key in enc, f"element_types.json encoding missing key {key!r}"
    assert et["element_types"], "element_types.json element_types is empty"
    sample = next(iter(et["element_types"].values()))
    for field in ("value", "hex", "numerical_type", "category", "signed", "bit_count"):
        assert field in sample, f"element_types.json entry missing field {field!r}"

    sc = json.load(open(sc_path))
    for key in ("schema_version", "status_codes"):
        assert key in sc, f"status_codes.json missing top-level key {key!r}"
    assert sc["status_codes"], "status_codes.json status_codes is empty"
    sample = next(iter(sc["status_codes"].values()))
    assert "value" in sample, "status_codes.json entry missing field 'value'"
PY

exit "$ASSERT_FAILS"
