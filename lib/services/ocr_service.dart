import 'dart:io';

/// עטיפת-OCR ל-Tesseract (subprocess). משמש לקריאת **תוויות-קואורדינטה
/// מודפסות** ממפות-סקר/קדסטרליות (רשת ITM) — מנתיב "רשת-קואורדינטות".
///
/// ⚠️ נכון לעכשיו **Windows בלבד** (קריאה ל-`tesseract.exe`). באנדרואיד
/// יש להוסיף מנוע (ML Kit / flutter_tesseract_ocr) — [available] יחזיר
/// false ואז הנתיב פשוט לא יוצע.
class OcrService {
  static String? _cached;
  static bool _resolved = false;
  static String? _tessdataDir; // כשמשתמשים ב-Tesseract המצורף

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

  static Future<bool> available() async => (await tesseractPath()) != null;

  /// מריץ OCR עם פלט **TSV** (תיבות-מילים) — לכל מילה: טקסט + מרכז-פיקסל.
  /// משמש לאיתור-אוטומטי של תוויות-קואורדינטה. ריק בכשל.
  static Future<List<({String text, double cx, double cy})>> readWords(
    String imagePath, {
    int psm = 11,
  }) async {
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
}
