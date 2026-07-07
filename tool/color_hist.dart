// 15 הצבעים הנפוצים בתמונה (מקוונטט ל-8 רמות/ערוץ) + בהירות של כל אחד.
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
  final counts = <int, int>{};
  for (var y = 0; y < work.height; y++) {
    for (var x = 0; x < work.width; x++) {
      final p = work.getPixel(x, y);
      final key = (p.r.toInt() ~/ 16) << 10 |
          (p.g.toInt() ~/ 16) << 5 |
          (p.b.toInt() ~/ 16);
      counts[key] = (counts[key] ?? 0) + 1;
    }
  }
  final total = work.width * work.height;
  final sorted = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final e in sorted.take(15)) {
    final r = (e.key >> 10) * 16 + 8;
    final g = ((e.key >> 5) & 31) * 16 + 8;
    final b = (e.key & 31) * 16 + 8;
    final lum = (0.299 * r + 0.587 * g + 0.114 * b).round();
    print('rgb(~$r,~$g,~$b) lum~$lum  '
        '${(100.0 * e.value / total).toStringAsFixed(1)}%');
  }
}
