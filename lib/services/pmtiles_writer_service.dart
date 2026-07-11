import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart' as sql;

/// ממיר MBTiles-רסטר ל-**PMTiles v3** ב-Dart טהור — ל-GDAL אין דרייבר-רסטר
/// PMTiles, אז האריזה נעשית כאן: קוראים את אריחי-ה-PNG מה-SQLite וכותבים
/// ארכיון יחיד (header + ספריית-אינדקס + אריחים) לפי המפרט:
/// https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md
///
/// אותם אריחים בדיוק כמו ב-MBTiles — רק אריזה שונה (מותאמת ל-HTTP range
/// requests: אחסון סטטי/CDN בלי שרת-מפות; MapLibre קורא ישירות).
class PmtilesWriterService {
  /// ממיר את [mbtilesPath] ל-[pmtilesPath] (נדרס אם קיים). רץ ב-Isolate —
  /// קריאת ה-SQLite וה-gzip חוסמים.
  static Future<void> mbtilesToPmtiles({
    required String mbtilesPath,
    required String pmtilesPath,
  }) =>
      Isolate.run(() => _convertSync(mbtilesPath, pmtilesPath));

  static void _convertSync(String mbtilesPath, String pmtilesPath) {
    final db = sql.sqlite3.open(mbtilesPath, mode: sql.OpenMode.readOnly);
    final List<_Tile> tiles;
    final Map<String, String> meta;
    try {
      meta = {
        for (final row in db.select('SELECT name, value FROM metadata'))
          row['name'] as String: (row['value'] ?? '').toString(),
      };
      tiles = [
        for (final row in db.select(
            'SELECT zoom_level, tile_column, tile_row, tile_data FROM tiles'))
          _Tile(
            z: row['zoom_level'] as int,
            x: row['tile_column'] as int,
            // MBTiles הוא TMS (y הפוך) — PMTiles הוא XYZ.
            y: ((1 << (row['zoom_level'] as int)) - 1) - (row['tile_row'] as int),
            data: row['tile_data'] as Uint8List,
          ),
      ];
    } finally {
      db.dispose();
    }
    if (tiles.isEmpty) {
      throw const FormatException('ה-MBTiles ריק — אין אריחים להמרה');
    }

    // ── מיון לפי tile_id (עקומת-הילברט) — חובה לספרייה, ונותן clustered ──
    for (final t in tiles) {
      t.id = _tileId(t.z, t.x, t.y);
    }
    tiles.sort((a, b) => a.id.compareTo(b.id));

    // ── גוש-האריחים + רשומות-הספרייה ──
    final tileData = BytesBuilder(copy: false);
    final entries = <_Entry>[];
    var offset = 0;
    for (final t in tiles) {
      entries.add(_Entry(tileId: t.id, offset: offset, length: t.data.length));
      tileData.add(t.data);
      offset += t.data.length;
    }

    final rootDir = gzip.encode(_serializeDirectory(entries));
    final metadataJson = gzip.encode(utf8.encode(json.encode({
      if (meta['name'] != null) 'name': meta['name'],
      if (meta['description'] != null) 'description': meta['description'],
      if (meta['attribution'] != null) 'attribution': meta['attribution'],
    })));

    // ── header (127 בתים, little-endian) ──
    final minZoom = tiles.first.z, maxZoom = tiles.last.z;
    final bounds = _bounds(meta, tiles, maxZoom);
    const headerLen = 127;
    final rootOff = headerLen;
    final metaOff = rootOff + rootDir.length;
    final dataOff = metaOff + metadataJson.length;

    final h = ByteData(headerLen);
    for (var i = 0; i < 7; i++) {
      h.setUint8(i, 'PMTiles'.codeUnitAt(i));
    }
    h.setUint8(7, 3); // spec version
    h.setUint64(8, rootOff, Endian.little);
    h.setUint64(16, rootDir.length, Endian.little);
    h.setUint64(24, metaOff, Endian.little);
    h.setUint64(32, metadataJson.length, Endian.little);
    h.setUint64(40, 0, Endian.little); // leaf dirs — אין (הכל ב-root)
    h.setUint64(48, 0, Endian.little);
    h.setUint64(56, dataOff, Endian.little);
    h.setUint64(64, offset, Endian.little);
    h.setUint64(72, tiles.length, Endian.little); // addressed tiles
    h.setUint64(80, entries.length, Endian.little); // tile entries
    h.setUint64(88, tiles.length, Endian.little); // tile contents (בלי dedup)
    h.setUint8(96, 1); // clustered — כתבנו בסדר tile_id
    h.setUint8(97, 2); // internal compression: gzip
    h.setUint8(98, 1); // tile compression: none (PNG כבר דחוס)
    h.setUint8(99, 2); // tile type: png
    h.setUint8(100, minZoom);
    h.setUint8(101, maxZoom);
    h.setInt32(102, _e7(bounds.minLon), Endian.little);
    h.setInt32(106, _e7(bounds.minLat), Endian.little);
    h.setInt32(110, _e7(bounds.maxLon), Endian.little);
    h.setInt32(114, _e7(bounds.maxLat), Endian.little);
    h.setUint8(118, minZoom); // center zoom
    h.setInt32(119, _e7((bounds.minLon + bounds.maxLon) / 2), Endian.little);
    h.setInt32(123, _e7((bounds.minLat + bounds.maxLat) / 2), Endian.little);

    final out = BytesBuilder(copy: false)
      ..add(h.buffer.asUint8List())
      ..add(rootDir)
      ..add(metadataJson)
      ..add(tileData.takeBytes());
    File(pmtilesPath).writeAsBytesSync(out.takeBytes());
  }

