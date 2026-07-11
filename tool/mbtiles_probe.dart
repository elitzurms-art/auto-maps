// בוחן-עשן לייצוא MBTiles: טוען את auto_maps_ecw.dll מתיקיית ה-build,
// יוצר PNG סינתטי, קורא ל-ecw_write_mbtiles ובודק שנוצר קובץ.
// הרצה אחרי build, עם תיקיית ה-Debug ב-PATH (בשביל gdal313.dll וחבריו):
//   $env:PATH = "build\windows\x64\runner\Debug;$env:PATH"
//   dart run tool/mbtiles_probe.dart
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;

void main() {
  const dllPath = r'build\windows\x64\runner\Debug\auto_maps_ecw.dll';
  if (!File(dllPath).existsSync()) {
    print('DLL not built: $dllPath');
    exitCode = 1;
    return;
  }

  // תמונה סינתטית עם קצת מגוון (שהאריחים לא יהיו אחידים לגמרי).
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
  if (File(dst).existsSync()) File(dst).deleteSync();

  // geotransform: ‎~0.008°×0.006° סביב 35.0E/32.0N (ישראל).
  final gt = <double>[35.0, 0.00001, 0, 32.0, 0, -0.00001];

  final fn = DynamicLibrary.open(dllPath).lookupFunction<
      Int32 Function(
          Pointer<Utf8>, Pointer<Utf8>, Pointer<Double>, Pointer<Utf8>),
      int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Double>,
          Pointer<Utf8>)>('ecw_write_mbtiles');

  final s = src.toNativeUtf8();
  final d = dst.toNativeUtf8();
  final n = 'בדיקת שכבה'.toNativeUtf8();
  final g = calloc<Double>(6);
  g.asTypedList(6).setAll(0, gt);
  final rc = fn(s, d, g, n);
  calloc.free(s);
  calloc.free(d);
  calloc.free(n);
  calloc.free(g);

  final exists = File(dst).existsSync();
  final size = exists ? File(dst).lengthSync() : 0;
  print('mbtiles rc=$rc, exists=$exists, size=$size bytes');
  print('output: $dst');
  exitCode = (rc == 0 && exists && size > 0) ? 0 : 1;
}
