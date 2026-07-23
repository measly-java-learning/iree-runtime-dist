# Enriched constants metadata — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the flat `{ NAME: int }` constants with self-describing enriched JSON + JSON
Schemas (a breaking change), and publish them as a per-release `iree-runtime-metadata-<version>.zip`
asset so non-CMake consumers fetch one stable URL. Closes #6.

**Architecture:** The C emitter (compiled against IREE headers) stays the source of raw values and
additionally emits IREE's numerical-type enum. A new pure-Python enricher decodes each element
type into `{value, hex, numerical_type, category, signed, bit_count}`, attaches curated
status-code descriptions, and writes the enriched data + schemas into the prefix. The `release` job
zips the metadata once and uploads it.

**Tech Stack:** C (emitter, against IREE headers), Python 3 (enricher + schemas; `jsonschema` for
tests), Bash (`set -euo pipefail`), GitHub Actions.

## Global Constraints

- **Breaking change, no back-compat.** The flat format is gone; nothing keeps a flat
  `element_types.json`. (spec §3)
- **Authoritative, never hand-transcribed.** Values and the numerical-type enum come from IREE's
  headers via the C emitter; the enricher only decodes arithmetic (`value = (num<<24)|bits`) and
  buckets categories. No IREE constant value or enum value is typed by hand. (spec §1, §4.4)
- **The enriched files ship in BOTH places:** inside the tarball at `share/iree-runtime-dist/`
  (CMake path vars point at them) AND in the metadata zip. Generated once, no drift. (spec §4.5)
- **The zip is built once per release, not per variant** — constants are variant-independent.
  `manifest.json` is NOT in the zip. (spec §4.5)
- **Docs carry the boundary, not just the schema:** type *properties* are authoritative; the
  native-type *mapping* is the consumer's irreducible integration work. (spec §2, §6)
- **No per-language bindings.** JSON + schema only. (spec §3 non-goals)
- `set -euo pipefail`; explicit git staging; recipe idempotent.

## File Structure

- `scripts/enrich-constants.py` — CREATE: pure decode + schema emission. The heart; fully hermetic.
- `emit/emit_constants.c` — MODIFY: also emit the numerical-type enum; `main` takes a 3rd path.
- `scripts/gen-constants.sh` — MODIFY: run emitter → work dir, then enricher → `share/`.
- `test/constants.test.sh` — REWRITE: assert the enriched shape + schema validation (breaking).
- `test/enrich_constants.test.sh` — CREATE: hermetic unit test of the enricher's decode.
- `scripts/package-metadata.sh` — CREATE: assemble the metadata zip from a prefix's `share/`.
- `docs/metadata-README.md.in` — CREATE: the zip's README (schema + boundary).
- `.github/workflows/release.yml` — MODIFY: build + upload the metadata zip in the `release` job.
- `docs/share-README.md.in` — MODIFY: describe the enriched format (was "flat JSON object").
- `docs/handover/2026-07-20-djl-iree-engine-handover.md`, `README.md` — MODIFY: enriched format + boundary.

---

### Task 1: The enricher (`enrich-constants.py`) + hermetic test

The core transformation, fully testable without a build.

**Files:**
- Create: `scripts/enrich-constants.py`, `test/enrich_constants.test.sh`

**Interfaces:**
- Consumes: three raw JSON files — `element_types` (flat `{NAME:int}`), `status_codes` (flat),
  `numerical_types` (flat enum `{NAME:int}`).
- Produces: writes `element_types.json`, `status_codes.json`, `element_types.schema.json`,
  `status_codes.schema.json` into an output dir. Invocation:
  `enrich-constants.py <raw_element_types> <raw_status_codes> <raw_numerical_types> <out_dir>`.

