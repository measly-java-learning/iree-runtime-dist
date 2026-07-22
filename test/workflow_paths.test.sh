#!/usr/bin/env bash
# Hermetic: assert every workspace-relative path release.yml hands to an action
# actually resolves, given the job's own checkout layout.
#
# This exists because `uses:` steps ignore `working-directory` and resolve paths
# against the workspace root, not the repo root. A job that checks out to
# `path: dist` must say `dist/docker`, and nothing in actionlint or a YAML
# schema catches the difference -- only an actual run does, minutes in.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WF="${1:-$REPO/.github/workflows/release.yml}"

# The build-image Dockerfile path is no longer a literal `with: file:` -- it is
# computed per-platform into $GITHUB_ENV (BUILD_DOCKERFILE) and passed as
# ${{ env.BUILD_DOCKERFILE }}, which the action-path check below skips. The
# platform list is the same single source of truth the workflow uses.
PLATFORMS="$(. "$REPO/scripts/lib/naming.sh"; known_platforms | tr '\n' ' ')"

python3 - "$WF" "$REPO" "$PLATFORMS" <<'PY'
import sys, os, re, yaml

wf_path, repo, platforms = sys.argv[1], sys.argv[2], sys.argv[3].split()
with open(wf_path) as f:
    wf = yaml.safe_load(f)

# Keys whose values name a path in the workspace. Only actions are listed:
# `run:` steps honour working-directory, so their paths are not checkable here.
PATH_KEYS = {
    "docker/build-push-action": ("context", "file"),
}

failures = []
checked = 0

for job_name, job in wf.get("jobs", {}).items():
    # Where does this job put the repo? Default is the workspace root ("").
    # A job may check out several repos; only our own (no `repository:`, or
    # this repo by name) defines where our files land.
    roots = []
    for step in job.get("steps", []):
        uses = step.get("uses", "")
        if not uses.startswith("actions/checkout@"):
            continue
        with_ = step.get("with") or {}
        if with_.get("repository"):
            continue  # a foreign repo, not the source of our paths
        roots.append(with_.get("path", ""))
    root = roots[0] if roots else ""

    # BUILD_DOCKERFILE is computed in a run step as
    #   echo "BUILD_DOCKERFILE=<prefix>$(build_dockerfile "$PLATFORM")"
    # and later consumed as ${{ env.BUILD_DOCKERFILE }} by build-push-action,
    # which resolves it against the workspace root exactly like `context`. So
    # its literal <prefix> must equal this job's checkout root, and the file it
    # names must exist for every known platform. This is the same wrong-root
    # bug class as `context`, just one indirection removed.
    for step in job.get("steps", []):
        run = step.get("run", "")
        m = re.search(r'BUILD_DOCKERFILE=([^\n"]*)\$\(build_dockerfile', run)
        if not m:
            continue
        prefix = m.group(1).rstrip("/")   # "" or "dist"
        if prefix != root:
            failures.append(
                f"{job_name}: BUILD_DOCKERFILE prefix {prefix!r} != this job's "
                f"checkout root {root!r} -- build-push resolves it against the "
                f"workspace root, so it would point outside the repo"
            )
            continue
        for plat in platforms:
            rel = os.path.join("docker", f"{plat}.Dockerfile")
            checked += 1
            if not os.path.exists(os.path.join(repo, rel)):
                failures.append(
                    f"{job_name}: BUILD_DOCKERFILE for {plat} resolves to "
                    f"{rel!r}, which does not exist in the repo"
                )

    for step in job.get("steps", []):
        uses = step.get("uses", "")
        action = uses.split("@")[0]
        keys = PATH_KEYS.get(action)
        if not keys:
            continue
        with_ = step.get("with") or {}
        for key in keys:
            val = with_.get(key)
            if not val or "${{" in val:
                continue
            checked += 1
            # The workspace path the runner will resolve...
            if root and not val.startswith(root + "/"):
                failures.append(
                    f"{job_name}: {action} {key}: {val!r} is not under this "
                    f"job's checkout path {root!r}/ -- the runner resolves it "
                    f"against the workspace root, where it does not exist"
                )
                continue
            # ...maps back to this repo-relative path on disk.
            rel = val[len(root) + 1:] if root else val
            if not os.path.exists(os.path.join(repo, rel)):
                failures.append(
                    f"{job_name}: {action} {key}: {val!r} resolves to "
                    f"{rel!r}, which does not exist in the repo"
                )

if checked == 0:
    print("FAIL: no action path arguments were checked -- the test is inert")
    sys.exit(1)

for f in failures:
    print(f"FAIL: {f}")
if failures:
    sys.exit(1)
print(f"PASS: workflow_paths ({checked} action path arguments resolve)")
PY
