import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show Offset;

import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';

import 'ocr_service.dart';
import 'world_file_parser_service.dart';

/// נתיב **רשת-קואורדינטות**: קורא תוויות-קואורדינטה מודפסות ממפות-סקר/
/// קדסטרליות/צבאיות → נקודות-בקרה מדויקות → ג'יאורפרנס ישיר, בלי התאמה/
/// מודל. משתמש ב-[OcrService] (Tesseract) לקריאת הספרות.
///
/// כל **צלב-רשת** (בכל צורה — +, ר/L, טיק) נושא שני מספרים: מזרח (easting)
/// וצפון (northing). קוראים את שניהם (רגיל + מסובב 90°) — חסין לצורת-
/// הסימון ולכיוון-הכיתוב. **ה-CRS מזוהה אוטומטית מטווח-הערכים** דרך
/// [WorldFileParserService.detectCrs]:
/// - **ITM** (רשת-ישראל אזרחית): X 100–300 אלף, Y 400–800 אלף (6 ספרות).
/// - **UTM 36N** (מפות צבאיות): Y ≈ 3.5 **מיליון** (7 ספרות!) — זה המפתח
///   להבחנה; easting ≈ 600–800 אלף.
/// - **רשת-ישראל ישנה**: Y 800 אלף–1.3 מיליון.
/// הצפון תמיד גדול מהמזרח, אז מזהים northing/easting לפי הטווחים ומזהים
/// CRS מהזוג — ואז ממירים ל-WGS84 עם ה-proj המתאים.
class GridCoordService {
  /// חלון סביב פיקסל-הקליק, מוגדל ×[scale], OCR רגיל + מסובב-CCW,
  /// חילוץ מספרי 6–7 ספרות ושיוך easting/northing. מחזיר (easting,
  /// northing, crs) או null אם לא נמצא זוג תקין.
  static Future<({double easting, double northing, String crs})?> readTick(
    img.Image src,
    Offset px, {
    double radius = 130,
    int scale = 4,
  }) async {
    List<int> nums(String s) {
      final o = <int>[];
      for (final t in s.split(RegExp(r'\s+'))) {
        final d = t.replaceAll(',', '').trim();
        if (RegExp(r'^\d{6,7}$').hasMatch(d)) o.add(int.parse(d));
      }
      return o;
    }

    final x0 = (px.dx - radius).round().clamp(0, src.width - 2);
    final y0 = (px.dy - radius).round().clamp(0, src.height - 2);
    final x1 = (px.dx + radius).round().clamp(x0 + 1, src.width);
    final y1 = (px.dy + radius).round().clamp(y0 + 1, src.height);
    var win = img.copyCrop(src, x: x0, y: y0, width: x1 - x0, height: y1 - y0);
    win = img.copyResize(win,
        width: win.width * scale, interpolation: img.Interpolation.cubic);

    final dir = Directory.systemTemp;
    final nPath = '${dir.path}/_amocr_n.png';
    final rPath = '${dir.path}/_amocr_r.png';
    File(nPath).writeAsBytesSync(img.encodePng(win));
    File(rPath).writeAsBytesSync(img.encodePng(img.copyRotate(win, angle: -90)));

    final all = <int>[
      ...nums(await OcrService.readDigits(nPath)),
      ...nums(await OcrService.readDigits(rPath)),
    ];
    // northing תמיד גדול מ-easting. UTM northing = 7-ספרות (3–4 מיליון);
    // אחרת northing 400 אלף–1.3 מיליון; easting: UTM 600–834 אלף, אחרת
    // 100–300 אלף. מזהים לפי הטווחים כדי לא לבלבל UTM-easting עם ITM-Y.
    final utmN = all.where((v) => v >= 3000000 && v <= 4000000).toList();
    double? easting, northing;
    if (utmN.isNotEmpty) {
      northing = utmN.first.toDouble();
      final e = all.where((v) => v >= 600000 && v <= 900000).toList();
      if (e.isNotEmpty) easting = e.first.toDouble();
    } else {
      final n = all.where((v) => v >= 400000 && v <= 1300000).toList();
      final e = all.where((v) => v >= 100000 && v <= 300000).toList();
      if (n.isNotEmpty) northing = n.first.toDouble();
      if (e.isNotEmpty) easting = e.first.toDouble();
    }
    if (easting == null || northing == null) return null;
    final crs = WorldFileParserService().detectCrs(easting, northing);
    return (easting: easting, northing: northing, crs: crs);
  }

  /// קורא צלב בפיקסל [px] ומחזיר את מיקומו ב-WGS84 (‏CRS מזוהה אוטומטית),
  /// או null אם לא נקרא זוג-קואורדינטה תקין.
  static Future<LatLng?> readTickWgs84(img.Image src, Offset px) async {
    final t = await readTick(src, px);
    if (t == null) return null;
    return WorldFileParserService()
        .projectToWgs84(t.easting, t.northing, t.crs);
  }

