cmake_minimum_required(VERSION 3.21)
project(iree_runtime_dist_consumer C)

# This is the downstream consumption path, verbatim. If this resolves, the
# consumer's hand-rolled ResolveIree.cmake is obsolete.
find_package(IreeRuntimeDist REQUIRED)

add_executable(consumer consumer.c)
target_link_libraries(consumer PRIVATE iree-runtime-dist::runtime)

if(MSVC)
  # MSVC's default C mode predates C11 and rejects _Generic, which IREE's
  # atomics headers use throughout. /std:c17 is the whole delta -- do NOT
  # switch LANGUAGE to CXX, which cascades into C7555/C4576/C7560 and would
  # require editing consumer.c away from what a real consumer writes.
  set_source_files_properties(consumer.c PROPERTIES COMPILE_FLAGS "/std:c17")
endif()
