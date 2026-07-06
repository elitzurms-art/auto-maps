/*
 * ECW spike — Phase 0b functional probe.
 *
 * Opens a .ecw, prints its georeferencing (size, projection, datum, origin,
 * cell increments) and decodes a small RGBA window, printing a checksum.
 *
 * Proves the ECW SDK 3.3 source actually DECODES our imagery, and reveals the
 * native SRS (expected ITM / EPSG:2039) + datum — the input we need to design
 * the Web-Mercator reprojection in Phase 1.
 *
 * Built for macOS arm64 on CI and run natively (decode logic is portable C;
 * the iphoneos-specific link is exercised later when we build the xcframework).
 *
 *   Usage: ecw_spike_probe <path-to.ecw>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "NCSECWClient.h"
#include "NCSErrors.h"

#define VIEW_PX 256   /* decode a 256x256 window from the top-left */

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <path-to.ecw>\n", argv[0]);
        return 2;
    }
    const char *path = argv[1];
    printf("[spike] opening: %s\n", path);

    NCSFileView *pView = NULL;
    NCSError e = NCScbmOpenFileView((char *)path, &pView, NULL);
    if (e != NCS_SUCCESS || pView == NULL) {
        fprintf(stderr, "[spike] OpenFileView failed: %d (%s)\n",
                (int)e, NCSGetErrorText(e));
        return 1;
    }
    printf("[spike] OpenFileView OK\n");

    NCSFileViewFileInfoEx *pInfo = NULL;
    e = NCScbmGetViewFileInfoEx(pView, &pInfo);
    if (e != NCS_SUCCESS || pInfo == NULL) {
        fprintf(stderr, "[spike] GetViewFileInfoEx failed: %d\n", (int)e);
        NCScbmCloseFileView(pView);
        return 1;
    }

    printf("[spike] --- georeference ---\n");
    printf("[spike] size        : %u x %u px\n", pInfo->nSizeX, pInfo->nSizeY);
    printf("[spike] bands       : %u\n", (unsigned)pInfo->nBands);
    printf("[spike] projection  : %s\n", pInfo->szProjection ? pInfo->szProjection : "(null)");
    printf("[spike] datum       : %s\n", pInfo->szDatum ? pInfo->szDatum : "(null)");
    printf("[spike] cellUnits   : %d\n", (int)pInfo->eCellSizeUnits);
    printf("[spike] origin      : X=%.3f Y=%.3f\n", pInfo->fOriginX, pInfo->fOriginY);
    printf("[spike] cellInc     : dX=%.6f dY=%.6f\n", pInfo->fCellIncrementX, pInfo->fCellIncrementY);
    printf("[spike] colorSpace  : %d\n", (int)pInfo->eColorSpace);

    /* Decode a small top-left window. */
    UINT32 w = pInfo->nSizeX, h = pInfo->nSizeY;
    UINT32 nBands = pInfo->nBands < 3 ? pInfo->nBands : 3;
    UINT32 band[3] = {0, 1, 2};
    UINT32 vw = w < VIEW_PX ? w : VIEW_PX;
    UINT32 vh = h < VIEW_PX ? h : VIEW_PX;

    e = NCScbmSetFileView(pView, nBands, band,
                          0, 0, vw - 1, vh - 1,   /* image-coord extent */
                          vw, vh);                /* output size in px  */
    if (e != NCS_SUCCESS) {
        fprintf(stderr, "[spike] SetFileView failed: %d\n", (int)e);
        NCScbmCloseFileView(pView);
        return 1;
    }

    UINT32 *line = (UINT32 *)malloc((size_t)vw * sizeof(UINT32));
    unsigned long long checksum = 0;
    UINT32 nonzero = 0;
    for (UINT32 y = 0; y < vh; ++y) {
        NCSEcwReadStatus rs = NCScbmReadViewLineRGBA(pView, line);
        if (rs != NCSECW_READ_OK) {
            fprintf(stderr, "[spike] ReadViewLineRGBA failed at row %u: %d\n", y, (int)rs);
            free(line);
            NCScbmCloseFileView(pView);
            return 1;
        }
        for (UINT32 x = 0; x < vw; ++x) {
            checksum += line[x];
            if (line[x] & 0x00FFFFFFu) ++nonzero;
        }
    }
    free(line);
    NCScbmCloseFileView(pView);

    printf("[spike] --- decode ---\n");
    printf("[spike] decoded     : %u x %u px\n", vw, vh);
    printf("[spike] checksum    : %llu\n", checksum);
    printf("[spike] nonzero px  : %u / %u\n", nonzero, vw * vh);
    printf("[spike] SUCCESS — ECW SDK 3.3 decoded the image.\n");
    return 0;
}
