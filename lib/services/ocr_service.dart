import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';

/// מילה שזוהתה: טקסט + מרכז-תיבה בקואורדינטות התמונה המקורית.
typedef OcrWord = ({String text, double cx, double cy});

/// עטיפת-OCR לקריאת תוויות-קואורדינטה מודפסות ממפות-סקר/קדסטרליות
/// (נתיב "רשת-קואורדינטות") — **Tesseract בכל הפלטפורמות** (זהות-מנוע):
/// - **Windows/desktop** — tesseract.exe כ-subprocess (מצורף ליד ה-exe).
/// - **Android/iOS** — Tesseract נייטיבי (flutter_tesseract_ocr) עם אותו
///   `eng.traineddata` בדיוק (‏assets/tessdata, זהה לבנדל-הדסקטופ).
///
/// **הכנת-התמונה ב-Skia** (`readGridLabels`): תוויות-רשת הן טקסט קטן
/// שדורש הגדלה ×3, אבל הגדלת כל-התמונה מפוצצת זיכרון-מובייל וב-Dart
/// (‏package:image) לוקחת דקות. לכן: אריחים חופפים, כל אריח מוגדל
/// (ומסובב, למעבר-האנכי) ב-`Canvas.drawImageRect` — קוד נייטיבי, עשרות-
/// מילישניות במקום שניות — וקידוד-PNG נייטיבי של Skia. רץ על ה-isolate
/// הראשי (חובה ל-Skia/platform-channels); העבודה הכבדה כולה נייטיבית.
///
/// ⚠️ ML Kit נוסה (2026-07-12) ונפסל: על תוויות-מפה קטנות הוא גם איטי
/// (דקות) וגם חלש (2 צפונים מ-466 מילים באושה, מול פענוח-מלא ב-Tesseract).
class OcrService {
  static String? _cached;
  static bool _resolved = false;
  static String? _tessdataDir; // כשמשתמשים ב-Tesseract המצורף (Windows)

  static bool get _mobile => Platform.isAndroid || Platform.isIOS;

  /// נתיב ל-tesseract.exe. סדר-עדיפות: **מצורף ליד ה-exe** (`tesseract/`,
  /// עצמאי — בלי התקנה) → מותקן (Program Files) → PATH. null אם לא נמצא.
  static Future<String?> tesseractPath() async {
    if (_resolved) return _cached;
    _resolved = true;
    if (Platform.isWindows) {
      // 1) מצורף ליד ה-exe (bundle) — עצמאי.
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final bundled = '$exeDir\\tesseract\\tesseract.exe';
      if (File(bundled).existsSync()) {
        _cached = bundled;
        final td = '$exeDir\\tesseract\\tessdata';
        if (Directory(td).existsSync()) _tessdataDir = td;
        return bundled;
      }
      // 2) מותקן.
      const candidates = [
        r'C:\Program Files\Tesseract-OCR\tesseract.exe',
        r'C:\Program Files (x86)\Tesseract-OCR\tesseract.exe',
      ];
      for (final c in candidates) {
        if (File(c).existsSync()) {
          _cached = c;
          return c;
        }
      }
    }
    // 3) חיפוש ב-PATH.
    try {
      final r = await Process.run(
          Platform.isWindows ? 'where' : 'which', ['tesseract']);
      if (r.exitCode == 0) {
        final p = (r.stdout as String).split('\n').first.trim();
        if (p.isNotEmpty && File(p).existsSync()) {
          _cached = p;
          return p;
        }
      }
    } catch (_) {}
    return null;
  }

  /// ארגומנטי-בסיס: כשמשתמשים ב-Tesseract המצורף מעבירים --tessdata-dir
  /// (אין TESSDATA_PREFIX במערכת).
  static List<String> _tessdataArgs() =>
      _tessdataDir == null ? const [] : ['--tessdata-dir', _tessdataDir!];

  /// מנוע-OCR זמין? במובייל תמיד (Tesseract נייטיבי + tessdata ב-assets);
  /// בדסקטופ — אם נמצא tesseract.exe.
  static Future<bool> available() async =>
      _mobile || (await tesseractPath()) != null;

