# Post-mortem: how the Windows platform add got baroque

**Date:** 2026-07-27
**Scope:** issue #11, commits `832a21c`..`87b6e4d`
**Companion:** [2026-07-27-gha-matrix-simplification.md](2026-07-27-gha-matrix-simplification.md)
(the remediation)

Blameless. Every individual decision below was locally reasonable and well-argued in writing.
That is what makes this worth writing down — there is no careless step to point at.

## What we shipped vs. what the reference does

| | `executorch-runtime-dist` | `iree-runtime-dist` after #11 |
|---|---|---|
| Windows in CI | its own job, `build-windows`, literal matrix | a fifth row in the shared `build` matrix |
| `scripts/lib/variants.sh` | 11 lines, no platform axis | 78 lines, platform-aware, JSON serializer, loud-failure guard |
| `scripts/lib/naming.sh` | 6 lines | 78 lines (was 32 before #11) |
| Matrix construction | JSON literal in workflow `env:` | 30-line Python step in `setup`, emitting `{variant, platform, runner, toolchain}` triples |
| Toolchain branching | none — separate jobs | 8 `if: matrix.toolchain == …` step guards inside two shared jobs |
| `release.yml` | — | 363 → 494 lines |

The reference was named in the design doc. We still built the other thing.

## Timeline of the five decisions

1. **`810bf46` — add `platform_toolchain()`.** Design §1 (lines 63–71). Correct and necessary:
   `build_image_tag`/`build_dockerfile` derived from the platform token unconditionally, Windows
   has no Dockerfile, so a classifier was needed to make those two functions fail loudly. ~8 lines.
2. **`7ae532e` — make the variant list platform-aware.** Design §5 (lines 118–127). The
   load-bearing decision. Rationale as written: "`release.yml` fans out a full `variant × platform`
   cross-product, so adding the token would schedule an unbuildable `tsan`/`windows-x86_64` job."
3. **`8333494` — make `variants_json` fail loudly on a missing platform.** Correct hardening of
   the change in (2), which had introduced an argument that could be silently omitted.
4. **`a6d1e88` — reshape the release matrix into `{variant, platform, runner}` pairs.** Plan Task
   12a, whose own text (plan line 1041) reads: *"Since Task 4, `variants_json` requires a platform
   and this step **fails loudly by design** — 12a is what un-breaks it."*
5. **CLAUDE.md rewritten to document (2) and (1) as doctrine.** Pre-authorised in the design (line
   298: CLAUDE.md is edited "in the same change") and in plan Task 4 (line 408).

## Root cause

**The premise "Windows is a new row in the existing matrix" was never recorded as a decision, so
it was never reviewed.** Everything downstream was locally correct *given* that premise.

Grep the design doc, the plan, and all 40-odd commit messages for "separate job", "its own job",
`build-windows` — zero hits. The option was never on the table to be rejected.

## Five contributing factors

### 1. The reference was consulted as a fact oracle, never as a structural precedent

`executorch-runtime-dist` appears three times in the design doc, and two of the three uses are
exemplary:

- **§4 packaging** (line 106): ET "kept a single unbranched `tarball_name()` emitting `.tar.gz`" →
  used to *withdraw* our own "almost certainly `.zip` on Windows" assumption. Textbook.
- **Runner label** (line 37): ET pins `windows-2022` → adopted.

Every consultation was a lookup of a specific Windows fact. Nobody opened ET's `release.yml` and
read its *shape*. The answer was one `grep -n "strategy:"` away: a `build` job and a
`build-windows` job, `variants.sh` at 11 lines, `PLATFORMS` as a JSON literal in workflow `env:`.

### 2. The one structural reading of ET concluded it was the *less* rigorous repo

Design line 158, on relocatability: *"`executorch-runtime-dist` is the counter-example and should
be read accurately… **ET's shipped precedent therefore does not validate 'no absolute paths in
Windows archives.'** It clears a lower bar, deliberately."*

That paragraph is *correct* — ET's relocatability gate genuinely is functional rather than a
string scan, and genuinely does clear a lower bar on that axis. But it was the only place the
design engaged ET structurally, and having concluded "lower bar" there, the repo was implicitly
demoted from precedent to cautionary tale everywhere else. A finding about one axis silently
became a prior about the whole repo.

**The tell:** the same doc simultaneously treats ET as authoritative enough to overturn our
packaging assumption and as too lax to imitate. Those cannot both be defaults. Neither was
stated as a scope.

### 3. The option space was enumerated *within* the premise, not *across* it

Design §5's argument in full: platform-aware `known_variants`, *or* an `exclude:` block in YAML —
and `exclude:` "was rejected because CLAUDE.md requires the variant list be single-sourced and
never hardcoded in a workflow."

A two-item menu. Both items preserve "one matrix spans both toolchain classes." The rejection is
well-reasoned against the alternative it considered, which is exactly why it reads as thorough
and passed review.

### 4. CLAUDE.md was cited as a constraint, then rewritten to entrench the result

The ratchet, in order:

- CLAUDE.md's existing rule ("a variant list is never hardcoded in a workflow") was quoted to
  reject `exclude:`.
- The chosen design was then written *back into* CLAUDE.md as newly-justified doctrine — plan
  Task 4 (line 408) instructs recording that "the exclusion lives in `variants.sh` rather than an
  `exclude:` block so a variant list is never hardcoded in a workflow." Design line 298 does the
  same for `platform_toolchain`.

A rule authored for a narrower context (two variants, all Linux, list genuinely shared by three
consumers) was applied as an absolute to a case it was not written for, and the outcome became a
new rule. Without the simplification note, the next session would have read CLAUDE.md and
inherited all of it as settled.

### 5. A self-inflicted breakage was routed to the plan instead of to design review

Step (2) broke the `setup` job. Step (4) was a numbered task to un-break it, pre-authorised
before the breakage happened.

Plan Task 12a even says *"Do not silence it with a placeholder platform"* — the right instinct,
scoped one level too narrowly. It guarded against the cheap wrong fix and left the expensive
wrong fix (30 lines of Python building triples) as the sanctioned path. A design change that
breaks an existing component and requires a dedicated repair task is the design saying something;
here it got absorbed as planned work, and having a checkbox made it feel like progress.

### Bonus: a good abstraction put under the wrong load

`platform_toolchain` (factor-free, decision 1) was justified for a real internal invariant and is
~8 lines. It then became a matrix key and the branch condition for eight YAML step guards — not
because the classifier wanted that, but because a job spanning two toolchain classes needed
*something* to branch on and the classifier was the nearest thing available. The remediation note
keeps the function and demotes it back to an internal validator. The abstraction was never the
problem.

## What would have caught it

Five checks, ordered by cost.

1. **When a reference implementation is named, read its topology before you read its facts.**
   Thirty seconds: `grep -n "^  [a-z-]*:\|strategy:" <ref>/.github/workflows/release.yml`. If our
   job graph differs in shape from the reference's, that difference is a decision requiring an
   explicit written justification — not a thing to discover after shipping.

2. **State the reference's scope of authority up front, once.** "ET is authoritative for CI
   topology and packaging; its relocatability bar is lower than ours and we deliberately exceed
   it." Written down, factor 2 cannot happen: a finding on one axis can't leak into a prior about
   the whole repo.

3. **A rejected alternative implies at least three candidates, one of which challenges the
   premise.** Whenever a design section reads "X was rejected because," require a third option of
   the form *"restructure so the question doesn't arise."* Here that option was "split the job,"
   and it would have won on the spot.

4. **A design change that breaks an existing component escalates to design review, not to the
   plan.** If the fix needs its own numbered task, the design gets one more pass first. Cheap
   test, since it fires rarely.

5. **Guard the doctrine ratchet.** CLAUDE.md rewrites should not be a deliverable of the same
   plan that made the architectural choice they describe. Where they must be, the text records
   *what the rule protects* and *what was rejected*, so a later reader can reopen it — never just
   *what the current implementation is*, which is unfalsifiable and reads as settled law.

### Quantitative smell to watch

A platform add should mostly add **data**, not **axes**. `naming.sh` 32→78 and `variants.sh`
54→78 during a change billed as additive is the signal. Concretely: growth in a *shared* library
during a *platform* add means the new platform is being made to fit an existing structure that
does not fit it. Check the shared-lib diff before the workflow diff.

## Was any of it wasted?

Mostly no, and this is worth being fair about. The Windows work that matters — the MSVC build
path, static-CRT routing through the cache variable, COFF-aware relocatability, the
`/d1trimfile:` repairs, platform-conditional manifest provenance, the consumer gate on Windows —
is all sound, hard-won, and untouched by the remediation. Roughly one commit in six
(`810bf46`, `7ae532e`, `8333494`, `a6d1e88`, plus their tests and CLAUDE.md text) is the baroque
part. The remediation deletes machinery, not capability.

The real cost was **the shape it left for the next task**: the unimplemented Windows verify leg
(handoff plan §1) looked like "thread more `if: matrix.toolchain == 'runner'` branches through a
containerised job," which is why it was handed off rather than finished. Under the split it is a
job you write straight.

## Actions

- [ ] Execute the remediation in
      [2026-07-27-gha-matrix-simplification.md](2026-07-27-gha-matrix-simplification.md),
      including its step 8 (CLAUDE.md rewrite) — that step is what unwinds factor 4.
- [ ] Add checks 1–3 above to the design-doc habit for the next platform or variant add. The
      natural home is a short "reference implementations and their scope of authority" section at
      the top of any design doc that names one.
- [ ] When rewriting CLAUDE.md's "Variant matrix" and "Architecture" sections, state what each
      rule *protects* and name the alternative rejected, per check 5.
