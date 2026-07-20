#!/usr/bin/env bash
# The minimal IREE submodule set a runtime-only build needs. Single source of truth.
#
# Determined empirically (see .superpowers/sdd/task-1-report.md, Task 1):
# with -DIREE_BUILD_COMPILER=OFF, IREE's own CMakeLists.txt runs
# build_tools/scripts/git/check_submodule_init.py --runtime_only on every fresh
# configure, and that script hard-requires every path listed in
# build_tools/scripts/git/runtime_submodules.txt to be initialized -- regardless
# of which HAL drivers/loaders are actually enabled. This is the full list from
# that file at v3.11.0 (~100 MB total). third_party/llvm-project (2.6 GB) is
# NOT in it and is not needed. CI must use `submodules: false` plus an explicit
# init of this list -- never `recursive`.
IREE_REQUIRED_SUBMODULES="third_party/benchmark third_party/flatcc third_party/googletest third_party/hip-build-deps third_party/hsa-runtime-headers third_party/musl third_party/printf third_party/spirv_cross third_party/tracy third_party/vulkan_headers third_party/webgpu-headers"

required_submodules() { printf '%s' "$IREE_REQUIRED_SUBMODULES"; }
