#!/usr/bin/env python3
"""Emit manifest.json for a staged iree-runtime-dist prefix.

Every value arrives as a positional argument and is never interpolated into
source: a value containing a quote or backslash (e.g. an unusual path) could
otherwise break the parse or smuggle content into the JSON. Keeping this a real
script makes that property structural rather than comment-enforced.

One deliberate exception to the argv discipline: build_config (and the fields
derived from it -- crt, sanitizer -- plus cmake_version) are READ from the build
tree's CMakeCache.txt rather than passed in. That is the whole point of Task 5:
provenance observes what the build actually did instead of reconstructing it
from the arguments that drove the build. The argv-discipline property still
holds for the shell-known values; the cache is the one authority for the
build-known ones.
"""

import json
import os
import sys


def read_cache(build_dir):
    """Return (declared_config, cmake_version) from a build tree's CMakeCache.txt.

    The cache is the one authority for what the build actually did. Filtering is
    by KEY NAME, taken from the IREE_DIST_DECLARED_KEYS entry the cache-init
    files register -- never by entry type. A command-line -D override wins over
    a cache-init set() and resets the entry's type to UNINITIALIZED, so a
    type-based filter would silently drop exactly the keys that differ from what
    we declared, which is the only interesting case.
    """
    entries = {}
    path = os.path.join(build_dir, "CMakeCache.txt")
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith(("#", "//")):
                    continue
                name, sep, value = line.partition("=")
                if not sep or ":" not in name:
                    continue
                key, _, _type = name.partition(":")
                # First occurrence wins, matching CMake's own read order.
                entries.setdefault(key, value)
    except OSError as exc:
        raise SystemExit(f"error: cannot read {path}: {exc}") from None

    declared = entries.get("IREE_DIST_DECLARED_KEYS", "")
    keys = [k for k in declared.split(";") if k]
    if not keys:
        raise SystemExit(
            f"error: {path} has no IREE_DIST_DECLARED_KEYS -- was it configured "
            "with this recipe's cmake -C files?"
        )
    missing = [k for k in keys if k not in entries]
    if missing:
        raise SystemExit(
            "error: keys declared but absent from the cache: " + ", ".join(missing)
        )

    version = ".".join(
        entries.get(f"CMAKE_CACHE_{part}_VERSION", "?")
        for part in ("MAJOR", "MINOR", "PATCH")
    )
    return {k: entries[k] for k in keys}, version


def normalize_paths(config, roots):
    r"""Rewrite build-machine roots inside cache VALUES to stable tokens.

    build_config is observed from the cache, but two of its entries are
    path-dependent by construction: cmake/gnu-toolchain.cmake composes
    -ffile-prefix-map=$IREE_SRC=iree and cmake/windows-x86_64.cmake composes
    -d1trimfile:$IREE_SRC_NATIVE\. manifest.json and BUILDINFO both ship inside
    the prefix, so publishing those verbatim puts the builder's source root in a
    shipped file -- which scripts/relocatability.sh asserts against, correctly.

    This is the repair being extended, never the assertion being weakened. The
    rewrite is total and mechanical: only the source and build roots are
    touched, every flag keeps its shape, and the token says a path was
    normalized rather than pretending a different value was used.

    `roots` is (needle, token) pairs. Longest needle first, so a build tree
    nested inside the source root cannot be half-rewritten by the shorter one.
    Windows needs both slash styles: cl.exe and CMake disagree about which they
    emit, and a literal replace matches neither spelling of the other.
    """
    pairs = []
    for needle, token in roots:
        if not needle:
            continue
        pairs.append((needle, token))
        if "\\" in needle:
            pairs.append((needle.replace("\\", "/"), token))
    pairs.sort(key=lambda p: len(p[0]), reverse=True)

    out = {}
    for key, value in config.items():
        # Every value is scanned, but only the roots are rewritten, so
        # CMAKE_C_COMPILER / CMAKE_CXX_COMPILER survive intact -- a toolchain
        # path is not a root. That is deliberate and must stay true: their
        # absolute value is the point, provenance naming the exact compiler on
        # the build image (the resolved cl.exe, per cmake/windows-x86_64.cmake's
        # find_program REQUIRED). It is a path on the builder, not one the
        # artifact asks a consumer to resolve. Never add a toolchain prefix to
        # `roots`.
        for needle, token in pairs:
            value = value.replace(needle, token)
        out[key] = value
    return out


(
    _,
    out_path,
    variant,
    platform,
    iree_version,
    iree_tag,
    runtime_commit,
    runtime_dist_commit,
    compiler_version,
    glibc_build,
    clang_version,
    vm_bytecode_version,
    msvc_toolset,
    build_dir,
    iree_src,
    iree_src_native,
) = sys.argv

build_config, cmake_version = read_cache(build_dir)

# Observed, then path-normalized: the path-dependent flag entries would
# otherwise ship the builder's source root inside manifest.json and BUILDINFO.
# See normalize_paths' docstring. iree_src_native is empty on linux-*, where
# there is no second spelling of the path; normalize_paths skips empty needles.
build_config = normalize_paths(
    build_config,
    [
        (iree_src, "@IREE_SOURCE_ROOT@"),
        (iree_src_native, "@IREE_SOURCE_ROOT@"),
        (build_dir, "@IREE_BUILD_DIR@"),
    ],
)

# sanitizer and crt are read from the NORMALIZED config deliberately: neither
# looks at a path, and reading one dict rather than two removes any chance of
# the manifest's published build_config and its derived fields disagreeing.
sanitizer = (
    "thread" if "-fsanitize=thread" in build_config.get("CMAKE_C_FLAGS", "") else ""
)

