#!/usr/bin/env bash
# Fetch the source for the iOS GDAL stack (Phase 1 of the ECW-on-iOS initiative):
# PROJ + GDAL, into native_third_party/ (gitignored). libecw is fetched separately
# by download_libecw.sh. See MEMORY ecw-ios-native-initiative.
#
# Usage: bash scripts/fetch_gdal_stack.sh
set -euo pipefail

PROJ_VERSION="9.5.1"
GDAL_VERSION="3.10.1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TP="${ROOT}/native_third_party"
mkdir -p "${TP}"

fetch_tar() {
    local name="$1" url="$2" dest="$3" marker="$4"
    if [ -e "${dest}/${marker}" ]; then
        echo "${name} already present at ${dest} — skipping."
        return 0
    fi
    local tmp; tmp="$(mktemp -d)"
    echo "Downloading ${name}..."
    curl -fsSL -o "${tmp}/src.tar.gz" "${url}"
    mkdir -p "${dest}"
    tar -xzf "${tmp}/src.tar.gz" -C "${tmp}"
    # Move the single extracted top-level dir's contents into dest.
    local inner; inner="$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d | head -1)"
    cp -R "${inner}/." "${dest}/"
    rm -rf "${tmp}"
    echo "${name} installed at ${dest}"
}

fetch_tar "PROJ ${PROJ_VERSION}" \
    "https://github.com/OSGeo/PROJ/releases/download/${PROJ_VERSION}/proj-${PROJ_VERSION}.tar.gz" \
    "${TP}/proj" "CMakeLists.txt"

fetch_tar "GDAL ${GDAL_VERSION}" \
    "https://github.com/OSGeo/gdal/releases/download/v${GDAL_VERSION}/gdal-${GDAL_VERSION}.tar.gz" \
    "${TP}/gdal" "CMakeLists.txt"
