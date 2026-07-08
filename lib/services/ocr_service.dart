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

  /// נתיב ל-tesseract.exe (מותקן/מצורף) או null אם לא נמצא.
  static Future<String?> tesseractPath() async {
    if (_resolved) return _cached;
    _resolved = true;
    if (Platform.isWindows) {
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
    // חיפוש ב-PATH.
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

  static Future<bool> available() async => (await tesseractPath()) != null;

  /// מריץ OCR על קובץ-תמונה עם whitelist-ספרות (+פסיק). מחזיר את הפלט
  /// הגולמי, או מחרוזת ריקה בכשל. [psm] — מצב-פילוח (7=שורה, 11=דליל).
  static Future<String> readDigits(String imagePath, {int psm = 11}) async {
    final t = await tesseractPath();
    if (t == null) return '';
    try {
      final r = await Process.run(t, [
        imagePath,
        'stdout',
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