  /// מריץ OCR על קובץ-תמונה עם whitelist-ספרות (+פסיק). מחזיר את הפלט
  /// הגולמי, או מחרוזת ריקה בכשל. [psm] — מצב-פילוח (7=שורה, 11=דליל).
  static Future<String> readDigits(String imagePath, {int psm = 11}) async {
    if (_mobile) {
      try {
        return await FlutterTesseractOcr.extractText(
          imagePath,
          language: 'eng',
          args: {
            'psm': '$psm',
            'tessedit_char_whitelist': '0123456789,',
          },
        );
      } catch (e) {
        debugPrint('[OCR] mobile extractText failed: $e');
        return '';
      }
    }
    final t = await tesseractPath();
    if (t == null) return '';
    try {
      final r = await Process.run(t, [
        imagePath,
        'stdout',
        ..._tessdataArgs(),
        '--psm',
        '$psm',
        '-c',
        'tessedit_char_whitelist=0123456789,',
      ]);
      return r.exitCode == 0 ? (r.stdout as String) : '';
    } catch (_) {
      return '';
    }
  }

  // ── קריאת-תוויות מכל התמונה (איתור-הרשת האוטומטי) ──
  static const _tileSrc = 1100; // צלע-אריח בפיקסלי-מקור
  static const _tileOverlap = 220; // חפיפה — שתווית על-התפר לא תיחתך
  static const _upscale = 3; // ההגדלה ש-Tesseract דורש לתוויות קטנות

  /// קורא את כל תוויות-התמונה בשני כיוונים — אופקי ([OcrWord] ב-normal)
  /// ואנכי (vertical — כל אריח מסובב 90° כך שכיתוב-אנכי נהיה קריא) —
  /// שניהם **בקואורדינטות התמונה המקורית**. [onTile] מדווח התקדמות.
  static Future<({List<OcrWord> normal, List<OcrWord> vertical})>
      readGridLabels(
    String imagePath, {
    int psm = 11,
    void Function(int done, int total)? onTile,
  }) async {
    final sw = Stopwatch()..start();
    final bytes = await File(imagePath).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final im = frame.image;
    codec.dispose();
    try {
      final rects = _tileRects(im.width, im.height);
      final normal = <OcrWord>[];
      final vertical = <OcrWord>[];
      final total = rects.length * 2;
      var done = 0;
      // דסקטופ = subprocess נפרד לכל אריח → אפשר לְמַקְבֵּל; מובייל =
      // מופע-Tesseract יחיד בפלאגין → טורי.
      final batch = _mobile ? 1 : 4;
      for (var i = 0; i < rects.length; i += batch) {
        await Future.wait(rects.skip(i).take(batch).map((r) async {
          normal.addAll(await _ocrTile(im, r, rotated: false, psm: psm));
          onTile?.call(++done, total);
          vertical.addAll(await _ocrTile(im, r, rotated: true, psm: psm));
          onTile?.call(++done, total);
        }));
      }
      final n = _dedupWords(normal), v = _dedupWords(vertical);
      debugPrint('[OCR] grid-labels: ${rects.length} tiles in '
          '${sw.elapsedMilliseconds}ms → ${n.length} normal + '
          '${v.length} vertical words');
      return (normal: n, vertical: v);
    } finally {
      im.dispose();
    }
  }

  /// רשת-האריחים החופפים המכסה את התמונה.
  static List<ui.Rect> _tileRects(int w, int h) {
    const step = _tileSrc - _tileOverlap;
    final out = <ui.Rect>[];
    for (var y0 = 0; y0 < h; y0 += step) {
      for (var x0 = 0; x0 < w; x0 += step) {
        final tw = math.min(_tileSrc, w - x0), th = math.min(_tileSrc, h - y0);
        if ((tw < 80 || th < 80) && out.isNotEmpty) continue; // שאריות-שוליים
        out.add(ui.Rect.fromLTWH(
            x0.toDouble(), y0.toDouble(), tw.toDouble(), th.toDouble()));
      }
    }
    return out;
  }

