#!/usr/bin/env bash
# Download the ECW SDK 3.3 source (makinacorpus/libecw) into native_third_party/libecw/
# Source is .gitignored — it is GPL-style ("ECW JPEG 2000 SDK Public Use License").
# Used by the iOS ECW native spike (ios_native/ecw_spike) — see MEMORY ecw-ios-native-initiative.
#
# Usage: bash scripts/download_libecw.sh
set -euo pipefail

# Pin a commit for reproducibility; bump deliberately.
REF="master"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${ROOT}/native_third_party/libecw"

if [ -d "${DEST}/Source/include" ]; then
    echo "libecw already present at ${DEST}/Source — skipping."
    exit 0
fi

echo "Cloning libecw (ECW SDK 3.3 source, ref=${REF})..."
mkdir -p "${DEST}"
git clone --depth 1 --branch "${REF}" https://github.com/makinacorpus/libecw.git "${DEST}"

# --- Apple (macOS/iOS) portability patches ---------------------------------
# The 2006-era SDK predates wcsdup() being in the Darwin C library. It defines a
# static wcsdup under `#if SOLARIS || MACOSX`, which now collides with the system
# declaration ("static declaration follows non-static"). Neutralise the SDK's
# definition (rename -> unused static); callers fall through to the system wcsdup.
NCSDEFS="${DEST}/Source/include/NCSDefs.h"
if [ -f "${NCSDEFS}" ]; then
    perl -0pi -e 's/static NCS_INLINE wchar_t \*wcsdup\(/static NCS_INLINE wchar_t *ncs_wcsdup_unused(/g' "${NCSDEFS}"
    echo "patched: NCSDefs.h wcsdup (Apple)"
fi

# The 3.3 headers key their platform/machine type off MACOSX/POSIX defines (the
# autotools build passed -DMACOSX). Make the headers self-detect Apple so ANY
# consumer compiles — crucially GDAL's own ECW driver (frmts/ecw/*.cpp), which
# includes these headers without defining MACOSX. Without it: NCSTypes.h hits
# "#error unknown machine type" / UINT32 undefined.
PLAT_BLOCK=$'#if defined(__APPLE__)\n#  ifndef MACOSX\n#    define MACOSX\n#  endif\n#  ifndef POSIX\n#    define POSIX\n#  endif\n#endif\n'
for H in NCSTypes.h NCSDefs.h; do
    F="${DEST}/Source/include/${H}"
    if [ -f "${F}" ] && ! grep -q "defined(__APPLE__)" "${F}"; then
        printf '%s' "${PLAT_BLOCK}" | cat - "${F}" > "${F}.new" && mv "${F}.new" "${F}"
        echo "patched: ${H} Apple platform auto-define"
    fi
done

# JP2 ICC colour management needs Little-CMS (lcms.h), which we don't ship and
# don't need for ECW decode. Disable it (guarded by NCSJPC_USE_LCMS in 2 files).
JPCDEFS="${DEST}/Source/include/NCSJPCDefs.h"
if [ -f "${JPCDEFS}" ]; then
    perl -0pi -e 's{^#define\s+NCSJPC_USE_LCMS\b}{// #define NCSJPC_USE_LCMS (disabled: no lcms)}m' "${JPCDEFS}"
    echo "patched: NCSJPCDefs.h disable NCSJPC_USE_LCMS"
fi

# NCSProxy.cpp (ECWP proxy auth — unused for local file decode) calls getlogin()
# on the MACOSX branch without declaring it. Stub it: we never use the proxy.
NCSPROXY="${DEST}/Source/C/NCSnet/NCScnet3/NCSProxy.cpp"
if [ -f "${NCSPROXY}" ]; then
    perl -0pi -e 's/getlogin\(\)/"navigate"/g' "${NCSPROXY}"
    echo "patched: NCSProxy.cpp getlogin stub (Apple)"
fi

echo "libecw installed at ${DEST}"
echo "NOTE: Public Use (GPL-style) license — internal/feasibility only. Resolve licensing before distribution."