- [ ] **Step 1: Write the failing test** `test/enrich_constants.test.sh`:
```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/assert.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Synthetic raw inputs covering every decode branch.
cat > "$tmp/et.json" <<'EOF'
{ "NONE": 0, "OPAQUE_32": 32, "BOOL_8": 318767112,
  "INT_32": 268435488, "SINT_32": 285212704, "UINT_16": 301989904,
  "FLOAT_32": 553648160, "BFLOAT_16": 570425360, "COMPLEX_FLOAT_64": 587202624 }
EOF
cat > "$tmp/sc.json" <<'EOF'
{ "OK": 0, "INVALID_ARGUMENT": 3 }
EOF
cat > "$tmp/nt.json" <<'EOF'
{ "UNKNOWN": 0, "INTEGER": 16, "INTEGER_SIGNED": 17, "INTEGER_UNSIGNED": 18,
  "BOOLEAN": 19, "FLOAT": 32, "FLOAT_IEEE": 33, "FLOAT_BRAIN": 34, "FLOAT_COMPLEX": 35 }
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

s="$tmp/out/status_codes.json"
assert_eq "$(get "$s" "['status_codes']['OK']['value']")" "0" "status OK value"
case "$(get "$s" "['status_codes']['OK']['description']")" in
  ""|"None") echo "FAIL: OK missing description" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1));;
  *) echo "ok: OK has a description";;
esac

# schemas are valid JSON Schema and the data validates against them.
python3 - "$tmp/out" <<'PY' && echo "ok: data validates against shipped schemas" || { echo "FAIL: schema validation" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
import json,sys
try:
    import jsonschema
except ImportError:
    print("skip: jsonschema not installed"); sys.exit(0)
d=sys.argv[1]
for data,schema in [("element_types.json","element_types.schema.json"),
                    ("status_codes.json","status_codes.schema.json")]:
    jsonschema.validate(json.load(open(f"{d}/{data}")), json.load(open(f"{d}/{schema}")))
PY
exit "$ASSERT_FAILS"
```
(BOOL_8 = `IREE_HAL_ELEMENT_TYPE_VALUE(BOOLEAN=0x13, 8)` = `0x13000008` = 318767112.)

- [ ] **Step 2: Run, verify failure** — `bash test/enrich_constants.test.sh` FAILs (no script).

