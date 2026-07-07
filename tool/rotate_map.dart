// מסובב תמונה בזווית נתונה (עם רקע לבן) לבדיקת מפה לא-מיושרת-צפון.
// dart run tool/rotate_map.dart "<in>" <deg> "<out>"
import 'dart:io';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  final src = img.decodeImage(File(args[0]).readAsBytesSync())!;
  final deg = double.parse(args[1]);
  final rotated = img.copyRotate(
    src,
    angle: deg,
    interpolation: img.Interpolation.linear,
  );
  // רקע לבן במקום שקוף (JPG/הצגה).
  final canvas = img.Image(width: rotated.width, height: rotated.height);
  img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(canvas, rotated);
  File(args[2]).writeAsBytesSync(img.encodePng(canvas));
  stdout.writeln('wrote ${args[2]} (${canvas.width}x${canvas.height}, ${deg}°)');
}
