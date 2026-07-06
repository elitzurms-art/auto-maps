# Native ECW decoder for Android — thin C wrapper around the prebuilt
# libgdal.so (GDAL with the ECW/JPEG2000 SDK statically linked in).
#
# Produces libauto_maps_ecw.so, loaded from Dart via
# lib/services/ecw/ecw_gdal_decoder.dart (DynamicLibrary.open).
#
# The prebuilt libgdal.so / libproj.so / libc++_shared.so live in
# src/main/jniLibs/${ANDROID_ABI}/ (reused from the navigate project, arm64-v8a
# only). Gradle packages them into the APK and the runtime linker resolves
# libgdal's deps (libproj, libc++_shared, libz) there.

cmake_minimum_required(VERSION 3.22.1)
project("auto_maps_ecw")

# The prebuilt GDAL/PROJ ship for arm64-v8a only, so guard the whole ECW target
# to that ABI — otherwise a 32-bit / x86 configure pass fails looking for a
# libgdal.so that does not exist for that ABI.
if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(JNILIBS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI})

    add_library(gdal_prebuilt SHARED IMPORTED)
    set_target_properties(gdal_prebuilt PROPERTIES
        IMPORTED_LOCATION ${JNILIBS_DIR}/libgdal.so)

    add_library(proj_prebuilt SHARED IMPORTED)
    set_target_properties(proj_prebuilt PROPERTIES
        IMPORTED_LOCATION ${JNILIBS_DIR}/libproj.so)

    # ecw_wrapper.c is plain C → links against libc only (no libc++_shared dep),
    # avoiding any STL ABI clash with the prebuilt libgdal/libproj.
    add_library(auto_maps_ecw SHARED ecw_wrapper.c)
    target_link_libraries(auto_maps_ecw gdal_prebuilt proj_prebuilt log android)
endif()
