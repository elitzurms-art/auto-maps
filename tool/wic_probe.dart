// בוחן-עשן לממיר ה-WIC: טוען את auto_maps_wic.dll מתיקיית ה-build וממיר
// PNG→PNG (WIC מפענח גם PNG — מאמת את כל הצינור כולל נתיבים בעברית).
// הרצה אחרי build: dart run tool/wic_probe.dart
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;

void main() {
  const dllPath = r'build\windows\x64\runner\Debug\auto_maps_wic.dll';
  if (!File(dllPath).existsSync()) {
    print('DLL not built: $dllPath');
    exitCode = 1;
    return;
  }
  // קלט זמני עם שם עברי
  final tmp = Directory.systemTemp.path;
  final src = '$tmp\\בדיקת_wic.png';
  final dst = '$tmp\\בדיקת_wic_out.png';
  final im = img.Image(width: 64, height: 40);
  img.fill(im, color: img.ColorRgb8(10, 200, 90));
  File(src).writeAsBytesSync(img.encodePng(im));

  final fn = DynamicLibrary.open(dllPath).lookupFunction<
      Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
      int Function(Pointer<Utf8>, Pointer<Utf8>)>('wic_convert_to_png');
  final s = src.toNativeUtf8();
  final d = dst.toNativeUtf8();
  final rc = fn(s, d);
  calloc.free(s);
  calloc.free(d);
  print('wic rc=$rc');
  if (rc != 0 || !File(dst).existsSync()) {
    print('WIC FAILED');
    exitCode = 1;
    return;
  }
  final out = img.decodeImage(File(dst).readAsBytesSync());
  print(out != null && out.width == 64 ? 'WIC OK (${out.width}x${out.height})' : 'WIC BAD OUTPUT');
  exitCode = (out != null && out.width == 64) ? 0 : 1;
}
