// מדגם בהירות בנקודות-מפתח של מפה (בקואורדינטות התמונה המוקטנת ל-1100).
// הרצה: dart run tool/sample_lum.dart "<image>"
import 'dart:io';
import 'dart:math';

import 'package:image/image.dart' as img;

void main(List<String> args) {
  final im = img.decodeImage(File(args[0]).readAsBytesSync())!;
  final maxSide = max(im.width, im.height);
  final work = maxSide > 1100
      ? (im.width >= im.height
          ? img.copyResize(im, width: 1100)
          : img.copyResize(im, height: 1100))
      : im;
  print('work ${work.width}x${work.height}');
  final samples = <String, (int, int)>{
    'ring-road-south': (520, 995),
    'ring-road-east': (940, 550),
    'internal-road': (600, 430),
    'internal-road-2': (450, 620),
    'plot-fill': (500, 330),
    'plot-fill-2': (700, 500),
    'outer-bg': (60, 540),
    'green-area': (870, 700),
    'legend-blue': (985, 62),
  };
  for (final e in samples.entries) {
    final (x, y) = e.value;
    // ממוצע 3x3 סביב הנקודה
    var sum = 0.0;
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        sum += img.getLuminance(work.getPixel(x + dx, y + dy));
      }
    }
    final p = work.getPixel(x, y);
    print('${e.key.padRight(16)} lum=${(sum / 9).round()} '
        'rgb=(${p.r},${p.g},${p.b})');
  }
}
