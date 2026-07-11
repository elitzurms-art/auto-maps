// בוחן-עשן לכותב ה-MBTiles ה-Dart-טהור (MbtilesWriterService — בלי GDAL):
// PNG סינתטי + 4 פינות → MBTiles. אימות-תוכן: gdalinfo (אם מותקן OSGeo4W).
// הרצה: dart run tool/mbtiles_probe.dart
import 'dart:io';

import 'package:auto_maps/services/mbtiles_writer_service.dart';
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

Future<void> main() async {
  final tmp = Directory.systemTemp.path;
  final src = '$tmp\\בדיקת_mbtiles.png';
  final dst = '$tmp\\בדיקת_mbtiles.mbtiles';

  final im = img.Image(width: 800, height: 600);
  img.fill(im, color: img.ColorRgb8(240, 240, 220));
  img.fillRect(im,
      x1: 100, y1: 100, x2: 700, y2: 200, color: img.ColorRgb8(200, 40, 40));
  img.fillRect(im,
      x1: 300, y1: 300, x2: 500, y2: 550, color: img.ColorRgb8(40, 80, 200));
  File(src).writeAsBytesSync(img.encodePng(im));

  // ‎0.008°×0.006°‎ סביב 35.0E/32.0N — פינות NW,NE,SE,SW.
  const nw = LatLng(32.0, 35.0);
  const ne = LatLng(32.0, 35.008);
  const se = LatLng(31.994, 35.008);
  const sw = LatLng(31.994, 35.0);

  await MbtilesWriterService.write(
    pngPath: src,
    corners: const [nw, ne, se, sw],
    name: 'בדיקת שכבה',
    mbtilesPath: dst,
  );

  final db = sql.sqlite3.open(dst, mode: sql.OpenMode.readOnly);
  final meta = {
    for (final r in db.select('SELECT name, value FROM metadata'))
      r['name']: r['value'],
  };
  final counts = db.select(
      'SELECT zoom_level z, count(*) n FROM tiles GROUP BY z ORDER BY z');
  db.dispose();

  final size = File(dst).lengthSync();
  print('mbtiles ok: $dst ($size bytes)');
  print('metadata: $meta');
  for (final r in counts) {
    print('  zoom ${r['z']}: ${r['n']} tiles');
  }
  exitCode = size > 0 && counts.isNotEmpty ? 0 : 1;
}
