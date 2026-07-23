# Enriched, self-describing constants metadata — design

**Date:** 2026-07-23
**Status:** Approved design (from in-conversation brainstorming), pre-implementation
**Addresses:** #6 (element_types.json / status_codes.json: no schema doc, no non-CMake discovery
path). Supersedes the flat `{ "NAME": <int> }` constants format with a **breaking change**.

---

## 1. Motivation

Two distinct pains, from consumer feedback (#6) and the follow-up investigation of
`djl-iree-engine`'s build:

1. **Availability, not format, is what burned releases.** The flat `element_types.json` lives
   only inside the CMake-fetched tarball, so `djl-iree-engine` copies it out
   (`native/build.sh:97`) into a Gradle-visible resource dir and re-stages it across GitHub
   Actions jobs. Every hop in that chain is a release-breaking candidate. A CMake path variable
   (`IREE_RUNTIME_DIST_ELEMENT_TYPES`) does not help a Gradle/Python/Rust build at all.

2. **The flat format discards authoritative structure, forcing hand-derivation.** `{ "FLOAT_32":
   553648160 }` throws away everything except the raw value, so each consumer re-derives "this is
   a signed 32-bit integer / this is a 16-bit float" by hand — the exact class of the original
   `FLOAT_32 = 0x120` transcription bug this file was created to prevent. IREE encodes that
   structure in the value itself (`value = (numerical_type << 24) | bit_count`), and we build
   against IREE's headers — so we can hand it over authoritatively instead.

The fix is (a) publish the constants as a standalone **metadata zip release asset** so non-CMake
consumers fetch one stable URL independent of the native build, and (b) **enrich** the constants
into a self-describing form plus a **JSON Schema**, so the objective properties of each type are
authoritative data rather than hand-derived.

## 2. What this does and does not remove (the boundary — must be documented)

This is load-bearing for the end-user docs (see §6). The enrichment removes the *objective* half
of the mapping problem and leaves the *subjective* half untouched:

- **Now authoritative, no judgment:** each IREE type's value, its numerical-type category
  (float / integer / boolean / opaque / complex), whether it is signed / unsigned /
  sign-agnostic, and its bit width.
- **Still irreducibly per-consumer:** *which* IREE type best fits a given native type, plus
  direction preferences and exclusions. IREE offers `INT_32` (sign-agnostic), `SINT_32` (signed),
  and `UINT_32` (unsigned) as genuinely distinct types; there is no IREE-authoritative "canonical
  signed 32-bit," so choosing one for a consumer's `int` is policy, not a fact. A NumPy, ONNX, or
  Rust consumer makes different calls against the same enriched data.

Net: we **shrink and de-risk** the integration, we do not eliminate it. The shipped docs must say
this plainly so consumers neither expect a turnkey mapping nor re-derive facts we already provide.

## 3. Scope

**In:** enriched self-describing `element_types.json` + `status_codes.json`; a JSON Schema for
each; a `iree-runtime-metadata-<version>.zip` release asset; the enriched files also inside the
tarball (CMake path variables point at them); end-user docs surfacing the schema and the §2
boundary.

**Out (non-goals):**
- Owning any consumer's native-type mapping (§2 — it is policy).
- Back-compat with the flat `{ NAME: int }` format. This is a **clean break**; the sole known
  consumer wants to rewrite its codegen against the better shape.
- Additional serialization formats (TOML, `.properties`). JSON + schema only; the zip is the
  extension point if a second format is ever demanded.
- **Per-language bindings / reader code.** The producer-side decoder (`enrich-constants.py`) is
  redundant to consumers once its output is the enriched data, and shipping a reader for one
  language reopens "why not the others." The **JSON Schema is the neutral codegen enabler**
  (schema-to-source generators exist per language); the zip can carry an optional, clearly-labeled
  *reference* reader later if a consumer commits to a specific language and demand is demonstrated.

## 4. Design

### 4.1 Enriched `element_types.json`

```json
{
  "schema_version": 1,
  "encoding": {
    "formula": "value = (numerical_type << 24) | bit_count",
    "numerical_types": {
      "UNKNOWN": 0, "INTEGER": 16, "INTEGER_SIGNED": 17, "INTEGER_UNSIGNED": 18,
      "BOOLEAN": 19, "FLOAT": 32, "FLOAT_IEEE": 33, "FLOAT_BRAIN": 34, "FLOAT_COMPLEX": 35,
      "FLOAT_8_E5M2": 36, "FLOAT_8_E4M3FN": 37, "FLOAT_8_E5M2_FNUZ": 38,
      "FLOAT_8_E4M3_FNUZ": 39, "FLOAT_8_E8M0_FNU": 40
    }
  },
  "element_types": {
    "FLOAT_32": { "value": 553648160, "hex": "0x21000020",
                  "numerical_type": "FLOAT_IEEE", "category": "float",
                  "signed": null, "bit_count": 32 },
    "SINT_32":  { "value": 285212704, "hex": "0x11000020",
                  "numerical_type": "INTEGER_SIGNED", "category": "integer",
                  "signed": true, "bit_count": 32 },
    "UINT_16":  { "value": 301989904, "hex": "0x12000010",
                  "numerical_type": "INTEGER_UNSIGNED", "category": "integer",
                  "signed": false, "bit_count": 16 },
    "INT_32":   { "value": 268435488, "hex": "0x10000020",
                  "numerical_type": "INTEGER", "category": "integer",
                  "signed": null, "bit_count": 32 }
  }
}
```

Every field is derived authoritatively:
- `value` — from IREE's headers (as today).
- `hex` — `value` formatted `0x%08x`.
- `numerical_type` — the IREE enum name for `value >> 24`, from the enum emitted from
  `iree/hal/buffer_view.h` (not a hand-copied table).
- `category` — coarse bucket derived from `numerical_type`: `opaque` (UNKNOWN family),
  `boolean` (BOOLEAN), `integer` (INTEGER / _SIGNED / _UNSIGNED), `float` (FLOAT / _IEEE /
  _BRAIN / FP8), `complex` (FLOAT_COMPLEX). Redundant with `numerical_type` but convenient;
  kept because both are cheap and consumers bucket differently.
- `signed` — `true` for INTEGER_SIGNED, `false` for INTEGER_UNSIGNED, `null` otherwise
  (sign-agnostic `INT_*`, booleans, floats, opaque). The `null` on `INT_*` is the signal that
  encodes the §2 policy point: IREE does not pick a sign for you.
- `bit_count` — `value & 0xFF`.

### 4.2 Enriched `status_codes.json`

Status codes are ordinal integers with no sub-structure to decompose, so "enriched" means the
same envelope for consistency plus a curated one-line description (typed-exception consumers want
the human meaning):

```json
{
  "schema_version": 1,
  "status_codes": {
    "OK":               { "value": 0,  "description": "Not an error; success." },
    "INVALID_ARGUMENT": { "value": 3,  "description": "Caller specified an invalid argument." }
  }
}
```

The 19 descriptions are curated once from IREE's `iree/base/status.h` semantics (stable, small).
Descriptions are the only hand-authored content in this feature; the schema documents that they
are informational, not a contract.

### 4.3 JSON Schemas

Ship `element_types.schema.json` and `status_codes.schema.json` (JSON Schema 2020-12) alongside
the data. Each field carries a `description` — this is the answer to "JSON can't have comments":
the human documentation lives with the data as machine-consumable schema, usable for validation
and editor tooling. The element-types schema's top-level `description` restates the §2 boundary in
one sentence.

### 4.4 Generation

Keep values authoritative, keep decomposition logic out of C:
- `emit/emit_constants.c` (compiled against IREE headers) additionally emits the numerical-type
  enum (name → value) — so the category/sign decode is driven by IREE's own enum, not a table
  transcribed into our tooling.
- A new `scripts/enrich-constants.py` reads the emitted raw values + the numerical-type enum,
  decodes each element type into the §4.1 fields, attaches the curated status-code descriptions,
  and writes the four files (two data, two schema). Pure-arithmetic decode; no IREE headers
  needed at enrich time.
- `scripts/gen-constants.sh` runs the emitter then the enricher, writing the enriched files into
  `$PREFIX/share/iree-runtime-dist/` (replacing the flat files — the breaking change).

### 4.5 Packaging: the metadata zip

- The enriched files ship **inside the tarball** at `share/iree-runtime-dist/` (so the CMake
  `IREE_RUNTIME_DIST_ELEMENT_TYPES` / `_STATUS_CODES` variables now point at the enriched files).
- The constants are **variant-independent** (same IREE headers), so the zip is built **once per
  release**, not per variant. The `release` job assembles
  `iree-runtime-metadata-<version>.zip` from the `default` tarball's metadata and uploads it as a
  release asset. Contents: `element_types.json`, `status_codes.json`, `element_types.schema.json`,
  `status_codes.schema.json`, and a `README.md` (§6). `manifest.json` is **not** in the zip — it
  is per-variant build provenance, not consumer constants, and stays in the tarball.
- Consumer effect: fetch one stable URL, unzip, read — no CMake, no `FetchContent`, no
  `build.sh:97` staging, no cross-job re-staging.

## 5. Testing

**Hermetic (`test/*.test.sh`):**
- `enrich-constants.py` decode: known inputs → expected fields — `FLOAT_32` → float/`null`/32,
  `SINT_32` → integer/`true`/32, `UINT_16` → integer/`false`/16, `INT_32` → integer/`null`/32,
  `BOOL_8` → boolean/`null`/8, `OPAQUE_32` → opaque/`null`/32, `COMPLEX_FLOAT_64` → complex.
  Mutation-checked so a wrong decode (e.g. sign of `INT_*`) fails.
- Envelope: both files parse, carry `schema_version`, and the enriched `value` fields equal the
  raw emitted values (no drift between flat source and enriched output).
- Schema validity: the two `.schema.json` files are themselves valid JSON Schema, and the data
  validates against them (using a validator if available in the env; otherwise a structural
  check of required keys).

**Structural (`test/build_smoke.sh`, prefix arg):** the tarball ships the four enriched/schema
files; each is non-empty and valid JSON.

**Release-level (documented, confirmed on a real tag):** the `iree-runtime-metadata-<version>.zip`
asset exists, is a valid zip, and contains the five expected members.

## 6. End-user documentation (explicit requirement)

Three surfaces, all must carry the §2 boundary, not just the schema:
- **`README.md` inside the zip** — the primary consumer-facing doc: the file inventory, the
  encoding formula, the field meanings, and a "what you can and cannot depend on this for"
  section stating plainly that the type *properties* are authoritative but the *mapping to your
  native types* is your integration work (with the `INT_*` vs `SINT_*`/`UINT_*` example).
- **Handover §4** (`docs/handover/...`) — updated from the flat format to the enriched one, with
  the same boundary framing and a pointer to the zip asset.
- **Project `README.md`** — note the metadata zip asset and that the in-tarball
  `share/iree-runtime-dist/` copies are the same files.

## 7. Requirement traceability

| Source | Requirement | Where |
|---|---|---|
| #6 | schema doc for the JSON files | §4.3 |
| #6 | non-CMake discovery / no reverse-engineering | §4.5 zip asset |
| #6 (investigation) | kill the `build.sh:97` staging that burned releases | §4.5 |
| this discussion | enrich with authoritative structure, not hand-derived | §4.1 |
| this discussion | JSON can't carry comments → docs-as-data | §4.3 schema descriptions |
| this discussion | enrich `status_codes` too (cheap YAGNI) | §4.2 |
| this discussion | zip as single, format-extensible location | §4.5 |
| this discussion | docs surface schema AND the depend-on boundary | §2, §6 |
