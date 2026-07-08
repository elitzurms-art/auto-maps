import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:proj4dart/proj4dart.dart' as proj4;
import 'package:xml/xml.dart' as xml;

/// תוצאת פרסור world file / georeferencing
///
/// שומר גם bounding box (SW/NE) לתאימות אחורה, וגם את 4 הפינות האמיתיות
/// ([cornersWgs84], בסדר NW, NE, SE, SW) — כדי לשמר סיבוב שה-bbox מאבד.
class WorldFileResult {
  final LatLng southWest;
  final LatLng northEast;
  final String detectedCrs;
  final int imageWidth;
  final int imageHeight;

  /// 4 הפינות האמיתיות ב-WGS84, בסדר: NW, NE, SE, SW.
  /// null כשהמקור לא סיפק פינות (למשל bbox בלבד).
  final List<LatLng>? cornersWgs84;

  const WorldFileResult({
    required this.southWest,
    required this.northEast,
    required this.detectedCrs,
    required this.imageWidth,
    required this.imageHeight,
    this.cornersWgs84,
  });

  LatLng? get nw => cornersWgs84?[0];
  LatLng? get ne => cornersWgs84?[1];
  LatLng? get se => cornersWgs84?[2];
  LatLng? get sw => cornersWgs84?[3];
}

/// שירות פרסור world file (PGW/TFW/JGW) + זיהוי CRS + המרה ל-WGS84
class WorldFileParserService {
  // CRS definitions
  static const _itmProj =
      '+proj=tmerc +lat_0=31.7343936111111 +lon_0=35.2045169444444 '
      '+k=1.0000067 +x_0=219529.584 +y_0=626907.39 +ellps=GRS80 '
      '+towgs84=-48,55,52,0,0,0,0 +units=m +no_defs';
  static const _utm36nProj =
      '+proj=utm +zone=36 +datum=WGS84 +units=m +no_defs';
  static const _oldIsraelProj =
      '+proj=cass +lat_0=31.7340969444444 +lon_0=35.2120805555556 '
      '+x_0=170251.555 +y_0=1126867.909 +a=6378300.789 +b=6356566.435 '
      '+units=m +no_defs';
  static const _wgs84Proj = '+proj=longlat +datum=WGS84 +no_defs';

  /// פרסור world file + קריאת מימדי תמונה + חישוב bounds ב-WGS84
  Future<WorldFileResult> parse({
    required String worldFileContent,
    required String imagePath,
    String? crsOverride,
  }) async {
    // 1. פרסור 6 שורות של world file
    final lines = worldFileContent.trim().split(RegExp(r'\r?\n'));
    if (lines.length < 6) {
      throw FormatException(
          'World file must have 6 lines, got ${lines.length}');
    }

    final a = double.parse(lines[0].trim()); // pixel size X
    final d = double.parse(lines[1].trim()); // rotation
    final b = double.parse(lines[2].trim()); // rotation
    final e = double.parse(lines[3].trim()); // pixel size Y (negative)
    final c = double.parse(lines[4].trim()); // upper-left X
    final f = double.parse(lines[5].trim()); // upper-left Y

    // 2. קריאת מימדי תמונה
    final imageSize = await _getImageSize(imagePath);
    final width = imageSize.width;
    final height = imageSize.height;

    // 3. חישוב 4 פינות (תומך סיבוב)
    // pixel (col, row) → world: x = c + a*col + b*row, y = f + d*col + e*row
    final ulX = c;
    final ulY = f;
    final urX = c + a * (width - 1);
    final urY = f + d * (width - 1);
    final llX = c + b * (height - 1);
    final llY = f + e * (height - 1);
    final lrX = c + a * (width - 1) + b * (height - 1);
    final lrY = f + d * (width - 1) + e * (height - 1);

    // 4. זיהוי CRS
    final crs = crsOverride ?? detectCrs(c, f);

    // 5. המרה ל-WGS84
    final ul = projectToWgs84(ulX, ulY, crs);
    final ur = projectToWgs84(urX, urY, crs);
    final ll = projectToWgs84(llX, llY, crs);
    final lr = projectToWgs84(lrX, lrY, crs);
    final corners = [ul, ur, ll, lr];

    // 6. Bounding box
    double minLat = corners[0].latitude;
    double maxLat = corners[0].latitude;
    double minLng = corners[0].longitude;
    double maxLng = corners[0].longitude;
    for (final corner in corners) {
      minLat = min(minLat, corner.latitude);
      maxLat = max(maxLat, corner.latitude);
      minLng = min(minLng, corner.longitude);
      maxLng = max(maxLng, corner.longitude);
    }

    return WorldFileResult(
      southWest: LatLng(minLat, minLng),
      northEast: LatLng(maxLat, maxLng),
      detectedCrs: crs,
      imageWidth: width,
      imageHeight: height,
      // NW, NE, SE, SW
      cornersWgs84: [ul, ur, lr, ll],
    );
  }

