import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'gemini_anchor_service.dart';
import 'ocr_service.dart';

/// **מנוע שמות-המקומות** — לשטח פתוח בלי רשת מודפסת ובלי כבישים: קורא
/// שמות מודפסים מהמפה (OCR עברית), מאתר אותם קודם ב**גזטיר-אופליין**
/// (‏assets/gazetteer_il.txt — ‏GeoNames-TSV, ‏~84 אלף מקומות בארץ) ורק
/// אם אין מספיק — ‏Nominatim אונליין; ואז RANSAC בוחר את תת-הקבוצה
/// העקבית-גיאומטרית (שמות חוזרים בארץ — "עין חנה" יש כמה) → עוגנים.
class TerrainNamesService {
  // ── גזטיר: אינדקס שם-מנורמל → מיקומים ──
  static Map<String, List<int>>? _byName;
  static Float64List? _lats, _lons;

  /// טעינת-האינדקס (חד-פעמית, עצלה): פרסור 84 אלף שורות ב-Isolate.
  static Future<void> _ensureIndex() async {
    if (_byName != null) return;
    final raw = await rootBundle.loadString('assets/gazetteer_il.txt');
    final parsed = await Isolate.run(() {
      final byName = <String, List<int>>{};
      final lats = <double>[], lons = <double>[];
      for (final line in const LineSplitter().convert(raw)) {
        final c = line.split('\t');
        if (c.length < 5) continue;
        // איתור-עמודות גמיש: זוג-המספרים הראשון בטווחי-ישראל = ‏lat/lon;
        // כל מה שלפניו = עמודות-שמות (הפורמט מכיל עמודת-ID משתנה).
        var coordAt = -1;
        for (var i = 1; i + 1 < c.length; i++) {
          final la = double.tryParse(c[i]), lo = double.tryParse(c[i + 1]);
          if (la != null &&
              lo != null &&
              la >= 29 &&
              la <= 34 &&
              lo >= 33.5 &&
              lo <= 36.5) {
            coordAt = i;
            break;
          }
        }
        if (coordAt < 1) continue;
        final idx = lats.length;
        lats.add(double.parse(c[coordAt]));
        lons.add(double.parse(c[coordAt + 1]));
        final names = <String>{};
        for (var i = 0; i < coordAt; i++) {
          names.addAll(c[i].split(','));
        }
        for (final n in names) {
          final k = normalizeName(n);
          if (k.length < 3) continue;
          (byName[k] ??= []).add(idx);
          // וריאנטים ל-OCR: ‏Tesseract קורא גרשיים כ-"יי" (תנ"ך→תנייך)
          // וגרש כ-"י" — מוסיפים מפתחות חלופיים דטרמיניסטיים.
          if (n.contains('"') || n.contains('״') || n.contains("'")) {
            final v = normalizeName(n
                .replaceAll('"', 'יי')
                .replaceAll('״', 'יי')
                .replaceAll("'", 'י')
                .replaceAll('׳', 'י'));
            if (v.length >= 3 && v != k) (byName[v] ??= []).add(idx);
          }
          // ‏psm-11 נוטה לבלוע את האות-הראשונה של תווית ("גבעת"→"בעת") —
          // וריאנט בלי האות-הראשונה לשמות ארוכים דיו.
          if (k.length >= 6) (byName[k.substring(1)] ??= []).add(idx);
          // קיצור-חורבה של מפות: "חורבת/חרבת/ח'ירבת נקיק" נכתב במפה
          // "ח' נקיק" (ואחרי נרמול-הגרש: "ח נקיק" או דבוק "חנקיק").
          final hurva =
              RegExp(r"^(חורבת|חרבת|חירבת) (.+)$").firstMatch(k);
          if (hurva != null) {
            final rest = hurva.group(2)!;
            (byName['ח $rest'] ??= []).add(idx);
            (byName['ח$rest'] ??= []).add(idx);
          }
        }
      }
      return (
        byName: byName,
        lats: Float64List.fromList(lats),
        lons: Float64List.fromList(lons),
      );
    });
    _byName = parsed.byName;
    _lats = parsed.lats;
    _lons = parsed.lons;
    debugPrint('[NAMES] גזטיר: ${_lats!.length} מקומות, '
        '${_byName!.length} שמות');
  }

