# Shared clang/GNU-style toolchain configuration for every non-MSVC platform.
# Included by cmake/linux-x86_64.cmake and cmake/linux-aarch64.cmake; a future
# macOS platform file would include it too, which is the point of splitting it
# out from the platform files rather than duplicating it.
#
# Naming the compiler explicitly is what keeps a stray gcc on the build image
# from being picked up. The container Dockerfile pins the clang/lld NEVRAs; this
# selects them.
include("${CMAKE_CURRENT_LIST_DIR}/dist-set.cmake")

dist_set(CMAKE_C_COMPILER   clang   STRING "")
dist_set(CMAKE_CXX_COMPILER clang++ STRING "")

# -ffile-prefix-map keeps __FILE__ (which IREE embeds in status strings) and
# DWARF DW_AT_comp_dir relative, so published artifacts carry no build-machine
# paths. clang/gcc-only; cl.exe does not understand it, which is why this lives
# here and not in common.cmake.
#
# $ENV{IREE_SRC} is the container-internal source path, exported by
# build-runtime.sh. Composed here, once, where the path is actually known --
# these flags are path-dependent by construction.
#
# Setting CMAKE_C_FLAGS here DROPS the platform's CMAKE_C_FLAGS_INIT
# contribution rather than merging with it (verified: -C behaves exactly like a
# command-line -D in this respect). On Linux that initialised default is empty,
# so the clobber costs nothing. On MSVC it does not -- see
# cmake/windows-x86_64.cmake.
#
# FORCE is what makes the recipe idempotent. cmake/variant-tsan.cmake appends
# to this entry by reading it back, so without FORCE a re-configure over an
# existing build tree finds the entry already set, skips this line, and appends
# a SECOND copy of -fsanitize=thread -g -- growing by one copy per configure.
# Re-declaring the base unconditionally means the variant append always starts
# from the same value. Verified: three consecutive configures now produce a
# byte-identical CMAKE_C_FLAGS, and the cache fingerprint stops depending on how
# many times the tree was configured.
#
# FORCE does not defeat an ad-hoc override: -C files load before command-line
# -D entries, so -DCMAKE_C_FLAGS=... still wins.
dist_set(CMAKE_C_FLAGS   "-ffile-prefix-map=$ENV{IREE_SRC}=iree" STRING "" FORCE)
dist_set(CMAKE_CXX_FLAGS "-ffile-prefix-map=$ENV{IREE_SRC}=iree" STRING "" FORCE)
