# linux-x86_64. Everything is shared with linux-aarch64; this file exists as a
# distinct file so the -C path is derived straight from the platform token, with
# no platform-to-file mapping in shell. It is also where a genuinely
# arch-specific entry would go if one ever appears.
include("${CMAKE_CURRENT_LIST_DIR}/gnu-toolchain.cmake")
