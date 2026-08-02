#!/usr/bin/env python3
"""Hermetic guard on the two workflow invariants that only fail on a real runner.

1. PATH PREFIX. Jobs that check this repo out to ``path: dist`` (to leave the
   workspace root free for an adjacent ``iree/``) must prefix every path that
   Actions resolves against the WORKSPACE ROOT rather than the step's cwd:
   local ``uses: ./...`` action refs, and build-push-action's ``context``/``file``.
   ``uses:`` steps ignore ``working-directory``, and build-push-action's ``file``
   is NOT relative to its ``context``. Both mistakes fail only once a runner
   picks the job up, minutes into a release, with an opaque message ("Can't find
   'action.yml'", "failed to read dockerfile").

2. MATRIX KEY. A matrix object built from the ``PLATFORMS`` JSON is referenced as
   ``matrix.<obj>.<key>``; an unresolved key expands to the EMPTY STRING rather
   than erroring, so a typo in ``runs-on:`` yields a job that cannot be scheduled
   and never names the typo.

This replaces the earlier workflow_paths.test.sh, which drove its loop from
naming.sh's platform list. Neither check needs a platform list: the prefix rule
is a property of a job's own checkout, and the key rule reads the workflow's own
PLATFORMS block. The lists in scripts/lib/ validate build-runtime.sh's
--platform and drive test/cmake_init.test.sh; they are deliberately not the CI
matrix source.

Usage: workflow_paths.py <repo-root>
"""

import json
import pathlib
import re
import sys

import yaml

FAILS = 0


def ok(msg):
    print(f"ok: {msg}")


def bad(msg, detail=""):
    global FAILS
    print(f"FAIL: {msg}" + (f"\n  {detail}" if detail else ""), file=sys.stderr)
    FAILS += 1


def check_matrix_keys(name, doc, text):
    """Invariant 2: every matrix.<obj>.<key> exists in the PLATFORMS JSON."""
    platforms = (doc.get("env") or {}).get("PLATFORMS")
    if not platforms:
        return

    keys = set()
    for entry in json.loads(platforms):
        keys |= set(entry)

    # Find the matrix variable(s) fed from that JSON rather than assuming a
    # name, so renaming the variable cannot silently disarm this check.
    objs = set()
    for job in (doc.get("jobs") or {}).values():
        matrix = (job.get("strategy") or {}).get("matrix") or {}
        for var, val in matrix.items():
            if isinstance(val, str) and ("outputs.platforms" in val or "PLATFORMS" in val):
                objs.add(var)
    if not objs:
        bad(f"{name}: declares env.PLATFORMS but no matrix variable consumes it")

    for obj in sorted(objs):
        used = set(re.findall(rf"matrix\.{obj}\.([A-Za-z_][A-Za-z0-9_]*)", text))
        if not used:
            bad(f"{name}: matrix.{obj} is never dereferenced")
            continue
        unknown = sorted(used - keys)
        if unknown:
            bad(
                f"{name}: matrix.{obj} references key(s) absent from PLATFORMS",
                f"unknown: {unknown}; PLATFORMS defines: {sorted(keys)}",
            )
        else:
            ok(f"{name}: every matrix.{obj}.<key> exists in PLATFORMS ({sorted(used)})")


def checkout_root(steps):
    """This repo's checkout path for a job: actions/checkout with no `repository:`."""
    for step in steps:
        uses = step.get("uses", "")
        with_ = step.get("with") or {}
        if uses.startswith("actions/checkout@") and not with_.get("repository"):
            return str(with_.get("path", "")).strip("/")
    return ""


def check_path_prefixes(repo, name, doc):
    """Invariant 1: workspace-root-resolved paths carry the job's checkout root."""
    for job_id, job in (doc.get("jobs") or {}).items():
        steps = job.get("steps") or []
        root = checkout_root(steps)
        if not root:
            continue

        for step in steps:
            uses = step.get("uses", "")
            with_ = step.get("with") or {}
            label = f"{name}:{job_id}"

            if uses.startswith("./"):
                if not uses.startswith(f"./{root}/"):
                    bad(
                        f"{label}: local action '{uses}' is not ./{root}/-prefixed",
                        "uses: resolves against the workspace root and ignores working-directory",
                    )
                    continue
                # Prefix is right -- now prove the action actually exists.
                rel = uses[len(f"./{root}/") :]
                if not any((repo / rel / f).is_file() for f in ("action.yml", "action.yaml")):
                    bad(f"{label}: local action '{uses}' has no action.yml at {rel}/")
                else:
                    ok(f"{label}: local action '{uses}' resolves")

            if uses.startswith("docker/build-push-action@"):
                for key in ("context", "file"):
                    val = str(with_.get(key, ""))
                    if not val:
                        continue
                    if not val.startswith(f"{root}/"):
                        bad(
                            f"{label}: build-push-action `{key}: {val}` is not {root}/-prefixed",
                            "build-push-action resolves BOTH context and file against the workspace root",
                        )
                    else:
                        ok(f"{label}: build-push-action `{key}` is {root}/-prefixed")


def main():
    repo = pathlib.Path(sys.argv[1])
    for wf in sorted((repo / ".github" / "workflows").glob("*.yml")):
        text = wf.read_text()
        check_matrix_keys(wf.name, yaml.safe_load(text), text)
        check_path_prefixes(repo, wf.name, yaml.safe_load(text))

    if FAILS:
        print(f"\n{FAILS} assertion(s) FAILED", file=sys.stderr)
        return 1
    print("workflow_paths: all assertions passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
