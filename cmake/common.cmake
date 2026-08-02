# Platform- and variant-independent configuration. The single place the runtime
# feature set is stated.
#
# `default` and `tsan` build the SAME runtime -- same drivers, same loaders,
# tracing off. Keeping every capability entry here, where no variant file can
# reach it, makes that sameness structural: the two cannot drift, because
# there is only one file that can say what they are.
#
# Deliberately touches no CMAKE_C_FLAGS / CMAKE_CXX_FLAGS. Those are
# path-dependent (-ffile-prefix-map / d1trimfile embed $IREE_SRC) and so belong
# to the platform files.
include("${CMAKE_CURRENT_LIST_DIR}/dist-set.cmake")

# The compiler is out of contract: never built, never shipped. It appears only
# as a version string in manifest.json and as a CI-time pip wheel that compiles
# add.vmfb.
dist_set(IREE_BUILD_COMPILER             OFF BOOL "")
dist_set(IREE_BUILD_TESTS                OFF BOOL "")
dist_set(IREE_BUILD_SAMPLES              OFF BOOL "")
dist_set(IREE_BUILD_BINDINGS_TFLITE      OFF BOOL "")
dist_set(IREE_BUILD_BINDINGS_TFLITE_JAVA OFF BOOL "")
dist_set(IREE_BUILD_PYTHON_BINDINGS      OFF BOOL "")

dist_set(BUILD_SHARED_LIBS               OFF BOOL "")
# Release for BOTH variants, never RelWithDebInfo: that renames the exported
# config (IMPORTED_LOCATION_RELEASE -> _RELWITHDEBINFO) and silently breaks the
# Release-hardcoded libbacktrace and relocatability repairs. tsan gets its
# symbolized frames from -g in cmake/variant-tsan.cmake instead.
dist_set(CMAKE_BUILD_TYPE                Release STRING "")
dist_set(CMAKE_POSITION_INDEPENDENT_CODE ON  BOOL "")
dist_set(IREE_ALLOCATOR_SYSTEM           libc STRING "")
dist_set(IREE_ENABLE_THREADING           ON  BOOL "")

# Drivers and loaders. DEFAULTS=OFF then an explicit opt-in list, so a future
# IREE version adding a driver to its defaults cannot silently widen what we
# ship. The two driver names here are what a consumer passes to
# iree_runtime_instance_try_create_default_device -- exact names, not URIs.
dist_set(IREE_HAL_DRIVER_DEFAULTS                    OFF BOOL "")
dist_set(IREE_HAL_DRIVER_LOCAL_SYNC                  ON  BOOL "")
dist_set(IREE_HAL_DRIVER_LOCAL_TASK                  ON  BOOL "")
dist_set(IREE_HAL_EXECUTABLE_LOADER_DEFAULTS         OFF BOOL "")
dist_set(IREE_HAL_EXECUTABLE_LOADER_EMBEDDED_ELF     ON  BOOL "")
dist_set(IREE_HAL_EXECUTABLE_LOADER_SYSTEM_LIBRARY   ON  BOOL "")
dist_set(IREE_ENABLE_RUNTIME_TRACING                 OFF BOOL "")

# Not per-invocation, so it is declared here rather than passed as a -D:
# the packaged layout is lib/, always. CMAKE_INSTALL_PREFIX is the only value
# that genuinely varies per invocation and stays on the command line.
dist_set(CMAKE_INSTALL_LIBDIR lib STRING "")
