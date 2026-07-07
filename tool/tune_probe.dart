// מריץ את גלאי-הצמתים על קובץ מפה אמיתי עם פלט-דיבוג של כל שלב.
// הרצה: dart run tool/tune_probe.dart "<image>" "<debugDir>"
import 'dart:io';

import 'package:image/image.dart' as img;

import 'package:auto_maps/services/road_junction_detector.dart';

void main(List<String> args) {
  final path = args[0];
  final debugDir = args[1];
  Directory(debugDir).createSync(recursive: true);
  final im = img.decodeImage(File(path).readAsBytesSync());
  if (im == null) {
    print('decode failed');
    exitCode = 1;
    return;
  }
  print('image ${im.width}x${im.height}');
  final sw = Stopwatch()..start();
  final found = RoadJunctionDetector.detect(im, debugDir: debugDir);
  print('candidates: ${found.length} in ${sw.elapsedMilliseconds}ms');
  print(File('$debugDir/00_info.txt').readAsStringSync());
}
