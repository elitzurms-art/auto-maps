import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show Offset;

import 'package:ffi/ffi.dart';
import 'package:latlong2/latlong.dart';

import 'ecw/ecw_gdal_decoder.dart' show openEcwLibrary;
import 'world_file_parser_service.dart';

typedef _WarpTpsNative =
    Int32 Function(
      Pointer<Utf8> srcPath,
      Pointer<Utf8> dstPngPath,
      Int32 gcpCount,
      Pointer<Double> gcps,
      Pointer<Double> outGt6,
      Pointer<Int32> outSize2,
    );
typedef _WarpTpsDart =
    int Function(
      Pointer<Utf8> srcPath,
      Pointer<Utf8> dstPngPath,
      int gcpCount,
      Pointer<Double> gcps,
      Pointer<Double> outGt6,
      Pointer<Int32> outSize2,
    );

typedef _GeoTiffNative = Int32 Function(
    Pointer<Utf8> src, Pointer<Utf8> dst, Pointer<Double> gt6);
typedef _GeoTiffDart = int Function(
    Pointer<Utf8> src, Pointer<Utf8> dst, Pointer<Double> gt6);

/// תוצאת יישור TPS — הרסטר המיושר (PNG חדש) + הפינות/מימדים שלו.
class TpsWarpResult {
  /// ה-PNG המיושר-צפון שנכתב (זו התמונה שמיוצאת ל-LiveMaps במקום המקור).
  final String pngPath;

  /// bounds + פינות של הרסטר המיושר (WGS84, מיושר-צפון).
  final WorldFileResult result;

  const TpsWarpResult({required this.pngPath, required this.result});
}

/// יישור מפות "לא ישרות" (מצולמות/משורטטות ביד) ב-Thin-Plate-Spline —
/// המקבילה של `gdalwarp -tps`, דרך ה-GDAL המצורף (אותו נתיב נייטיבי כמו ECW:
/// `auto_maps_ecw.dll` / `libauto_maps_ecw.so` / linkage סטטי ב-iOS).
///
/// הפלט נשאר בחוזה של LiveMaps: רסטר מיושר-צפון + 4 פינות. הצרכן לא משתנה —
/// רק `transform` ב-json מסומן `"tps"`.
class GdalWarpService {
  /// אותן פלטפורמות כמו ה-ECW הנייטיבי (שם יושב GDAL המצורף).
  static bool get isSupportedPlatform =>
      Platform.isAndroid || Platform.isIOS || Platform.isWindows;

  /// מיישר את [srcImagePath] לפי נקודות ההתאמה, כותב PNG ל-[dstPngPath].
  ///
  /// דורש לפחות 3 נקודות (מומלץ 5+ לפיזור טוב של ה-spline). רץ ב-isolate
  /// נפרד — קריאת ה-FFI חוסמת וכבדה (שניות עבור תמונות גדולות).
  static Future<TpsWarpResult> warpTps({
    required String srcImagePath,
    required List<({Offset pixel, LatLng world})> points,
    required String dstPngPath,
  }) async {
    if (!isSupportedPlatform) {
      throw UnsupportedError(
        'יישור TPS דורש את GDAL המצורף (Windows/Android/iOS בלבד)',
      );
    }
    if (points.length < 3) {
      throw const FormatException('יישור TPS דורש לפחות 3 נקודות');
    }

    // שיטוח הנקודות ל-[px, py, lon, lat] — עביר בין isolates.
    final flat = <double>[
      for (final p in points) ...[
        p.pixel.dx,
        p.pixel.dy,
        p.world.longitude,
        p.world.latitude,
      ],
    ];

    final raw = await Isolate.run(
      () => _warpInIsolate(srcImagePath, dstPngPath, flat),
    );

    final gt = raw.gt;
    final w = raw.width;
    final h = raw.height;

    // geotransform מיושר-צפון (gt[2]==gt[4]==0): פינות ממלוא ההיקף (w,h).
    final nw = LatLng(gt[3], gt[0]);
    final ne = LatLng(gt[3], gt[0] + w * gt[1]);
    final se = LatLng(gt[3] + h * gt[5], gt[0] + w * gt[1]);
    final sw = LatLng(gt[3] + h * gt[5], gt[0]);

    return TpsWarpResult(
      pngPath: dstPngPath,
      result: WorldFileResult(
        southWest: sw,
        northEast: ne,
        detectedCrs: 'EPSG:4326',
        imageWidth: w,
        imageHeight: h,
        cornersWgs84: [nw, ne, se, sw],
      ),
    );
  }

