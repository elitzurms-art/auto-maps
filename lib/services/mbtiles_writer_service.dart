import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

/// כותב MBTiles-רסטר ב-**Dart טהור** — בלי GDAL. ה-libgdal.so של אנדרואיד
/// נבנה בלי sqlite3 (אין דרייבר MBTILES), אז הפירוס נעשה כאן: כל אריח
/// ‎256²‎ ממופה הפוך (Web Mercator → WGS84 → affine-הפוך → פיקסל-מקור)
/// ונדגם בילינארית; זום-מקסימום לפי רזולוציית-הקרקע (כמו GDAL), רמות-זום
/// יורדות מ-downsample ממוצע של המקור. הכתיבה ב-package:sqlite3 (מצורף
/// בכל הפלטפורמות דרך sqlite3_flutter_libs).
class MbtilesWriterService {
  static const _tile = 256;
  static const _r = 6378137.0; // רדיוס Web Mercator
  static const _maxZoomCap = 22;

  /// כותב את [pngPath] (עם 4 פינות NW,NE,SE,SW ב-WGS84 — סיבוב נתמך)
  /// ל-[mbtilesPath] (נדרס אם קיים). רץ ב-Isolate — רינדור + PNG + SQLite.
  static Future<void> write({
    required String pngPath,
    required List<LatLng> corners,
    required String name,
    required String mbtilesPath,
  }) {
    final c = [for (final p in corners) [p.latitude, p.longitude]];
    return Isolate.run(() => _writeSync(pngPath, c, name, mbtilesPath));
  }

  static void _writeSync(
    String pngPath,
    List<List<double>> cornersLatLon,
    String name,
    String mbtilesPath,
  ) {
    final decoded = img.decodeImage(File(pngPath).readAsBytesSync());
    if (decoded == null) {
      throw const FormatException('כשל בפענוח תמונת-המקור ל-MBTiles');
    }
    final full = decoded.convert(numChannels: 4);
    final fullW = full.width, fullH = full.height;

    // ── affine מהפינות: (px,py)→(lon,lat), והמטריצה ההפוכה ──
    final nw = cornersLatLon[0], ne = cornersLatLon[1], sw = cornersLatLon[3];
    final a0 = nw[1], d0 = nw[0];
    final b = (ne[1] - nw[1]) / fullW, c = (sw[1] - nw[1]) / fullH;
    final e = (ne[0] - nw[0]) / fullW, f = (sw[0] - nw[0]) / fullH;
    final det = b * f - c * e;
    if (det.abs() < 1e-18) {
      throw const FormatException('פינות מנוונות — אין affine הפיך');
    }

    // ── טווח-מרקטור וזומים ──
    var minMx = double.infinity, maxMx = -double.infinity;
    var minMy = double.infinity, maxMy = -double.infinity;
    for (final p in cornersLatLon) {
      final mx = _mercX(p[1]), my = _mercY(p[0]);
      minMx = math.min(minMx, mx);
      maxMx = math.max(maxMx, mx);
      minMy = math.min(minMy, my);
      maxMy = math.max(maxMy, my);
    }
    // רזולוציית-המקור במטרי-מרקטור (לאורך שורת-הפיקסלים העליונה).
    final srcRes = math.sqrt(
          math.pow(_mercX(ne[1]) - _mercX(nw[1]), 2) +
              math.pow(_mercY(ne[0]) - _mercY(nw[0]), 2),
        ) /
        fullW;
    final worldRes = 2 * math.pi * _r / _tile; // רזולוציית זום-0
    final maxZoom = (math.log(worldRes / srcRes) / math.ln2)
        .round()
        .clamp(0, _maxZoomCap);
    // זום-מינימום: יורדים כל עוד צלע-המפה הקצרה עדיין ≥ אריח (כמו GDAL).
    var minZoom = maxZoom;
    while (minZoom > 0) {
      final res = worldRes / (1 << (minZoom - 1));
      if (math.min(maxMx - minMx, maxMy - minMy) / res < _tile) break;
      minZoom--;
    }

    // ── SQLite ──
    final outFile = File(mbtilesPath);
    if (outFile.existsSync()) outFile.deleteSync();
    final db = sql.sqlite3.open(mbtilesPath);
    try {
      db.execute('''
        CREATE TABLE metadata (name text, value text);
        CREATE TABLE tiles (zoom_level integer, tile_column integer,
                            tile_row integer, tile_data blob);
        CREATE UNIQUE INDEX tile_index
          ON tiles (zoom_level, tile_column, tile_row);
      ''');
      final minLon = _lonOf(minMx), maxLon = _lonOf(maxMx);
      final minLat = _latOf(minMy), maxLat = _latOf(maxMy);
      final metaStmt =
          db.prepare('INSERT INTO metadata (name, value) VALUES (?, ?)');
      for (final kv in {
        'name': name,
        'format': 'png',
        'type': 'overlay',
        'version': '1.1',
        'minzoom': '$minZoom',
        'maxzoom': '$maxZoom',
        'bounds': '$minLon,$minLat,$maxLon,$maxLat',
        'center': '${(minLon + maxLon) / 2},${(minLat + maxLat) / 2},$minZoom',
      }.entries) {
        metaStmt.execute([kv.key, kv.value]);
      }
      metaStmt.dispose();

      final ins = db.prepare(
          'INSERT INTO tiles (zoom_level, tile_column, tile_row, tile_data)'
          ' VALUES (?, ?, ?, ?)');
      // רמת-מקור נוכחית — מוקטנת פי-2 (ממוצע) לכל ירידת-זום.
      var level = full;
      var levelBytes = level.getBytes(order: img.ChannelOrder.rgba);
      for (var z = maxZoom; z >= minZoom; z--) {
        final res = worldRes / (1 << z);
        final scaleX = fullW / level.width, scaleY = fullH / level.height;
        final txMin = ((minMx + math.pi * _r) / (res * _tile)).floor();
        final txMax = ((maxMx + math.pi * _r) / (res * _tile)).ceil() - 1;
        final tyMin = ((math.pi * _r - maxMy) / (res * _tile)).floor();
        final tyMax = ((math.pi * _r - minMy) / (res * _tile)).ceil() - 1;
        db.execute('BEGIN');
        for (var ty = tyMin; ty <= tyMax; ty++) {
          for (var tx = txMin; tx <= txMax; tx++) {
            final data = _renderTile(
              levelBytes, level.width, level.height, scaleX, scaleY,
              tx, ty, z, res,
              a0, d0, b, c, e, f, det,
            );
            if (data == null) continue; // אריח שקוף-לגמרי — לא נשמר
            final png = img.encodePng(img.Image.fromBytes(
              width: _tile,
              height: _tile,
              bytes: data.buffer,
              numChannels: 4,
            ));
            // MBTiles הוא TMS — שורת-האריח הפוכה מ-XYZ.
            ins.execute([z, tx, ((1 << z) - 1) - ty, png]);
          }
        }
        db.execute('COMMIT');
        if (z > minZoom && (level.width > 1 || level.height > 1)) {
          level = img.copyResize(
            level,
            width: math.max(1, level.width ~/ 2),
            height: math.max(1, level.height ~/ 2),
            interpolation: img.Interpolation.average,
          );
          levelBytes = level.getBytes(order: img.ChannelOrder.rgba);
        }
      }
      ins.dispose();
    } finally {
      db.dispose();
    }
  }

