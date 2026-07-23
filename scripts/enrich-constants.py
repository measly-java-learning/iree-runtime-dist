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
