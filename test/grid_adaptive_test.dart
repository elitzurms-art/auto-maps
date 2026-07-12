// אימות מקצה-לקצה של זרימת גישוש→כיול→טבעות על מפות-בוחן סינתטיות עם
// אמת-קרקע ידועה: A (תוויות-שוליים מלאות → "גישוש בלבד") ו-B (מזרחים
// למעלה + צפונים פנימיים → מסלול-הכיול). בודק גם דיוק-פיקסל של הצלבים.
// הרצה: flutter test test/grid_adaptive_test.dart
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:auto_maps/services/grid_coord_service.dart';
import 'package:flutter_test/flutter_test.dart';

// אמת-הקרקע של מחוללי-המפות (tool/make_test_maps.py).
const e0 = 205000.0, n0 = 742400.0;
const stepM = 200.0, stepPx = 400.0, margin = 300.0;

Future<void> runOn(
  String path,
  WidgetTester tester, {
  double e0v = e0,
  double n0v = n0,
  double stepMv = stepM,
  double stepPxv = stepPx,
}) async {
  if (!File(path).existsSync()) {
    markTestSkipped('אין מפת-בוחן ($path)');
    return;
  }
  await tester.runAsync(() async {
    final sw = Stopwatch()..start();
    final ticks = await GridCoordService.autoDetectTicks(
      path,
      onProgress: (s, f) {},
    );
    // ignore: avoid_print
    print('=== $path: ${sw.elapsedMilliseconds}ms, ${ticks.length} ticks');
    var maxErr = 0.0;
    for (final t in ticks) {
      final ex = margin + (t.e - e0v) / stepMv * stepPxv;
      final ey = margin + (n0v - t.n) / stepMv * stepPxv;
      final err = math.sqrt(math.pow(t.pixel.dx - ex, 2) +
          math.pow(t.pixel.dy - ey, 2));
      maxErr = math.max(maxErr, err);
      // ignore: avoid_print
      print('  E=${t.e.round()} N=${t.n.round()} '
          '@(${t.pixel.dx.round()},${t.pixel.dy.round()}) '
          'צפוי (${ex.round()},${ey.round()}) שגיאה ${err.round()}px');
    }
    // ignore: avoid_print
    print('  שגיאה מרבית: ${maxErr.round()}px');
    expect(ticks.length, greaterThanOrEqualTo(2));
    expect(maxErr, lessThan(60)); // 60px = 30מ' בקנה-המידה הזה
  });
}

void main() {
  final temp = Platform.environment['TEMP'] ?? '/tmp';
  testWidgets('מפה A — תוויות-שוליים מלאות (גישוש בלבד)', (tester) async {
    await runOn('$temp\\מפת_בוחן_גדולה.png', tester);
  });
  testWidgets('מפה B — מזרחים למעלה + צפונים פנימיים (מסלול-כיול)',
      (tester) async {
    await runOn('$temp\\מפת_בוחן_פנימית.png', tester);
  });
  testWidgets('מפה C — כיתוב-אנכי הפוך (נפילה-לאחור CW)', (tester) async {
    await runOn('$temp\\מפת_בוחן_הפוכה.png', tester);
  });
  testWidgets('מפה D — תוויות-ק"מ מקוצרות (מפה צבאית)', (tester) async {
    await runOn('$temp\\מפת_בוחן_קמ.png', tester,
        e0v: 205000, n0v: 742000, stepMv: 1000, stepPxv: 1000);
  });
}