  /// זיהוי CRS אוטומטי לפי טווח ערכים
  String detectCrs(double x, double y) {
    // WGS84: lon < 360, lat < 90
    if (x.abs() < 360 && y.abs() < 90) {
      return 'EPSG:4326';
    }
    // ITM (Israel Transverse Mercator): X 100K-300K, Y 400K-800K
    if (x >= 100000 && x <= 300000 && y >= 400000 && y <= 800000) {
      return 'EPSG:2039';
    }
    // UTM 36N: Y 3M-4M
    if (y >= 3000000 && y <= 4000000) {
      return 'EPSG:32636';
    }
    // Old Israel Grid: X 100K-300K, Y 800K-1.3M
    if (x >= 100000 && x <= 300000 && y >= 800000 && y <= 1300000) {
      return 'EPSG:28193';
    }
    // Default: ITM (common for Israel)
    return 'EPSG:2039';
  }

  /// המרת קואורדינטה ל-WGS84
  LatLng projectToWgs84(double x, double y, String crs) {
    if (crs == 'EPSG:4326') {
      return LatLng(y, x); // WGS84 — x=lon, y=lat
    }

    final srcDef = _projDefinition(crs);
    final src = proj4.Projection.parse(srcDef);
    final dst = proj4.Projection.parse(_wgs84Proj);

    final point = proj4.Point(x: x, y: y);
    final result = src.transform(dst, point);
    return LatLng(result.y, result.x);
  }

  /// המרה הפוכה — WGS84 → קואורדינטה מוקרנת (ITM/UTM וכו').
  /// מחזיר easting/northing במטרים. ל-EPSG:4326 מחזיר lon/lat כפי שהם.
  ({double x, double y}) wgs84ToProjected(LatLng ll, String crs) {
    if (crs == 'EPSG:4326') {
      return (x: ll.longitude, y: ll.latitude);
    }
    final src = proj4.Projection.parse(_wgs84Proj);
    final dst = proj4.Projection.parse(_projDefinition(crs));
    final point = proj4.Point(x: ll.longitude, y: ll.latitude);
    final result = src.transform(dst, point);
    return (x: result.x, y: result.y);
  }

  String _projDefinition(String crs) {
    switch (crs) {
      case 'EPSG:2039':
        return _itmProj;
      case 'EPSG:32636':
        return _utm36nProj;
      case 'EPSG:28193':
        return _oldIsraelProj;
      case 'EPSG:4326':
        return _wgs84Proj;
      default:
        return _itmProj;
    }
  }

