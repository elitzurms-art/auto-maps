// אימות מקצה-לקצה של מנוע שמות-המקומות על מפת-בוחן שנבנתה מהגזטיר
// האמיתי (tool/make_names_test_map.py): שמות אמיתיים במיקומים היחסיים
// האמיתיים. בודק שהעוגנים תואמים את רשומות-האמת (world מדויק — הוא בא
// מהגזטיר; pixel עד היסט-תווית).
// הרצה (דורש מודל-עברית): ‏
//   $env:AUTO_MAPS_TESSDATA="C:\auto maps\assets\tessdata"
//   flutter test test/names_engine_test.dart
@Timeout(Duration(minutes: 8))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:auto_maps/services/terrain_names_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  testWidgets('מנוע-השמות על מפת-בוחן מהגזטיר', (tester) async {
    final temp = Platform.environment['TEMP'] ?? '/tmp';
    final png = '$temp\\מפת_בוחן_שמות.png';
    final truthPath = '$temp\\מפת_בוחן_שמות.json';
    if (!File(png).existsSync() || !File(truthPath).existsSync()) {
      markTestSkipped('אין מפת-בוחן — הרץ tool/make_names_test_map.py');
      return;
    }
    final truth = jsonDecode(File(truthPath).readAsStringSync())
        as Map<String, dynamic>;
    final names = (truth['names'] as List).cast<Map<String, dynamic>>();
    const dist = Distance();

    await tester.runAsync(() async {
      final sw = Stopwatch()..start();
      final anchors = await TerrainNamesService.suggestAnchors(
        imagePath: png,
        onStage: (s) {},
      );
      // ignore: avoid_print
      print('=== ${sw.elapsedMilliseconds}ms, '
          '${anchors?.length ?? 0} anchors');
      expect(anchors, isNotNull);
      // ‏2 = מסלול שני-זרעים-נדירים (אמינות-נמוכה); ‏3+ = חזק.
      expect(anchors!.length, greaterThanOrEqualTo(2));
      var matched = 0;
      for (final a in anchors) {
        // רשומת-האמת הקרובה-ביותר בעולם — העוגן חייב לשבת עליה (הצד-
        // העולמי מגיע ישירות מהגזטיר, אז הוא או מדויק או שם-שגוי).
        var bestM = double.infinity;
        Map<String, dynamic>? bestT;
        for (final t in names) {
          final m = dist(
            a.world,
            LatLng((t['lat'] as num).toDouble(), (t['lon'] as num).toDouble()),
          );
          if (m < bestM) {
            bestM = m;
            bestT = t;
          }
        }
        final pxErr = bestT == null
            ? double.infinity
            : math.sqrt(
                math.pow(a.pixel.dx - (bestT['px'] as num), 2) +
                    math.pow(a.pixel.dy - (bestT['py'] as num), 2));
        // ignore: avoid_print
        print('  "${a.name}" world-err ${bestM.round()}m, '
            'pixel-err ${pxErr.round()}px');
        if (bestM < 60) matched++;
        // הפיקסל = מרכז-התווית; מותר היסט של עד ~רוחב-תווית מהפריט.
        expect(pxErr, lessThan(500));
      }
      // רוב-מוחלט של העוגנים חייב לשבת על רשומת-האמת הנכונה.
      expect(matched, greaterThanOrEqualTo(anchors.length - 1));
    });
  });
}
