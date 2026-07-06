// Native ECW decoder for Android — thin C wrapper around the prebuilt
// libgdal.so (GDAL 3.12.1 with the ECW JPEG2000 SDK statically linked in).
//
// We do NOT pull in the full GDAL headers; only the ~15 C-API entry points we
// use are declared below (handles are opaque void*, so this is ABI-safe). The
// wrapper is plain C so it links against libc only — it does NOT depend on
// libc++_shared, avoiding any STL ABI clash with the prebuilt libgdal/libproj.
//
// Mirrors what scripts/ecw_tile_server.py does on Windows (gdal.Warp), but runs
// natively on the device: open the ECW once, then warp an on-demand tile to
// EPSG:3857 (Web Mercator) for each {z}/{x}/{y} request.

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>

#define LOG_TAG "navigate_ecw"
// Portable logging: Android uses logcat; everywhere else (iOS, macOS) -> stderr.
// This file is compiled verbatim by both the Android NDK build and the iOS pod.
#if defined(__ANDROID__)
#include <android/log.h>
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#else
#define LOGI(...) do { fprintf(stderr, "[" LOG_TAG "] "); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } while (0)
#define LOGE(...) do { fprintf(stderr, "[" LOG_TAG " E] "); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } while (0)
#endif

// ───────────────────────── GDAL C API (manual decls) ─────────────────────────
typedef void *GDALDatasetH;
typedef void *GDALWarpAppOptionsH;

// eAccess: GA_ReadOnly = 0
// eRWFlag: GF_Read = 0
// eBufType: GDT_Byte = 1
// CPLErr:   CE_None = 0

extern void GDALAllRegister(void);
extern GDALDatasetH GDALOpen(const char *pszFilename, int eAccess);
extern void GDALClose(GDALDatasetH);
extern const char *GDALVersionInfo(const char *pszRequest);
extern int GDALGetRasterXSize(GDALDatasetH);
extern int GDALGetRasterYSize(GDALDatasetH);
extern int GDALGetRasterCount(GDALDatasetH);
extern const char *GDALGetProjectionRef(GDALDatasetH);
extern int GDALGetGeoTransform(GDALDatasetH, double *padfTransform); // 6 doubles
extern void CPLSetConfigOption(const char *pszKey, const char *pszValue);
extern const char *CPLGetLastErrorMsg(void);

extern GDALWarpAppOptionsH GDALWarpAppOptionsNew(char **papszArgv, void *binary);
extern void GDALWarpAppOptionsFree(GDALWarpAppOptionsH);
extern GDALDatasetH GDALWarp(const char *pszDest, GDALDatasetH hDstDS,
                             int nSrcCount, GDALDatasetH *pahSrcDS,
                             GDALWarpAppOptionsH psOptions, int *pbUsageError);

extern int GDALDatasetRasterIO(GDALDatasetH hDS, int eRWFlag, int nXOff,
                               int nYOff, int nXSize, int nYSize, void *pData,
                               int nBufXSize, int nBufYSize, int eBufType,
                               int nBandCount, int *panBandMap, int nPixelSpace,
                               int nLineSpace, int nBandSpace);

// ───────────────────────────── wrapper API ──────────────────────────────────
// Exported to Dart via dart:ffi (see lib/services/ecw/ecw_gdal_decoder.dart).

// GDALAllRegister() is not thread-safe; with a pool of worker isolates (which
// share one native process) several threads may reach it at once. pthread_once
// guarantees the driver registration + global config run exactly once.
static pthread_once_t g_register_once = PTHREAD_ONCE_INIT;

static void do_register(void) {
  // Decode-only ECW: keep GDAL/ECW caches modest. Config is process-global
  // (shared by all worker isolates), so these are NOT multiplied per worker.
  CPLSetConfigOption("GDAL_CACHEMAX", "256");
  CPLSetConfigOption("ECW_CACHE_MAXMEM", "134217728"); // 128 MB
  // ECW driver is decode-capable without a license key; silence the encode key
  // probe just in case.
  CPLSetConfigOption("GDAL_PAM_ENABLED", "NO");
  GDALAllRegister();
  LOGI("GDAL registered: %s", GDALVersionInfo("RELEASE_NAME"));
}

static void ensure_registered(void) {
  pthread_once(&g_register_once, do_register);
}

// Returns the GDAL release string (e.g. "3.12.1"). Never NULL.
const char *ecw_gdal_version(void) {
  ensure_registered();
  const char *v = GDALVersionInfo("RELEASE_NAME");
  return v ? v : "";
}

// Opens an ECW file read-only. Returns an opaque dataset handle, or NULL.
GDALDatasetH ecw_open(const char *path) {
  ensure_registered();
  GDALDatasetH ds = GDALOpen(path, /*GA_ReadOnly*/ 0);
  if (!ds) {
    LOGE("ecw_open failed: %s — %s", path, CPLGetLastErrorMsg());
  } else {
    LOGI("ecw_open ok: %s (%dx%d, %d bands)", path, GDALGetRasterXSize(ds),
         GDALGetRasterYSize(ds), GDALGetRasterCount(ds));
  }
  return ds;
}

int ecw_width(GDALDatasetH h) { return h ? GDALGetRasterXSize(h) : 0; }
int ecw_height(GDALDatasetH h) { return h ? GDALGetRasterYSize(h) : 0; }
int ecw_band_count(GDALDatasetH h) { return h ? GDALGetRasterCount(h) : 0; }

