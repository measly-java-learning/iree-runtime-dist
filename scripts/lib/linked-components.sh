#!/usr/bin/env bash
# Third-party components ACTUALLY LINKED into the shipped artifact. Source me.
#
# Deliberately NOT IREE_REQUIRED_SUBMODULES. That list is a checkout gate: IREE's
# check_submodule_init.py --runtime_only demands all 11 paths in
# runtime_submodules.txt be initialized regardless of what the build uses. Most are
# never linked into a local-sync/local-task CPU runtime, and shipping a license
# notice for an unlinked component misrepresents what the artifact contains --
# the same error as claiming LLVM, which IREE_BUILD_COMPILER=OFF excludes entirely.
#
# Determined empirically by inspecting the built archives and the CMake export set
# (see Task 8 Step 3 / task-8-report.md). Method used, in order of confidence:
#   1. Transitive closure of INTERFACE_LINK_LIBRARIES starting from the targets a
#      downstream consumer actually links (iree_runtime_impl / iree_runtime_unified)
#      in out/lib/cmake/IREE/IREETargets-Runtime.cmake.
#   2. Cross-checking each candidate component's defined symbols (nm -u / nm on the
#      .a) against every other installed archive's undefined-symbol list, to see
#      whether anything outside the component actually calls into it.
#
# Results:
#   flatcc      - flatcc_parsing is directly link-reachable from iree_runtime_impl
#                 (via iree_base_internal_flatcc_parsing) and its symbols
#                 (flatcc_verify_*) are referenced from libflatcc_parsing.a's
#                 consumers. flatcc_runtime (the builder half) is declared but not
#                 reachable from the runtime target and contributes no referenced
#                 symbols -- only flatcc_parsing (the verifier) is actually used at
#                 runtime. One license covers both halves of the same submodule.
#   printf      - printf_printf is directly in iree_base_base's
#                 INTERFACE_LINK_LIBRARIES (link-reachable), and its symbols
#                 (vfctprintf, vsnprintf_) are referenced as undefined symbols from
#                 libiree_base_base.a and present in the merged libiree_runtime_unified.a.
#   libbacktrace - libbacktrace_libbacktrace is directly in iree_base_base's
#                 INTERFACE_LINK_LIBRARIES (link-reachable) -- this is the target
#                 build-runtime.sh had to hand-define because upstream never
#                 exports it. No compiled object in this configuration currently
#                 calls into it (IREE_ENABLE_LIBBACKTRACE-gated code path is a
#                 stub here), so it contributes zero bytes to any archive today,
#                 but it is a mandatory link dependency: omitting its notice would
#                 misrepresent the artifact's build-time dependency surface, and a
#                 downstream consumer's link line unconditionally references it.
#
#   benchmark   - REJECTED. `benchmark`'s symbols (InitializeStreams,
#                 RegisterBenchmarkInternal, etc.) are referenced only from
#                 libiree_testing_benchmark.a, a sibling test-tool archive that is
#                 NOT in iree_runtime_impl/iree_runtime_unified's transitive
#                 INTERFACE_LINK_LIBRARIES closure. A consumer linking only
#                 iree::runtime::unified never pulls in benchmark. Physically
#                 present in out/lib (the export set installs everything), but not
#                 linked into the shipped runtime target.
#   musl        - REJECTED, and rejected for a third reason distinct from the two
#                 below: it IS installed (libiree_builtins_musl_bin_libmusl.a) but
#                 nothing references it. The archive defines 4 symbols --
#                 iree_builtins_libmusl_create plus two embedded wasm bitcode blobs
#                 as rodata (file_0/file_1) and a toc -- and they appear as
#                 undefined symbols in zero other archives, including
#                 libiree_runtime_unified.a; it is likewise absent from
#                 iree_runtime_impl's INTERFACE_LINK_LIBRARIES closure. It is a
#                 container for precompiled device-side builtins, not code linked
#                 into a CPU runtime. Called out explicitly because musl IS one of
#                 the 11 IREE_REQUIRED_SUBMODULES and IS physically present in
#                 out/lib, so an auditor who finds the archive but no notice needs
#                 to find the reason here. Verified identically on linux-x86_64 and
#                 on Windows (see spike/windows-iree-runbook.md, W4).
#   tracy, spirv_cross, vulkan_headers, webgpu-headers, hip-build-deps,
#   hsa-runtime-headers, googletest, llvm-project - REJECTED. No archive, no
#   symbol, in out/lib at all; confirmed absent by both `ls out/lib/*.a` and
#   `nm -o out/lib/*.a` (the only hits for these substrings are IREE's own
#   flatbuffer schema target names, e.g. vulkan_executable_def_c_fbs).
#
# When the driver/loader set changes, re-run that inspection -- this list is not
# derivable from the build flags alone.
IREE_LINKED_COMPONENTS="flatcc printf libbacktrace"

linked_components() { printf '%s' "$IREE_LINKED_COMPONENTS"; }
