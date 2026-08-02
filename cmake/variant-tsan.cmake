# The `tsan` variant differs from `default` ONLY in compiler flags. Every
# capability entry -- drivers, loaders, tracing -- lives in cmake/common.cmake
# where this file cannot reach it, so the two variants cannot drift on what
# runtime they build.
include("${CMAKE_CURRENT_LIST_DIR}/dist-set.cmake")

# FORCE is required: cmake/<platform>.cmake already created these entries, and
# a non-FORCE set() on an existing cache entry is a no-op (verified). This is
# also why the platform file must be passed BEFORE this one on the command
# line -- ${CMAKE_C_FLAGS} below reads what it set.
#
# FORCE here does NOT defeat ad-hoc overrides: -C files load before
# command-line -D entries are applied, so a -DCMAKE_C_FLAGS=... still wins
# (verified).
#
# -g, not CMAKE_BUILD_TYPE=RelWithDebInfo. RelWithDebInfo renames the exported
# config (IMPORTED_LOCATION_RELEASE -> _RELWITHDEBINFO), silently breaking the
# Release-hardcoded libbacktrace and relocatability repairs. -g gives TSan
# symbolized frames without that rename.
#
# -g also embeds the build directory in debug info that -ffile-prefix-map does
# not reach, which is why scripts/relocatability.sh exempts DWARF-only paths for
# sanitizer variants via RELOC_ALLOW_DEBUG_PATHS. That exemption is expected for
# a sanitizer variant; do not widen it beyond debug paths.
#
# The flag is propagated to consumers as an INTERFACE option on the umbrella
# target, so linking this variant instruments the consumer's whole program --
# but the consumer's own build must use clang to match this toolchain.
dist_set(CMAKE_C_FLAGS   "${CMAKE_C_FLAGS} -fsanitize=thread -g"   STRING "" FORCE)
dist_set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fsanitize=thread -g" STRING "" FORCE)