  /// **איתור-רשת אוטומטי** — בלי קליקים. מגדיל את התמונה ×3, מריץ OCR מלא
  /// (רגיל→צפונים, מסובב 90°→מזרחים), מסנן מספרי-קואורדינטה **עגולים**
  /// (כפולת-100, בטווח) שמבודדים את התוויות-האמיתיות מרעש-מספרי-מגרש, מזהה
  /// CRS מהצפונים, ומזווג כל צפון למזרח הקרוב-ביותר → נקודות-בקרה. מחזיר
  /// רשימת (pixel, easting, northing, crs), או ריק אם לא נמצאו ≥2.
  static Future<List<({Offset pixel, double e, double n, String crs})>>
      autoDetectTicks(
    img.Image src, {
    void Function(String status, double fraction)? onProgress,
  }) async {
    // סקאלת-ההגדלה תלוית-מנוע: Tesseract (דסקטופ) צריך ×3; ‏ML Kit (מובייל)
    // עובד ברזולוציית-המקור — וגם חייב, ×3 היה מפוצץ את זיכרון-המכשיר.
    final scale = OcrService.autoScale;
    final dir = Directory.systemTemp;
    final nPath = '${dir.path}/_amauto_n.png';
    final rPath = '${dir.path}/_amauto_r.png';
    // ⚠️ ההגדלה + קידוד-ה-PNG הם עבודה **סינכרונית כבדה** (~שניות) —
    // ב-Isolate כדי לא לתקוע את ה-UI (אחרת פס-ההתקדמות קופא).
    onProgress?.call('שלב 1/4: מכין את התמונה…', 0.15);
    final uw = await Isolate.run(() {
      final up = scale == 1
          ? src
          : img.copyResize(src,
              width: src.width * scale, interpolation: img.Interpolation.cubic);
      File(nPath).writeAsBytesSync(img.encodePng(up));
      File(rPath)
          .writeAsBytesSync(img.encodePng(img.copyRotate(up, angle: -90)));
      return up.width;
    });

    int? roundVal(String t) {
      final d = t.replaceAll(',', '').trim();
      if (!RegExp(r'^\d{6,7}$').hasMatch(d)) return null;
      final v = int.parse(d);
      return v % 100 == 0 ? v : null; // תוויות-רשת הן מספרים עגולים
    }

    bool isNorthing(int v) =>
        (v >= 400000 && v <= 1300000) || (v >= 3000000 && v <= 4000000);

    // מעבר-רגיל **פעם אחת** — ממנו גם צפונים וגם מזרחים-אופקיים.
    onProgress?.call('שלב 2/4: קורא תוויות אופקיות (OCR)…', 0.35);
    final normalWords = await OcrService.readWords(nPath);
    final norths = <({double v, Offset px})>[];
    for (final w in normalWords) {
      final v = roundVal(w.text);
      if (v != null && isNorthing(v)) {
        norths.add((v: v.toDouble(), px: Offset(w.cx / scale, w.cy / scale)));
      }
    }
    if (norths.isEmpty) return const [];
    // CRS מהצפונים → טווח-המזרח המתאים (בלי חפיפה בין ITM ל-UTM).
    final utm = norths.any((n) => n.v >= 3000000);
    bool isEasting(int v) =>
        utm ? (v >= 600000 && v <= 834000) : (v >= 100000 && v <= 300000);

    final easts = <({double v, Offset px})>[];
    for (final w in normalWords) {
      final v = roundVal(w.text);
      if (v != null && isEasting(v)) {
        easts.add((v: v.toDouble(), px: Offset(w.cx / scale, w.cy / scale)));
      }
    }
    // מזרחים אנכיים מהמעבר-המסובב (-90° CCW): dst(dx,dy)→src(uw-1-dy, dx).
    onProgress?.call('שלב 3/4: קורא תוויות אנכיות (OCR)…', 0.7);
    for (final w in await OcrService.readWords(rPath)) {
      final v = roundVal(w.text);
      if (v != null && isEasting(v)) {
        easts.add((
          v: v.toDouble(),
          px: Offset((uw - 1 - w.cy) / scale, w.cx / scale),
        ));
      }
    }
    if (easts.isEmpty) return const [];
    onProgress?.call('שלב 4/4: מזווג ומחשב…', 0.92);

    // זיווג: לכל צפון, המזרח הקרוב-ביותר (אותה פינת-רשת). הפיקסל = אמצע
    // בין שתי התוויות (≈ פינת-הצלב, שגיאה זניחה).
    final crs = WorldFileParserService().detectCrs(
      easts.first.v,
      norths.first.v,
    );
    final ticks = <({Offset pixel, double e, double n, String crs})>[];
    for (final nrt in norths) {
      ({double v, Offset px})? best;
      var bd = double.infinity;
      for (final e in easts) {
        final d = (nrt.px - e.px).distanceSquared;
        if (d < bd) {
          bd = d;
          best = e;
        }
      }
      if (best == null) continue;
      ticks.add((
        pixel: Offset((nrt.px.dx + best.px.dx) / 2, (nrt.px.dy + best.px.dy) / 2),
        e: best.v,
        n: nrt.v,
        crs: crs,
      ));
    }
    return ticks;
  }
}
