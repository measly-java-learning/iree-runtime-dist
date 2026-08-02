# The `default` variant contributes NO compiler flags. This file is empty of
# declarations on purpose and must not be deleted: build-runtime.sh passes
# -C cmake/variant-$VARIANT.cmake unconditionally, so a missing file is a
# configure error. Present-and-empty states "default adds nothing" explicitly;
# absent would state "someone forgot".
#
# It also includes dist-set.cmake for uniformity, so every -C file has the same
# shape and test/cmake_init.test.sh can assert that uniformly.
include("${CMAKE_CURRENT_LIST_DIR}/dist-set.cmake")
