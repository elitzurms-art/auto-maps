/*
 * Link-proof for the iOS ECW pipeline (Phase 1c).
 *
 * Links ecw_wrapper.c (the same file Android uses) against the combined
 * gdal+proj+ecw static lib for iphoneos arm64. If this links, every GDAL/PROJ/
 * ECW symbol the wrapper needs is resolved — i.e. the iOS pod will link too.
 * (Built for the device target; not run here — symbol resolution is the proof.)
 */
extern const char *ecw_gdal_version(void);
extern void *ecw_open(const char *path);
extern int ecw_width(void *h);
extern int ecw_render_tile(void *h, double minx, double miny, double maxx,
                           double maxy, int size, unsigned char **out_rgba);
extern void ecw_free(unsigned char *p);
extern void ecw_close(void *h);

int main(void) {
  /* Reference the wrapper entry points so the linker must resolve them. */
  const char *v = ecw_gdal_version();
  void *(*open_fn)(const char *) = ecw_open;
  (void)open_fn;
  (void)ecw_width;
  (void)ecw_render_tile;
  (void)ecw_free;
  (void)ecw_close;
  return v ? 0 : 1;
}
