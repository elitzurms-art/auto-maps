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
// pthread is used for one-time GDAL registration on POSIX (Android/iOS). MSVC
// has no <pthread.h>; the Windows build uses InitOnceExecuteOnce instead (below).
#if !defined(_WIN32)
#include <pthread.h>
#endif

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

typedef void *GDALTranslateOptionsH;
extern GDALTranslateOptionsH GDALTranslateOptionsNew(char **papszArgv, void *binary);
extern void GDALTranslateOptionsFree(GDALTranslateOptionsH);
extern GDALDatasetH GDALTranslate(const char *pszDest, GDALDatasetH hSrcDS,
                                  GDALTranslateOptionsH psOptions,
                                  int *pbUsageError);
extern void *GDALGetDriverByName(const char *pszName);
extern GDALDatasetH GDALCreateCopy(void *hDriver, const char *pszFilename,
                                   GDALDatasetH hSrcDS, int bStrict,
                                   char **papszOptions, void *pfnProgress,
                                   void *pProgressData);
extern void *GDALGetRasterBand(GDALDatasetH, int nBandId);
extern void *GDALGetRasterColorTable(void *hBand);

extern int GDALDatasetRasterIO(GDALDatasetH hDS, int eRWFlag, int nXOff,
                               int nYOff, int nXSize, int nYSize, void *pData,
                               int nBufXSize, int nBufYSize, int eBufType,
                               int nBandCount, int *panBandMap, int nPixelSpace,
                               int nLineSpace, int nBandSpace);

// ───────────────────────── Windows self-configuration ───────────────────────
// On Windows the app ships the OSGeo4W GDAL runtime *next to the .exe* (no
// OSGeo4W install on the end machine). GDAL therefore can't find its plugin dir
// / data files via the registry, so we point it at the bundled folders, which
// sit beside this very DLL:  <dir>/gdalplugins , <dir>/gdal_data , <dir>/proj_data.
// We locate our own module at runtime (GetModuleFileName) so it works regardless
// of the working directory. Config options must be set *before* GDALAllRegister.
#if defined(_WIN32)
#include <windows.h>
static void ecw_set_win_data_dirs(void) {
  HMODULE hm = NULL;
  if (!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                              GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                          (LPCSTR)&ecw_set_win_data_dirs, &hm)) {
    return;
  }
  char dir[MAX_PATH];
  DWORD n = GetModuleFileNameA(hm, dir, (DWORD)sizeof(dir));
  if (n == 0 || n >= sizeof(dir)) return;
  char *slash = strrchr(dir, '\\');
  if (slash) *slash = '\0';

  char buf[MAX_PATH + 32];
  snprintf(buf, sizeof(buf), "%s\\gdalplugins", dir);
  CPLSetConfigOption("GDAL_DRIVER_PATH", buf);
  snprintf(buf, sizeof(buf), "%s\\gdal_data", dir);
  CPLSetConfigOption("GDAL_DATA", buf);
  snprintf(buf, sizeof(buf), "%s\\proj_data", dir);
  CPLSetConfigOption("PROJ_DATA", buf);  // PROJ 6+ search path (GDAL forwards it)
  CPLSetConfigOption("PROJ_LIB", buf);   // legacy PROJ name, harmless duplicate
  LOGI("Windows GDAL data dirs anchored at %s", dir);
}
#endif

// ───────────────────────────── wrapper API ──────────────────────────────────
// Exported to Dart via dart:ffi (see lib/services/ecw/ecw_gdal_decoder.dart).

// GDALAllRegister() is not thread-safe; with a pool of worker isolates (which
// share one native process) several threads may reach it at once. A one-time
// init guarantees the driver registration + global config run exactly once
// (pthread_once on POSIX, InitOnceExecuteOnce on Windows).
#if !defined(_WIN32)
static pthread_once_t g_register_once = PTHREAD_ONCE_INIT;
#endif

