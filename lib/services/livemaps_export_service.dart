import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;

import 'world_file_parser_service.dart';

/// תוצאת ייצוא — הנתיבים של שני הקבצים שנכתבו.
class LiveMapsExportResult {
  final String pngPath;
  final String jsonPath;

  const LiveMapsExportResult({required this.pngPath, required this.jsonPath});
}

/// שירות ייצוא שכבה ג'יאורפרנסית בפורמט שאפליקציית LiveMaps צורכת.
///
/// כותב שני קבצים לתיקיית היעד:
///  * `<name>.png`          — התמונה (מומרת ל-PNG אם צריך).
///  * `<name>.livemap.json` — מטא-דאטה בסכימה הקנונית (מפתחות nw/ne/se/sw,
///    קואורדינטות `[lat, lon]` — lat קודם).
class LiveMapsExportService {
  static const int schemaVersion = 1;

  /// מייצא שכבה. [name] = שם בסיס לקבצים (בלי סיומת).
  ///
  /// [cornersWgs84] בסדר NW, NE, SE, SW. אם null — נגזרות מ-bbox
  /// (SW/NE) של [result] כ-fallback (מאבד סיבוב, מיושר-צפון).
  Future<LiveMapsExportResult> export({
    required String sourceImagePath,
    required WorldFileResult result,
    required String name,
    required String targetDir,
    String sourceCrs = 'EPSG:2039',
  }) async {
    final dir = Directory(targetDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final safeName = _sanitize(name);
    final pngPath = p.join(targetDir, '$safeName.png');
    final jsonPath = p.join(targetDir, '$safeName.livemap.json');

    // 1. כתיבת התמונה כ-PNG (המרה אם המקור אינו PNG).
    await _writePng(sourceImagePath, pngPath);

    // 2. הפקת 4 הפינות (NW, NE, SE, SW).
    final corners = result.cornersWgs84 ?? _cornersFromBbox(result);

    // 3. כתיבת ה-JSON בסכימה הקנונית.
    final json = <String, dynamic>{
      'version': schemaVersion,
      'name': name,
      'image': '$safeName.png',
      'imageWidth': result.imageWidth,
      'imageHeight': result.imageHeight,
      'transform': 'affine',
      'corners': {
        'nw': _latLon(corners[0]),
        'ne': _latLon(corners[1]),
        'se': _latLon(corners[2]),
        'sw': _latLon(corners[3]),
      },
      'sourceCrs': sourceCrs,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'tool': 'auto_maps',
    };

    const encoder = JsonEncoder.withIndent('  ');
    await File(jsonPath).writeAsString(encoder.convert(json));

    return LiveMapsExportResult(pngPath: pngPath, jsonPath: jsonPath);
  }

  /// `[lat, lon]` — lat קודם (קריטי לצרכן ב-LiveMaps).
  List<double> _latLon(LatLng c) => [c.latitude, c.longitude];

  /// גזירת 4 פינות מ-bbox כשאין פינות אמיתיות (fallback, מיושר-צפון).
  List<LatLng> _cornersFromBbox(WorldFileResult r) {
    final n = r.northEast.latitude;
    final s = r.southWest.latitude;
    final e = r.northEast.longitude;
    final w = r.southWest.longitude;
    return [
      LatLng(n, w), // NW
      LatLng(n, e), // NE
      LatLng(s, e), // SE
      LatLng(s, w), // SW
    ];
  }

  /// כתיבת התמונה כ-PNG. אם המקור כבר PNG — העתקה ישירה.
  Future<void> _writePng(String sourcePath, String pngPath) async {
    final ext = p.extension(sourcePath).toLowerCase();
    if (ext == '.png') {
      await File(sourcePath).copy(pngPath);
      return;
    }
    final bytes = await File(sourcePath).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw const FormatException('Failed to decode source image for export');
    }
    await File(pngPath).writeAsBytes(img.encodePng(decoded));
  }

  String _sanitize(String name) {
    final cleaned = name.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return cleaned.isEmpty ? 'layer' : cleaned;
  }
}
