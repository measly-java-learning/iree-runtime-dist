# Task 0 spike result — TSan runs clean in CI, no ASLR workaround needed

**Date:** 2026-07-23 (run 29977133170 on `main`)
**Closes:** spec §7 blocking spike; unblocks plan Tasks 6, 8, 9.

## Question

Does a `-fsanitize=thread` binary run reliably in an unprivileged container on a
GitHub-hosted runner, given the `unexpected memory mapping` failures observed locally?

## Result — the premise was wrong, and in our favor

Measured on a real GitHub-hosted runner (kernel `6.17.0-1020-azure`), 200 runs of the toy
race in the project's own toolchain image (clang 21.1.8, manylinux_2_28):

```
DEFAULT (mmap_rnd_bits=28): ok=200 mapfail=0 / 200
LOWERED (mmap_rnd_bits=28): ok=200 mapfail=0 / 200
```

**The GitHub-hosted runner already defaults to `vm.mmap_rnd_bits=28`, not 32.** TSan ran
clean 200/200 with NO fix applied. The `sudo sysctl -w vm.mmap_rnd_bits=28` step was a
no-op (already 28).

The ~65% `unexpected memory mapping` failure rate measured during design was **specific to
the local dev host**, which runs `mmap_rnd_bits=32`. The spec's assumption that
GitHub-hosted Ubuntu runners ship 32 was incorrect — corrected in spec §2/§7.

(Note: reading `/proc/sys/vm/mmap_rnd_bits` as the runner user is `Permission denied`; it
reads fine as root inside the container. The 28 value above is the in-container read.)

## Decision for the gate (Task 6)

- **Gate B is viable in CI as designed** — no workaround required at the current runner default.
- **Keep an idempotent `sudo sysctl -w vm.mmap_rnd_bits=28` step in the verify job anyway**, as
  cheap belt-and-suspenders insurance: it is a no-op today (already 28) but makes the TSan gate
  robust if a future runner image ever raises the default to 32 (as some Ubuntu 24.04 images
  historically did). The gate must not silently start flaking on a runner-default change.
- The B-vs-C (suppressions) question is unchanged and still resolved empirically in Task 9 by
  running the real IREE tsan build under the gate.

## Cache bonus (answers the warm-cache question, same-ref)

The image build read the `main`-scope GHA cache and restored the toolchain layer:
`#5 importing cache manifest from gha:...` → `#6 [2/2] RUN dnf install ... → #6 CACHED`.
So the `warm-build-image` cache is readable and non-empty on the default branch. This is the
same-ref (main→main) read; the main→tag fallback (issue #1) still awaits a real release tag.

## Cleanup

The throwaway `.github/workflows/spike-tsan-aslr.yml` is deleted in the same commit as this note.
