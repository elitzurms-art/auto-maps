#
# auto_maps_ecw — native ECW satellite decode for iOS.
#
# Links the prebuilt GDAL+PROJ+ECW(SDK 3.3) static stack (gdal_ecw.xcframework)
# and compiles ecw_wrapper.c — the SAME wrapper Android uses (full parity).
#
# The xcframework + proj.db are produced by ios_native/build_gdal_xcframework.sh,
# which MUST run before `pod install`. This podspec is inert until referenced
# from the Podfile (kept separate so it can't break the iOS build prematurely).
#
Pod::Spec.new do |s|
  s.name             = 'auto_maps_ecw'
  s.version          = '0.1.0'
  s.summary          = 'Native ECW satellite raster decode (GDAL + PROJ + ECW SDK 3.3) for iOS.'
  s.description      = 'Compiles ecw_wrapper.c (shared with Android) against a static ' \
                       'GDAL/PROJ/ECW stack so the app can warp .ecw imagery to Web Mercator ' \
                       'tiles natively, mirroring the Android implementation.'
  s.homepage         = 'https://elitzur.net'
  s.license          = { :type => 'Proprietary', :text => 'Internal — see project.' }
  s.author           = { 'Auto Maps' => 'auto_maps@elitzur.net' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '16.0'

  # Shared C wrapper (one source of truth with the Android NDK build) + a tiny
  # ObjC +load that points PROJ at the bundled proj.db on iOS.
  s.source_files     = ['../android/app/src/main/cpp/ecw_wrapper.c', 'ecw_proj_init.m']

  # Prebuilt stack — produced by ios_native/build_gdal_xcframework.sh.
  s.vendored_frameworks = 'gdal_ecw/gdal_ecw.xcframework'

  # PROJ runtime database (reprojection). The wrapper points PROJ at the bundle.
  s.resource_bundles = { 'auto_maps_ecw_proj' => ['gdal_ecw/share/proj/proj.db'] }

  # System libraries the static GDAL stack pulls in (proven by the CI link-proof).
  s.libraries        = 'c++', 'sqlite3', 'iconv', 'z', 'xml2'

  s.requires_arc     = false
  s.pod_target_xcconfig = {
    'CLANG_WARN_DOCUMENTATION_COMMENTS' => 'NO',
    'GCC_WARN_INHIBIT_ALL_WARNINGS'     => 'YES',
  }
end
