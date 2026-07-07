// בוחן חי של הצנרת המחווטת: suggestAnchors עם רמז-אזור → המסלול הקלאסי
// (Overpass+RANSAC) אמור להחזיר עוגנים בלי אף קריאת-מודל.
//   flutter run -t tool/classical_run_main.dart -d windows
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:auto_maps/services/gemini_anchor_service.dart';

const _mapPath =
    r'C:\Users\moshe\OneDrive\שולחן העבודה\פרוייקטים\ניווט\מפת נוב\מפת מושב נוב_page1.png';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('...')))));

  final bytes = await File(_mapPath).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final w = frame.image.width, h = frame.image.height;
  frame.image.dispose();
  stdout.writeln('RUN image ${w}x$h');

  final sw = Stopwatch()..start();
  try {
    final anchors = await GeminiAnchorService().suggestAnchors(
      imagePath: _mapPath,
      imageWidth: w,
      imageHeight: h,
      apiKey: '',
      areaHint: 'נוב רמת הגולן',
      onStatus: (s) => stdout.writeln('RUN [${sw.elapsed.inSeconds}s] $s'),
    );
    sw.stop();
    stdout.writeln('RUN === ${anchors.length} עוגנים ב-${sw.elapsed.inSeconds}s ===');
    for (final a in anchors) {
      stdout.writeln('RUN ${a.verified == true ? "V" : "?"} "${a.name}" '
          '(${a.basis}) @ ${a.world.latitude.toStringAsFixed(5)},'
          '${a.world.longitude.toStringAsFixed(5)}');
    }
  } catch (e) {
    stdout.writeln('RUN ERROR: $e');
  }
  stdout.writeln('RUN DONE');
  exit(0);
}
