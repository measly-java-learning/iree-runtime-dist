# windows-x86_64 (MSVC). No Dockerfile: the toolchain comes from a PINNED
# GitHub runner image (windows-2022, never windows-latest) plus a VS dev-shell
# activation that release.yml enters before invoking build-runtime.sh.
include("${CMAKE_CURRENT_LIST_DIR}/dist-set.cmake")

# find_program with REQUIRED rather than a `command -v cl` guard in shell: it
# fails at configure with CMake's own diagnostic, and the RESOLVED ABSOLUTE
# PATH is what lands in the cache -- so recorded provenance names the exact cl
# that was used, not whatever PATH happened to resolve. Asking for clang here
# would either not resolve, or worse, pick up the LLVM that ships alongside VS
# and silently build with a different toolchain than the msvc_toolset value
# manifest.json attests to.
find_program(IREE_DIST_CL NAMES cl REQUIRED)
dist_set(CMAKE_C_COMPILER   "${IREE_DIST_CL}" STRING "")
dist_set(CMAKE_CXX_COMPILER "${IREE_DIST_CL}" STRING "")

# Static CRT (/MT). The consumer is a JNI shim linking into a DLL; a dynamic
# CRT would push a VC++ redistributable requirement onto every downstream user.
# CMAKE_MSVC_RUNTIME_LIBRARY is the supported CMake spelling -- deliberately a
# cache variable rather than smuggled into a raw flag string, because
# gen-manifest.sh derives manifest.json's `crt` field from this exact entry.
dist_set(CMAKE_MSVC_RUNTIME_LIBRARY MultiThreaded STRING "")

# /d1trimfile: is MSVC's -ffile-prefix-map analog -- verified working on the
# pinned CI toolset (cl 19.44.35228, VS 2022): baseline __FILE__
# "C:\trimtest\sub\foo.c" became "sub\foo.c" using -d1trimfile:C:\trimtest\ --
# ONE trailing backslash, not doubled. Unlike -ffile-prefix-map it TRIMS A
# PREFIX rather than remapping to a token, so the prefix must be the source
# root WITH that trailing backslash, or the last path component gets glued onto
# the following relative path.
#
# $ENV{IREE_SRC_NATIVE} is the cygpath -w form, produced by build-runtime.sh.
# cl.exe bakes __FILE__ in as a Windows path (C:\...), but the recipe runs under
# Git-Bash, where $IREE_SRC is a POSIX mount path (/c/Users/...). /d1trimfile:
# only trims a LITERAL prefix match against what cl emits, so a POSIX-flavoured
# prefix matches NOTHING and silently leaves every absolute __FILE__ in the
# shipped archives. Do not use $ENV{IREE_SRC} here.
#
# Dash spelling (-d1trimfile, not /d1trimfile): cl accepts both. This is now
# composed inside a cache-init file rather than passed as
# -DCMAKE_C_FLAGS=/d1trimfile:..., so MSYS2's argument converter never sees it
# and MSYS2_ARG_CONV_EXCL is no longer needed. The dash spelling is kept anyway
# -- it costs nothing and removes the trap entirely rather than relying on the
# invocation shape staying as it is.
set(_trimfile "-d1trimfile:$ENV{IREE_SRC_NATIVE}\\")

# Restate the platform defaults we are about to clobber.
#
# Setting CMAKE_C_FLAGS / CMAKE_CXX_FLAGS here DROPS what Windows-MSVC.cmake
# initialised, it does not add to it. Verified: cmake_initialize_per_config_
# variable does a non-FORCE set(... CACHE ...), and a -C file has already
# created the entry, so _INIT is dropped rather than merged. `-C` does NOT fix
# this -- it behaves exactly like a command-line -D did.
#
# Windows-MSVC.cmake seeds CXX with /DWIN32 /D_WINDOWS /GR /EHsc. Losing /EHsc
# makes every C++ translation unit that touches <ostream> fail C4530 ("C++
# exception handler used, but unwind semantics are not enabled"), which IREE's
# own -WX turns into an error. That is an OBSERVED failure: run 30281540210 died
# 322 objects in, on third_party/benchmark, for exactly this reason.
#
# /W3 is deliberately NOT restated -- IREE sets its own /W4, and restating a
# weaker warning level would only fight it. -GR and -EHsc are C++-only and must
# not appear in the C flags. If CMake ever changes these defaults, these two
# lines are what to update; test/cmake_init.test.sh asserts -EHsc is present in
# CXX and absent from C precisely so a future edit dropping it fails
# hermetically instead of 322 objects into a 40-minute CI build.
#
# FORCE for the same idempotency reason as cmake/gnu-toolchain.cmake: a variant
# file appends by reading this entry back, so the base must be re-declared on
# every configure or a re-configure appends a second copy. Windows builds only
# `default` today, which appends nothing -- the two platform files stay
# symmetric so that stops being true safely.
dist_set(CMAKE_C_FLAGS   "-DWIN32 -D_WINDOWS ${_trimfile}"          STRING "" FORCE)
dist_set(CMAKE_CXX_FLAGS "-DWIN32 -D_WINDOWS -GR -EHsc ${_trimfile}" STRING "" FORCE)
