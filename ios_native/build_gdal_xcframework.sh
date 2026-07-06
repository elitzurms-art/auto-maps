#!/usr/bin/env bash
# Build the GDAL+PROJ+ECW stack for iphoneos arm64 and package it as
# gdal_ecw.xcframework + the PROJ runtime data (proj.db), into ios/gdal_ecw/.
# This is the prebuild the iOS pod depends on — run it before `pod install`.
#
# Encapsulates the steps proven green in .github/workflows/ecw-ios-gdal.yml.
# macOS + Xcode only. See MEMORY ecw-ios-native-initiative.
#
# Usage (from navigate_app/): bash ios_native/build_gdal_xcframework.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"      # navigate_app/
BUILD="${ROOT}/../build/gdal_stack_ios"        # scratch (outside the package)
OUTDIR="${ROOT}/ios/gdal_ecw"                  # pod consumes from here
DEPLOY="16.0"
SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)"

if [ -f "${OUTDIR}/gdal_ecw.xcframework/Info.plist" ] && [ -f "${OUTDIR}/share/proj/proj.db" ]; then
    echo "gdal_ecw.xcframework + proj.db already present — skipping (delete ${OUTDIR} to rebuild)."
    exit 0
fi

echo "==> Fetching source"
bash "${ROOT}/scripts/fetch_gdal_stack.sh"
bash "${ROOT}/scripts/download_libecw.sh"

mkdir -p "${BUILD}"
STAGE="${BUILD}/stage"

echo "==> PROJ (iphoneos arm64)"
cmake -S "${ROOT}/native_third_party/proj" -B "${BUILD}/proj" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOY}" -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_INSTALL_PREFIX="${STAGE}" \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_APPS=OFF -DBUILD_TESTING=OFF \
    -DENABLE_CURL=OFF -DENABLE_TIFF=OFF \
    -DEXE_SQLITE3=/usr/bin/sqlite3 \
    -DSQLite3_INCLUDE_DIR="${SYSROOT}/usr/include" \
    -DSQLite3_LIBRARY="${SYSROOT}/usr/lib/libsqlite3.tbd"
cmake --build "${BUILD}/proj" --config Release -j3
cmake --install "${BUILD}/proj" --config Release

echo "==> libecw (ECW SDK 3.3) + ECW root"
cmake -S "${ROOT}/ios_native/ecw_spike" -B "${BUILD}/ecw" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOY}" -DCMAKE_OSX_SYSROOT=iphoneos
cmake --build "${BUILD}/ecw" --config Release -j3
ECW_A="$(find "${BUILD}/ecw" -name 'libecw_spike.a' | head -1)"
ECWROOT="${BUILD}/ecwroot"
mkdir -p "${ECWROOT}/include" "${ECWROOT}/lib"
cp -R "${ROOT}/native_third_party/libecw/Source/include/." "${ECWROOT}/include/"
for n in NCSEcw NCSUtil NCSCnet NCSEcwC ecwj2; do cp "${ECW_A}" "${ECWROOT}/lib/lib${n}.a"; done

echo "==> GDAL + ECW (iphoneos arm64)"
cmake -S "${ROOT}/native_third_party/gdal" -B "${BUILD}/gdal" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOY}" -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_PREFIX_PATH="${STAGE}" \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_APPS=OFF -DBUILD_TESTING=OFF \
    -DBUILD_PYTHON_BINDINGS=OFF -DGDAL_USE_INTERNAL_LIBS=ON \
    -DGDAL_BUILD_OPTIONAL_DRIVERS=OFF -DOGR_BUILD_OPTIONAL_DRIVERS=OFF \
    -DGDAL_USE_CURL=OFF -DGDAL_USE_ECW=ON -DGDAL_ENABLE_DRIVER_ECW=ON \
    -DECW_ROOT="${ECWROOT}" -DECW_INCLUDE_DIR="${ECWROOT}/include" \
    -DECW_LIBRARY="${ECWROOT}/lib/libNCSEcw.a" \
    -DECWnet_LIBRARY="${ECWROOT}/lib/libNCSCnet.a" \
    -DECWC_LIBRARY="${ECWROOT}/lib/libNCSEcwC.a" \
    -DNCSUtil_LIBRARY="${ECWROOT}/lib/libNCSUtil.a" \
    -DPROJ_INCLUDE_DIR="${STAGE}/include" -DPROJ_LIBRARY="${STAGE}/lib/libproj.a" \
    -DSQLite3_INCLUDE_DIR="${SYSROOT}/usr/include" \
    -DSQLite3_LIBRARY="${SYSROOT}/usr/lib/libsqlite3.tbd"
cmake --build "${BUILD}/gdal" --config Release -j3

echo "==> Assemble xcframework"
GDAL_A="$(find "${BUILD}/gdal" -name 'libgdal.a' | head -1)"
mkdir -p "${BUILD}/xcf"
# One copy of libecw only (the 5 names were just for FindECW).
libtool -static -o "${BUILD}/xcf/libgdal_ecw.a" "${GDAL_A}" "${STAGE}/lib/libproj.a" "${ECW_A}"
rm -rf "${OUTDIR}"
mkdir -p "${OUTDIR}/share/proj"
xcodebuild -create-xcframework \
    -library "${BUILD}/xcf/libgdal_ecw.a" \
    -output "${OUTDIR}/gdal_ecw.xcframework"
# PROJ runtime database (needed for any reprojection at runtime).
cp "${STAGE}/share/proj/proj.db" "${OUTDIR}/share/proj/proj.db"

echo "==> Done:"
find "${OUTDIR}" -maxdepth 3 | sed "s|${OUTDIR}|ios/gdal_ecw|"