// Source CRS as WKT (read-only pointer owned by GDAL). May be empty.
const char *ecw_srs(GDALDatasetH h) {
  if (!h) return "";
  const char *s = GDALGetProjectionRef(h);
  return s ? s : "";
}

// Fills out6 with the source geotransform. Returns 0 on success.
int ecw_geotransform(GDALDatasetH h, double *out6) {
  if (!h || !out6) return -1;
  return GDALGetGeoTransform(h, out6) == 0 ? 0 : -1;
}

void ecw_close(GDALDatasetH h) {
  if (h) GDALClose(h);
}

void ecw_free(unsigned char *p) {
  if (p) free(p);
}

// Renders one tile: warps the source ECW into a `size`×`size` RGBA buffer in
// EPSG:3857 covering [minx,miny,maxx,maxy] (Web Mercator meters). Output is
// tightly packed RGBA8888 (size*size*4 bytes), allocated with malloc — the
// caller must release it via ecw_free. Areas outside the imagery are transparent.
//
// Returns 0 on success, negative on error.
int ecw_render_tile(GDALDatasetH h, double minx, double miny, double maxx,
                    double maxy, int size, unsigned char **out_rgba) {
  if (!h || !out_rgba || size <= 0) return -1;
  *out_rgba = NULL;

  char s_minx[64], s_miny[64], s_maxx[64], s_maxy[64], s_size[32];
  snprintf(s_minx, sizeof(s_minx), "%.10f", minx);
  snprintf(s_miny, sizeof(s_miny), "%.10f", miny);
  snprintf(s_maxx, sizeof(s_maxx), "%.10f", maxx);
  snprintf(s_maxy, sizeof(s_maxy), "%.10f", maxy);
  snprintf(s_size, sizeof(s_size), "%d", size);

  // gdalwarp-equivalent: warp to Web Mercator, exact tile extent, 256², with an
  // alpha band so out-of-coverage pixels come back transparent.
  char *argv[] = {
      "-of",     "MEM",
      "-t_srs",  "EPSG:3857",
      "-te",     s_minx, s_miny, s_maxx, s_maxy,
      "-ts",     s_size, s_size,
      "-r",      "bilinear",
      "-dstalpha",
      NULL};

  GDALWarpAppOptionsH opts = GDALWarpAppOptionsNew(argv, NULL);
  if (!opts) {
    LOGE("GDALWarpAppOptionsNew failed: %s", CPLGetLastErrorMsg());
    return -2;
  }

  int usageErr = 0;
  GDALDatasetH warped = GDALWarp("", NULL, 1, &h, opts, &usageErr);
  GDALWarpAppOptionsFree(opts);
  if (!warped) {
    LOGE("GDALWarp failed (usageErr=%d): %s", usageErr, CPLGetLastErrorMsg());
    return -3;
  }

  int wbands = GDALGetRasterCount(warped);
  const long npix = (long)size * (long)size;
  unsigned char *buf = (unsigned char *)malloc((size_t)npix * 4);
  if (!buf) {
    GDALClose(warped);
    return -4;
  }

  int rc = 0;
  if (wbands >= 4) {
    // RGB + alpha: interleaved read straight into RGBA.
    int bandMap[4] = {1, 2, 3, 4};
    rc = GDALDatasetRasterIO(warped, /*GF_Read*/ 0, 0, 0, size, size, buf, size,
                             size, /*GDT_Byte*/ 1, 4, bandMap, 4, size * 4, 1);
  } else if (wbands == 2) {
    // Gray + alpha: read into a temp, expand gray to RGB.
    unsigned char *tmp = (unsigned char *)malloc((size_t)npix * 2);
    if (!tmp) {
      rc = -5;
    } else {
      int bandMap[2] = {1, 2};
      rc = GDALDatasetRasterIO(warped, 0, 0, 0, size, size, tmp, size, size, 1,
                               2, bandMap, 2, size * 2, 1);
      if (rc == 0) {
        for (long i = 0; i < npix; i++) {
          unsigned char g = tmp[i * 2], a = tmp[i * 2 + 1];
          buf[i * 4] = g; buf[i * 4 + 1] = g; buf[i * 4 + 2] = g; buf[i * 4 + 3] = a;
        }
      }
      free(tmp);
    }
  } else {
    // 1 or 3 colour bands, no alpha: read colours, set alpha opaque.
    int nc = wbands >= 3 ? 3 : 1;
    unsigned char *tmp = (unsigned char *)malloc((size_t)npix * nc);
    if (!tmp) {
      rc = -5;
    } else {
      int bandMap[3] = {1, 2, 3};
      rc = GDALDatasetRasterIO(warped, 0, 0, 0, size, size, tmp, size, size, 1,
                               nc, bandMap, nc, size * nc, 1);
      if (rc == 0) {
        for (long i = 0; i < npix; i++) {
          if (nc == 3) {
            buf[i * 4] = tmp[i * 3];
            buf[i * 4 + 1] = tmp[i * 3 + 1];
            buf[i * 4 + 2] = tmp[i * 3 + 2];
          } else {
            unsigned char g = tmp[i];
            buf[i * 4] = g; buf[i * 4 + 1] = g; buf[i * 4 + 2] = g;
          }
          buf[i * 4 + 3] = 255;
        }
      }
      free(tmp);
    }
  }

  GDALClose(warped);
  if (rc != 0) {
    free(buf);
    LOGE("RasterIO failed rc=%d bands=%d: %s", rc, wbands, CPLGetLastErrorMsg());
    return -6;
  }
  *out_rgba = buf;
  return 0;
}
