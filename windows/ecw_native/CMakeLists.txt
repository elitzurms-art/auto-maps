# Windows build of the native ECW decoder — produces auto_maps_ecw.dll bundled
# next to the auto_maps.exe, plus the OSGeo4W GDAL runtime it needs at load time.
# Shares ecw_wrapper.c source with the Android build (which links GDAL statically).
#
# On Windows we do NOT compile GDAL from source: we link against the prebuilt
# OSGeo4W gdal313.dll via a minimal import lib (gdal_i.lib, committed here — it
# was generated from the DLL's export table, see gdal_i.def), and copy the whole
# runtime DLL closure + GDAL/PROJ data next to the .exe so end machines need no
# OSGeo4W install. ecw_wrapper.c self-anchors GDAL_DRIVER_PATH/GDAL_DATA/PROJ_DATA
# to these bundled folders at runtime (see ecw_set_win_data_dirs there).
#
# No project() here on purpose (terrain_engine/jp2_native pattern) — a nested
# project() would spawn its own CMAKE_INSTALL_PREFIX and misplace the DLL.

cmake_minimum_required(VERSION 3.14)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# OSGeo4W install providing the prebuilt GDAL 3.13 runtime with the ECW SDK 5.5
# driver. Overridable from the CMake cache if installed elsewhere.
set(OSGEO4W_ROOT "C:/OSGeo4W" CACHE PATH "OSGeo4W root (prebuilt GDAL runtime)")

# Shared C source (also compiled by the Android NDK build).
set(ECW_WRAPPER_SRC
    ${CMAKE_CURRENT_SOURCE_DIR}/../../android/app/src/main/cpp/ecw_wrapper.c)

if(NOT EXISTS ${ECW_WRAPPER_SRC})
    message(FATAL_ERROR "ecw_wrapper.c not found at ${ECW_WRAPPER_SRC}")
endif()

set(GDAL_IMPORT_LIB ${CMAKE_CURRENT_SOURCE_DIR}/gdal_i.lib)
if(NOT EXISTS ${GDAL_IMPORT_LIB})
    message(FATAL_ERROR
        "gdal_i.lib not found at ${GDAL_IMPORT_LIB}. Regenerate it from the DLL:\n"
        "  lib /def:gdal_i.def /machine:x64 /out:gdal_i.lib")
endif()

add_library(auto_maps_ecw SHARED ${ECW_WRAPPER_SRC})

target_link_libraries(auto_maps_ecw PRIVATE ${GDAL_IMPORT_LIB})

set_target_properties(auto_maps_ecw PROPERTIES
    OUTPUT_NAME "auto_maps_ecw"
    WINDOWS_EXPORT_ALL_SYMBOLS ON)

# ── Runtime GDAL DLL closure (transitive imports of gdal313.dll + ECW plugin) ──
# Computed once from dumpbin /dependents; all 56 must be present for the loader
# to bring up gdal313.dll. Copied from OSGeo4W/bin next to the .exe.
set(GDAL_RUNTIME_DLLS
    Lerc.dll NCSEcw.dll aec.dll archive.dll arrow.dll arrow_acero.dll
    arrow_compute.dll arrow_dataset.dll blosc.dll brotlicommon.dll brotlidec.dll
    brotlienc.dll freetype.dll freexl.dll gdal313.dll geos.dll geos_c.dll hdf.dll
    hdf5.dll hdf5_hl.dll iconv-2.dll jpeg62.dll jxl.dll jxl_cms.dll jxl_threads.dll
    libcrypto-3-x64.dll libcurl.dll libexpat.dll liblzma.dll libmysql.dll
    libpng16.dll libpq.dll libsharpyuv.dll libssl-3-x64.dll libwebp.dll libxml2.dll
    lz4.dll mfhdf.dll msvcp140.dll msvcp140_atomic_wait.dll netcdf.dll openjp2.dll
    parquet.dll poppler.dll proj_9.dll spatialite.dll sqlite3.dll szip.dll
    thriftmd.dll tiff.dll vcomp140.dll vcruntime140.dll vcruntime140_1.dll
    xerces-c_3_2.dll zlib.dll zstd.dll)