  static int _e7(double deg) => (deg * 1e7).round();

  /// tile_id של PMTiles: מספר-האריחים המצטבר בזומים הקודמים + מיקום (x,y)
  /// על עקומת-הילברט בזום z.
  static int _tileId(int z, int x, int y) {
    var acc = 0;
    for (var i = 0; i < z; i++) {
      acc += 1 << (2 * i); // 4^i
    }
    var tx = x, ty = y, d = 0;
    for (var s = (1 << z) >> 1; s > 0; s >>= 1) {
      final rx = (tx & s) > 0 ? 1 : 0;
      final ry = (ty & s) > 0 ? 1 : 0;
      d += s * s * ((3 * rx) ^ ry);
      // סיבוב הרביע
      if (ry == 0) {
        if (rx == 1) {
          tx = s - 1 - tx;
          ty = s - 1 - ty;
        }
        final t = tx;
        tx = ty;
        ty = t;
      }
    }
    return acc + d;
  }

  /// סריאליזציית-ספרייה לפי המפרט: N, ואז 4 סדרות varint — דלתות-tile_id,
  /// run-lengths (תמיד 1), אורכים, והיסטים (offset+1; ‏0=המשך-רציף).
  static Uint8List _serializeDirectory(List<_Entry> entries) {
    final b = BytesBuilder(copy: false);
    _varint(b, entries.length);
    var last = 0;
    for (final e in entries) {
      _varint(b, e.tileId - last);
      last = e.tileId;
    }
    for (final _ in entries) {
      _varint(b, 1);
    }
    for (final e in entries) {
      _varint(b, e.length);
    }
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      final prev = i > 0 ? entries[i - 1] : null;
      if (prev != null && e.offset == prev.offset + prev.length) {
        _varint(b, 0);
      } else {
        _varint(b, e.offset + 1);
      }
    }
    return b.takeBytes();
  }

  static void _varint(BytesBuilder b, int v) {
    var n = v;
    while (n >= 0x80) {
      b.addByte((n & 0x7f) | 0x80);
      n >>= 7;
    }
    b.addByte(n);
  }

  /// bounds מה-metadata של ה-MBTiles ("minLon,minLat,maxLon,maxLat"); אם
  /// חסר — מחושב מהיקף-האריחים בזום-המקסימלי (נוסחאות slippy).
  static ({double minLon, double minLat, double maxLon, double maxLat})
      _bounds(Map<String, String> meta, List<_Tile> tiles, int maxZoom) {
    final raw = meta['bounds']?.split(',');
    if (raw != null && raw.length == 4) {
      final v = raw.map((s) => double.tryParse(s.trim())).toList();
      if (!v.contains(null)) {
        return (minLon: v[0]!, minLat: v[1]!, maxLon: v[2]!, maxLat: v[3]!);
      }
    }
    final zt = tiles.where((t) => t.z == maxZoom);
    var minX = 1 << maxZoom, minY = 1 << maxZoom, maxX = -1, maxY = -1;
    for (final t in zt) {
      minX = math.min(minX, t.x);
      minY = math.min(minY, t.y);
      maxX = math.max(maxX, t.x);
      maxY = math.max(maxY, t.y);
    }
    double lon(int x) => x / (1 << maxZoom) * 360 - 180;
    double lat(int y) {
      final n = math.pi - 2 * math.pi * y / (1 << maxZoom);
      return 180 / math.pi * math.atan((math.exp(n) - math.exp(-n)) / 2);
    }

    return (
      minLon: lon(minX),
      minLat: lat(maxY + 1),
      maxLon: lon(maxX + 1),
      maxLat: lat(minY),
    );
  }
}

class _Tile {
  final int z, x, y;
  final Uint8List data;
  int id = 0;
  _Tile({required this.z, required this.x, required this.y, required this.data});
}

class _Entry {
  final int tileId, offset, length;
  const _Entry({required this.tileId, required this.offset, required this.length});
}
