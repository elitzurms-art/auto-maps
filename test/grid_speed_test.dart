// מדידת-זמן מבודדת ל-readGridLabels (בלי מנוע-הכבישים שרץ במקביל באפליקציה)
// — מאתרת אם האטת-הרשת באפליקציה באה מהצינור עצמו או מתחרות-ליבות.
// הרצה: flutter test test/grid_speed_test.dart
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:auto_maps/services/ocr_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('grid-labels timing on reassembled Usha', (tester) async {
    final path =
        '${Platform.environment['TEMP'] ?? '/tmp'}\\_usha_reassembled.png';
    if (!File(path).existsSync()) {
      markTestSkipped('אין תמונת-בדיקה ($path)');
      return;
    }
    await tester.runAsync(() async {
      final sw = Stopwatch()..start();
      final labels = await OcrService.readGridLabels(path);
      // ignore: avoid_print
      print('standalone: ${sw.elapsedMilliseconds}ms, '
          '${labels.normal.length} normal + ${labels.vertical.length} vertical');
      expect(labels.normal, isNotEmpty);
    });
  });
}
