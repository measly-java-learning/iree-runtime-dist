# The declaration primitive for this recipe's cmake -C cache-init files.
#
# Two jobs in one call, deliberately coupled: set the cache entry, and record
# that we are the ones who declared it. gen-manifest.sh reads
# IREE_DIST_DECLARED_KEYS to know which of CMakeCache.txt's hundreds of entries
# belong to us. The alternative -- grepping these files for `set(` calls -- would
# be a second parser of the same data, which is the exact defect class this
# whole change exists to remove.
#
# Filter by KEY NAME, never by entry type. A command-line -D overrides a
# cache-init value (verified: -C files load before -D entries, so -D wins even
# against FORCE) and resets the entry's TYPE to UNINITIALIZED. Filtering by
# type would therefore silently drop exactly the keys that differ from what we
# declared -- the only interesting case.
#
# Include me from every -C file. A macro is not a cache variable and does not
# persist between -C scripts, so each one needs its own include.

macro(dist_set key value type doc)
  # ${ARGN} carries an optional trailing FORCE, which cmake/variant-tsan.cmake
  # needs: it re-declares an entry the platform file already created, and a
  # non-FORCE set() on an existing cache entry is a no-op.
  set(${key} "${value}" CACHE ${type} "${doc}" ${ARGN})
  # The list accumulates across separate -C files because it lives in the cache.
  # REMOVE_DUPLICATES matters because a later file re-declares CMAKE_C_FLAGS to
  # append to it.
  #
  # UNQUOTED ${IREE_DIST_DECLARED_KEYS}, deliberately: an unset or empty
  # variable expands to no arguments at all, so the first call produces a
  # one-element list rather than a leading empty element. The obvious
  # "${IREE_DIST_DECLARED_KEYS};${key}" does produce one, and REMOVE_DUPLICATES
  # over it warns CMP0007 on every configure; branching on emptiness with
  # if(... STREQUAL "") only trades that for a CMP0054 warning. A -C file runs
  # before any project(), so no cmake_minimum_required has selected policies
  # and cmake_policy(SET) would just move the noise around. Building a list
  # that never contains an empty element sidesteps both. Key names are CMake
  # identifiers, so no element can contain a separator.
  set(_dist_keys ${IREE_DIST_DECLARED_KEYS} ${key})
  list(REMOVE_DUPLICATES _dist_keys)
  set(IREE_DIST_DECLARED_KEYS "${_dist_keys}" CACHE INTERNAL
      "Cache keys declared by iree-runtime-dist's -C files; gen-manifest.sh reads this")
endmacro()