crt = ""
if platform.startswith("windows-"):
    _rt = build_config.get("CMAKE_MSVC_RUNTIME_LIBRARY", "")
    crt = {"MultiThreaded": "MT", "MultiThreadedDLL": "MD"}.get(_rt, "")
    if not crt:
        raise SystemExit(
            "error: windows platform requires CMAKE_MSVC_RUNTIME_LIBRARY to be "
            "MultiThreaded or MultiThreadedDLL in CMakeCache.txt (got "
            + (_rt or "<absent>")
            + ")"
        )

manifest = {
    "schema_version": 2,
    "variant": variant,
    "platform": platform,
    "iree_version": iree_version,
    "iree_tag": iree_tag,
    "runtime_commit": runtime_commit,
    "runtime_dist_commit": runtime_dist_commit,
    "iree_compile_version": compiler_version,
    "cmake_version": cmake_version,
    "vm_bytecode_version": vm_bytecode_version,
    "build_config": build_config,
    "notes": {
        "compiler": (
            "The IREE compiler is out of contract: built with "
            "IREE_BUILD_COMPILER=OFF and never shipped. Install "
            "iree-base-compiler==" + compiler_version + " to produce loadable "
            ".vmfb files."
        ),
        "pip_runtime_wheel": (
            "The pip iree-base-runtime wheel is NOT linkable at any version -- "
            "no headers, no static libs. Only a from-source build or this dist "
            "yields a linkable runtime."
        ),
        "vm_bytecode_version": (
            "IREE_VM_BYTECODE_VERSION_MAJOR.MINOR from the shipped runtime's "
            "own iree/vm/bytecode/utils/isa.h -- the value the VM bytecode "
            "verifier checks a loaded .vmfb against. A .vmfb compiled by a "
            "mismatched compiler version fails to load with a VM import "
            "signature mismatch; compare this field before loading one built "
            "elsewhere."
        ),
        "cmake_version": (
            "The CMake that configured this build, read from the build tree's "
            "own CMakeCache.txt. CMake is deliberately NOT pinned: a NEVRA pin "
            "is possible in the container but GitHub owns the windows-2022 "
            "runner's CMake, and pinning only one platform would hide risk "
            "rather than reduce it. This field is the mitigation -- it answers "
            "'which CMake built this artifact' for a shipped tarball, which a "
            "Dockerfile pin cannot do for the Windows half at all."
        ),
        "build_config": (
            "The cache entries this recipe's cmake -C files declared, read back "
            "from the build tree's own CMakeCache.txt -- what the build actually "
            "used, not a reconstruction from the arguments that drove it. One "
            "mechanical edit is applied: the build machine's IREE source root "
            "and build directory are rewritten to @IREE_SOURCE_ROOT@ and "
            "@IREE_BUILD_DIR@, because the compiler-flag entries embed them "
            "(-ffile-prefix-map on clang, -d1trimfile on MSVC) and a published "
            "artifact carries no build-machine paths. Values are otherwise "
            "verbatim; a value here can differ from the cache only in those two "
            "roots."
        ),
        "runtime_dist_commit": (
            "The iree-runtime-dist commit that produced this artifact -- every "
            "repair, the packaging, and the whole recipe come from that repo. A "
            "'-dirty' suffix means the build ran from an uncommitted working "
            "tree, which only ever happens for hand builds; CI is always clean."
        ),
    },
}

if sanitizer:
    manifest["sanitizer"] = sanitizer
    manifest["notes"]["sanitizer"] = (
        "This variant is built with -fsanitize=" + sanitizer + ". The umbrella "
        "target propagates the sanitizer flag as an INTERFACE option, so linking "
        "it instruments the whole consumer program. See share/iree-runtime-dist/"
        "TSAN.md for how to run it (ASLR/mmap_rnd_bits) and any suppressions."
    )

# Provenance keys are platform-conditional: a Windows artifact has no glibc,
# and a container-built Linux artifact has no MSVC toolset/CRT. Absence of
# the inapplicable key is the honest encoding -- a "n/a" sentinel would invite
# reading it as "no glibc requirement" rather than "wrong provenance model".
if platform.startswith("linux-"):
    manifest["glibc_build"] = glibc_build
    manifest["notes"]["glibc_build"] = (
        "glibc_build is the glibc version of the container these static "
        "archives were compiled against, NOT a detected minimum/floor -- "
        "static archives carry unversioned undefined libc symbols, so the "
        "consumer's own final link is what actually resolves glibc symbol "
        "versions. Do not read this as a guarantee of compatibility with "
        "any glibc older than the value recorded here."
    )
    manifest["clang_version"] = clang_version
    manifest["notes"]["clang_version"] = (
        "clang_version is the clang that compiled these archives, from the "
        "compiler's own banner. Provenance, not a compatibility claim -- the "
        "same standard as msvc_toolset on windows-*."
    )
elif platform.startswith("windows-"):
    manifest["msvc_toolset"] = msvc_toolset
    manifest["crt"] = crt
    manifest["notes"]["msvc_toolset"] = (
        "msvc_toolset is the cl.exe version these archives were compiled "
        "with, on a PINNED runner image (windows-2022). It is provenance, "
        "not a compatibility claim."
    )
    manifest["notes"]["crt"] = (
        "crt is the C runtime model these archives were compiled with (MT = "
        "static). The archives carry only /DEFAULTLIB:LIBCMT directives; the "
        "CRT itself is resolved at the consumer's final link, not embedded "
        "here. This is NOT a compatibility floor -- it is the CRT a consumer "
        "must match to avoid a mixed-CRT link."
    )

try:
    with open(out_path, "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")
except OSError as exc:
    raise SystemExit(f"error: cannot write {out_path}: {exc}") from None
