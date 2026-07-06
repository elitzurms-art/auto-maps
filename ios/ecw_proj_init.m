//
// navigate_ecw — point PROJ at its bundled database at app launch.
//
// ecw_wrapper.c is plain C and can't resolve the iOS bundle path. The pod ships
// proj.db inside auto_maps_ecw_proj.bundle (resource_bundle); without telling PROJ
// where it is, every reprojection (ECW source SRS -> Web Mercator) fails.
//
// +load runs at image load — before main, hence before any ecw_open() / GDAL use —
// so PROJ_DATA is set before the driver registers. CPLSetConfigOption is process-
// global, so a single call here covers the whole app.
//
#import <Foundation/Foundation.h>

extern void CPLSetConfigOption(const char *pszKey, const char *pszValue);

@interface AutoMapsEcwProjInit : NSObject
@end

@implementation AutoMapsEcwProjInit

+ (void)load {
  @autoreleasepool {
    // Static frameworks copy their resource bundles into the app's main bundle.
    NSString *bundlePath =
        [[NSBundle mainBundle] pathForResource:@"auto_maps_ecw_proj" ofType:@"bundle"];
    if (bundlePath == nil) {
      NSBundle *own = [NSBundle bundleForClass:[AutoMapsEcwProjInit class]];
      bundlePath = [own pathForResource:@"auto_maps_ecw_proj" ofType:@"bundle"];
    }

    if (bundlePath != nil) {
      NSString *projDb = [bundlePath stringByAppendingPathComponent:@"proj.db"];
      if ([[NSFileManager defaultManager] fileExistsAtPath:projDb]) {
        const char *dir = [bundlePath UTF8String];
        CPLSetConfigOption("PROJ_DATA", dir);  // PROJ 9 / GDAL 3.10
        CPLSetConfigOption("PROJ_LIB", dir);   // older fallback
        NSLog(@"[auto_maps_ecw] PROJ_DATA = %@", bundlePath);
        return;
      }
    }
    NSLog(@"[auto_maps_ecw] WARNING: auto_maps_ecw_proj.bundle/proj.db not found — "
          @"ECW reprojection will fail at runtime");
  }
}

@end
