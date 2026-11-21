#!/usr/bin/env python3
"""Hermetic guard on workflow invariants that otherwise fail only on a real runner
(or, worse, only in what a release publishes).

1. PATH PREFIX. Jobs that check this repo out to ``path: dist`` (to leave the
   workspace root free for an adjacent ``iree/``) must prefix every path that
   Actions resolves against the WORKSPACE ROOT rather than the step's cwd:
   local ``uses: ./...`` action refs, and build-push-action's ``context``/``file``.
   Same-repo actions are referenced as ``uses: $/...`` (repo-root-relative, at
   the workflow's own commit) so actions.lock can cover what they use; those
   take no prefix, and only their existence is checked.
   ``uses:`` steps ignore ``working-directory``, and build-push-action's ``file``
   is NOT relative to its ``context``. Both mistakes fail only once a runner
   picks the job up, minutes into a release, with an opaque message ("Can't find
   'action.yml'", "failed to read dockerfile").

2. MATRIX KEY. A matrix object built from the ``PLATFORMS`` JSON is referenced as
   ``matrix.<obj>.<key>``; an unresolved key expands to the EMPTY STRING rather
   than erroring, so a typo in ``runs-on:`` yields a job that cannot be scheduled
   and never names the typo.

3. FILTERED DOWNLOAD. A job that runs ``gh release`` must not download artifacts
   unfiltered (foreign ``.dockerbuild`` records reached v3.11.0-11 that way).

4. DRY RUN CANNOT PUBLISH. In a workflow with a ``workflow_dispatch`` dry run,
   every ``gh release`` job and every ``actions/attest`` step is gated on
   ``github.event_name == 'push'``.

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


def check_publishing_jobs_filter(name, doc):
    """Invariant 3: a job that publishes must not download artifacts unfiltered.

    An unfiltered actions/download-artifact pulls every artifact the run
    produced, and a build job does not own that namespace: build-push-action
    uploads a `.dockerbuild` build record per invocation. v3.11.0-11 published
    four of them, and immutable releases meant they could not be deleted. The
    release step's `release/*` glob is deliberately bare, so the filter has to
    be here -- which makes its absence a silent, unrecoverable defect rather
    than a noisy one.
    """
    for job_id, job in (doc.get("jobs") or {}).items():
        steps = job.get("steps") or []
        publishes = any(
            "gh release" in str(step.get("run", "")) for step in steps
        )
        if not publishes:
            continue

        label = f"{name}:{job_id}"
        downloads = [
            s for s in steps if str(s.get("uses", "")).startswith("actions/download-artifact@")
        ]
        if not downloads:
            ok(f"{label}: publishes but downloads no artifacts")
            continue
        for step in downloads:
            with_ = step.get("with") or {}
            if not (with_.get("pattern") or with_.get("name")):
                bad(
                    f"{label}: publishing job downloads artifacts unfiltered",
                    "add `pattern:` -- an unfiltered download sweeps foreign "
                    "artifacts (e.g. build-push-action's .dockerbuild records) "
                    "into the published release",
                )
            else:
                ok(f"{label}: publishing job filters its artifact download")


def _triggers(doc):
    # PyYAML (YAML 1.1) parses the bare key `on` as boolean True.
    on = doc.get("on", doc.get(True)) or {}
    if isinstance(on, str):
        return {on}
    return set(on)


def _gated_on_push(cond):
    return "github.event_name == 'push'" in str(cond or "")


def check_dry_run_cannot_publish(name, doc):
    """Invariant 4: in a workflow that can dry-run, nothing publishes off-push.

    release.yml's workflow_dispatch trigger exists to build every platform from
    a branch WITHOUT publishing. Its contract is only as good as the gates on
    the steps that publish: a release job (`gh release`) and an attestation
    (actions/attest -- a public, permanent transparency-log entry). One missing
    `if: github.event_name == 'push'` and a dry run publishes, into a repo with
    immutable releases. So the gate is asserted, not assumed.
    """
    if "workflow_dispatch" not in _triggers(doc):
        return
    for job_id, job in (doc.get("jobs") or {}).items():
        label = f"{name}:{job_id}"
        job_gated = _gated_on_push(job.get("if"))
        steps = job.get("steps") or []
        if any("gh release" in str(st.get("run", "")) for st in steps):
            if job_gated:
                ok(f"{label}: publishing job is gated on push")
            else:
                bad(
                    f"{label}: publishing job is not gated on push",
                    "a workflow_dispatch dry run would publish a release; add "
                    "`if: github.event_name == 'push'` to the job",
                )
        for st in steps:
            if str(st.get("uses", "")).startswith("actions/attest@"):
                if job_gated or _gated_on_push(st.get("if")):
                    ok(f"{label}: attest step is gated on push")
                else:
                    bad(
                        f"{label}: attest step is not gated on push",
                        "a workflow_dispatch dry run would write a public "
                        "attestation for an unpublished artifact",
                    )


def check_path_prefixes(repo, name, doc):
    """Invariant 1: workspace-root-resolved paths carry the job's checkout root."""
    for job_id, job in (doc.get("jobs") or {}).items():
        steps = job.get("steps") or []
        root = checkout_root(steps)
        label = f"{name}:{job_id}"

        # `$/` actions resolve from this repo at the workflow's own commit, NOT
        # from the workspace, so they take no checkout-root prefix -- which is
        # why they are the form the lockfile can follow (gh actions-lock refuses
        # to lock a workspace-relative `./` action that uses remote actions).
        # Only existence needs proving, and it holds with or without a checkout.
        for step in steps:
            uses = step.get("uses", "")
            if uses.startswith("$/"):
                rel = uses[2:]
                if not any((repo / rel / f).is_file() for f in ("action.yml", "action.yaml")):
                    bad(f"{label}: same-repo action '{uses}' has no action.yml at {rel}/")
                else:
                    ok(f"{label}: same-repo action '{uses}' resolves")

        if not root:
            continue

        for step in steps:
            uses = step.get("uses", "")
            with_ = step.get("with") or {}

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
        doc = yaml.safe_load(text)
        check_matrix_keys(wf.name, doc, text)
        check_path_prefixes(repo, wf.name, doc)
        check_publishing_jobs_filter(wf.name, doc)
        check_dry_run_cannot_publish(wf.name, doc)

    if FAILS:
        print(f"\n{FAILS} assertion(s) FAILED", file=sys.stderr)
        return 1
    print("workflow_paths: all assertions passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
