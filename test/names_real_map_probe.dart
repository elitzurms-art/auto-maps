// בוחן-הרצה של מנוע-השמות על מפה אמיתית — כלי-איטרציה (לא רגרסיה):
//   $env:AUTO_MAPS_TESSDATA="C:\auto maps\assets\tessdata"
//   $env:AUTO_MAPS_PROBE_IMAGE="<נתיב-תמונה>"
//   flutter test test/names_real_map_probe.dart
// מדפיס את העוגנים שנמצאו (או את סיבת-הכישלון בלוגי [NAMES]).
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:auto_maps/services/terrain_names_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('names probe on real map', (tester) async {
    final path = Platform.environment['AUTO_MAPS_PROBE_IMAGE'];
    if (path == null || !File(path).existsSync()) {
      markTestSkipped('קבע AUTO_MAPS_PROBE_IMAGE לנתיב-תמונה');
      return;
    }
    await tester.runAsync(() async {
      final sw = Stopwatch()..start();
      final anchors = await TerrainNamesService.suggestAnchors(
        imagePath: path,
        onStage: (s) {},
      );
      // ignore: avoid_print
      print('=== $path: ${sw.elapsedMilliseconds}ms → '
          '${anchors?.length ?? 0} anchors');
      for (final a in anchors ?? const []) {
        // ignore: avoid_print
        print('  "${a.name}" @(${a.pixel.dx.round()},${a.pixel.dy.round()}) '
            '→ ${a.world.latitude.toStringAsFixed(5)},'
            '${a.world.longitude.toStringAsFixed(5)}');
      }
    });
  });
}