  /// נרמול-שם משותף לגזטיר ול-OCR: הסרת ניקוד/טעמים (ה-OCR "קורא" אותם
  /// מצילומים — "בִּעת"), ואז אותיות עברית/לטינית/ספרות ורווחים בלבד.
  static String normalizeName(String s) => s
      .toLowerCase()
      .replaceAll(RegExp('[֑-ׇ]'), '')
      .replaceAll(RegExp(r'[^א-תa-z0-9 ]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// חיפוש אופליין: התאמה מדויקת על השם המנורמל. שם עם המון מופעים
  /// (למשל "בית ספר") לא-מבחין — נזרק.
  static List<LatLng> lookupOffline(String name, {int maxHits = 10}) {
    final hits = _byName?[normalizeName(name)];
    if (hits == null || hits.isEmpty || hits.length > maxHits) return const [];
    return [for (final i in hits) LatLng(_lats![i], _lons![i])];
  }

  /// התאמה-עמומה (מרחק-עריכה ≤1) לצירופים ארוכים — ‏OCR של צילומים מחליף
  /// אות ("גומר"→"גומף") והתאמה-מדויקת מתה. מוחזר רק כשמספר-המקומות
  /// הכולל קטן (ייחודי דיו).
  static List<LatLng> lookupFuzzy(String name, {int maxHits = 3}) {
    final t = normalizeName(name);
    if (t.length < 6) return const [];
    final hits = <int>{};
    for (final e in _byName!.entries) {
      final k = e.key;
      if ((k.length - t.length).abs() > 1) continue;
      if (_dist1(t, k)) hits.addAll(e.value);
      if (hits.length > maxHits) return const [];
    }
    return [for (final i in hits) LatLng(_lats![i], _lons![i])];
  }

  /// האם מרחק-העריכה בין [a] ל-[b] הוא ≤1 (החלפה/הוספה/מחיקה בודדת).
  static bool _dist1(String a, String b) {
    if (a == b) return true;
    final la = a.length, lb = b.length;
    if ((la - lb).abs() > 1) return false;
    if (la == lb) {
      var diff = 0;
      for (var i = 0; i < la; i++) {
        if (a.codeUnitAt(i) != b.codeUnitAt(i) && ++diff > 1) return false;
      }
      return true;
    }
    final s = la < lb ? a : b, l = la < lb ? b : a; // s קצר ב-1
    var i = 0, j = 0, skipped = false;
    while (i < s.length) {
      if (s.codeUnitAt(i) == l.codeUnitAt(j)) {
        i++;
        j++;
      } else if (!skipped) {
        skipped = true;
        j++;
      } else {
        return false;
      }
    }
    return true;
  }

  /// נפילה-לאחור אונליין (Nominatim, מוגבל לישראל) — רק כשהאופליין לא
  /// סיפק מספיק שמות.
  static Future<List<LatLng>> lookupOnline(String name) async {
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': name,
        'format': 'json',
        'limit': '3',
        'countrycodes': 'il',
        'accept-language': 'he',
      });
      final resp = await http.get(uri, headers: {
        'User-Agent': 'auto_maps/1.0 (georeference tool)',
      }).timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return const [];
      final list = jsonDecode(resp.body) as List;
      return [
        for (final e in list)
          LatLng(double.parse(e['lat'] as String),
              double.parse(e['lon'] as String)),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// הזרימה המלאה: ‏OCR-טקסט → צירופי-מילים → גזטיר (ואונליין כגיבוי) →
  /// ‏RANSAC עקביות → עוגנים. null כשאין ≥3 שמות עקביים.
  static Future<List<GeminiAnchorSuggestion>?> suggestAnchors({
    required String imagePath,
    void Function(String stage)? onStage,
  }) async {
    onStage?.call('טוען גזטיר…');
    await _ensureIndex();
    // ‏OCR רב-סקאלה: מפה מודפסת גדולה נקראת ב-×1; **צילום קטן** צריך
    // הגדלה (השמות זעירים) — מסלימים ×2/×3 כל עוד אין ≥2 עוגני-זרע,
    // ורק כשהקריאה דלה (תמונה קטנה — אחרת ×1 כבר הציף מילים).
    // ‏OCR רב-סקאלה **מצטבר**: כל סקאלה קוראת שמות אחרים קצת אחרת
    // (צילום קטן צריך הגדלה; ‏×1 מספיק למפה מודפסת גדולה) — צוברים את
    // ההתאמות מכל הסקאלות ועוצרים כשיש מספיק זרעים.
    final matches = <({String text, Offset px, List<LatLng> options})>[];
    final seenText = <String>{};
    final phrases = <({String text, Offset px})>[];
    final phraseKeys = <String>{};
    // שער-הסלמה לפי מידות אמיתיות (ולא לפי כמות-מילים — מפה צפופה קטנה
    // מציפה מילות-זבל ונעצרה ב-×2 בטעות): מסלימים כל עוד התמונה-המוגדלת
    // בתקציב-פיקסלים סביר.
    final (imW, imH) = await OcrService.imageSize(imagePath);
    for (final upscale in [1, 2, 3]) {
      if (upscale > 1 && math.max(imW, imH) * upscale > 6500) break;
      onStage?.call('קורא שמות (OCR ×$upscale)…');
      final words = await OcrService.readTextWords(
        imagePath,
        upscale: upscale,
        onTile: (d, t) => onStage?.call('קורא שמות (OCR ×$upscale)… $d/$t'),
      );
      onStage?.call('מאתר שמות בגזטיר…');
      var fresh = 0;
      for (final p in _buildPhrases(words)) {
        final key = '${p.text}@${(p.px.dx / 60).round()}_'
            '${(p.px.dy / 60).round()}';
        if (!phraseKeys.add(key)) continue;
        phrases.add(p);
        final opts = lookupOffline(p.text);
        if (opts.isEmpty) continue;
        // אותו שם יכול להופיע פעמיים על המפה — כל מופע-פיקסל נשמר.
        matches.add((text: p.text, px: p.px, options: opts));
        seenText.add(p.text);
        fresh++;
      }
      final seedCount = [
        for (final m in matches)
          if (_isSeed(m.text, m.options.length)) m,
      ].length;
      debugPrint('[NAMES] ×$upscale: ${words.length} מילים, +$fresh התאמות '
          '(סה"כ ${matches.length}), $seedCount זרעים');
      if (seedCount >= 3) break;
    }
    // סיבוב-עמום (תמיד — זול): צירופים ארוכים שלא הותאמו — מרחק-עריכה 1
    // ("גומף"→"גומר", "בית עזיאל"→"בית עוזיאל", "תלגזר"→"תל גזר").
    // מסוננים מצירופי-זבל של קווי-גובה: כל מילה ≥2 תווים, בלי מילות-אות.
    {
      onStage?.call('התאמה עמומה…');
      final unmatchedLong = [
        for (final p in phrases)
          if (!seenText.contains(p.text) &&
              p.text.length >= 6 &&
              p.text.split(' ').every((w) => w.length >= 2))
            p,
      ]..sort((a, b) => b.text.length.compareTo(a.text.length));
      debugPrint('[NAMES] מועמדי-עמום: ${[
        for (final p in unmatchedLong.take(12)) '"${p.text}"'
      ].join(' ')}');
      var fuzzy = 0;
      for (final p in unmatchedLong.take(80)) {
        final opts = lookupFuzzy(p.text);
        if (opts.isEmpty) continue;
        matches.add((text: p.text, px: p.px, options: opts));
        seenText.add(p.text);
        fuzzy++;
      }
      debugPrint('[NAMES] עמום: +$fuzzy התאמות '
          '(${unmatchedLong.length} מועמדים)');
    }
    // דיכוי תת-צירופים: "קופת חולים" שהוא חלק מ"קופת חולים מאוחדת" שהתאים
    // גם הוא — נזרק (השבר מתאים לרשומות-אקראי בארץ ומרעיל את ה-RANSAC).
    matches.removeWhere((m) => matches.any((m2) =>
        !identical(m2, m) &&
        m2.text.length > m.text.length &&
        m2.text.contains(m.text) &&
        (m2.px - m.px).distance < 400));
    seenText
      ..clear()
      ..addAll([for (final m in matches) m.text]);
    debugPrint('[NAMES] ${phrases.length} צירופים → ${matches.length} '
        'התאמות-גזטיר (${seenText.length} שמות שונים)');
    debugPrint('[NAMES] התאמות: ${[
      for (final m in matches) '"${m.text}"(${m.options.length})'
    ].join(' ')}');
    debugPrint('[NAMES] דוגמת-צירופים: ${[
      for (final p in phrases.take(25)) '"${p.text}"'
    ].join(' ')}');

