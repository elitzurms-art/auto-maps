// בוחן עצמאי ל-ecw_warp_tps: רץ מתוך תיקיית ה-Debug של האפליקציה כדי
// שה-loader יפתור את כל סגירת ה-GDAL מהתיקייה — בדיוק כמו auto_maps.exe.
#include <windows.h>
#include <stdio.h>

typedef int (*warp_fn)(const char *, const char *, int, const double *,
                       double *, int *);

int main(int argc, char **argv) {
  if (argc < 3) {
    printf("usage: tps_harness <src.png> <dst.png>\n");
    return 9;
  }
  HMODULE m = LoadLibraryA("auto_maps_ecw.dll");
  if (!m) {
    printf("LOAD FAIL err=%lu\n", GetLastError());
    return 1;
  }
  warp_fn f = (warp_fn)GetProcAddress(m, "ecw_warp_tps");
  if (!f) {
    printf("NO PROC ecw_warp_tps\n");
    return 2;
  }
  // ריבוע ~1 ק"מ ליד ירושלים עם מרכז מוזז מעט — מכריח את ה-TPS לעוות.
  double gcps[] = {
      0,   0,   35.2000, 31.8000,
      799, 0,   35.2105, 31.8006,
      799, 599, 35.2110, 31.7925,
      0,   599, 35.1998, 31.7930,
      400, 300, 35.2060, 31.7969,
  };
  double gt[6];
  int size[2];
  int rc = f(argv[1], argv[2], 5, gcps, gt, size);
  printf("rc=%d\n", rc);
  if (rc == 0) {
    printf("gt=[%.6f %.9f %.9f %.6f %.9f %.9f] size=%dx%d\n", gt[0], gt[1],
           gt[2], gt[3], gt[4], gt[5], size[0], size[1]);
  }
  return rc;
}