  /// פרסור GeoTIFF — חילוץ bounds + CRS מ-TIFF tags + המרה ל-PNG
  /// מחזיר WorldFileResult + נתיב PNG שנוצר
  Future<({WorldFileResult result, String pngPath})> parseGeoTiff({
    required String tiffPath,
    String? crsOverride,
  }) async {
    final bytes = await File(tiffPath).readAsBytes();
    final data = ByteData.sublistView(bytes);

    // 1. קריאת byte order
    final byteOrder = bytes[0] == 0x49 ? Endian.little : Endian.big;
    final magic = data.getUint16(2, byteOrder);
    if (magic != 42) {
      throw const FormatException('Not a valid TIFF file');
    }

    // 2. קריאת IFD
    final ifdOffset = data.getUint32(4, byteOrder);
    final tags = _readIfdTags(data, ifdOffset, byteOrder);

    // 3. מימדי תמונה מ-TIFF tags
    final width = _getTagInt(tags, 256, data, byteOrder); // ImageWidth
    final height = _getTagInt(tags, 257, data, byteOrder); // ImageLength
    if (width == null || height == null) {
      throw const FormatException('Missing image dimensions in TIFF');
    }

    // 4. GeoTIFF metadata
    final pixelScale = _getTagDoubles(tags, 33550, data, byteOrder); // ModelPixelScaleTag
    final tiepoint = _getTagDoubles(tags, 33922, data, byteOrder); // ModelTiepointTag

    if (pixelScale == null || pixelScale.length < 2 ||
        tiepoint == null || tiepoint.length < 6) {
      throw const FormatException(
          'Missing GeoTIFF tags (ModelPixelScale / ModelTiepoint)');
    }

    final scaleX = pixelScale[0];
    final scaleY = pixelScale[1];
    // Tiepoint: [pixelI, pixelJ, pixelK, worldX, worldY, worldZ]
    final tpI = tiepoint[0];
    final tpJ = tiepoint[1];
    final worldX = tiepoint[3];
    final worldY = tiepoint[4];

    // 5. חישוב פינות (upper-left world coordinate)
    final ulX = worldX - tpI * scaleX;
    final ulY = worldY + tpJ * scaleY;
    final lrX = ulX + width * scaleX;
    final lrY = ulY - height * scaleY;

    // 6. זיהוי CRS
    String crs;
    if (crsOverride != null) {
      crs = crsOverride;
    } else {
      // נסיון לקרוא CRS מ-GeoKeys
      crs = _detectCrsFromGeoKeys(tags, data, byteOrder) ??
          detectCrs(ulX, ulY);
    }

    // 7. המרה ל-WGS84
    final sw = projectToWgs84(min(ulX, lrX), min(ulY, lrY), crs);
    final ne = projectToWgs84(max(ulX, lrX), max(ulY, lrY), crs);

    // 8. המרת TIFF ל-PNG
    final tiffImage = img.decodeTiff(bytes);
    if (tiffImage == null) {
      throw const FormatException('Failed to decode TIFF image');
    }
    final pngBytes = img.encodePng(tiffImage);
    final dir = p.dirname(tiffPath);
    final baseName = p.basenameWithoutExtension(tiffPath);
    final pngPath = p.join(dir, '${baseName}_converted.png');
    await File(pngPath).writeAsBytes(pngBytes);

    return (
      result: WorldFileResult(
        southWest: LatLng(
          min(sw.latitude, ne.latitude),
          min(sw.longitude, ne.longitude),
        ),
        northEast: LatLng(
          max(sw.latitude, ne.latitude),
          max(sw.longitude, ne.longitude),
        ),
        detectedCrs: crs,
        imageWidth: width,
        imageHeight: height,
      ),
      pngPath: pngPath,
    );
  }

  /// בדיקה אם קובץ הוא GeoTIFF
  static bool isGeoTiff(String path) {
    final ext = p.extension(path).toLowerCase();
    return ext == '.tif' || ext == '.tiff';
  }

  /// בדיקה אם קובץ הוא KMZ
  static bool isKmz(String path) {
    final ext = p.extension(path).toLowerCase();
    return ext == '.kmz';
  }

