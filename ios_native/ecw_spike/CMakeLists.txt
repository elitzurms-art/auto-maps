# iOS ECW spike — Phase 0 of the ECW-on-iOS initiative.
# Goal: prove the ECW SDK 3.3 source (makinacorpus/libecw) COMPILES for iphoneos arm64.
# We build a STATIC lib only: archiving tolerates unresolved externals, so this is a
# cheap "does it compile for iOS arm64" signal, decoupled from Flutter/Pods/Shorebird.
#
# Configure (on a macOS runner) e.g.:
#   cmake -S ios_native/ecw_spike -B build/ecw_spike_ios \
#         -G Xcode \
#         -DCMAKE_SYSTEM_NAME=iOS \
#         -DCMAKE_OSX_ARCHITECTURES=arm64 \
#         -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
#         -DLIBECW_DIR=../../native_third_party/libecw
#   cmake --build build/ecw_spike_ios --config Release
#
# See MEMORY ecw-ios-native-initiative for the full plan.
cmake_minimum_required(VERSION 3.20)
project(ecw_ios_spike LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED OFF)   # 2006-era code; don't be strict yet.

# Path to the cloned libecw (scripts/download_libecw.sh). Override with -DLIBECW_DIR=...
set(LIBECW_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../native_third_party/libecw"
    CACHE PATH "Path to the cloned makinacorpus/libecw source tree")
get_filename_component(LIBECW_DIR "${LIBECW_DIR}" ABSOLUTE)

set(SRC_ROOT "${LIBECW_DIR}/Source")
if(NOT EXISTS "${SRC_ROOT}/include/NCSECWClient.h")
  message(FATAL_ERROR
    "libecw source not found at ${SRC_ROOT}. Run: bash scripts/download_libecw.sh")
endif()

# Source list = the canonical PORTABLE set the upstream Linux/Gnu build compiles,
# read straight from Source/NCSBuildGnu/Makefile.am (the NCSECWSRC/NCSUTILSRC/...
# variables). This deliberately avoids the Windows-only COM/ATL/CE files
# (ComNCSRenderer.cpp, comissue.cpp, StdAfx.cpp, NCSEcwCE/*) that pull <atlbase.h>
# and are NOT part of the Linux build. Self-maintaining: tracks upstream exactly.
set(_makefile_am "${SRC_ROOT}/NCSBuildGnu/Makefile.am")
if(NOT EXISTS "${_makefile_am}")
  message(FATAL_ERROR "Missing ${_makefile_am} — cannot derive the portable source list.")
endif()
# Read the whole file and MATCHALL — line-by-line foreach breaks here because the
# trailing "\" continuations escape CMake's list separator and merge lines.
file(READ "${_makefile_am}" _mk_text)
string(REGEX MATCHALL "\\.\\./C/[A-Za-z0-9_/]+\\.(cpp|c)" _mk_paths "${_mk_text}")
set(ECW_SOURCES "")
foreach(_p ${_mk_paths})
  string(REGEX REPLACE "^\\.\\./C/" "" _rel "${_p}")   # -> "<subpath>.cpp"
  list(APPEND ECW_SOURCES "${SRC_ROOT}/C/${_rel}")
endforeach()
list(REMOVE_DUPLICATES ECW_SOURCES)

# Drop the SDK's bundled Little-CMS sources: we disabled NCSJPC_USE_LCMS (JP2 ICC
# colour), so nothing references lcms and there's no need to compile it.
list(FILTER ECW_SOURCES EXCLUDE REGEX "/lcms/")

message(STATUS "ECW spike: ${LIBECW_DIR}")
list(LENGTH ECW_SOURCES _n)
message(STATUS "ECW spike: compiling ${_n} source files")

add_library(ecw_spike STATIC ${ECW_SOURCES})

target_include_directories(ecw_spike PRIVATE
  "${SRC_ROOT}/include"
  "${SRC_ROOT}/NCSBuildGnu"          # NCSGnuConfig.h
  "${SRC_ROOT}/C/NCSEcw"
  "${SRC_ROOT}/C/NCSEcw/NCSEcw"
  "${SRC_ROOT}/C/NCSEcw/NCSJP2"
  "${SRC_ROOT}/C/NCSEcw/shared_src"
  "${SRC_ROOT}/C/NCSUtil"
  "${SRC_ROOT}/C/NCSnet"
  "${SRC_ROOT}/C/NCSnet/NCScnet3"
  "${SRC_ROOT}/C/NCSGDT2"
  "${SRC_ROOT}/C/tinyxml"
  "${SRC_ROOT}/C/libjpeg")

# Darwin platform path (configure.in: *darwin* -> "MACOSX"); POSIX as in EXTERNAL_DEFS.
target_compile_definitions(ecw_spike PRIVATE MACOSX POSIX)
# Only flag iOS on the real iphoneos target — lets us branch away from
# Carbon/Cocoa desktop bits there, while the macOS functional build (0b) keeps them.
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
  target_compile_definitions(ecw_spike PRIVATE TARGET_OS_IPHONE=1)
endif()

# Old code: keep the compiler permissive. Modern clang (Xcode 15+/clang 16+)
# promotes implicit function/int declarations to hard ERRORS — which -w does NOT
# undo — so this 2006-era C (e.g. gettimeofday used without <sys/time.h>) breaks.
# Downgrade that whole class back to warnings.
target_compile_options(ecw_spike PRIVATE
  -w
  -fno-strict-aliasing
  -Wno-deprecated-declarations
  -Wno-error=implicit-function-declaration
  -Wno-error=implicit-int
  -Wno-implicit-function-declaration
  -Wno-implicit-int)

# Phase 0b: decode probe executable. Forces a full link, so enable on the macOS
# host build (Carbon/CoreServices are present there) — NOT for iphoneos.
option(BUILD_SPIKE_EXE "Build the ECW decode probe executable" OFF)
if(BUILD_SPIKE_EXE)
  add_executable(ecw_spike_probe spike_main.c)
  target_include_directories(ecw_spike_probe PRIVATE "${SRC_ROOT}/include")
  # spike_main.c includes NCSECWClient.h -> NCSTypes.h, which needs the platform
  # macro to define UINT32/etc. (same defines the library target gets).
  target_compile_definitions(ecw_spike_probe PRIVATE MACOSX POSIX)
  target_link_libraries(ecw_spike_probe PRIVATE ecw_spike)
  if(APPLE)
    target_link_libraries(ecw_spike_probe PRIVATE
      "-framework Carbon" "-framework CoreServices" z iconv)
  endif()
endif()
