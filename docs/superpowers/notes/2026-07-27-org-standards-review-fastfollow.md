# Fast-follow: org-wide standards review

**Date recorded:** 2026-07-27
**Status:** deferred — **gated on shipping Windows** (handoff plan §1, then the matrix
simplification). Do not start before that.
**Scope:** all `measly-java-learning` repos, not just the two `*-runtime-dist` instances.

## The idea

One project extends the frontier; the associated projects learn from it. That transfer is
currently manual, ad hoc, and — per the
[Windows add post-mortem](2026-07-27-windows-add-postmortem.md) — unreliable even when the
reference is explicitly named in a design doc. The frontier repo advances, the lesson does not
propagate, and the next repo re-derives a worse version of a solved problem.

Some divergence between repos is defensible and should survive the review. The bar is not
uniformity; it is that **no two repos should be so different that a lesson from one cannot be
carried into the other**. Divergence that blocks transfer is the defect.

## Why this is the right follow-up, and why it waits

The post-mortem's root cause was that a named reference implementation was consulted for facts
but never for structure. Its remedies (read the reference's topology first; declare a reference's
scope of authority; require a premise-challenging third option) are habits for *one* design doc.
This review is the structural version: make the transfer cheap enough that it happens by default
rather than by discipline.

It waits because the Windows work is the live frontier extension. Standardising mid-flight would
codify the shape we are about to remediate — the exact ratchet the post-mortem identified.

## Current landscape (surveyed 2026-07-27)

Org `measly-java-learning`:

| Repo | Kind | Workflows | `scripts/lib` | `test/` | `CLAUDE.md` | `docs/superpowers` |
|---|---|---|---|---|---|---|
| `iree-runtime-dist` | producer | `release.yml` (22K), `warm-build-image.yml` | yes | yes | 13.5K | yes |
| `executorch-runtime-dist` | producer | `release.yml` (12.4K), `extras-gate.yml` | yes | yes | 8.5K | yes |
| `djl-iree-engine` | consumer | `native-build{,-job}.yml`, `publish.yml`, `dependency-submission.yml` | — | — | **absent** | yes |
| `.github` | org defaults | — (only `profile/README.md`) | — | — | — | — |

Outside the org, same family: `corey-cole/djl-executorch-engine` (consumer; same four workflow
filenames as `djl-iree-engine`, `CLAUDE.md` present at 10.7K).

Three observations that fall out of the table alone, before any real review:

1. **Two families, two shapes.** The producers share a shape (`scripts/lib` + `test/` + a release
   pipeline). The consumers share a *different* shape (four identically-named workflows). Within
   each family the pairing is clearly copy-derived — and has drifted:
   `djl-iree-engine/native-build-job.yml` is 3.4K against `djl-executorch-engine`'s 9.3K, same
   filename, same job. That drift is the transfer failure made visible.
2. **`djl-iree-engine` has no `CLAUDE.md`** while its sibling has 10.7K of one. Whatever was
   learned writing the ExecuTorch engine is not available to an agent working the IREE engine.
3. **The org `.github` repo is empty** beyond a profile README. It is the natural home for
   reusable workflows, shared actions, and org-level defaults, and it is currently doing none of
   that.

`djl-executorch-engine` sitting under a personal account rather than the org is a governance
inconsistency to resolve as part of this, since org-level defaults do not reach it.

## Candidate standards to evaluate

Not decisions — the input list for the review. Each needs a "defensible difference?" ruling.

**CI topology**
- One job per toolchain class; never one matrix spanning container and runner toolchains
  (the post-mortem's central lesson, and the thing `executorch-runtime-dist` already got right).
- Platform/variant enumeration as a JSON literal in workflow `env:`, or discovered from disk —
  never an enumeration function in a shared shell library.
- Pinned runner labels (`windows-2022`, never `windows-latest`) wherever the toolchain version is
  attested provenance.
- Composite actions for boilerplate shared across jobs, which is what makes the job split
  affordable (`executorch-runtime-dist/.github/actions/` is the working example).
- Reusable workflows hosted in the org `.github` repo, where a standard genuinely is shared.

**Repo scaffolding**
- `CLAUDE.md` present in every repo, with an agreed section skeleton (what this repo is / key
  commands / hard constraints / architecture / conventions).
- `docs/superpowers/{specs,plans,notes}` layout — already consistent across all four, so likely
  a keeper to ratify rather than change.
- A hermetic `test/run.sh` needing no build, plus a separate acceptance gate.

**Producer/consumer contract**
- Asset naming, pin-file generation, and attestation verification are a contract *between* the
  producer and consumer repos. Divergence here is the most expensive kind and the highest-value
  thing to standardise.

**Doc discipline (from the post-mortem)**
- A "reference implementations and their scope of authority" section in any design doc that
  names one.
- CLAUDE.md text records what a rule *protects* and what was rejected, never just what the
  current implementation is.

## Method sketch

1. Survey each repo's workflows, scripts, tests, and CLAUDE.md against the candidate list.
   Record, per axis: same / drifted / deliberately different.
2. For each **drifted** axis, decide which repo holds the better version and why. Drift is the
   target; identical-and-worse is a separate, lesser problem.
3. For each **deliberately different** axis, write the one-line justification. If none can be
   written, reclassify as drift.
4. Land the agreed standards where they are enforceable — org `.github` reusable workflows and
   composite actions first, a short written standard second, per-repo `CLAUDE.md` last.
5. Backfill `djl-iree-engine`'s `CLAUDE.md` and resolve `djl-executorch-engine`'s org membership.

Expect step 2 to be most of the work and step 3 to be the most valuable output: an explicit,
short list of sanctioned differences is what stops the next review from re-litigating them.

## Not in scope

The many non-org workspace repos (`djl-demo`, `iree-build`, scratch and dataset repos). This is
about the four-repo production family and the contract between its halves.
