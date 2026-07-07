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
  final full = img.Image(width: rotated.width, height: rotated.height);
  img.fill(full, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(full, rotated);

  // חיתוך לשוליים הלא-לבנים (bbox של התוכן) — אחרת ההקטנה מרסקת רזולוציה.
  var minX = full.width, minY = full.height, maxX = 0, maxY = 0;
  for (var y = 0; y < full.height; y += 2) {
    for (var x = 0; x < full.width; x += 2) {
      final p = full.getPixel(x, y);
      if (p.r < 245 || p.g < 245 || p.b < 245) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  const pad = 20;
  minX = (minX - pad).clamp(0, full.width);
  minY = (minY - pad).clamp(0, full.height);
  maxX = (maxX + pad).clamp(0, full.width);
  maxY = (maxY + pad).clamp(0, full.height);
  final canvas = img.copyCrop(full,
      x: minX, y: minY, width: maxX - minX, height: maxY - minY);
  File(args[2]).writeAsBytesSync(img.encodePng(canvas));
  stdout.writeln('wrote ${args[2]} (${canvas.width}x${canvas.height}, ${deg}°)');
}
