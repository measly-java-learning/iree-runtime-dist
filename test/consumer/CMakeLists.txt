cmake_minimum_required(VERSION 3.21)
project(iree_runtime_dist_consumer C)

# This is the downstream consumption path, verbatim. If this resolves, the
# consumer's hand-rolled ResolveIree.cmake is obsolete.
find_package(IreeRuntimeDist REQUIRED)

add_executable(consumer consumer.c)
target_link_libraries(consumer PRIVATE iree-runtime-dist::runtime)