  /// כותב GeoTIFF (WGS84) מ-[srcImagePath] עם geotransform מלא הנגזר מ-4
  /// הפינות — **תומך בסיבוב**. [corners] בסדר NW, NE, SE, SW; [imageWidth]/
  /// [imageHeight] הם ממדי-הרסטר (חייבים להתאים ל-srcImagePath). למפה
  /// מיושרת-צפון איברי-הסיבוב יוצאים 0 → זהה למיושר-צפון.
  static Future<void> writeGeoTiff({
    required String srcImagePath,
    required String dstTiffPath,
    required List<LatLng> corners,
    required int imageWidth,
    required int imageHeight,
  }) async {
    if (!isSupportedPlatform) {
      throw UnsupportedError(
        'ייצוא GeoTIFF דורש את GDAL המצורף (Windows/Android/iOS בלבד)',
      );
    }
    final gt = _gtFromCorners(corners, imageWidth, imageHeight);
    await Isolate.run(() => _geoTiffInIsolate(srcImagePath, dstTiffPath, gt));
  }

  /// geotransform בסדר GDAL: {originX, pxW, rowRot, originY, colRot, pxH}.
  /// world = gt0 + px·gt1 + py·gt2 (lon) ; gt3 + px·gt4 + py·gt5 (lat).
  /// [corners] בסדר NW, NE, SE, SW.
  static List<double> _gtFromCorners(
      List<LatLng> corners, int imageWidth, int imageHeight) {
    final nw = corners[0], ne = corners[1], sw = corners[3];
    final w = imageWidth.toDouble(), h = imageHeight.toDouble();
    return <double>[
      nw.longitude,
      (ne.longitude - nw.longitude) / w,
      (sw.longitude - nw.longitude) / h,
      nw.latitude,
      (ne.latitude - nw.latitude) / w,
      (sw.latitude - nw.latitude) / h,
    ];
  }

  static void _geoTiffInIsolate(String src, String dst, List<double> gt) {
    final lib = openEcwLibrary();
    final fn = lib.lookupFunction<_GeoTiffNative, _GeoTiffDart>(
      'ecw_write_geotiff',
    );
    final srcP = src.toNativeUtf8();
    final dstP = dst.toNativeUtf8();
    final gtP = malloc<Double>(6);
    try {
      gtP.asTypedList(6).setAll(0, gt);
      final rc = fn(srcP, dstP, gtP);
      if (rc != 0) throw Exception('ייצוא GeoTIFF נכשל (קוד $rc)');
    } finally {
      malloc.free(srcP);
      malloc.free(dstP);
      malloc.free(gtP);
    }
  }

  static ({List<double> gt, int width, int height}) _warpInIsolate(
    String srcPath,
    String dstPath,
    List<double> flatGcps,
  ) {
    final lib = openEcwLibrary();
    final warp = lib.lookupFunction<_WarpTpsNative, _WarpTpsDart>(
      'ecw_warp_tps',
    );

    final n = flatGcps.length ~/ 4;
    final srcP = srcPath.toNativeUtf8();
    final dstP = dstPath.toNativeUtf8();
    final gcpsP = malloc<Double>(flatGcps.length);
    final gtP = malloc<Double>(6);
    final sizeP = malloc<Int32>(2);
    try {
      gcpsP.asTypedList(flatGcps.length).setAll(0, flatGcps);
      final rc = warp(srcP, dstP, n, gcpsP, gtP, sizeP);
      if (rc != 0) {
        throw Exception('יישור TPS נכשל (קוד $rc)');
      }
      return (
        gt: List<double>.from(gtP.asTypedList(6)),
        width: sizeP[0],
        height: sizeP[1],
      );
    } finally {
      malloc.free(srcP);
      malloc.free(dstP);
      malloc.free(gcpsP);
      malloc.free(gtP);
      malloc.free(sizeP);
    }
  }
}
