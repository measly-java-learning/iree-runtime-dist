#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Synthetic raw inputs covering every decode branch.
cat > "$tmp/et.json" <<'EOF'
{ "NONE": 0, "OPAQUE_32": 32, "BOOL_8": 318767112,
  "INT_32": 268435488, "SINT_32": 285212704, "UINT_16": 301989904,
  "FLOAT_32": 553648160, "BFLOAT_16": 570425360, "FLOAT_8_E4M3FN": 620757000,
  "BARE_FLOAT_32": 536870944, "COMPLEX_FLOAT_64": 587202624 }
EOF
cat > "$tmp/sc.json" <<'EOF'
{ "OK": 0, "INVALID_ARGUMENT": 3 }
EOF
cat > "$tmp/nt.json" <<'EOF'
{ "UNKNOWN": 0, "INTEGER": 16, "INTEGER_SIGNED": 17, "INTEGER_UNSIGNED": 18,
  "BOOLEAN": 19, "FLOAT": 32, "FLOAT_IEEE": 33, "FLOAT_BRAIN": 34, "FLOAT_8_E4M3FN": 37, "FLOAT_COMPLEX": 35 }
EOF

python3 "$here/../scripts/enrich-constants.py" "$tmp/et.json" "$tmp/sc.json" "$tmp/nt.json" "$tmp/out"

get() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))$2)" "$1"; }
e="$tmp/out/element_types.json"

assert_eq "$(get "$e" "['schema_version']")" "1" "schema_version"
assert_eq "$(get "$e" "['encoding']['numerical_types']['FLOAT_IEEE']")" "33" "enum embedded"
# decode branches:
assert_eq "$(get "$e" "['element_types']['FLOAT_32']['value']")"          "553648160" "FLOAT_32 value preserved"
assert_eq "$(get "$e" "['element_types']['FLOAT_32']['hex']")"            "0x21000020" "FLOAT_32 hex"
assert_eq "$(get "$e" "['element_types']['FLOAT_32']['numerical_type']")" "FLOAT_IEEE" "FLOAT_32 numtype"
assert_eq "$(get "$e" "['element_types']['FLOAT_32']['category']")"       "float"      "FLOAT_32 category"
assert_eq "$(get "$e" "['element_types']['FLOAT_32']['signed']")"         "None"       "FLOAT_32 signed null"
assert_eq "$(get "$e" "['element_types']['FLOAT_32']['bit_count']")"      "32"         "FLOAT_32 bits"
assert_eq "$(get "$e" "['element_types']['SINT_32']['signed']")"          "True"       "SINT_32 signed"
assert_eq "$(get "$e" "['element_types']['SINT_32']['category']")"        "integer"    "SINT_32 integer"
assert_eq "$(get "$e" "['element_types']['UINT_16']['signed']")"          "False"      "UINT_16 unsigned"
assert_eq "$(get "$e" "['element_types']['UINT_16']['bit_count']")"       "16"         "UINT_16 bits"
assert_eq "$(get "$e" "['element_types']['INT_32']['signed']")"           "None"       "INT_32 sign-agnostic (the policy signal)"
assert_eq "$(get "$e" "['element_types']['BOOL_8']['category']")"         "boolean"    "BOOL_8 boolean"
assert_eq "$(get "$e" "['element_types']['OPAQUE_32']['category']")"      "opaque"     "OPAQUE_32 opaque"
assert_eq "$(get "$e" "['element_types']['COMPLEX_FLOAT_64']['category']")" "complex"  "COMPLEX complex"
assert_eq "$(get "$e" "['element_types']['FLOAT_8_E4M3FN']['category']")" "float" "FP8 -> float"
assert_eq "$(get "$e" "['element_types']['FLOAT_8_E4M3FN']['numerical_type']")" "FLOAT_8_E4M3FN" "FP8 numtype"
assert_eq "$(get "$e" "['element_types']['BARE_FLOAT_32']['category']")" "float" "bare FLOAT -> float"
assert_eq "$(get "$e" "['element_types']['BFLOAT_16']['category']")" "float" "BFLOAT_16 -> float"

s="$tmp/out/status_codes.json"
assert_eq "$(get "$s" "['status_codes']['OK']['value']")" "0" "status OK value"
case "$(get "$s" "['status_codes']['OK']['description']")" in
  ""|"None") echo "FAIL: OK missing description" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1));;
  *) echo "ok: OK has a description";;
esac

# schemas are valid JSON Schema and the data validates against them. If
# jsonschema is importable, do full schema validation; otherwise fall back to
# the structural check spec section 5 mandates -- required keys must be
# present -- rather than silently skipping (skipping here means this named
# requirement never runs in CI, which has no jsonschema).
python3 - "$tmp/out" <<'PY' && echo "ok: data validates against shipped schemas" || { echo "FAIL: schema validation" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
import json,sys
d = sys.argv[1]
try:
    import jsonschema
    have_jsonschema = True
except ImportError:
    have_jsonschema = False

if have_jsonschema:
    for data,schema in [("element_types.json","element_types.schema.json"),
                        ("status_codes.json","status_codes.schema.json")]:
        jsonschema.validate(json.load(open(f"{d}/{data}")), json.load(open(f"{d}/{schema}")))
else:
    et = json.load(open(f"{d}/element_types.json"))
    for key in ("schema_version", "encoding", "element_types"):
        assert key in et, f"element_types.json missing top-level key {key!r}"
    enc = et["encoding"]
    for key in ("formula", "numerical_types"):
        assert key in enc, f"element_types.json encoding missing key {key!r}"
    assert et["element_types"], "element_types.json element_types is empty"
    sample = next(iter(et["element_types"].values()))
    for field in ("value", "hex", "numerical_type", "category", "signed", "bit_count"):
        assert field in sample, f"element_types.json entry missing field {field!r}"

    sc = json.load(open(f"{d}/status_codes.json"))
    for key in ("schema_version", "status_codes"):
        assert key in sc, f"status_codes.json missing top-level key {key!r}"
    assert sc["status_codes"], "status_codes.json status_codes is empty"
    sample = next(iter(sc["status_codes"].values()))
    assert "value" in sample, "status_codes.json entry missing field 'value'"
PY
exit "$ASSERT_FAILS"
