import 'dart:io';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show debugPrint;
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

  /// **איתור-רשת אוטומטי** — בלי קליקים. [OcrService.readGridLabels] קורא
  /// את כל התוויות בשני הכיוונים (אריחי-Skia מוגדלים ×3, מהיר בכל
  /// הפלטפורמות), כאן מסננים מספרי-קואורדינטה **עגולים** (כפולת-100,
  /// בטווח) שמבודדים את התוויות-האמיתיות מרעש-מספרי-מגרש, מזהים CRS
  /// מהצפונים, ומזווגים כל צפון למזרח הקרוב-ביותר → נקודות-בקרה. מחזיר
  /// רשימת (pixel, easting, northing, crs), או ריק אם לא נמצאו ≥2.
  static Future<List<({Offset pixel, double e, double n, String crs})>>
      autoDetectTicks(
    String imagePath, {
    void Function(String status, double fraction)? onProgress,
  }) async {
    int? roundVal(String t) {
      final d = t.replaceAll(',', '').trim();
      if (!RegExp(r'^\d{6,7}$').hasMatch(d)) return null;
      final v = int.parse(d);
      return v % 100 == 0 ? v : null; // תוויות-רשת הן מספרים עגולים
    }

    bool isNorthing(int v) =>
        (v >= 400000 && v <= 1300000) || (v >= 3000000 && v <= 4000000);

    // עצירה-מוקדמת (נבדק בסוף כל טבעת-אריחים): ≥2 צפונים שונים + ≥2
    // מזרחים שונים — המינימום ל-affine מלא. ערכים **שונים** — כפילויות של
    // אותה תווית לא נחשבות (מונע עצירה על זוג-מנוון).
    bool enough(List<OcrWord> normal, List<OcrWord> vertical) {
      final ns = <int>{};
      for (final w in normal) {
        final v = roundVal(w.text);
        if (v != null && isNorthing(v)) ns.add(v);
      }
      if (ns.length < 2) return false;
      final utm = ns.any((v) => v >= 3000000);
      bool isE(int v) =>
          utm ? (v >= 600000 && v <= 834000) : (v >= 100000 && v <= 300000);
      final es = <int>{};
      for (final w in [...normal, ...vertical]) {
        final v = roundVal(w.text);
        if (v != null && isE(v)) es.add(v);
      }
      return es.length >= 2;
    }

    // מסווג-תווית לשלב-הגישוש: מספר עגול בטווח קואורדינטות כלשהו (צפון
    // או מזרח, ITM/UTM/ישן) — קובע נוכחות-רשת ומודד גובה-תווית לכיול.
    bool anyCoordLabel(String t) {
      final v = roundVal(t);
      return v != null &&
          ((v >= 100000 && v <= 1300000) || (v >= 3000000 && v <= 4000000));
    }

    onProgress?.call('קורא תוויות (OCR)…', 0.05);
    final labels = await OcrService.readGridLabels(
      imagePath,
      onTile: (done, total) => onProgress?.call(
        'קורא תוויות (OCR)… $done/$total',
        0.05 + 0.85 * (done / total).clamp(0.0, 1.0),
      ),
      isEnough: enough,
      looksLikeLabel: anyCoordLabel,
    );

    // צפונים — כיתוב אופקי. (הקואורדינטות כבר בפיקסלי-המקור.)
    final norths = <({double v, Offset px})>[];
    for (final w in labels.normal) {
      final v = roundVal(w.text);
      if (v != null && isNorthing(v)) {
        norths.add((v: v.toDouble(), px: Offset(w.cx, w.cy)));
      }
    }
    debugPrint('[GRID] normal: ${labels.normal.length} words → '
        '${norths.length} norths');
    final allWords = [...labels.normal, ...labels.vertical];
    if (norths.isEmpty) return _kmFallback(imagePath, allWords, onProgress);
    // CRS מהצפונים → טווח-המזרח המתאים (בלי חפיפה בין ITM ל-UTM).
    final utm = norths.any((n) => n.v >= 3000000);
    bool isEasting(int v) =>
        utm ? (v >= 600000 && v <= 834000) : (v >= 100000 && v <= 300000);

    // מזרחים — גם אופקיים (normal) וגם אנכיים (vertical, כבר ממופים).
    final easts = <({double v, Offset px})>[];
    for (final w in [...labels.normal, ...labels.vertical]) {
      final v = roundVal(w.text);
      if (v != null && isEasting(v)) {
        easts.add((v: v.toDouble(), px: Offset(w.cx, w.cy)));
      }
    }
    debugPrint('[GRID] easts: ${easts.length} '
        '(utm=$utm, vertical words ${labels.vertical.length})');
    if (easts.isEmpty) return _kmFallback(imagePath, allWords, onProgress);
    onProgress?.call('מזווג ומחשב…', 0.95);

    // זיווג: לכל צפון, המזרח הקרוב-ביותר. הפיקסל = **הצטלבות הקווים**:
    // תווית-מזרח יושבת על הקו-האנכי שלה (X), תווית-צפון על הקו-האופקי (Y)
    // → הצלב ב-(east.x, north.y). כשהתוויות צמודות לצומת זה שקול לאמצע;
    // כשהן רחוקות (תוויות-שוליים, מזרח-יחיד כמו באושה) האמצע שגוי בחצי-
    // המרחק וההצטלבות נכונה.
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
        pixel: Offset(best.px.dx, nrt.px.dy),
        e: best.v,
        n: nrt.v,
        crs: crs,
      ));
    }
    debugPrint('[GRID] ticks: ${[
      for (final t in ticks)
        'E=${t.e.round()} N=${t.n.round()} @(${t.pixel.dx.round()},${t.pixel.dy.round()})'
    ].join(' | ')} '
        '(norths: ${norths.map((n) => n.v.round()).toList()}, '
        'easts: ${easts.map((e) => e.v.round()).toList()})');
    if (ticks.length < 2) {
      final km = await _kmFallback(imagePath, allWords, onProgress);
      if (km.length >= 2) return km;
    }
    return ticks;
  }

  /// נפילת-אחור למצב-ק"מ: קודם ניסיון ישיר על המילים שכבר נקראו; אם אין —
  /// ובתנאי ששער-הכניסה מזהה חתימת-ק"מ (מונע עלות ממפות-כבישים שמלאות
  /// מספרי-גבהים) — **מעבר-OCR שני מכויל-לתוויות-הק"מ**: הגישוש מודד את
  /// גובהן וסורק בסקאלה הנכונה (×3 של המעבר-הראשון מרסק ספרות גדולות:
  /// "742"→"142" — נמדד במפת-הבוחן).
  static Future<List<({Offset pixel, double e, double n, String crs})>>
      _kmFallback(
    String imagePath,
    List<OcrWord> firstWords,
    void Function(String status, double fraction)? onProgress,
  ) async {
    final direct = kmTicks(firstWords);
    if (direct.length >= 2) return direct;

    int? kmVal(String t) {
      final d = t.replaceAll(',', '').trim();
      if (!RegExp(r'^\d{2,4}$').hasMatch(d)) return null;
      return int.parse(d);
    }

    // שער-כניסה: חתימה של שני הצירים (מזרח+צפון) בטווחי-ק"מ — מספרי-גבהים
    // לבדם (400-800) לא מזניקים מעבר-שני.
    Set<int> inRange(int lo, int hi) => {
          for (final w in firstWords)
            if (kmVal(w.text) case final v? when v >= lo && v <= hi) v,
        };
    final itmStyle = inRange(120, 300).length >= 2; // מזרח-ITM ייחודי
    final utmStyle =
        inRange(600, 834).length >= 2 && inRange(3300, 3700).length >= 2;
    if (!itmStyle && !utmStyle) return const [];

    bool kmLabel(String t) {
      final v = kmVal(t);
      return v != null &&
          ((v >= 120 && v <= 300) ||
              (v >= 380 && v <= 834) ||
              (v >= 3300 && v <= 3700));
    }

    bool kmEnough(List<OcrWord> normal, List<OcrWord> vertical) {
      final all = [...normal, ...vertical];
      Set<int> got(int lo, int hi) => {
            for (final w in all)
              if (kmVal(w.text) case final v? when v >= lo && v <= hi) v,
          };
      final e = got(120, 300).length >= 2 || got(600, 834).length >= 2;
      final n = got(380, 800).length >= 2 || got(3300, 3700).length >= 2;
      return e && n;
    }

    onProgress?.call('מעבר-ק"מ (OCR מכויל)…', 0.5);
    final labels2 = await OcrService.readGridLabels(
      imagePath,
      onTile: (d, t) => onProgress?.call(
        'מעבר-ק"מ (OCR)… $d/$t',
        0.5 + 0.4 * (d / t).clamp(0.0, 1.0),
      ),
      isEnough: kmEnough,
      looksLikeLabel: kmLabel,
    );
    return kmTicks([...labels2.normal, ...labels2.vertical]);
  }

  /// **מצב-ק"מ מקוצר** — מפות צבאיות/סימון-שבילים (1:50000) מתייגות את
  /// הרשת בק"מ בני 2-4 ספרות ("154","156" / "3654") במקום מטרים מלאים.
  /// מופעל כשהפורמט-המלא לא מצא: מסנן מועמדים לטווחי-ק"מ של ה-CRS,
  /// ומאתר לכל ציר את **תת-הקבוצה בעלת השיפוע-העקבי** (תוויות-רשת יושבות
  /// בקו עם מרווח-ערך קבוע; גבהים/מספרי-כביש מפוזרים אקראית ונופלים).
  /// אימות-צולב: קנה-המידה משני הצירים חייב להסכים (פיקסלים ריבועיים).
  static List<({Offset pixel, double e, double n, String crs})> kmTicks(
      List<OcrWord> words) {
    // מועמדים: מספר 2-4 ספרות שלם.
    final cands = <({double v, Offset px})>[];
    for (final w in words) {
      final d = w.text.replaceAll(',', '').trim();
      if (!RegExp(r'^\d{2,4}$').hasMatch(d)) continue;
      cands.add((v: double.parse(d), px: Offset(w.cx, w.cy)));
    }
    debugPrint('[GRID] km-mode: ${cands.length} מועמדים '
        '${cands.map((c) => c.v.round()).toList()}');
    if (cands.length < 4) return const [];

    // התאמת-ציר: **כל** תת-הקבוצות בעלות שיפוע-עקבי ומרווח-ק"מ אחיד
    // (סדרה חשבונית 1-5, סובלנות לתווית-חסרה) — הבחירה הסופית נעשית
    // כזוג-צולב (ראו למטה), לא פר-ציר.
    List<(double slope, List<({double v, Offset px})>, double step)> fitAxis(
      List<({double v, Offset px})> pool,
      double Function(Offset) coord, {
      required bool increasing,
    }) {
      final fits =
          <(double, List<({double v, Offset px})>, double)>[];
      final signatures = <String>{};
      for (var i = 0; i < pool.length; i++) {
        for (var j = i + 1; j < pool.length; j++) {
          final dv = pool[j].v - pool[i].v;
          if (dv == 0) continue;
          final s = (coord(pool[j].px) - coord(pool[i].px)) / dv;
          if (increasing ? s <= 0 : s >= 0) continue;
          if (s.abs() < 20 || s.abs() > 6000) continue; // ק"מ = 20-6000px
          final members = <double, ({double v, Offset px})>{};
          for (final c in pool) {
            final pred = coord(pool[i].px) + (c.v - pool[i].v) * s;
            if ((coord(c.px) - pred).abs() <= 0.25 * s.abs()) {
              // ערך כפול — שומרים את הקרוב-לחיזוי (תווית משני צדי-הגיליון).
              final cur = members[c.v];
              if (cur == null ||
                  (coord(c.px) - pred).abs() <
                      (coord(cur.px) - pred).abs()) {
                members[c.v] = c;
              }
            }
          }
          if (members.length < 2) continue;
          final vals = members.keys.toList()..sort();
          var uniform = true;
          final step = vals[1] - vals[0];
          if (step < 1 || step > 5) uniform = false;
          for (var k = 2; uniform && k < vals.length; k++) {
            if ((vals[k] - vals[k - 1] - step).abs() > 0.01) uniform = false;
          }
          if (!uniform) continue;
          if (!signatures.add(vals.join(','))) continue;
          fits.add((s, members.values.toList(), step));
          if (fits.length >= 60) return fits;
        }
      }
      return fits;
    }

    // שתי השערות-CRS; ‏600-800 חופף (ITM-צפון/UTM-מזרח) — הניקוד מכריע.
    final hypos = <({String name, double eLo, double eHi, double nLo, double nHi, double scale})>[
      (name: 'ITM', eLo: 120, eHi: 300, nLo: 380, nHi: 800, scale: 1000),
      (name: 'UTM', eLo: 600, eHi: 834, nLo: 3300, nHi: 3700, scale: 1000),
    ];
    List<({Offset pixel, double e, double n, String crs})> bestTicks =
        const [];
    var bestScore = 0;
    for (final h in hypos) {
      final ePool = [
        for (final c in cands)
          if (c.v >= h.eLo && c.v <= h.eHi) c,
      ];
      final nPool = [
        for (final c in cands)
          if (c.v >= h.nLo && c.v <= h.nHi) c,
      ];
      final eFits = fitAxis(ePool, (p) => p.dx, increasing: true);
      final nFits = fitAxis(nPool, (p) => p.dy, increasing: false);
      debugPrint('[GRID] km-mode ${h.name}: ePool=${ePool.length} '
          'nPool=${nPool.length} → ${eFits.length}/${nFits.length} '
          'התאמות-ציר');
      // הבחירה הצולבת: **פיקסלים ריבועיים** (|px/km| שווה בשני הצירים)
      // היא המפריד החזק — זוג-רעש כמעט אף פעם לא מסכים בקנה-מידה עם
      // זוג-אמת בציר-השני. ניקוד: גודל + קרבת-יחס + עדיפות-מרווח-קטן.
      for (final ef in eFits) {
        for (final nf in nFits) {
          final ratio = ef.$1.abs() / nf.$1.abs();
          if (ratio < 0.85 || ratio > 1.18) continue;
          final score = (ef.$2.length + nf.$2.length) * 100 -
              ((ratio - 1).abs() * 200).round() -
              (ef.$3 + nf.$3).round();
          if (score <= bestScore) continue;
          final crs = WorldFileParserService()
              .detectCrs(ef.$2.first.v * h.scale, nf.$2.first.v * h.scale);
          final ticks =
              <({Offset pixel, double e, double n, String crs})>[];
          for (final n in nf.$2) {
            for (final e in ef.$2) {
              if (ticks.length >= 12) break;
              ticks.add((
                pixel: Offset(e.px.dx, n.px.dy),
                e: e.v * h.scale,
                n: n.v * h.scale,
                crs: crs,
              ));
            }
          }
          bestScore = score;
          bestTicks = ticks;
          debugPrint('[GRID] km-mode ${h.name}: '
              'easts=${ef.$2.map((c) => c.v.round()).toList()} '
              'norths=${nf.$2.map((c) => c.v.round()).toList()} '
              '(px/km: ${ef.$1.round()}/${nf.$1.round()})');
        }
      }
    }
    return bestTicks;
  }
}
