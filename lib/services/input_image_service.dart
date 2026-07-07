import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';

/// נרמול קבצי-קלט לתמונה שה-UI (ושאר הצנרת) יודעים להציג:
/// - PNG/JPG/WebP/BMP/GIF — עוברים כמו שהם.
/// - PDF — העמוד הנבחר מרונדר ל-PNG ברזולוציה גבוהה (pdfium דרך pdfx).
/// - HEIC/HEIF — דרך קודק המנוע (Android/iOS/macOS) או WIC ‏(Windows,
///   ‏auto_maps_wic.dll — דורש את HEIF Image Extensions של MS).
/// - TIFF ושאר פורמטים ש-package:image מפענח — מומרים ל-PNG ב-Isolate.
class InputImageService {
  static const _passThrough = {
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
    '.bmp',
    '.gif',
  };

  /// הסיומות שבורר-הקבצים מציע.
  static const pickerExtensions = [
    'png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif',
    'tif', 'tiff',
    'heic', 'heif',
    'pdf',
  ];

  static bool isPdf(String path) => p.extension(path).toLowerCase() == '.pdf';

  /// מספר העמודים ב-PDF (לבחירת עמוד כשיש יותר מאחד).
  static Future<int> pdfPageCount(String path) async {
    final doc = await PdfDocument.openFile(path);
    try {
      return doc.pagesCount;
    } finally {
      await doc.close();
    }
  }

  /// מחזיר נתיב תמונה להצגה. [pdfPage] — עמוד לרינדור (1-based).
  static Future<String> normalize(String path, {int pdfPage = 1}) async {
    final ext = p.extension(path).toLowerCase();
    if (_passThrough.contains(ext)) return path;

    final tmp = await getTemporaryDirectory();
    final base = p.basenameWithoutExtension(path);

    if (ext == '.pdf') {
      final doc = await PdfDocument.openFile(path);
      try {
        final page = await doc.getPage(pdfPage.clamp(1, doc.pagesCount));
        try {
          // רינדור לצלע-ארוכה ~4500px — מספיק לנעיצה מדויקת ולגלאי-הצמתים.
          final scale = 4500 / max(page.width, page.height);
          final rendered = await page.render(
            width: page.width * scale,
            height: page.height * scale,
            format: PdfPageImageFormat.png,
          );
          if (rendered == null) {
            throw Exception('רינדור עמוד ה-PDF נכשל');
          }
          final out = p.join(tmp.path, '$base-עמוד$pdfPage.png');
          await File(out).writeAsBytes(rendered.bytes);
          return out;
        } finally {
          await page.close();
        }
      } finally {
        await doc.close();
      }
    }

    final out = p.join(tmp.path, '$base.png');

    if (ext == '.heic' || ext == '.heif') {
      // Android/iOS/macOS — קודק המנוע יודע HEIC; Windows — ‏WIC.
      if (await _tryUiCodec(path, out)) return out;
      if (Platform.isWindows && _wicConvert(path, out)) return out;
      throw Exception(
        'פענוח HEIC נכשל — ב-Windows ודא ש"HEIF Image Extensions" מותקן '
        '(Microsoft Store), או המר את הקובץ ל-JPG',
      );
    }

    // המרה גנרית דרך package:image (TIFF וכד') — כבד, רץ ב-Isolate.
    // המתודה סטטית והקלוז'ר תופס רק מחרוזות — בטוח לשליחה בין isolates.
    final ok = await Isolate.run(() => _convertSync(path, out));
    if (!ok) {
      throw Exception('פענוח הקובץ נכשל — פורמט לא נתמך ($ext)');
    }
    return out;
  }

  static bool _convertSync(String src, String dst) {
    final decoded = img.decodeImage(File(src).readAsBytesSync());
    if (decoded == null) return false;
    File(dst).writeAsBytesSync(img.encodePng(decoded));
    return true;
  }

  /// המרה דרך קודק-התמונות של מנוע Flutter (מפענח פורמטים פלטפורמתיים
  /// כמו HEIC במובייל/מק). false כשהקודק לא מכיר את הפורמט.
  static Future<bool> _tryUiCodec(String src, String dst) async {
    try {
      final codec = await ui.instantiateImageCodec(
        await File(src).readAsBytes(),
      );
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      frame.image.dispose();
      if (data == null) return false;
      await File(dst).writeAsBytes(data.buffer.asUint8List());
      return true;
    } catch (_) {
      return false;
    }
  }

  // ═══ ממיר WIC ‏(Windows) ═══

  static int Function(Pointer<Utf8>, Pointer<Utf8>)? _wicFn;

  static bool _wicConvert(String src, String dst) {
    try {
      _wicFn ??= DynamicLibrary.open('auto_maps_wic.dll').lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Utf8>, Pointer<Utf8>)>('wic_convert_to_png');
      final s = src.toNativeUtf8();
      final d = dst.toNativeUtf8();
      try {
        return _wicFn!(s, d) == 0;
      } finally {
        calloc.free(s);
        calloc.free(d);
      }
    } catch (_) {
      return false;
    }
  }
}