  /// מרנדר אריח (z,tx,ty): לכל פיקסל — מרכז-הפיקסל במרקטור → WGS84 →
  /// affine-הפוך לפיקסל-מקור מלא → חלוקה לסקאלת-הרמה → דגימה בילינארית.
  /// מחזיר RGBA (‎256²×4‎) או null כשהאריח שקוף לגמרי.
  static Uint8List? _renderTile(
    Uint8List src, int srcW, int srcH, double scaleX, double scaleY,
    int tx, int ty, int z, double res,
    double a0, double d0, double b, double c, double e, double f, double det,
  ) {
    final out = Uint8List(_tile * _tile * 4);
    var any = false;
    final originMx = -math.pi * _r + tx * res * _tile;
    final originMy = math.pi * _r - ty * res * _tile;
    for (var j = 0; j < _tile; j++) {
      final my = originMy - (j + 0.5) * res;
      final lat = _latOf(my);
      for (var i = 0; i < _tile; i++) {
        final mx = originMx + (i + 0.5) * res;
        final lon = _lonOf(mx);
        // affine הפוך: פיקסל במקור המלא.
        final dl = lon - a0, dp = lat - d0;
        final px = (f * dl - c * dp) / det;
        final py = (b * dp - e * dl) / det;
        if (px < -0.5 || py < -0.5 || px > srcW * scaleX - 0.5 ||
            py > srcH * scaleY - 0.5) {
          continue; // מחוץ למפה — שקוף
        }
        final v = _bilinear(src, srcW, srcH, px / scaleX, py / scaleY);
        if (v == 0) continue;
        final o = (j * _tile + i) * 4;
        out[o] = (v >> 24) & 0xff;
        out[o + 1] = (v >> 16) & 0xff;
        out[o + 2] = (v >> 8) & 0xff;
        out[o + 3] = v & 0xff;
        any = true;
      }
    }
    return any ? out : null;
  }

  /// דגימה בילינארית מ-RGBA שטוח; שכנים מחוץ-לתחום נחשבים שקופים.
  /// מחזיר RGBA ארוז (‎r<<24|g<<16|b<<8|a‎); 0 = שקוף לגמרי.
  static int _bilinear(Uint8List src, int w, int h, double fx, double fy) {
    final x = fx - 0.5, y = fy - 0.5;
    final x0 = x.floor(), y0 = y.floor();
    final dx = x - x0, dy = y - y0;
    var r = 0.0, g = 0.0, bl = 0.0, a = 0.0;
    for (var n = 0; n < 4; n++) {
      final sx = x0 + (n & 1), sy = y0 + (n >> 1);
      if (sx < 0 || sy < 0 || sx >= w || sy >= h) continue;
      final wgt = ((n & 1) == 0 ? 1 - dx : dx) * ((n >> 1) == 0 ? 1 - dy : dy);
      if (wgt == 0) continue;
      final o = (sy * w + sx) * 4;
      final pa = src[o + 3] / 255.0;
      // משקול-אלפא: צבע נשקל לפי אלפא (מונע הילות בקצוות שקופים).
      r += src[o] * wgt * pa;
      g += src[o + 1] * wgt * pa;
      bl += src[o + 2] * wgt * pa;
      a += src[o + 3] * wgt;
    }
    if (a < 0.5) return 0;
    final af = a / 255.0;
    return ((r / af).round().clamp(0, 255) << 24) |
        ((g / af).round().clamp(0, 255) << 16) |
        ((bl / af).round().clamp(0, 255) << 8) |
        a.round().clamp(0, 255);
  }

  static double _mercX(double lonDeg) => _r * lonDeg * math.pi / 180;

  static double _mercY(double latDeg) {
    final lat = latDeg * math.pi / 180;
    return _r * math.log(math.tan(math.pi / 4 + lat / 2));
  }

  static double _lonOf(double mx) => mx / _r * 180 / math.pi;

  static double _latOf(double my) =>
      (2 * math.atan(math.exp(my / _r)) - math.pi / 2) * 180 / math.pi;
}
