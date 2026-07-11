// בוחן-עשן לייצוא PMTiles: PNG סינתטי → MBTiles (דרך auto_maps_ecw.dll)
// → PMTiles (‏PmtilesWriterService). מדפיס את רשימת-האריחים (XYZ) כ-JSON
// כדי שבודק חיצוני (ספריית pmtiles הרשמית ב-Node) יאמת את הארכיון.
// הרצה: עם build\windows\x64\runner\Debug ב-PATH (‏gdal313.dll + sqlite3.dll):
//   dart run tool/pmtiles_probe.dart
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:auto_maps/services/pmtiles_writer_service.dart';
import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:sqlite3/sqlite3.dart' as sql;

Future<void> main() async {
  const dllPath = r'build\windows\x64\runner\Debug\auto_maps_ecw.dll';
  if (!File(dllPath).existsSync()) {
    print('DLL not built: $dllPath');
    exitCode = 1;
    return;
  }

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
  for (final f in [mb, pm]) {
    if (File(f).existsSync()) File(f).deleteSync();
  }

  // ‎~0.016°×0.012° סביב 35.0E/32.0N.
  final gt = <double>[35.0, 0.00001, 0, 32.0, 0, -0.00001];
  final fn = DynamicLibrary.open(dllPath).lookupFunction<
      Int32 Function(
          Pointer<Utf8>, Pointer<Utf8>, Pointer<Double>, Pointer<Utf8>),
      int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Double>,
          Pointer<Utf8>)>('ecw_write_mbtiles');
  final s = src.toNativeUtf8();
  final d = mb.toNativeUtf8();
  final n = 'בדיקת pmtiles'.toNativeUtf8();
  final g = calloc<Double>(6);
  g.asTypedList(6).setAll(0, gt);
  final rc = fn(s, d, g, n);
  calloc.free(s);
  calloc.free(d);
  calloc.free(n);
  calloc.free(g);
  if (rc != 0) {
    print('mbtiles FAILED rc=$rc');
    exitCode = 1;
    return;
  }

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