static void do_register(void) {
#if defined(_WIN32)
  ecw_set_win_data_dirs();
#endif
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

#if defined(_WIN32)
static INIT_ONCE g_register_once = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK do_register_cb(PINIT_ONCE once, PVOID param, PVOID *ctx) {
  (void)once;
  (void)param;
  (void)ctx;
  do_register();
  return TRUE;
}
static void ensure_registered(void) {
  InitOnceExecuteOnce(&g_register_once, do_register_cb, NULL, NULL);
}
#else
static void ensure_registered(void) {
  pthread_once(&g_register_once, do_register);
}
#endif

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

// Rectifies a distorted map image (hand-drawn / photographed, not exactly
// straight) into a north-up WGS84 PNG using a Thin-Plate-Spline over the
// user's control points — the gdalwarp -tps equivalent, in-process.
//
// gcps: gcp_count × 4 doubles, [pixel_x, pixel_y, lon, lat] per point (WGS84).
// Writes dst_png_path (overwritten), fills out_gt6 with the output dataset's
// geotransform (north-up: gt[2]==gt[4]==0) and out_size2 with {width, height}.
// Returns 0 on success, negative on error.
//
// Pipeline: GDALTranslate (attach GCPs to a MEM copy — PNG can't store GCPs,
// and PAM is disabled) → GDALWarp -tps to MEM → GDALCreateCopy to PNG.
int ecw_warp_tps(const char *src_path, const char *dst_png_path, int gcp_count,
                 const double *gcps, double *out_gt6, int *out_size2) {
  ensure_registered();
  if (!src_path || !dst_png_path || !gcps || !out_gt6 || !out_size2 ||
      gcp_count < 3) {
    return -1;
  }

  GDALDatasetH src = GDALOpen(src_path, /*GA_ReadOnly*/ 0);
  if (!src) {
    LOGE("warp_tps: open failed: %s — %s", src_path, CPLGetLastErrorMsg());
    return -2;
  }

  // ── 1. Attach GCPs (+expand palette→rgba) via gdal_translate to MEM ──
  int has_palette =
      GDALGetRasterColorTable(GDALGetRasterBand(src, 1)) != NULL;
  // argv: -of MEM -a_srs EPSG:4326 [-expand rgba] + 5 slots per GCP + NULL
  int max_args = 6 + gcp_count * 5 + 1;
  char **argv = (char **)calloc((size_t)max_args, sizeof(char *));
  // 32 bytes per formatted number, 4 numbers per GCP
  char *pool = (char *)malloc((size_t)gcp_count * 4 * 32);
  if (!argv || !pool) {
    free(argv); free(pool); GDALClose(src);
    return -3;
  }
  int ai = 0;
  argv[ai++] = "-of";    argv[ai++] = "MEM";
  argv[ai++] = "-a_srs"; argv[ai++] = "EPSG:4326";
  if (has_palette) { argv[ai++] = "-expand"; argv[ai++] = "rgba"; }
  for (int i = 0; i < gcp_count; i++) {
    argv[ai++] = "-gcp";
    for (int j = 0; j < 4; j++) {
      char *slot = pool + ((size_t)i * 4 + (size_t)j) * 32;
      snprintf(slot, 32, "%.12g", gcps[i * 4 + j]);
      argv[ai++] = slot;
    }
  }
  argv[ai] = NULL;

  GDALTranslateOptionsH topts = GDALTranslateOptionsNew(argv, NULL);
  GDALDatasetH gcp_ds =
      topts ? GDALTranslate("", src, topts, NULL) : NULL;
  if (topts) GDALTranslateOptionsFree(topts);
  free(argv);
  free(pool);
  if (!gcp_ds) {
    LOGE("warp_tps: translate(GCP attach) failed: %s", CPLGetLastErrorMsg());
    GDALClose(src);
    return -4;
  }

  // ── 2. TPS warp to north-up WGS84 (alpha only if not already present) ──
  int src_bands = GDALGetRasterCount(gcp_ds);
  char *wargv[10];
  int wi = 0;
  wargv[wi++] = "-of";    wargv[wi++] = "MEM";
  wargv[wi++] = "-tps";
  wargv[wi++] = "-t_srs"; wargv[wi++] = "EPSG:4326";
  wargv[wi++] = "-r";     wargv[wi++] = "bilinear";
  if (src_bands < 4) wargv[wi++] = "-dstalpha";
  wargv[wi] = NULL;

  GDALWarpAppOptionsH wopts = GDALWarpAppOptionsNew(wargv, NULL);
  int usage_err = 0;
  GDALDatasetH warped =
      wopts ? GDALWarp("", NULL, 1, &gcp_ds, wopts, &usage_err) : NULL;
  if (wopts) GDALWarpAppOptionsFree(wopts);
  GDALClose(gcp_ds);
  GDALClose(src);
  if (!warped) {
    LOGE("warp_tps: GDALWarp failed (usageErr=%d): %s", usage_err,
         CPLGetLastErrorMsg());
    return -5;
  }

  // ── 3. Emit PNG + report geotransform/size ──
  if (GDALGetGeoTransform(warped, out_gt6) != 0) {
    LOGE("warp_tps: no geotransform on warped result");
    GDALClose(warped);
    return -6;
  }
  out_size2[0] = GDALGetRasterXSize(warped);
  out_size2[1] = GDALGetRasterYSize(warped);

  void *png_drv = GDALGetDriverByName("PNG");
  if (!png_drv) {
    LOGE("warp_tps: PNG driver missing");
    GDALClose(warped);
    return -7;
  }
  GDALDatasetH out = GDALCreateCopy(png_drv, dst_png_path, warped,
                                    /*bStrict*/ 0, NULL, NULL, NULL);
  GDALClose(warped);
  if (!out) {
    LOGE("warp_tps: PNG CreateCopy failed: %s — %s", dst_png_path,
         CPLGetLastErrorMsg());
    return -8;
  }
  GDALClose(out);
  LOGI("warp_tps ok: %s (%dx%d, %d GCPs)", dst_png_path, out_size2[0],
       out_size2[1], gcp_count);
  return 0;
}
