import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

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

  /// מילים + מרכזי-תיבות מ-ML Kit: בלוקים → שורות → אלמנטים (מילים) —
  /// מקביל אחד-לאחד לשורות ה-TSV של Tesseract.
  static Future<List<({String text, double cx, double cy})>> _mlkitWords(
      String imagePath) async {
    try {
      final r = await _mlkit.processImage(InputImage.fromFilePath(imagePath));
      final out = <({String text, double cx, double cy})>[];
      for (final block in r.blocks) {
        for (final line in block.lines) {
          for (final el in line.elements) {
            final t = el.text.trim();
            if (t.isEmpty) continue;
            out.add((
              text: t,
              cx: el.boundingBox.center.dx,
              cy: el.boundingBox.center.dy,
            ));
          }
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
}