    // גיבוי-אונליין: רק כשאין מספיק, ורק לצירופים ה"חזקים" (ארוכים).
    if (seenText.length < 3) {
      onStage?.call('משלים מ-Nominatim…');
      final candidates = [
        for (final p in phrases)
          if (!seenText.contains(p.text) &&
              p.text.length >= 5 &&
              p.text.contains(' '))
            p,
      ]..sort((a, b) => b.text.length.compareTo(a.text.length));
      for (final p in candidates.take(5)) {
        final opts = await lookupOnline(p.text);
        if (opts.isEmpty) continue;
        matches.add((text: p.text, px: p.px, options: opts));
        seenText.add(p.text);
        if (seenText.length >= 5) break;
      }
      debugPrint('[NAMES] אחרי אונליין: ${seenText.length} שמות');
    }
    if (seenText.length < 3) return null;

    onStage?.call('מצליב גיאומטרית…');
    return _ransac(matches);
  }

  /// קיבוץ מילים לצירופים: שורות לפי קרבת-גובה, חלונות של 1-3 מילים.
  /// עברית נקראת ימין-לשמאל — סדר-המילים בשורה לפי cx יורד.
  static List<({String text, Offset px})> _buildPhrases(List<OcrWord> words) {
    final hebrew = RegExp(r'[֐-׿]');
    final ws = [
      for (final w in words)
        if (normalizeName(w.text).isNotEmpty) w,
    ]..sort((a, b) => a.cy.compareTo(b.cy));
    // שורות: מילה מצטרפת לשורה אם גובהה קרוב לשלה.
    final lines = <List<OcrWord>>[];
    for (final w in ws) {
      final line = lines.isEmpty ? null : lines.last;
      if (line != null && (w.cy - line.first.cy).abs() < line.first.h * 0.8) {
        line.add(w);
      } else {
        lines.add([w]);
      }
    }
    final out = <({String text, Offset px})>[];
    final seen = <String>{};
    final digitsOnlyWord = RegExp(r'^[0-9]+$');
    for (final line in lines) {
      line.sort((a, b) => b.cx.compareTo(a.cx)); // RTL
      for (var start = 0; start < line.length; start++) {
        for (var len = 1; len <= 5 && start + len <= line.length; len++) {
          final seg = line.sublist(start, start + len);
          // מילים סמוכות בלבד (פער אופקי סביר יחסית לגובה-האות), ובלי
          // מילות-ספרות (סימוני-מפה כמו עיגולים נקראים "9" ומזהמים).
          var ok = !seg.any(
              (w) => digitsOnlyWord.hasMatch(normalizeName(w.text)));
          for (var i = 1; ok && i < seg.length; i++) {
            final gap = seg[i - 1].cx - seg[i].cx;
            if (gap <= 0 || gap > seg[i].h * 14) ok = false;
          }
          if (!ok) continue;
          // גיזום ספרות-קצה פר-מילה: סימוני-מפה (עיגול="9") נדבקים למילה
          // הסמוכה ("אלכסנדר9") ושוברים התאמה-מדויקת.
          final text = normalizeName(seg
              .map((w) => normalizeName(w.text)
                  .replaceAll(RegExp(r'^[0-9]+|[0-9]+$'), ''))
              .join(' '));
          if (text.length < 3 || !hebrew.hasMatch(text)) continue;
          var cx = 0.0, cy = 0.0;
          for (final w in seg) {
            cx += w.cx;
            cy += w.cy;
          }
          final key = '$text@${(cx / seg.length).round()}';
          if (seen.add(key)) {
            out.add((
              text: text,
              px: Offset(cx / seg.length, cy / seg.length),
            ));
          }
        }
      }
    }
    return out;
  }

  /// עוגן-זרע ל-RANSAC: נדיר-מאוד (≤2 מקומות) מספיק גם בשם קצר ("פדיה"),
  /// נדיר-בינוני דורש שם ארוך. שמות-3-תווים = רעש-OCR שפוגע ברשומות-אקראי.
  static bool _isSeed(String text, int optionCount) =>
      (optionCount <= 2 && text.length >= 4) ||
      (optionCount <= 3 && text.length >= 6);

  /// פריסת ה-inliers ביחס לענן-ההתאמות: מלכודת-השברים היא קונצנזוס של
  /// תוויות צמודות — דורשים שה-inliers יכסו ≥35% מטווח-הענן בציר אחד
  /// לפחות ו≥15% בשני.
  static bool _spreadOk(
    List<({String text, Offset px, LatLng world})> inl,
    List<({String text, Offset px, List<LatLng> options})> all,
  ) {
    double spanOf(Iterable<Offset> pts, bool x) {
      var mn = double.infinity, mx = -double.infinity;
      for (final p in pts) {
        final v = x ? p.dx : p.dy;
        mn = math.min(mn, v);
        mx = math.max(mx, v);
      }
      return mx - mn;
    }

    final ax = spanOf([for (final m in all) m.px], true);
    final ay = spanOf([for (final m in all) m.px], false);
    final ix = spanOf([for (final m in inl) m.px], true);
    final iy = spanOf([for (final m in inl) m.px], false);
    if (ax < 1 || ay < 1) return true;
    final rx = ix / ax, ry = iy / ay;
    return (rx >= 0.35 && ry >= 0.15) || (ry >= 0.35 && rx >= 0.15);
  }

  /// ‏RANSAC על ההתאמות: זוגות-השערה → דמיון (סיבוב+סקאלה+הזזה) →
  /// ‏inliers לפי מרחק-פיקסלים; הטוב ≥3 שמות שונים + פריסה מנצח.
  static List<GeminiAnchorSuggestion>? _ransac(
      List<({String text, Offset px, List<LatLng> options})> matches) {
    // הטלת-מטרים מקומית סביב ממוצע-המועמדים.
    var lat0 = 0.0, lon0 = 0.0, n = 0;
    for (final m in matches) {
      for (final o in m.options) {
        lat0 += o.latitude;
        lon0 += o.longitude;
        n++;
      }
    }
    lat0 /= n;
    lon0 /= n;
    final kx = 111320.0 * math.cos(lat0 * math.pi / 180);
    const ky = 110540.0;
    (double, double) toM(LatLng p) =>
        ((p.longitude - lon0) * kx, (p.latitude - lat0) * ky);
    LatLng fromM(double mx, double my) =>
        LatLng(lat0 + my / ky, lon0 + mx / kx);

    // z=(px, -py) — כמו ב-anchor_matcher (היפוך ציר-y של תמונה).
    // זוגות-ההשערה נבנים רק מ**עוגני-זרע נדירים** (מעט-מועמדים ושם ארוך):
    // שמות גנריים ("קופת חולים", 5-7 מופעים בארץ) מסתדרים בתבניות דומות
    // בכל עיר ויוצרים קונצנזוס-שווא; הנדירים מקבעים את הטרנספורמציה
    // והגנריים רק מצטרפים כ-inliers.
    final seeds = [
      for (var i = 0; i < matches.length; i++)
        if (_isSeed(matches[i].text, matches[i].options.length)) i,
    ];
    if (seeds.length < 2) {
      debugPrint('[NAMES] רק ${seeds.length} עוגני-זרע נדירים — אין רישום');
      return null;
    }
    var bestScore = 0;
    List<({String text, Offset px, LatLng world})>? bestInliers;
    (double, double, double, double)? bestT; // (ar, ai, br, bi) של הזוכה
    for (final i in seeds) {
      for (final j in seeds) {
        if (j <= i || matches[i].text == matches[j].text) continue;
        for (final pi in matches[i].options) {
          for (final pj in matches[j].options) {
            final (xi, yi) = toM(pi);
            final (xj, yj) = toM(pj);
            final zi = (matches[i].px.dx, -matches[i].px.dy);
            final zj = (matches[j].px.dx, -matches[j].px.dy);
            final dzr = zj.$1 - zi.$1, dzi = zj.$2 - zi.$2;
            final dwr = xj - xi, dwi = yj - yi;
            final den = dzr * dzr + dzi * dzi;
            if (den < 1) continue;
            // A = dw/dz (מרוכבים), B = wi − A·zi
            final ar = (dwr * dzr + dwi * dzi) / den;
            final ai = (dwi * dzr - dwr * dzi) / den;
            final scale = math.sqrt(ar * ar + ai * ai);
            if (scale < 0.05 || scale > 60) continue; // מ'/px סביר
            final rot = math.atan2(ai, ar) * 180 / math.pi;
            if (rot.abs() > 60) continue; // מפות-שטח בערך-צפון
            final br = xi - (ar * zi.$1 - ai * zi.$2);
            final bi = yi - (ai * zi.$1 + ar * zi.$2);
            // ספירת-inliers **במרחב-הפיקסלים** (בלתי-תלוי-סקאלה): המועמד
            // מוטל חזרה לתמונה וצריך לנחות ≤300px ממרכז-התווית — בדיוק
            // "השם יושב ליד הפריט". (סובלנות-מטרים גדלה עם הסקאלה ונתנה
            // קונצנזוס-זבל לשברי-שמות.)
            const tolPx = 300.0;
            final a2 = ar * ar + ai * ai;
            final inl = <({String text, Offset px, LatLng world})>[];
            final usedNames = <String>{};
            for (final m in matches) {
              LatLng? best;
              var bd = double.infinity;
              for (final o in m.options) {
                final (ox, oy) = toM(o);
                final wr = ox - br, wi = oy - bi;
                final zr = (wr * ar + wi * ai) / a2;
                final zim = (wi * ar - wr * ai) / a2;
                // z=(x,−y) → הפיקסל החזוי (zr, −zim)
                final d = math.sqrt(math.pow(zr - m.px.dx, 2) +
                    math.pow(-zim - m.px.dy, 2));
                if (d < bd) {
                  bd = d;
                  best = o;
                }
              }
              if (best != null && bd <= tolPx && usedNames.add(m.text)) {
                inl.add((text: m.text, px: m.px, world: best));
              }
            }
            if (inl.length > bestScore) {
              bestScore = inl.length;
              bestInliers = inl;
              bestT = (ar, ai, br, bi);
            }
          }
        }
      }
    }
    // שער-פריסה על התוצאה הסופית בלבד (לא פר-השערה — 2 זרעים לגיטימיים
    // לא יעברו 35% לבד): קונצנזוס-שברים מקובץ נפסל. תוצאת-2 מותרת רק
    // כששני הצדדים זרעים-נדירים — ותצא תמיד "אמינות נמוכה" (כתום).
    final minOk = bestInliers != null &&
        (bestScore >= 3 ||
            (bestScore == 2 &&
                bestInliers.every((m) => matches
                    .where((x) => x.text == m.text)
                    .every((x) => x.options.length <= 2))));
    if (!minOk || !_spreadOk(bestInliers, matches)) {
      debugPrint('[NAMES] רישום נכשל: מקסימום $bestScore שמות עקביים'
          '${minOk ? ' (פריסה דלה)' : ''}');
      return null;
    }
    debugPrint('[NAMES] רישום: $bestScore שמות עקביים — '
        '${[for (final m in bestInliers) m.text].join(", ")}');
    final strong = bestScore >= 4;
    final out = [
      for (final m in bestInliers)
        GeminiAnchorSuggestion(
          pixel: m.px,
          world: m.world,
          name: m.text,
          confidence: strong ? 1 : 0.5,
          basis: 'שם-מקום מהגזטיר',
          verified: strong ? true : null,
          verifyNote: strong
              ? 'עקביות גיאומטרית של $bestScore שמות'
              : 'רק $bestScore שמות עקביים — בדוק במיני-מפה',
          verifyKind: AnchorVerifyKind.geometric,
        ),
    ];
    // ‏2 עוגנים בלבד → עוגן-עזר שלישי מהטרנספורמציה הזוכה (בלעדיו אין
    // affine לשילוב-השקוף במסך-האישור, שדורש 3 נקודות) — ניצב לקטע
    // שביניהם, לא-קולינארי.
    if (out.length == 2 && bestT != null) {
      final (ar, ai, br, bi) = bestT;
      final z1 = (bestInliers[0].px.dx, -bestInliers[0].px.dy);
      final z2 = (bestInliers[1].px.dx, -bestInliers[1].px.dy);
      final dzr = z2.$1 - z1.$1, dzi = z2.$2 - z1.$2;
      // ‏z3 = אמצע + ‏0.8·(i·dz) — סיבוב-90° של הדלתא.
      final z3r = (z1.$1 + z2.$1) / 2 - 0.8 * dzi;
      final z3i = (z1.$2 + z2.$2) / 2 + 0.8 * dzr;
      final wx = ar * z3r - ai * z3i + br;
      final wy = ai * z3r + ar * z3i + bi;
      out.add(GeminiAnchorSuggestion(
        pixel: Offset(z3r, -z3i),
        world: fromM(wx, wy),
        name: 'עוגן-עזר (נגזר)',
        confidence: 0.5,
        basis: 'נגזר גיאומטרית משני השמות',
        verified: null,
        verifyNote: 'עוגן-עזר — נדרש לחישוב; אל תמחק',
        verifyKind: AnchorVerifyKind.geometric,
      ));
    }
    return out;
  }
}