  /// מרנדר אריח מוגדל ×3 (ומסובב-CCW-90 במעבר-האנכי) ב-**Skia**, מריץ
  /// עליו את המנוע, וממפה את מרכזי-המילים חזרה לקואורדינטות-המקור.
  static Future<List<OcrWord>> _ocrTile(
    ui.Image im,
    ui.Rect r, {
    required bool rotated,
    required int psm,
  }) async {
    final wUp = (r.width * _upscale).roundToDouble();
    final hUp = (r.height * _upscale).roundToDouble();
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    if (rotated) {
      // סיבוב-CCW-90 של התוכן: (x,y) → (y, wUp−x); ממדי-הפלט מתהפכים.
      canvas.translate(0, wUp);
      canvas.rotate(-math.pi / 2);
    }
    canvas.drawImageRect(
      im,
      r,
      ui.Rect.fromLTWH(0, 0, wUp, hUp),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final pic = rec.endRecording();
    final tile = await pic.toImage(
        (rotated ? hUp : wUp).round(), (rotated ? wUp : hUp).round());
    pic.dispose();
    final png = await tile.toByteData(format: ui.ImageByteFormat.png);
    tile.dispose();
    if (png == null) return const [];
    final tp = '${Directory.systemTemp.path}/_amocr_'
        '${rotated ? 'r' : 'n'}_${r.left.round()}_${r.top.round()}.png';
    await File(tp).writeAsBytes(
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes));
    final words = await _wordsOfFile(tp, psm: psm);
    // מיפוי חזרה: באריח-מסובב מילה ב-(cx,cy) ישבה במקור ב-(wUp−cy, cx).
    return [
      for (final w in words)
        (
          text: w.text,
          cx: r.left + (rotated ? (wUp - w.cy) : w.cx) / _upscale,
          cy: r.top + (rotated ? w.cx : w.cy) / _upscale,
        ),
    ];
  }

  /// מילים + מרכזי-תיבות מקובץ-תמונה (בקואורדינטות-הקובץ): דסקטופ — TSV
  /// של tesseract.exe; מובייל — hOCR של הפלאגין הנייטיבי.
  static Future<List<OcrWord>> _wordsOfFile(String imagePath,
      {required int psm}) async {
    if (_mobile) {
      try {
        final hocr = await FlutterTesseractOcr.extractHocr(
          imagePath,
          language: 'eng',
          args: {
            'psm': '$psm',
            'tessedit_char_whitelist': '0123456789,',
          },
        );
        return _parseHocr(hocr);
      } catch (e) {
        debugPrint('[OCR] mobile extractHocr failed: $e');
        return const [];
      }
    }
    final t = await tesseractPath();
    if (t == null) return const [];
    final out = '$imagePath.tsv_out';
    try {
      // ⚠️ TSV דרך המשתנה tessedit_create_tsv=1 ולא דרך קונפיג-הקובץ 'tsv'
      // — ה-Tesseract המצורף לא כולל את tessdata/configs/tsv (הועתק רק
      // traineddata), אז הקונפיג 'tsv' לא נמצא והקובץ לא נוצר.
      final r = await Process.run(t, [
        imagePath,
        out,
        ..._tessdataArgs(),
        '--psm',
        '$psm',
        '-c',
        'tessedit_char_whitelist=0123456789,',
        '-c',
        'tessedit_create_tsv=1',
      ]);
      if (r.exitCode != 0) return const [];
      final res = <OcrWord>[];
      for (final ln in File('$out.tsv').readAsLinesSync().skip(1)) {
        final c = ln.split('\t');
        if (c.length < 12) continue;
        final text = c[11].trim();
        if (text.isEmpty) continue;
        final x = double.tryParse(c[6]), y = double.tryParse(c[7]);
        final w = double.tryParse(c[8]), h = double.tryParse(c[9]);
        if (x == null || y == null || w == null || h == null) continue;
        res.add((text: text, cx: x + w / 2, cy: y + h / 2));
      }
      return res;
    } catch (_) {
      return const [];
    }
  }

  /// פרסור hOCR: כל `ocrx_word` נושא `title="bbox x0 y0 x1 y1; ..."`.
  static List<OcrWord> _parseHocr(String hocr) {
    final out = <OcrWord>[];
    final re = RegExp(
      r'''<span[^>]*class=.ocrx_word[^>]*title=.bbox (\d+) (\d+) (\d+) (\d+)[^>]*>(.*?)</span>''',
      dotAll: true,
    );
    for (final m in re.allMatches(hocr)) {
      final text = m
          .group(5)!
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .replaceAll('&amp;', '&')
          .trim();
      if (text.isEmpty) continue;
      final x0 = int.parse(m.group(1)!), y0 = int.parse(m.group(2)!);
      final x1 = int.parse(m.group(3)!), y1 = int.parse(m.group(4)!);
      out.add((text: text, cx: (x0 + x1) / 2, cy: (y0 + y1) / 2));
    }
    return out;
  }

  /// איחוד כפילויות מאזורי-החפיפה: אותו טקסט בטווח ~20px = אותה תווית.
  static List<OcrWord> _dedupWords(List<OcrWord> words) {
    final out = <OcrWord>[];
    for (final w in words) {
      final dup = out.any((o) =>
          o.text == w.text &&
          (o.cx - w.cx).abs() < 20 &&
          (o.cy - w.cy).abs() < 20);
      if (!dup) out.add(w);
    }
    return out;
  }
}