- [ ] **Step 3: Implement `scripts/enrich-constants.py`:**
```python
#!/usr/bin/env python3
"""Enrich raw IREE constant dumps into self-describing metadata + JSON Schema.

Inputs are the flat name->value maps and the numerical-type enum emitted by
emit_constants.c (which reads IREE's headers). This step is pure arithmetic --
value = (numerical_type << 24) | bit_count -- plus coarse category bucketing and
curated status-code descriptions. No IREE headers are needed here.
"""
import json
import sys

SCHEMA_VERSION = 1

# Coarse category from the numerical-type high byte. Our classification
# (documented in the schema), not an IREE-authoritative grouping.
def _category(hi):
    if hi == 0x00:                 return "opaque"
    if hi == 0x13:                 return "boolean"
    if hi in (0x10, 0x11, 0x12):   return "integer"
    if hi == 0x23:                 return "complex"
    if 0x20 <= hi <= 0x28:         return "float"
    return "unknown"

def _signed(hi):
    if hi == 0x11: return True
    if hi == 0x12: return False
    return None   # sign-agnostic INT_*, booleans, floats, opaque

# The one hand-authored input: short informational descriptions, curated from
# IREE's iree/base/status.h. Informational, not a contract (the schema says so).
STATUS_DESCRIPTIONS = {
    "OK": "Not an error; success.",
    "CANCELLED": "The operation was cancelled, typically by the caller.",
    "UNKNOWN": "Unknown error; an error not fitting any other code.",
    "INVALID_ARGUMENT": "The caller specified an invalid argument.",
    "DEADLINE_EXCEEDED": "A deadline expired before the operation could complete.",
    "NOT_FOUND": "A requested entity was not found.",
    "ALREADY_EXISTS": "An entity the caller attempted to create already exists.",
    "PERMISSION_DENIED": "The caller lacks permission for the operation.",
    "RESOURCE_EXHAUSTED": "A resource (memory, quota, handles) has been exhausted.",
    "FAILED_PRECONDITION": "The system is not in a state required for the operation.",
    "ABORTED": "The operation was aborted, often due to a concurrency conflict.",
    "OUT_OF_RANGE": "The operation was attempted past a valid range.",
    "UNIMPLEMENTED": "The operation is not implemented or supported.",
    "INTERNAL": "Internal invariant violated; a serious bug.",
    "UNAVAILABLE": "The service is currently unavailable; the caller may retry.",
    "DATA_LOSS": "Unrecoverable data loss or corruption.",
    "UNAUTHENTICATED": "The caller does not have valid authentication.",
    "DEFERRED": "The operation was deferred for asynchronous completion.",
    "INCOMPATIBLE": "The operation is incompatible with the target.",
}

def _enrich_element_types(values, num_enum):
    by_value = {v: k for k, v in num_enum.items()}
    types = {}
    for name, value in values.items():
        hi = value >> 24
        types[name] = {
            "value": value,
            "hex": "0x%08x" % value,
            "numerical_type": by_value.get(hi, "UNKNOWN"),
            "category": _category(hi),
            "signed": _signed(hi),
            "bit_count": value & 0xFF,
        }
    return {
        "schema_version": SCHEMA_VERSION,
        "encoding": {
            "formula": "value = (numerical_type << 24) | bit_count",
            "numerical_types": num_enum,
        },
        "element_types": types,
    }

def _enrich_status_codes(values):
    codes = {}
    for name, value in values.items():
        entry = {"value": value}
        desc = STATUS_DESCRIPTIONS.get(name)
        if desc:
            entry["description"] = desc
        codes[name] = entry
    return {"schema_version": SCHEMA_VERSION, "status_codes": codes}

def _element_types_schema():
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "title": "iree-runtime-dist element types",
        "description": (
            "Authoritative properties of each IREE HAL element type. The type "
            "PROPERTIES here are authoritative; mapping them to your own native "
            "types (and choosing among INT_*/SINT_*/UINT_*) is your integration "
            "work, not something this file decides."
        ),
        "type": "object",
        "required": ["schema_version", "encoding", "element_types"],
        "properties": {
            "schema_version": {"const": 1},
            "encoding": {
                "type": "object",
                "required": ["formula", "numerical_types"],
                "properties": {
                    "formula": {"type": "string",
                                "description": "How value decomposes into fields."},
                    "numerical_types": {"type": "object",
                                        "description": "IREE numerical-type enum, name -> value.",
                                        "additionalProperties": {"type": "integer"}},
                },
            },
            "element_types": {
                "type": "object",
                "additionalProperties": {
                    "type": "object",
                    "required": ["value", "hex", "numerical_type", "category",
                                 "signed", "bit_count"],
                    "properties": {
                        "value": {"type": "integer",
                                  "description": "The IREE_HAL_ELEMENT_TYPE_* value."},
                        "hex": {"type": "string",
                                "description": "value as 0x%08x."},
                        "numerical_type": {"type": "string",
                                           "description": "IREE numerical-type enum name for value>>24."},
                        "category": {"enum": ["opaque", "boolean", "integer", "float",
                                              "complex", "unknown"],
                                     "description": "Coarse bucket derived from numerical_type."},
                        "signed": {"type": ["boolean", "null"],
                                   "description": "true=signed, false=unsigned, null=sign-agnostic/NA."},
                        "bit_count": {"type": "integer",
                                      "description": "Element width in bits (value & 0xFF)."},
                    },
                },
            },
        },
    }

def _status_codes_schema():
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "title": "iree-runtime-dist status codes",
        "type": "object",
        "required": ["schema_version", "status_codes"],
        "properties": {
            "schema_version": {"const": 1},
            "status_codes": {
                "type": "object",
                "additionalProperties": {
                    "type": "object",
                    "required": ["value"],
                    "properties": {
                        "value": {"type": "integer",
                                  "description": "The IREE_STATUS_* ordinal value."},
                        "description": {"type": "string",
                                        "description": "Informational summary, not a contract."},
                    },
                },
            },
        },
    }

def _write(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f, indent=2, sort_keys=True)
        f.write("\n")

def main(argv):
    if len(argv) != 5:
        sys.stderr.write("usage: enrich-constants.py <raw_element_types> "
                         "<raw_status_codes> <raw_numerical_types> <out_dir>\n")
        return 2
    raw_et, raw_sc, raw_nt, out_dir = argv[1:]
    import os
    os.makedirs(out_dir, exist_ok=True)
    et = json.load(open(raw_et))
    sc = json.load(open(raw_sc))
    nt = json.load(open(raw_nt))
    _write(os.path.join(out_dir, "element_types.json"), _enrich_element_types(et, nt))
    _write(os.path.join(out_dir, "status_codes.json"), _enrich_status_codes(sc))
    _write(os.path.join(out_dir, "element_types.schema.json"), _element_types_schema())
    _write(os.path.join(out_dir, "status_codes.schema.json"), _status_codes_schema())
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 4: Run, verify pass** — `bash test/enrich_constants.test.sh` all ok;
`bash test/run.sh` ends `ALL UNIT TESTS PASS`.

- [ ] **Step 5: Commit** `git add scripts/enrich-constants.py test/enrich_constants.test.sh` and
`git commit -m "feat(metadata): enrich-constants.py — decode + JSON Schema (hermetic)"`.

---

### Task 2: Emit the numerical-type enum; wire the emitter → enricher

**Files:**
- Modify: `emit/emit_constants.c` (add `emit_numerical_types`, `main` takes a 3rd path)
- Modify: `scripts/gen-constants.sh` (emit to a work dir, then enrich into `share/`)

**Interfaces:**
- `emit_constants <element_types> <status_codes> <numerical_types>` writes three flat files.
- `gen-constants.sh <prefix>` ends with the enriched files in `$prefix/share/iree-runtime-dist/`.

- [ ] **Step 1: Add `emit_numerical_types` to `emit/emit_constants.c`**, mirroring the existing
`E(sym)` pattern but over the numerical-type enum, and call it in `main` for `argv[3]`:
```c
static int emit_numerical_types(const char* path) {
  FILE* f = fopen(path, "w");
  if (!f) return 1;
  fprintf(f, "{\n");
  int first = 1;
#define N(sym)                                                            \
  do {                                                                    \
    fprintf(f, "%s  \"%s\": %llu", first ? "" : ",\n", #sym,              \
            (unsigned long long)IREE_HAL_NUMERICAL_TYPE_##sym);           \
    first = 0;                                                            \
  } while (0)
  N(UNKNOWN); N(INTEGER); N(INTEGER_SIGNED); N(INTEGER_UNSIGNED); N(BOOLEAN);
  N(FLOAT); N(FLOAT_IEEE); N(FLOAT_BRAIN); N(FLOAT_COMPLEX);
  N(FLOAT_8_E5M2); N(FLOAT_8_E4M3FN); N(FLOAT_8_E5M2_FNUZ);
  N(FLOAT_8_E4M3_FNUZ); N(FLOAT_8_E8M0_FNU);
#undef N
  fprintf(f, "\n}\n");
  fclose(f);
  return 0;
}
```
Change `main`'s arg check to `argc != 4` and usage to three paths, and add
`if (emit_numerical_types(argv[3])) return 1;`.

- [ ] **Step 2: Update `scripts/gen-constants.sh`** so the emitter writes to a work dir and the
enricher writes the final files into `$OUT_DIR`:
```bash
raw="$(mktemp -d)"; trap 'rm -rf "$work" "$raw"' EXIT   # extend existing trap
"$work/b/emit_constants" "$raw/element_types.json" "$raw/status_codes.json" "$raw/numerical_types.json"
python3 "$HERE/enrich-constants.py" \
  "$raw/element_types.json" "$raw/status_codes.json" "$raw/numerical_types.json" "$OUT_DIR"
echo "==> generated enriched element_types.json, status_codes.json + schemas"
```
(The emitter no longer writes into `$OUT_DIR` directly; the enricher owns the shipped files.)

- [ ] **Step 3: Verify against a real prefix** (container or the existing `out/` build tree). Run
`bash scripts/gen-constants.sh out`, then confirm `out/share/iree-runtime-dist/element_types.json`
has the enriched shape and `element_types.FLOAT_32.value == 553648160`, and the two `.schema.json`
files exist. Expected: enriched files present, schemas present.

- [ ] **Step 4: Commit** `git add emit/emit_constants.c scripts/gen-constants.sh` and
`git commit -m "feat(metadata): emit numerical-type enum; gen-constants runs the enricher"`.

---

### Task 3: Rewrite `constants.test.sh` for the enriched format

**Files:** Modify `test/constants.test.sh` (breaking — it currently reads the flat shape).

- [ ] **Step 1: Rewrite the value assertions** to the enriched paths and add schema + file checks:
```bash
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
```

- [ ] **Step 2: Verify** against a prefix with enriched constants (from Task 2): passes. Against a
prefix without them: fails loudly.

- [ ] **Step 3: Commit** `git add test/constants.test.sh` and
`git commit -m "test(metadata): assert enriched constants shape + schema validation"`.

---

### Task 4: The metadata zip — assembly script, README, release wiring

**Files:**
- Create: `scripts/package-metadata.sh`, `docs/metadata-README.md.in`
- Modify: `.github/workflows/release.yml` (build + upload the zip in the `release` job)

- [ ] **Step 1: Author `docs/metadata-README.md.in`** — the zip's consumer doc: file inventory,
the `value = (numerical_type << 24) | bit_count` encoding, field meanings, and a **"What you can
and cannot depend on"** section stating that type properties are authoritative but the native-type
mapping is the consumer's work (with the `INT_*` vs `SINT_*`/`UINT_*` example). Use `@IREE_VERSION@`.

- [ ] **Step 2: Write `scripts/package-metadata.sh`** — assemble the zip from a prefix's metadata:
```bash
#!/usr/bin/env bash
# Build iree-runtime-metadata-<version>.zip from a prefix's share/ metadata.
# Constants are variant-independent, so this runs once per release.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${1:?usage: package-metadata.sh <prefix> <version> <outdir>}"
VERSION="${2:?version required}"; OUTDIR="${3:?outdir required}"
src="$PREFIX/share/iree-runtime-dist"
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
for f in element_types.json status_codes.json element_types.schema.json status_codes.schema.json; do
  cp "$src/$f" "$stage/"
done
sed "s|@IREE_VERSION@|${VERSION}|g" "$HERE/../docs/metadata-README.md.in" > "$stage/README.md"
mkdir -p "$OUTDIR"
( cd "$stage" && zip -q -X "$OLDPWD/$OUTDIR/iree-runtime-metadata-${VERSION}.zip" \
    element_types.json status_codes.json element_types.schema.json status_codes.schema.json README.md )
echo "==> packaged iree-runtime-metadata-${VERSION}.zip"
```
Add a hermetic-ish test `test/package_metadata.test.sh`: build a fake prefix with the five
metadata files, run the script, assert the zip exists and `unzip -l` lists all five members.

- [ ] **Step 3: Wire the `release` job** in `.github/workflows/release.yml`. After the assets are
downloaded (`merge-multiple`), before/with `gh release create`, extract the `default` tarball,
build the zip, and add it to the upload list:
```yaml
      - name: Build the metadata zip (once per release; variant-independent)
        run: |
          mkdir -p meta-extract
          tar -xzf release/iree-runtime-*-default-linux-x86_64.tar.gz -C meta-extract
          prefix="$(find meta-extract -maxdepth 1 -mindepth 1 -type d)"
          bash scripts/package-metadata.sh "$prefix" "${{ needs.setup.outputs.iree_version }}" release
```
and add `release/iree-runtime-metadata-*.zip` to BOTH the `gh release create` and the
`gh release upload --clobber` asset lists.

- [ ] **Step 4: Verify** — `actionlint` clean; `bash test/package_metadata.test.sh` passes;
`bash test/run.sh` green. (End-to-end zip publication is confirmed on a real tag.)

- [ ] **Step 5: Commit** the four files with
`git commit -m "feat(metadata): publish iree-runtime-metadata-<version>.zip release asset"`.

---

### Task 5: Documentation — enriched format + the boundary

**Files:** `docs/share-README.md.in`, `docs/handover/2026-07-20-djl-iree-engine-handover.md`,
`README.md`.

- [ ] **Step 1: `docs/share-README.md.in`** — replace the "flat JSON object, `{ NAME: <int> }`"
description with the enriched shape (per-entry `{value, hex, numerical_type, category, signed,
bit_count}`, top-level `encoding.numerical_types`, `schema_version`), note the `.schema.json`
files, and add the one-sentence boundary (properties authoritative; mapping is yours).

- [ ] **Step 2: Handover §4** — update the worked example to the enriched shape, and expand the
boundary paragraph (spec §2): the `INT_*`/`SINT_*`/`UINT_*` signedness point and that the mapping
is the consumer's integration work. Point at the metadata zip asset as the non-CMake path.

- [ ] **Step 3: `README.md`** — under "What this ships", note the enriched constants + schemas and
the separate `iree-runtime-metadata-<version>.zip` release asset (same files as in the tarball).

- [ ] **Step 4: Verify** `bash test/run.sh` green (docs only) and no stale "flat"/`{NAME:int}`
description of the constants remains (`grep`).

- [ ] **Step 5: Commit** with
`git commit -m "docs: enriched constants format + the authoritative-vs-policy boundary"`.

---

## Self-Review

- **Spec coverage:** enriched element types (§4.1) → T1; status codes (§4.2) → T1; schemas (§4.3)
  → T1; generation/authoritative enum (§4.4) → T1+T2; zip once-per-release + in-tarball (§4.5) →
  T2 (in-tarball) + T4 (zip); testing (§5) → T1/T3/T4; docs + boundary (§2, §6) → T4 (zip README)
  + T5. All covered.
- **Placeholder scan:** every code step carries real code or an exact command; the curated status
  descriptions are given in full in T1.
- **Type/name consistency:** `enrich-constants.py` signature (`<raw_et> <raw_sc> <raw_nt> <out>`),
  the enriched paths (`element_types.<NAME>.value`, `status_codes.<NAME>.value`), and the four
  shipped filenames are used identically across T1–T5.
- **Ordering:** T1 (hermetic core) precedes T2 (which feeds it real data); T3 depends on T2's
  output shape; T4 depends on the files existing; T5 documents them. Breaking change lands atomically
  across T1–T3 (no flat file survives).
- **Known environmental note:** `jsonschema` is present in the dev/CI Python, but the tests skip
  cleanly if it is ever absent, so they never false-fail on environment.
