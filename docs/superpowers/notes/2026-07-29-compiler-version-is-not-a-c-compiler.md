# `compiler_version` is the IREE compiler, not a C compiler

**Date:** 2026-07-29
**Why this note exists:** there is a TODO comment in `.github/workflows/release.yml` that
prescribes the wrong fix, based on a natural misreading of this name. Anyone acting on that comment
would move a value that has no business moving. Recording the correction so it is not rediscovered
the hard way.

## The misreading

`compiler_version` sounds like it names the C compiler — `clang` on Linux, `cl` on Windows. It does
not. It is the **`iree-base-compiler` pip wheel version**: the IREE compiler that produces `.vmfb`
bytecode. It has nothing to do with the toolchain that compiles the archives.

The TODO currently in `release.yml` (around the `build` job) proposes:

```
# It should be a 5 line setup in `build-runtime`:
# if compiler is clang:
#  compiler_version=$(clang --version)
# else:
#  compiler_version=$(whatever nonsense is required to get version from cl)
```

That would replace an ABI-pairing version with a toolchain version under the same key, silently
breaking `add.vmfb` compilation and the manifest's pairing guarantee. **Delete this comment; do not
implement it.**

## What the value actually is and does

`scripts/derive-version.sh` is the whole computation — a regex on the release tag and two string
chops, no toolchain involved:

```
v3.11.0-10  ->  IREE_VERSION=3.11.0 / IREE_TAG=v3.11.0 / COMPILER_VERSION=3.11.0
```

It is `compiler_version` because v1 anchors on IREE *stable* releases, where the pip compiler
version equals the runtime version. That identity is what makes ABI pairing correct by
construction, and it is why `derive-version.sh` stays trivial (tracking `main` would key on a
nightly and require resolving it to a commit — deliberately not done).

Three consumers, all wanting the wheel version:

| Consumer | Use |
|---|---|
| `scripts/gen-addvmfb.sh:61` | `pip install iree-base-compiler==$COMPILER_VERSION` to compile `add.vmfb` |
| `scripts/gen-manifest.sh:138` | the manifest's `iree_compile_version` field |
| `scripts/gen-tsan-docs.sh` | the `@COMPILER_VERSION@` substitution |

## The C toolchain version is already done the way that TODO wants

The instinct behind the comment is right; it is just aimed at the wrong value. Toolchain version
detection already lives in the build path, ~5 lines, no matrix plumbing — `gen-manifest.sh:60`:

```bash
MSVC_TOOLSET="$(cl 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
[ -n "$MSVC_TOOLSET" ] || MSVC_TOOLSET="unknown"
```

Same shape as `GLIBC_BUILD`. Detected where the compiler lives, at build time, from the tool's own
banner. That is the house pattern and it is already in place.

## Real gap this uncovered

**No clang version is recorded anywhere.** Linux manifests carry `glibc_build`; Windows manifests
carry `msvc_toolset`; the compiler that actually built the Linux archives is attested only
indirectly, via the pinned NEVRAs in `docker/<platform>.Dockerfile`. If symmetry with
`msvc_toolset` is wanted, that is the missing five lines — `clang --version | head -1`, parsed in
the same block, `linux-*`-conditional. Provenance, not a compatibility claim, same honesty standard
as the neighbours.

## Actions

- [ ] Delete the misleading TODO in `release.yml`. It is in uncommitted WIP as of this note.
- [ ] Rename `compiler_version` -> `iree_compiler_version` (and `COMPILER_VERSION` ->
      `IREE_COMPILER_VERSION`) across `derive-version.sh`, `release.yml`, `gen-addvmfb.sh`,
      `gen-manifest.sh`, `gen-tsan-docs.sh`, and `build-runtime.sh`. Mechanical, and it kills the
      misreading permanently. **Do not** rename the manifest's published `iree_compile_version`
      JSON key — it is already unambiguous and it is schema surface.
- [ ] Consider dropping the `setup` job output entirely: `build-runtime.sh:217` already does
      `COMPILER_VERSION="${COMPILER_VERSION:-$IREE_VERSION}"`, deriving it from `git describe` on
      the IREE checkout, which is redundant with the env pass in every case v1 supports. The
      counter-argument is that the env pass makes the *release tag* authoritative over whatever the
      container's checkout describes as — a real belt-and-braces on provenance. Decide, don't drift.
- [ ] Record a `clang` version for `linux-*` manifests, alongside `msvc_toolset`.

`iree_version` / `iree_tag` must stay `setup` outputs regardless — the release is named by the tag,
and the build cannot know it. See
[2026-07-29-package-port-regime.md](2026-07-29-package-port-regime.md) idiom 4 for the related
`iree_tag` reconstruction defect.
