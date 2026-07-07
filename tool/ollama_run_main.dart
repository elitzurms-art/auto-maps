// entrypoint אמיתי (רשת חיה) להרצת הצנרת האוטומטית מול Ollama מקומי,
// מוגבל ל-4 עוגנים. הרצה:
//   flutter run -t tool/ollama_run_main.dart -d windows
// הפלט לקונסולה; החלון נסגר אוטומטית בסיום.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:auto_maps/services/ai_engine.dart';
import 'package:auto_maps/services/gemini_anchor_service.dart';

const _mapPath =
    r'C:\Users\moshe\OneDrive\שולחן העבודה\פרוייקטים\ניווט\מפת נוב\מפת מושב נוב_page1.png';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('מריץ...')))));

  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('ai_engine', AiEngine.ollama);
  await prefs.setString('ollama_url', 'http://localhost:11434');
  await prefs.setString('ollama_model', 'qwen2.5vl:3b');

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
      maxAnchors: 4,
      onStatus: (s) => stdout.writeln('RUN [${sw.elapsed.inSeconds}s] $s'),
    );
    sw.stop();
    stdout.writeln('RUN === ${anchors.length} עוגנים ב-${sw.elapsed.inSeconds}s ===');
    for (final a in anchors) {
      final mark = a.verified == true ? 'V' : a.verified == false ? 'X' : '?';
      stdout.writeln(
        'RUN $mark "${a.name}" (${a.basis}) @ '
        '${a.world.latitude.toStringAsFixed(5)},'
        '${a.world.longitude.toStringAsFixed(5)}'
        '${a.verifyNote != null ? " -- ${a.verifyNote}" : ""}',
      );
    }
  } catch (e) {
    stdout.writeln('RUN ERROR: $e');
  }
  stdout.writeln('RUN DONE');
  exit(0);
}
