// בוחן-עשן לשרשרת PMTiles: PNG סינתטי → MBTiles (כותב-Dart) → PMTiles
// (‏PmtilesWriterService). מדפיס מניפסט-אריחים (XYZ) כ-JSON לאימות חיצוני
// עם ספריית pmtiles הרשמית ב-Node.
// הרצה: dart run tool/pmtiles_probe.dart
import 'dart:convert';
import 'dart:io';

import 'package:auto_maps/services/mbtiles_writer_service.dart';
import 'package:auto_maps/services/pmtiles_writer_service.dart';
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

Future<void> main() async {
  final tmp = Directory.systemTemp.path;
  final src = '$tmp\\בדיקת_pmtiles.png';
  final mb = '$tmp\\בדיקת_pmtiles.mbtiles';
  final pm = '$tmp\\בדיקת_pmtiles.pmtiles';
  final manifest = '$tmp\\בדיקת_pmtiles_manifest.json';

  final im = img.Image(width: 1600, height: 1200);
  img.fill(im, color: img.ColorRgb8(240, 240, 220));
  img.fillRect(im,
      x1: 200, y1: 200, x2: 1400, y2: 400, color: img.ColorRgb8(200, 40, 40));
  img.fillRect(im,
      x1: 600, y1: 600, x2: 1000, y2: 1100, color: img.ColorRgb8(40, 80, 200));
  File(src).writeAsBytesSync(img.encodePng(im));

  // ‎~0.016°×0.012°‎ סביב 35.0E/32.0N — פינות NW,NE,SE,SW.
  const nw = LatLng(32.0, 35.0);
  const ne = LatLng(32.0, 35.016);
  const se = LatLng(31.988, 35.016);
  const sw = LatLng(31.988, 35.0);

  await MbtilesWriterService.write(
    pngPath: src,
    corners: const [nw, ne, se, sw],
    name: 'בדיקת pmtiles',
    mbtilesPath: mb,
  );
  await PmtilesWriterService.mbtilesToPmtiles(
      mbtilesPath: mb, pmtilesPath: pm);

  // מניפסט-אריחים (XYZ) לבודק החיצוני.
  final db = sql.sqlite3.open(mb, mode: sql.OpenMode.readOnly);
  final tiles = [
    for (final row in db.select(
        'SELECT zoom_level z, tile_column x, tile_row r, length(tile_data) len'
        ' FROM tiles'))
      {
        'z': row['z'],
        'x': row['x'],
        'y': ((1 << (row['z'] as int)) - 1) - (row['r'] as int),
        'len': row['len'],
      },
  ];
  db.dispose();
  File(manifest).writeAsStringSync(json.encode(tiles));

  final size = File(pm).lengthSync();
  print('pmtiles ok: $pm ($size bytes, ${tiles.length} tiles)');
  print('manifest: $manifest');
}
