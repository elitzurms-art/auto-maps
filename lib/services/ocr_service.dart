import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;

/// עטיפת-OCR **דו-מנועית** לקריאת תוויות-קואורדינטה מודפסות ממפות-סקר/
/// קדסטרליות (נתיב "רשת-קואורדינטות"):
/// - **Windows/desktop** — Tesseract כ-subprocess (מצורף ליד ה-exe, בלי
///   התקנה; fallback ל-Program Files/PATH).
/// - **Android/iOS** — ML Kit Text Recognition v2 (on-device, המודל הלטיני
///   מצורף ל-APK — עובד בלי רשת ובלי הורדת-מודל).
/// אותו API לשני המנועים — [GridCoordService] לא מבדיל ביניהם.
class OcrService {
  static String? _cached;
  static bool _resolved = false;
  static String? _tessdataDir; // כשמשתמשים ב-Tesseract המצורף

  static bool get _mobile => Platform.isAndroid || Platform.isIOS;

  /// ML Kit — נוצר פעם אחת (טעינת-המודל יקרה). חייב לרוץ על ה-isolate
  /// הראשי (platform channels) — וכך זה אצלנו: רק הכנת-התמונה ב-Isolate.
  static TextRecognizer? _recognizer;
  static TextRecognizer get _mlkit =>
      _recognizer ??= TextRecognizer(script: TextRecognitionScript.latin);

  /// סקאלת-ההגדלה לאיתור-האוטומטי של תוויות: Tesseract צריך ×3 לדיוק;
  /// ל-ML Kit אין צורך — והוא גם הכרחי: ביטמאפ ×3 של מקור ~4500px היה
  /// מפוצץ את זיכרון-המובייל.
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

  /// מנוע-OCR זמין? במובייל תמיד (ML Kit מצורף); בדסקטופ — אם יש Tesseract.
  static Future<bool> available() async =>
      _mobile || (await tesseractPath()) != null;

  /// מריץ OCR עם תיבות-מילים — לכל מילה: טקסט + מרכז-פיקסל.
  /// משמש לאיתור-אוטומטי של תוויות-קואורדינטה. ריק בכשל.
  static Future<List<({String text, double cx, double cy})>> readWords(
    String imagePath, {
    int psm = 11,
  }) async {
    if (_mobile) return _mlkitWords(imagePath);
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

  /// מריץ OCR על קובץ-תמונה. בדסקטופ — Tesseract עם whitelist-ספרות
  /// (+פסיק); במובייל — ML Kit (בלי whitelist; הסינון הרגקספי אצל הקוראים).
  /// מחזיר את הפלט הגולמי, או מחרוזת ריקה בכשל. [psm] — מצב-פילוח של
  /// Tesseract (7=שורה, 11=דליל); לא רלוונטי ל-ML Kit.
  static Future<String> readDigits(String imagePath, {int psm = 11}) async {
    if (_mobile) {
      try {
        final r = await _mlkit.processImage(InputImage.fromFilePath(imagePath));
        return r.text;
      } catch (_) {
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

  // ── ML Kit: אריחים חופפים מוגדלים ×2 ──
  // תוויות-רשת הן טקסט קטן (~20-30px) — ML Kit מפספס אותן ברזולוציה
  // טבעית (בדיוק כמו ש-Tesseract דרש ×3). הגדלת כל התמונה ×2 מפוצצת
  // זיכרון-מובייל, אז חותכים לאריחים חופפים ומגדילים כל אריח בנפרד.
  static const _tileSrc = 1500; // צלע-אריח בפיקסלי-מקור
  static const _tileOverlap = 250; // חפיפה — שתווית על-התפר לא תיחתך
  static const _tileUpscale = 2;

  /// מילים + מרכזי-תיבות מ-ML Kit (בקואורדינטות התמונה המקורית) —
  /// מקביל אחד-לאחד לשורות ה-TSV של Tesseract.
  static Future<List<({String text, double cx, double cy})>> _mlkitWords(
      String imagePath) async {
    try {
      // הכנת-האריחים (פענוח/חיתוך/הגדלה/קידוד — כבד) ב-Isolate; קריאות
      // ML Kit עצמן חייבות את ה-isolate הראשי (platform channels).
      final tiles = await Isolate.run(() => _prepareTiles(imagePath));
      final words = <({String text, double cx, double cy})>[];
      for (final t in tiles) {
        words.addAll(await _mlkitFile(t.path, t.scale, t.offX, t.offY));
      }
      final dedup = _dedupWords(words);
      final digitish =
          dedup.where((w) => RegExp(r'^\d{6,7}$').hasMatch(w.text.replaceAll(',', ''))).length;
      debugPrint('[OCR] mlkit: ${tiles.length} tiles → ${dedup.length} words '
          '($digitish coord-like)');
      return dedup;
    } catch (e) {
      debugPrint('[OCR] mlkit failed: $e');
      return const [];
    }
  }

  /// חותך את התמונה לאריחים מוגדלים וכותב אותם ל-temp. תמונה קטנה —
  /// עוברת כמו-שהיא (למשל חלונות-הקליק של readTick, שכבר מוגדלים ×4).
  static List<({String path, double scale, int offX, int offY})>
      _prepareTiles(String imagePath) {
    final im = img.decodeImage(File(imagePath).readAsBytesSync());
    if (im == null) return const [];
    if (im.width <= 2200 && im.height <= 2200) {
      return [(path: imagePath, scale: 1.0, offX: 0, offY: 0)];
    }
    final out = <({String path, double scale, int offX, int offY})>[];
    const step = _tileSrc - _tileOverlap;
    var i = 0;
    for (var y0 = 0; y0 < im.height; y0 += step) {
      for (var x0 = 0; x0 < im.width; x0 += step) {
        final w = math.min(_tileSrc, im.width - x0);
        final h = math.min(_tileSrc, im.height - y0);
        if (w < 80 || h < 80) continue;
        var crop = img.copyCrop(im, x: x0, y: y0, width: w, height: h);
        crop = img.copyResize(crop,
            width: w * _tileUpscale, interpolation: img.Interpolation.cubic);
        final tp = '${Directory.systemTemp.path}/_amocr_t${i++}.png';
        File(tp).writeAsBytesSync(img.encodePng(crop));
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

  /// ML Kit על קובץ יחיד; ממפה מרכזים חזרה לקואורדינטות-המקור. בנוסף
  /// לאלמנטים (מילים) נוסף מועמד ברמת-שורה: תווית מפוצלת ("735 000")
  /// מתאחה לספרות רצופות — Tesseract עם whitelist לא סבל מזה, ML Kit כן.
  static Future<List<({String text, double cx, double cy})>> _mlkitFile(
      String path, double scale, int offX, int offY) async {
    final r = await _mlkit.processImage(InputImage.fromFilePath(path));
    final out = <({String text, double cx, double cy})>[];
    for (final block in r.blocks) {
      for (final line in block.lines) {
        final joined = line.text.replaceAll(RegExp(r'[^0-9]'), '');
        if (line.elements.length > 1 &&
            RegExp(r'^\d{6,7}$').hasMatch(joined)) {
          out.add((
            text: joined,
            cx: line.boundingBox.center.dx / scale + offX,
            cy: line.boundingBox.center.dy / scale + offY,
          ));
        }
        for (final el in line.elements) {
          final t = el.text.trim();
          if (t.isEmpty) continue;
          out.add((
            text: t,
            cx: el.boundingBox.center.dx / scale + offX,
            cy: el.boundingBox.center.dy / scale + offY,
          ));
        }
      }
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
