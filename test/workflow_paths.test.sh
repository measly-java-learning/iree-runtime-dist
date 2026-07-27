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
# platform list is the same single source of truth the workflow uses. Only
# container platforms have a Dockerfile at all -- runner platforms (Windows)
# get their toolchain from a pinned CI image, not a build-push-action step.
PLATFORMS="$(. "$REPO/scripts/lib/naming.sh"; for p in $(known_platforms); do if [ "$(platform_toolchain "$p")" = container ]; then printf '%s ' "$p"; fi; done)"

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

# The setup job's `pairs` step is the single source of the {variant, platform,
# runner} list both the build and verify matrices fromJson() into via a bare
# `include:` (no cross-multiplying axis). Execute that step's shell exactly as
# CI would and assert the emitted list is exactly the five valid pairs -- not
# merely non-empty, and not merely "excludes tsan/windows-x86_64": this repo
# has shipped seven defects shaped like "a plausible-looking result instead of
# failing or acting," and a short list here (e.g. only the Windows pair, from
# a loop bug) is exactly that shape for a matrix.
setup_steps = wf["jobs"]["setup"]["steps"]
pairs_steps = [s for s in setup_steps if s.get("id") == "pairs"]
if len(pairs_steps) != 1:
    print(f"FAIL: expected exactly one setup step with id 'pairs', found {len(pairs_steps)}")
    sys.exit(1)
pairs_script = pairs_steps[0]["run"]

import subprocess, tempfile, json as jsonlib

with tempfile.NamedTemporaryFile(mode="w+", delete=False) as gh_out:
    gh_out_path = gh_out.name
try:
    proc = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", pairs_script],
        cwd=repo,
        env={**os.environ, "GITHUB_OUTPUT": gh_out_path},
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        print("FAIL: the setup job's `pairs` step exited non-zero when executed directly")
        print(proc.stdout)
        print(proc.stderr)
        sys.exit(1)
    with open(gh_out_path) as f:
        out = f.read()
finally:
    os.unlink(gh_out_path)

m = re.search(r"^list=(.*)$", out, re.MULTILINE)
if not m:
    print(f"FAIL: the `pairs` step produced no 'list=' GITHUB_OUTPUT line; got: {out!r}")
    sys.exit(1)
pairs = jsonlib.loads(m.group(1))

expected = [
    {"variant": "default", "platform": "linux-x86_64",   "runner": "ubuntu-latest",    "toolchain": "container"},
    {"variant": "tsan",    "platform": "linux-x86_64",   "runner": "ubuntu-latest",    "toolchain": "container"},
    {"variant": "default", "platform": "linux-aarch64",  "runner": "ubuntu-24.04-arm", "toolchain": "container"},
    {"variant": "tsan",    "platform": "linux-aarch64",  "runner": "ubuntu-24.04-arm", "toolchain": "container"},
    {"variant": "default", "platform": "windows-x86_64", "runner": "windows-2022",     "toolchain": "runner"},
]

def key(p):
    return (p["variant"], p["platform"])

got_set = {key(p) for p in pairs}
expected_set = {key(p) for p in expected}

if got_set != expected_set:
    print(f"FAIL: emitted pairs {sorted(got_set)} != expected {sorted(expected_set)}")
    sys.exit(1)
if len(pairs) != len(expected):
    print(f"FAIL: emitted {len(pairs)} pairs, expected exactly {len(expected)} (duplicates?): {pairs}")
    sys.exit(1)
if ("tsan", "windows-x86_64") in got_set:
    print("FAIL: tsan/windows-x86_64 pair present -- TSan is clang-only, MSVC has no equivalent")
    sys.exit(1)
for p in pairs:
    if p["platform"] == "windows-x86_64" and p["runner"] != "windows-2022":
        print(f"FAIL: windows-x86_64 runner is {p['runner']!r}, must be pinned 'windows-2022' (never windows-latest)")
        sys.exit(1)

got = {tuple(sorted(x.items())) for x in pairs}
exp = {tuple(sorted(x.items())) for x in expected}
if got != exp:
    print(f"FAIL: full pair objects (incl. runner) differ from expected.\n  got: {pairs}\n  expected: {expected}")
    sys.exit(1)

print(f"PASS: setup job emits exactly the {len(expected)} expected {{variant, platform, runner, toolchain}} pairs")

# The build job now runs two different toolchains off one matrix. The failure
# mode to guard against is not "Docker fails on Windows" (loud) but "the
# Windows leg has nothing left to do and the job goes green having built
# nothing" (silent). So assert BOTH directions:
#   - every Docker-dependent step is gated to the container toolchain, and
#   - the runner toolchain actually has a build step of its own.
build_steps = wf["jobs"]["build"]["steps"]

def gate(step):
    return str(step.get("if", ""))

docker_steps = [
    s for s in build_steps
    if "docker/" in s.get("uses", "") or "docker run" in s.get("run", "")
    or "$(build_image_tag" in s.get("run", "")
]
if not docker_steps:
    print("FAIL: no Docker-dependent steps found in the build job -- this check is inert")
    sys.exit(1)
ungated = [s.get("name") or s.get("uses") for s in docker_steps
           if "matrix.toolchain == 'container'" not in gate(s)]
if ungated:
    print(f"FAIL: Docker-dependent build steps not gated on the container toolchain: {ungated}")
    sys.exit(1)

runner_steps = [s for s in build_steps if "matrix.toolchain == 'runner'" in gate(s)]
if not any("build-runtime.sh" in s.get("run", "") for s in runner_steps):
    print("FAIL: no runner-toolchain step invokes build-runtime.sh -- the Windows "
          "leg would go green without building anything")
    sys.exit(1)

# Shared (ungated) steps run on every runner OS, where the default shell is
# pwsh on Windows. Any shared step whose `run` calls bash tooling must say so.
for s in build_steps:
    run = s.get("run", "")
    if gate(s) or not run:
        continue
    if run.lstrip().startswith("bash ") or "\nbash " in run:
        if s.get("shell") != "bash":
            print(f"FAIL: shared build step {s.get('name')!r} runs bash tooling "
                  f"but does not set `shell: bash`; on Windows it would run under pwsh")
            sys.exit(1)

print(f"PASS: build job gates {len(docker_steps)} Docker steps on the container "
      f"toolchain and has a real runner-toolchain build step")
PY
