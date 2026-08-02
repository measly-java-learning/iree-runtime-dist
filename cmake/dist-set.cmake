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
# Include me from every -C file. A function is not a cache variable and does not
# persist between -C scripts, so each one needs its own include.
#
# A function(), NOT a macro(), and that is load-bearing rather than stylistic.
# Macro arguments are substituted TEXTUALLY into the body, which is then
# re-parsed as a command -- so a value containing backslashes is rescanned for
# escape sequences. cmake/windows-x86_64.cmake composes
# "-d1trimfile:$ENV{IREE_SRC_NATIVE}\", and IREE_SRC_NATIVE is cygpath -w
# output, so the value carries single backslashes BY DESIGN (that is exactly
# what /d1trimfile: needs -- cl emits __FILE__ as C:\..., and the trim is a
# literal prefix match; a POSIX-form prefix matches nothing and silently ships
# absolute paths). Under a macro, the \U in C:\Users\... is read as an escape
# and the re-parse fails with "Syntax error ... Invalid escape sequence \U",
# blamed on the set() line below rather than on the caller.
#
# Function arguments are ordinary variables, and variable-expansion results are
# never rescanned for escapes -- so ${value} arrives verbatim, whatever it
# contains. A direct set(... CACHE ...) at each call site would be safe for the
# same reason; it is the macro indirection that is escape-unsafe.
#
# This was a hard failure only on the Windows runner. Under CMP0010 OLD the
# re-parse is a mere developer warning and the value still lands correctly, so
# a CMake 3.x host builds green; CMake 4.x removed the OLD behaviour of every
# pre-3.5 policy, making it fatal. test/cmake_init.test.sh pins CMP0010 NEW so
# the regression is caught hermetically on any CMake instead of 40 minutes into
# a Windows CI job.

function(dist_set key value type doc)
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
endfunction()
