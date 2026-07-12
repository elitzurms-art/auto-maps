import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';
import 'package:image/image.dart' as img;

/// עטיפת-OCR לקריאת תוויות-קואורדינטה מודפסות ממפות-סקר/קדסטרליות
/// (נתיב "רשת-קואורדינטות") — **Tesseract בכל הפלטפורמות** (זהות-מנוע):
/// - **Windows/desktop** — tesseract.exe כ-subprocess (מצורף ליד ה-exe).
/// - **Android/iOS** — Tesseract נייטיבי (flutter_tesseract_ocr) עם אותו
///   `eng.traineddata` בדיוק (‏assets/tessdata, זהה לבנדל-הדסקטופ).
/// ⚠️ ML Kit נוסה (2026-07-12) ונפסל: על תוויות-מפה קטנות הוא גם איטי
/// (דקות) וגם חלש (2 צפונים מ-466 מילים באושה, מול פענוח-מלא ב-Tesseract).
class OcrService {
  static String? _cached;
  static bool _resolved = false;
  static String? _tessdataDir; // כשמשתמשים ב-Tesseract המצורף (Windows)

  static bool get _mobile => Platform.isAndroid || Platform.isIOS;

  /// סקאלת-ההגדלה שמכין [GridCoordService] לאיתור-האוטומטי: בדסקטופ ×3
  /// (התמונה כולה); במובייל 1 — ההגדלה נעשית כאן פר-אריח (זיכרון חסום).
  static int get autoScale => _mobile ? 1 : 3;

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

  /// מריץ OCR עם תיבות-מילים — לכל מילה: טקסט + מרכז-פיקסל (בקואורדינטות
  /// התמונה שנמסרה). משמש לאיתור-אוטומטי של תוויות-קואורדינטה. ריק בכשל.
  static Future<List<({String text, double cx, double cy})>> readWords(
    String imagePath, {
    int psm = 11,
  }) async {
    if (_mobile) return _mobileWords(imagePath, psm: psm);
    final t = await tesseractPath();
    if (t == null) return const [];
    final out = '${Directory.systemTemp.path}/_amtsv';
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
      final res = <({String text, double cx, double cy})>[];
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

  // ── מובייל: אריחים חופפים מוגדלים ×3 → Tesseract נייטיבי + hOCR ──
  // תוויות-רשת הן טקסט קטן (~15-30px) שדורש הגדלה (כמו ×3 בדסקטופ), אבל
  // הגדלת כל-התמונה מפוצצת זיכרון-מובייל — אז מגדילים פר-אריח. ‏BMP במקום
  // PNG ואינטרפולציה לינארית — קידוד-PNG של אריחי-ענק ב-Dart היה צוואר-
  // הבקבוק שהקפיץ את הריצה מעל ה-timeout.
  static const _tileSrc = 1100; // צלע-אריח בפיקסלי-מקור
  static const _tileOverlap = 220; // חפיפה — שתווית על-התפר לא תיחתך
  static const _tileUpscale = 3;

  static Future<List<({String text, double cx, double cy})>> _mobileWords(
      String imagePath,
      {required int psm}) async {
    try {
      final sw = Stopwatch()..start();
      // הכנת-האריחים (פענוח/חיתוך/הגדלה/קידוד — כבד) ב-Isolate; קריאת
      // ה-OCR (platform channel) על ה-isolate הראשי.
      final tiles = await Isolate.run(() => _prepareTiles(imagePath));
      final prepMs = sw.elapsedMilliseconds;
      final words = <({String text, double cx, double cy})>[];
      for (final t in tiles) {
        final hocr = await FlutterTesseractOcr.extractHocr(
          t.path,
          language: 'eng',
          args: {
            'psm': '$psm',
            'tessedit_char_whitelist': '0123456789,',
          },
        );
        words.addAll(_parseHocr(hocr, t.scale, t.offX, t.offY));
      }
      final dedup = _dedupWords(words);
      debugPrint('[OCR] tesseract-mobile: ${tiles.length} tiles, '
          'prep ${prepMs}ms, ocr ${sw.elapsedMilliseconds - prepMs}ms → '
          '${dedup.length} words');
      return dedup;
    } catch (e) {
      debugPrint('[OCR] tesseract-mobile failed: $e');
      return const [];
    }
  }

  /// חותך את התמונה לאריחים מוגדלים ×3 וכותב אותם כ-BMP ל-temp — תמיד,
  /// גם תמונה קטנה (אריח יחיד).
  static List<({String path, double scale, int offX, int offY})>
      _prepareTiles(String imagePath) {
    final im = img.decodeImage(File(imagePath).readAsBytesSync());
    if (im == null) return const [];
    final out = <({String path, double scale, int offX, int offY})>[];
    const step = _tileSrc - _tileOverlap;
    var i = 0;
    for (var y0 = 0; y0 < im.height; y0 += step) {
      for (var x0 = 0; x0 < im.width; x0 += step) {
        final w = math.min(_tileSrc, im.width - x0);
        final h = math.min(_tileSrc, im.height - y0);
        if ((w < 80 || h < 80) && i > 0) continue; // שאריות-שוליים זעירות
        var crop = img.copyCrop(im, x: x0, y: y0, width: w, height: h);
        crop = img.copyResize(crop,
            width: w * _tileUpscale, interpolation: img.Interpolation.linear);
        final tp = '${Directory.systemTemp.path}/_amocr_t${i++}.bmp';
        File(tp).writeAsBytesSync(img.encodeBmp(crop));
        out.add((
          path: tp,
          scale: _tileUpscale.toDouble(),
          offX: x0,
          offY: y0,
        ));
      }
    }
    return out;
  }

  /// פרסור hOCR: כל `ocrx_word` נושא `title="bbox x0 y0 x1 y1; ..."` —
  /// ממפים את מרכז-התיבה חזרה לקואורדינטות-המקור של האריח.
  static List<({String text, double cx, double cy})> _parseHocr(
      String hocr, double scale, int offX, int offY) {
    final out = <({String text, double cx, double cy})>[];
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
      out.add((
        text: text,
        cx: (x0 + x1) / 2 / scale + offX,
        cy: (y0 + y1) / 2 / scale + offY,
      ));
    }
    return out;
  }

  /// איחוד כפילויות מאזורי-החפיפה: אותו טקסט בטווח ~20px = אותה תווית.
  static List<({String text, double cx, double cy})> _dedupWords(
      List<({String text, double cx, double cy})> words) {
    final out = <({String text, double cx, double cy})>[];
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