  /// פרסור KMZ — חילוץ GroundOverlay מ-KML + תמונה
  /// מחזיר WorldFileResult + נתיב PNG
  Future<({WorldFileResult result, String pngPath})> parseKmz({
    required String kmzPath,
  }) async {
    final bytes = await File(kmzPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    // 1. מציאת KML
    ArchiveFile? kmlFile;
    for (final file in archive) {
      if (file.name.toLowerCase().endsWith('.kml') && file.isFile) {
        kmlFile = file;
        break;
      }
    }
    if (kmlFile == null) {
      throw const FormatException('No KML file found in KMZ');
    }

    final kmlContent = String.fromCharCodes(kmlFile.content as List<int>);
    final doc = xml.XmlDocument.parse(kmlContent);

    // 2. מציאת GroundOverlay
    final overlays = doc.findAllElements('GroundOverlay');
    if (overlays.isEmpty) {
      throw const FormatException('No GroundOverlay found in KML');
    }
    final overlay = overlays.first;

    // 3. חילוץ bounds מ-LatLonBox
    final latLonBox = overlay.findElements('LatLonBox').firstOrNull;
    if (latLonBox == null) {
      throw const FormatException('No LatLonBox found in GroundOverlay');
    }

    final north = double.parse(_kmlText(latLonBox, 'north'));
    final south = double.parse(_kmlText(latLonBox, 'south'));
    final east = double.parse(_kmlText(latLonBox, 'east'));
    final west = double.parse(_kmlText(latLonBox, 'west'));

    // 4. חילוץ תמונה
    final icon = overlay.findElements('Icon').firstOrNull;
    final href = icon != null ? _kmlText(icon, 'href') : null;
    if (href == null || href.isEmpty) {
      throw const FormatException('No image reference in GroundOverlay');
    }

    // מציאת קובץ התמונה בארכיון
    ArchiveFile? imageFile;
    for (final file in archive) {
      if (file.isFile && (file.name == href || file.name.endsWith('/$href') || p.basename(file.name) == href)) {
        imageFile = file;
        break;
      }
    }
    if (imageFile == null) {
      throw FormatException('Image file "$href" not found in KMZ');
    }

    // 5. שמירת תמונה כ-PNG
    final imageBytes = imageFile.content as List<int>;
    final dir = p.dirname(kmzPath);
    final baseName = p.basenameWithoutExtension(kmzPath);
    String pngPath;

    // אם התמונה היא PNG — שמור ישירות, אחרת המר
    final imgExt = p.extension(imageFile.name).toLowerCase();
    if (imgExt == '.png') {
      pngPath = p.join(dir, '${baseName}_extracted.png');
      await File(pngPath).writeAsBytes(imageBytes);
    } else {
      final decoded = img.decodeImage(Uint8List.fromList(imageBytes));
      if (decoded == null) {
        throw const FormatException('Failed to decode image from KMZ');
      }
      pngPath = p.join(dir, '${baseName}_extracted.png');
      await File(pngPath).writeAsBytes(img.encodePng(decoded));
    }

    // 6. קריאת מימדי תמונה
    final imageSize = await _getImageSize(pngPath);

    return (
      result: WorldFileResult(
        southWest: LatLng(south, west),
        northEast: LatLng(north, east),
        detectedCrs: 'EPSG:4326', // KML תמיד WGS84
        imageWidth: imageSize.width,
        imageHeight: imageSize.height,
      ),
      pngPath: pngPath,
    );
  }

  /// חילוץ שם GroundOverlay מ-KMZ (לשימוש כשם ברירת מחדל)
  static Future<String?> getKmzOverlayName(String kmzPath) async {
    try {
      final bytes = await File(kmzPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final file in archive) {
        if (file.name.toLowerCase().endsWith('.kml') && file.isFile) {
          final kml = String.fromCharCodes(file.content as List<int>);
          final doc = xml.XmlDocument.parse(kml);
          final overlay = doc.findAllElements('GroundOverlay').firstOrNull;
          if (overlay != null) {
            final name = overlay.findElements('name').firstOrNull;
            if (name != null && name.innerText.isNotEmpty) {
              return name.innerText;
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// helper: חילוץ טקסט מאלמנט KML
  String _kmlText(xml.XmlElement parent, String tag) {
    final el = parent.findElements(tag).firstOrNull;
    return el?.innerText.trim() ?? '';
  }

  // ═══ TIFF IFD parsing ═══

  /// קריאת IFD tags
  Map<int, _TiffTag> _readIfdTags(ByteData data, int offset, Endian endian) {
    final tags = <int, _TiffTag>{};
    final count = data.getUint16(offset, endian);
    var pos = offset + 2;
    for (var i = 0; i < count; i++) {
      final tagId = data.getUint16(pos, endian);
      final type = data.getUint16(pos + 2, endian);
      final cnt = data.getUint32(pos + 4, endian);
      final valueOffset = data.getUint32(pos + 8, endian);
      tags[tagId] = _TiffTag(tagId, type, cnt, valueOffset, pos + 8);
      pos += 12;
    }
    return tags;
  }

  /// קריאת ערך int מ-tag
  int? _getTagInt(Map<int, _TiffTag> tags, int tagId, ByteData data, Endian endian) {
    final tag = tags[tagId];
    if (tag == null) return null;
    if (tag.type == 3) {
      // SHORT
      return tag.count == 1
          ? data.getUint16(tag.inlineOffset, endian)
          : data.getUint16(tag.valueOffset, endian);
    }
    if (tag.type == 4) {
      // LONG
      return tag.count == 1
          ? tag.valueOffset
          : data.getUint32(tag.valueOffset, endian);
    }
    return tag.valueOffset;
  }

  /// קריאת ערכי double מ-tag (TIFF type DOUBLE = 12)
  List<double>? _getTagDoubles(Map<int, _TiffTag> tags, int tagId, ByteData data, Endian endian) {
    final tag = tags[tagId];
    if (tag == null) return null;
    final offset = tag.valueOffset;
    final result = <double>[];
    for (var i = 0; i < tag.count; i++) {
      result.add(data.getFloat64(offset + i * 8, endian));
    }
    return result;
  }

  /// קריאת ערכי SHORT מ-tag
  List<int>? _getTagShorts(Map<int, _TiffTag> tags, int tagId, ByteData data, Endian endian) {
    final tag = tags[tagId];
    if (tag == null) return null;
    if (tag.count <= 2) {
      // Inline
      final result = <int>[];
      for (var i = 0; i < tag.count; i++) {
        result.add(data.getUint16(tag.inlineOffset + i * 2, endian));
      }
      return result;
    }
    final offset = tag.valueOffset;
    final result = <int>[];
    for (var i = 0; i < tag.count; i++) {
      result.add(data.getUint16(offset + i * 2, endian));
    }
    return result;
  }

  /// זיהוי CRS מ-GeoKeyDirectoryTag (34735)
  String? _detectCrsFromGeoKeys(Map<int, _TiffTag> tags, ByteData data, Endian endian) {
    final shorts = _getTagShorts(tags, 34735, data, endian);
    if (shorts == null || shorts.length < 4) return null;

    // GeoKey directory: [version, revision, minor, numberOfKeys, key1, loc1, cnt1, val1, ...]
    final numKeys = shorts[3];
    for (var i = 0; i < numKeys; i++) {
      final base = 4 + i * 4;
      if (base + 3 >= shorts.length) break;
      final keyId = shorts[base];
      final value = shorts[base + 3];

      // ProjectedCSTypeGeoKey (3072) — e.g., 2039 = ITM, 32636 = UTM36N
      if (keyId == 3072 && value > 0) {
        return 'EPSG:$value';
      }
      // GeographicTypeGeoKey (2048) — e.g., 4326 = WGS84
      if (keyId == 2048 && value > 0) {
        return 'EPSG:$value';
      }
    }
    return null;
  }

  /// קריאת מימדי תמונה
  Future<({int width, int height})> _getImageSize(String imagePath) async {
    final bytes = await File(imagePath).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final result = (width: image.width, height: image.height);
    image.dispose();
    return result;
  }

  /// רשימת CRS נתמכים להצגה בתפריט
  static const supportedCrs = {
    'EPSG:2039': 'ITM (Israel Transverse Mercator)',
    'EPSG:32636': 'UTM Zone 36N',
    'EPSG:28193': 'Old Israel Grid (Cassini)',
    'EPSG:4326': 'WGS84 (Geographic)',
  };

  /// חישוב bounds מנקודות התאמה (Georeferencing)
  /// מינימום 3 נקודות — טרנספורמציה אפינית
  /// pixel (col, row) → world (lon, lat):
  ///   x = a*col + b*row + c
  ///   y = d*col + e*row + f
  static WorldFileResult calculateFromControlPoints({
    required List<({ui.Offset pixel, LatLng world})> points,
    required int imageWidth,
    required int imageHeight,
  }) {
    if (points.length < 3) {
      throw const FormatException('At least 3 control points required');
    }

    final n = points.length;

    // Least Squares: solve for [a,b,c] and [d,e,f]
    // A * [a,b,c]^T = X   and   A * [d,e,f]^T = Y
    // where A = [[col1, row1, 1], [col2, row2, 1], ...]

    // Build A^T*A (3x3) and A^T*X, A^T*Y (3x1)
    double sCc = 0, sCr = 0, sC = 0;
    double sRr = 0, sR = 0;
    double sCx = 0, sRx = 0, sX = 0;
    double sCy = 0, sRy = 0, sY = 0;

    for (final p in points) {
      final c = p.pixel.dx; // column (x in image)
      final r = p.pixel.dy; // row (y in image)
      final x = p.world.longitude;
      final y = p.world.latitude;

      sCc += c * c;
      sCr += c * r;
      sC += c;
      sRr += r * r;
      sR += r;
      sCx += c * x;
      sRx += r * x;
      sX += x;
      sCy += c * y;
      sRy += r * y;
      sY += y;
    }

    // A^T*A matrix:
    // | s_cc  s_cr  s_c |
    // | s_cr  s_rr  s_r |
    // | s_c   s_r   n   |
    final det = sCc * (sRr * n - sR * sR)
              - sCr * (sCr * n - sR * sC)
              + sC  * (sCr * sR - sRr * sC);

    if (det.abs() < 1e-10) {
      throw const FormatException('Control points are collinear');
    }

    // Inverse of 3x3 (cofactor method)
    final inv = [
      [(sRr * n - sR * sR) / det, (sC * sR - sCr * n) / det, (sCr * sR - sC * sRr) / det],
      [(sR * sC - sCr * n) / det, (sCc * n - sC * sC) / det, (sC * sCr - sCc * sR) / det],
      [(sCr * sR - sRr * sC) / det, (sCr * sC - sCc * sR) / det, (sCc * sRr - sCr * sCr) / det],
    ];

    // [a,b,c] = inv * [s_cx, s_rx, s_x]
    final a = inv[0][0] * sCx + inv[0][1] * sRx + inv[0][2] * sX;
    final b = inv[1][0] * sCx + inv[1][1] * sRx + inv[1][2] * sX;
    final c = inv[2][0] * sCx + inv[2][1] * sRx + inv[2][2] * sX;

    // [d,e,f] = inv * [s_cy, s_ry, s_y]
    final d = inv[0][0] * sCy + inv[0][1] * sRy + inv[0][2] * sY;
    final e = inv[1][0] * sCy + inv[1][1] * sRy + inv[1][2] * sY;
    final f = inv[2][0] * sCy + inv[2][1] * sRy + inv[2][2] * sY;

    // 4 corners → world coordinates (lon, lat)
    final w = imageWidth.toDouble();
    final h = imageHeight.toDouble();
    // UL(0,0)=NW, UR(w-1,0)=NE, LR(w-1,h-1)=SE, LL(0,h-1)=SW
    final nw = LatLng(f, c); // (0,0)
    final ne = LatLng(d * (w - 1) + f, a * (w - 1) + c); // (w-1,0)
    final se = LatLng(
        d * (w - 1) + e * (h - 1) + f, a * (w - 1) + b * (h - 1) + c); // (w-1,h-1)
    final sw = LatLng(e * (h - 1) + f, b * (h - 1) + c); // (0,h-1)
    final corners = [nw, ne, se, sw];

    double minLat = corners[0].latitude, maxLat = corners[0].latitude;
    double minLng = corners[0].longitude, maxLng = corners[0].longitude;
    for (final corner in corners) {
      minLat = min(minLat, corner.latitude);
      maxLat = max(maxLat, corner.latitude);
      minLng = min(minLng, corner.longitude);
      maxLng = max(maxLng, corner.longitude);
    }

    return WorldFileResult(
      southWest: LatLng(minLat, minLng),
      northEast: LatLng(maxLat, maxLng),
      detectedCrs: 'EPSG:4326',
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      // NW, NE, SE, SW
      cornersWgs84: corners,
    );
  }
}

/// TIFF IFD tag entry
class _TiffTag {
  final int id;
  final int type; // 1=BYTE, 2=ASCII, 3=SHORT, 4=LONG, 5=RATIONAL, 12=DOUBLE
  final int count;
  final int valueOffset; // offset to value (or inline value for ≤4 bytes)
  final int inlineOffset; // position of the 4-byte value/offset field itself

  const _TiffTag(this.id, this.type, this.count, this.valueOffset, this.inlineOffset);
}
