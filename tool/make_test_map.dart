// יוצר תמונת-מפה סינתטית לבדיקות (רשת + אלכסונים) ב-%TEMP%\tps_smoke_src.png
import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  final image = img.Image(width: 800, height: 600);
  img.fill(image, color: img.ColorRgb8(255, 253, 240));
  for (var x = 0; x < 800; x += 80) {
    img.drawLine(image,
        x1: x, y1: 0, x2: x, y2: 599, color: img.ColorRgb8(190, 70, 70));
  }
  for (var y = 0; y < 600; y += 80) {
    img.drawLine(image,
        x1: 0, y1: y, x2: 799, y2: y, color: img.ColorRgb8(70, 70, 190));
  }
  img.drawLine(image,
      x1: 0, y1: 0, x2: 799, y2: 599, color: img.ColorRgb8(40, 150, 40));
  img.drawCircle(image,
      x: 400, y: 300, radius: 60, color: img.ColorRgb8(20, 20, 20));
  final out =
      '${Platform.environment['TEMP'] ?? Directory.systemTemp.path}\\tps_smoke_src.png';
  File(out).writeAsBytesSync(img.encodePng(image));
  print('wrote $out');
}