set(ECW_PLUGIN     ${OSGEO4W_ROOT}/apps/gdal/lib/gdalplugins/gdal_ECW_JP2ECW.dll)
set(ECW_PLUGIN_INI ${OSGEO4W_ROOT}/apps/gdal/lib/gdalplugins/drivers.ini)
set(GDAL_DATA_DIR  ${OSGEO4W_ROOT}/apps/gdal/share/gdal)
set(PROJ_DB        ${OSGEO4W_ROOT}/share/proj/proj.db)

# Destination = runner/<Config>/ (next to auto_maps.exe). Same computation as
# jp2_native: relative to CMAKE_BINARY_DIR (build/windows/x64/).
set(ECW_RUNNER_DIR ${CMAKE_BINARY_DIR}/runner/$<CONFIG>)

# 1) Core wrapper DLL next to the exe.
add_custom_command(TARGET auto_maps_ecw POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory ${ECW_RUNNER_DIR}
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        $<TARGET_FILE:auto_maps_ecw> ${ECW_RUNNER_DIR}/
    COMMENT "Copying auto_maps_ecw.dll to runner/$<CONFIG>/")

# 2) GDAL runtime DLL closure.
foreach(dll ${GDAL_RUNTIME_DLLS})
    if(EXISTS ${OSGEO4W_ROOT}/bin/${dll})
        add_custom_command(TARGET auto_maps_ecw POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                ${OSGEO4W_ROOT}/bin/${dll} ${ECW_RUNNER_DIR}/)
    else()
        message(WARNING "GDAL runtime DLL missing: ${OSGEO4W_ROOT}/bin/${dll}")
    endif()
endforeach()

# 3) ECW driver plugin + registration order into gdalplugins/.
add_custom_command(TARGET auto_maps_ecw POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory ${ECW_RUNNER_DIR}/gdalplugins
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${ECW_PLUGIN} ${ECW_RUNNER_DIR}/gdalplugins/
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${ECW_PLUGIN_INI} ${ECW_RUNNER_DIR}/gdalplugins/
    COMMENT "Copying ECW GDAL plugin to runner/$<CONFIG>/gdalplugins/")

# 4) GDAL data + PROJ database into their bundled dirs.
add_custom_command(TARGET auto_maps_ecw POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory ${ECW_RUNNER_DIR}/gdal_data
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${GDAL_DATA_DIR} ${ECW_RUNNER_DIR}/gdal_data
    COMMAND ${CMAKE_COMMAND} -E make_directory ${ECW_RUNNER_DIR}/proj_data
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${PROJ_DB} ${ECW_RUNNER_DIR}/proj_data/
    COMMENT "Copying GDAL data + proj.db to runner/$<CONFIG>/")

# ── ממיר WIC ‏(HEIC→PNG) — DLL עצמאי קטן, בלי שום תלות ב-GDAL ──
add_library(auto_maps_wic SHARED ${CMAKE_CURRENT_SOURCE_DIR}/wic_convert.cpp)
target_link_libraries(auto_maps_wic PRIVATE windowscodecs ole32)
set_target_properties(auto_maps_wic PROPERTIES OUTPUT_NAME "auto_maps_wic")
add_custom_command(TARGET auto_maps_wic POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory ${ECW_RUNNER_DIR}
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        $<TARGET_FILE:auto_maps_wic> ${ECW_RUNNER_DIR}/
    COMMENT "Copying auto_maps_wic.dll to runner/$<CONFIG>/")

# ── Install rules (cmake --install / release packaging) ──
install(TARGETS auto_maps_wic RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
    COMPONENT Runtime)
install(TARGETS auto_maps_ecw RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
    COMPONENT Runtime)
foreach(dll ${GDAL_RUNTIME_DLLS})
    if(EXISTS ${OSGEO4W_ROOT}/bin/${dll})
        install(FILES ${OSGEO4W_ROOT}/bin/${dll}
            DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
    endif()
endforeach()
install(FILES ${ECW_PLUGIN} ${ECW_PLUGIN_INI}
    DESTINATION "${CMAKE_INSTALL_PREFIX}/gdalplugins" COMPONENT Runtime)
install(DIRECTORY ${GDAL_DATA_DIR}/
    DESTINATION "${CMAKE_INSTALL_PREFIX}/gdal_data" COMPONENT Runtime)
install(FILES ${PROJ_DB}
    DESTINATION "${CMAKE_INSTALL_PREFIX}/proj_data" COMPONENT Runtime)
