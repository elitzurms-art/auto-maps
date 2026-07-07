import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;

import 'gdal_warp_service.dart';

/// פורמטי-ייצוא נתמכים (מעבר ל-LiveMaps).
enum ExportFormat { liveMaps, worldFile, kmz, geoTiff }

/// שירות ייצוא לפורמטים ג'יאו-סטנדרטיים: World file (+.prj), KMZ
/// (GroundOverlay ל-Google Earth), ו-GeoTIFF (דרך GDAL). כולם צורכים את
/// 4 הפינות (NW, NE, SE, SW) ב-WGS84 שכבר חושבו.
class GeoExportService {
  /// WKT מינימלי של WGS84 ל-.prj.
  static const _wgs84Wkt =
      'GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,'
      '298.257223563]],PRIMEM["Greenwich",0],'
      'UNIT["degree",0.0174532925199433]]';

  /// כותב World file ל-PNG קיים: `<base>.pgw` (פרמטרי-affine) + `<base>.prj`
  /// (WGS84). QGIS/ArcGIS קוראים אותם מיד. [corners] בסדר NW, NE, SE, SW.
  /// מחזיר את נתיבי הקבצים שנכתבו.
  static Future<List<String>> writeWorldFile({
    required String pngPath,
    required List<LatLng> corners,
    required int imageWidth,
    required int imageHeight,
  }) async {
    final nw = corners[0], ne = corners[1], sw = corners[3];
    final w = imageWidth.toDouble(), h = imageHeight.toDouble();

    // affine: world = A·px + B·py + C (lon) ; world = D·px + E·py + F (lat).
    final a = (ne.longitude - nw.longitude) / w; // גודל-פיקסל x
    final b = (sw.longitude - nw.longitude) / h; // סקew x
    final d = (ne.latitude - nw.latitude) / w; // סקew y
    final e = (sw.latitude - nw.latitude) / h; // גודל-פיקסל y (שלילי לצפון-למעלה)
    // C/F = מרכז הפיקסל השמאלי-עליון (הזזת חצי-פיקסל מהפינה).
    final c = nw.longitude + 0.5 * a + 0.5 * b;
    final f = nw.latitude + 0.5 * d + 0.5 * e;

    final base = p.withoutExtension(pngPath);
    // סדר קנוני של world file: A, D, B, E, C, F (שורה לכל אחד).
    final pgw = '$base.pgw';
    await File(pgw).writeAsString(
      [a, d, b, e, c, f].map((v) => v.toStringAsFixed(12)).join('\n') + '\n',
    );
    final prj = '$base.prj';
    await File(prj).writeAsString(_wgs84Wkt);
    return [pgw, prj];
  }

  /// כותב KMZ (GroundOverlay עם gx:LatLonQuad — תומך ב-4 פינות/סיבוב).
  /// נפתח ב-Google Earth ובאפליקציות-שיטוט. התמונה מוטמעת בתוך ה-KMZ.
  /// [corners] בסדר NW, NE, SE, SW. מחזיר את נתיב ה-KMZ.
  static Future<String> writeKmz({
    required String pngPath,
    required List<LatLng> corners,
    required String name,
    required String kmzPath,
  }) async {
    final nw = corners[0], ne = corners[1], se = corners[2], sw = corners[3];
    String c(LatLng ll) =>
        '${ll.longitude.toStringAsFixed(9)},${ll.latitude.toStringAsFixed(9)},0';
    // gx:LatLonQuad — נגד כיוון-השעון החל מהפינה השמאלית-תחתונה: SW, SE, NE, NW.
    final coords = '${c(sw)} ${c(se)} ${c(ne)} ${c(nw)}';
    final imgName = p.basename(pngPath);
    final kml = '''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2">
  <GroundOverlay>
    <name>${_xml(name)}</name>
    <Icon><href>${_xml(imgName)}</href></Icon>
    <gx:LatLonQuad>
      <coordinates>$coords</coordinates>
    </gx:LatLonQuad>
  </GroundOverlay>
</kml>
''';

    final kmlBytes = utf8.encode(kml);
    final pngBytes = File(pngPath).readAsBytesSync();
    final archive = Archive()
      ..addFile(ArchiveFile('doc.kml', kmlBytes.length, kmlBytes))
      ..addFile(ArchiveFile(imgName, pngBytes.length, pngBytes));
    final zipped = ZipEncoder().encode(archive)!;
    await File(kmzPath).writeAsBytes(zipped);
    return kmzPath;
  }

  /// GeoTIFF זמין (דורש את GDAL המצורף).
  static bool get geoTiffSupported => GdalWarpService.isSupportedPlatform;

  /// כותב GeoTIFF (WGS84, עם geotransform מלא — תומך בסיבוב) מ-[pngPath].
  /// מחזיר את נתיב ה-TIF.
  static Future<String> writeGeoTiff({
    required String pngPath,
    required List<LatLng> corners,
    required int imageWidth,
    required int imageHeight,
    required String tifPath,
  }) async {
    await GdalWarpService.writeGeoTiff(
      srcImagePath: pngPath,
      dstTiffPath: tifPath,
      corners: corners,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
    );
    return tifPath;
  }

  /// מוודא שקיים PNG בנתיב [pngPath] (ממיר מהמקור אם צריך). מוחזר כדי
  /// שהפורמטים שנשענים על PNG (world file/KMZ) יעבדו גם בלי LiveMaps.
  static Future<void> ensurePng(String sourceImagePath, String pngPath) async {
    if (File(pngPath).existsSync() &&
        p.equals(sourceImagePath, pngPath) == false) {
      // כבר קיים (נכתב ע"י LiveMaps) — לא כותבים שוב.
      return;
    }
    final ext = p.extension(sourceImagePath).toLowerCase();
    if (ext == '.png') {
      await File(sourceImagePath).copy(pngPath);
      return;
    }
    final decoded = img.decodeImage(await File(sourceImagePath).readAsBytes());
    if (decoded == null) {
      throw const FormatException('כשל בפענוח תמונת-המקור לייצוא');
    }
    await File(pngPath).writeAsBytes(img.encodePng(decoded));
  }

  static String _xml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
