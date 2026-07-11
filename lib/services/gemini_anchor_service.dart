import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' show Offset;

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'anchor_matcher.dart';
import 'overpass_service.dart';
import 'road_junction_detector.dart';
import 'world_file_parser_service.dart';

/// אופן האימות של עוגן — קובע את התג הויזואלי במסך הכיוון.
enum AnchorVerifyKind {
  /// רישום גיאומטרי (מסלול קלאסי — RANSAC/OSM). ⊹
  geometric,

  /// אימות-ראייה של מודל מול קטע-מפה (מסלול AI). ◉
  vision,

  /// לא אומת (כשל טכני / אין רשת).
  none,
}

/// עוגן מוצע — נקודת פיקסל על התמונה + מיקום עולם.
/// ברירת-המחדל במסך-הכיוון: **מאושר**; המשתמש רק פוסל/מזיז את השגויים.
class GeminiAnchorSuggestion {
  final Offset pixel;
  final LatLng world;
  final String name;

  /// 0–1, כפי שדיווח המודל.
  final double confidence;

  /// על סמך מה זוהה (צומת, כיכר, מבנה, נקודת גובה...).
  final String basis;

  /// תוצאת האימות מול מפת-הייחוס: `true` — אומת; `false` — נדחה;
  /// `null` — לא בוצע.
  final bool? verified;

  /// הסבר קצר מהמאמת (מוצג בדיאלוג האישור).
  final String? verifyNote;

  /// אופן האימות — קלאסי-גיאומטרי מול AI-ראייה (לתג הויזואלי).
  final AnchorVerifyKind verifyKind;

  const GeminiAnchorSuggestion({
    required this.pixel,
    required this.world,
    required this.name,
    required this.confidence,
    required this.basis,
    this.verified,
    this.verifyNote,
    this.verifyKind = AnchorVerifyKind.none,
  });

  GeminiAnchorSuggestion copyWith({
    Offset? pixel,
    LatLng? world,
    bool? verified,
    String? verifyNote,
    AnchorVerifyKind? verifyKind,
  }) {
    return GeminiAnchorSuggestion(
      pixel: pixel ?? this.pixel,
      world: world ?? this.world,
      name: name,
      confidence: confidence,
      basis: basis,
      verified: verified ?? this.verified,
      verifyNote: verifyNote ?? this.verifyNote,
      verifyKind: verifyKind ?? this.verifyKind,
    );
  }
}

/// תיבה גיאוגרפית (WGS84).
typedef _Bbox = ({double south, double west, double north, double east});

/// המצב האוטומטי — הצעת עוגנים למפות משורטטות/סרוקות, **הכל בעיבוד-תמונה
/// מקומי בלי AI/רשת-מודל**:
///
/// 1. **גילוי** — גלאי-הצמתים הקלאסי מאתר צמתים/כיכרות מדויקי-פיקסל על
///    הסריקה, וגלאי-המצפן קורא את כיוון-הצפון.
/// 2. **איתור האזור** — רמז-המיקום שהמשתמש הזין עובר ג'יאוקודינג ב-Nominatim.
/// 3. **התאמה** — רישום RANSAC נעול-סיבוב (registerSweep) בין צמתי-הסריקה
///    לצמתי-OSM (Overpass), עם חפיפת-כבישים כשובר-שוויון → עוגנים
///    מדויקי-פיקסל בשניות. כשל ⇒ נעיצה ידנית במסך.
class GeminiAnchorService {
  static const _hintPrefsKey = 'gemini_area_hint';
  static const _userAgent = 'auto_maps/1.0 (github.com/elitzurms-art/auto-maps)';

  /// מסלול ההתאמה הקלאסי (Overpass+RANSAC). כבוי ⇒ נעיצה ידנית בלבד.
  static bool classicalMatchEnabled = true;

  /// רמז-המיקום האחרון שהמשתמש הזין (לפריפיל בדיאלוג).
  static Future<String?> getAreaHint() async {
    final prefs = await SharedPreferences.getInstance();
    final hint = prefs.getString(_hintPrefsKey)?.trim();
    return (hint == null || hint.isEmpty) ? null : hint;
  }

  static Future<void> setAreaHint(String hint) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_hintPrefsKey, hint.trim());
  }

  /// מריץ את הצנרת המלאה ומחזיר עוגנים מוצעים.
  ///
  /// [areaHint] — טקסט חופשי מהמשתמש ("נוב רמת הגולן") שמנחה את איתור
  /// האזור; עדיף על שם שהמודל קרא מהמפה. [onStatus] — עדכוני התקדמות.
  /// [maxAnchors] — תקרת עוגנים ("מצב מהיר"): מגביל את מספר המועמדים
  /// שנשלחים למודל, מוריד את יעד-האימות בהתאם, ומדלג על סבבי-השלמה —
  /// שימושי במיוחד עם מודל מקומי איטי.
  ///
  /// התמונה מוקטנת לצלע-מקסימום 1600px לפני השליחה; הפיקסלים המוחזרים הם
  /// בממדי-המקור [imageWidth]×[imageHeight].
  Future<List<GeminiAnchorSuggestion>> suggestAnchors({
    required String imagePath,
    required int imageWidth,
    required int imageHeight,
    String? areaHint,
    bool exactNorth = false,
    double? compassDeg,
    bool compassResolved = false,
    void Function(String status)? onStatus,
  }) async {
    final bytes = await File(imagePath).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw const FormatException('פענוח תמונת המפה נכשל');
    }

    // גלאי-הצמתים הקלאסי — עיבוד-תמונה מקומי, מדויק-פיקסל. רזולוציה מלאה
    // עד 2400px (בלי שליחה לרשת) כדי שימצא גם רחובות פנימיים.
    const maxDetDim = 2400;
    img.Image detImg = decoded;
    if (decoded.width > maxDetDim || decoded.height > maxDetDim) {
      detImg = decoded.width >= decoded.height
          ? img.copyResize(decoded, width: maxDetDim)
          : img.copyResize(decoded, height: maxDetDim);
    }
    final detScaleX = imageWidth / detImg.width; // detImg → מקור
    final detScaleY = imageHeight / detImg.height;

    onStatus?.call('מאתר צמתים על הסריקה (עיבוד-תמונה)...');
    final junctionPx = <Point<double>>[];
    final scanRound = <bool>[];
    var roadPointsScan = const <Point<double>>[];
    try {
      final det = await RoadJunctionDetector.detectFullInIsolate(detImg);
      for (final f in det.features) {
        if (f.kind == MapFeatureKind.junction ||
            f.kind == MapFeatureKind.roundabout) {
          junctionPx.add(Point(f.pos.x * detScaleX, f.pos.y * detScaleY));
          scanRound.add(f.kind == MapFeatureKind.roundabout);
        }
      }
      roadPointsScan = [
        for (final p in det.roadPoints)
          Point(p.x * detScaleX, p.y * detScaleY),
      ];
    } catch (_) {}

    // המסלול הקלאסי: רמז-אזור (חובה מה-UI) → רישום רשת-כבישים מול OSM,
    // בלי שום קריאת-מודל. מצליח ⇒ עוגנים מדויקי-פיקסל.
    final effectiveHint = areaHint?.trim() ?? '';
    if (classicalMatchEnabled &&
        effectiveHint.isNotEmpty &&
        junctionPx.length >= 4) {
      try {
        // deskew — מיישר את המפה לפי-התוכן ותופס **כל זווית**. זול למפה
        // ישרה (skew<2° → null); כבד רק למפה מסובבת (שם בדיוק רוצים אותו).
        // נאסף כאן, ונשלח יחד עם המסלול-הישיר להתאמה **מאוחדת** (איסוף-OSM
        // פעם אחת; כל אסטרטגיות-הכיוון מנוקדות יחד, הטובה מנצחת).
        onStatus?.call('בודק כיוון-מפה (יישור אוטומטי)...');
        final dsk = await Isolate.run(() => _deskewDetectSync(detImg));
        ({
          List<Point<double>> junctions,
          List<bool> rounds,
          List<Point<double>> roads,
          int cropW,
          int cropH,
          Offset Function(Offset) unmap,
        })? deskewBundle;
        if (dsk != null && dsk.junctions.length >= 4) {
          // מיפוי פיקסל-מיושר → פיקסל-מקור: הזזת-חיתוך → סיבוב-הפוך סביב
          // מרכז-detImg → קנה-מידה למקור. (סימן -skew אומת ויזואלית.)
          final t = -dsk.skew * pi / 180, ct = cos(t), st = sin(t);
          final cDeskX = dsk.deskW / 2, cDeskY = dsk.deskH / 2;
          final cDetX = dsk.detW / 2, cDetY = dsk.detH / 2;
          final sX = imageWidth / dsk.detW, sY = imageHeight / dsk.detH;
          Offset unmap(Offset p) {
            final dx = p.dx + dsk.minX - cDeskX, dy = p.dy + dsk.minY - cDeskY;
            return Offset(
              (ct * dx - st * dy + cDetX) * sX,
              (st * dx + ct * dy + cDetY) * sY,
            );
          }

          deskewBundle = (
            junctions: dsk.junctions,
            rounds: dsk.rounds,
            roads: dsk.roads,
            cropW: dsk.cropW,
            cropH: dsk.cropH,
            unmap: unmap,
          );
        }

        onStatus?.call('מתאים רשת-כבישים מול OSM (כל הזוויות, בלי AI)...');
        final classical = await _classicalMatch(
          junctionPx: junctionPx,
          scanRound: scanRound,
          roadPointsScan: roadPointsScan,
          areaHint: effectiveHint,
          exactNorth: exactNorth,
          compassDeg: compassDeg,
          compassResolved: compassResolved,
          deskew: deskewBundle,
        );
        if (classical != null && classical.length >= 4) {
          // סינון-שיורי רחב (90מ') — מפה סכמטית עשויה לסטות אמיתית; מה
          // שסוטה קיצונית = החלפת-נקודות, נזרק.
          _applyGeometricConsistency(classical, imageWidth, imageHeight,
              maxResidualMeters: 90);
          final kept = classical.where((s) => s.verified != false).toList();
          if (kept.length >= 4) return kept;
        }
      } catch (_) {
        // כשל (רשת/Overpass/אין התאמה) — אין מנוע-AI, מחזירים ריק.
      }
    }
    // המסלול הקלאסי לא הצליח — אין AI. ריק ⇒ נעיצה ידנית במסך.
    return const [];
  }

  /// מסנן חריגים גיאומטריים: מתאים affine לכל העוגנים, מחשב סטייה פר-עוגן
  /// (מטרים בין העולם-בפועל לעולם-החזוי מהטרנספורמציה), ופוסל איטרטיבית את
  /// החריג הגרוע כל עוד הוא קיצוני. סף ברירת-מחדל נדיב (`max(300מ', 4×חציון)`)
  /// למסלול-ה-AI (מפות מעוותות); [maxResidualMeters] קובע סף אבסולוטי צמוד
  /// למסלול הקלאסי — עוגני-OSM אמורים להתלכד היטב, וסטייה = החלפת-נקודות.
  void _applyGeometricConsistency(
    List<GeminiAnchorSuggestion> all,
    int imageWidth,
    int imageHeight, {
    double? maxResidualMeters,
  }) {
    while (true) {
      final active = [
        for (var i = 0; i < all.length; i++)
          if (all[i].verified != false) i,
      ];
      if (active.length < 4) return; // מעט מדי בשביל לזהות חריג בביטחון

      final WorldFileResult fit;
      try {
        fit = WorldFileParserService.calculateFromControlPoints(
          points: [
            for (final i in active)
              (pixel: all[i].pixel, world: all[i].world),
          ],
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        );
      } catch (_) {
        return; // נקודות קו-לינאריות וכד' — אין התאמה, אין סינון
      }
      final nw = fit.nw, ne = fit.ne, sw = fit.sw;
      if (nw == null || ne == null || sw == null) return;

      // עולם-חזוי לפיקסל: אינטרפולציה מהפינות (מדויקת עבור affine).
      LatLng predict(Offset px) {
        final u = px.dx / imageWidth;
        final v = px.dy / imageHeight;
        return LatLng(
          nw.latitude +
              u * (ne.latitude - nw.latitude) +
              v * (sw.latitude - nw.latitude),
          nw.longitude +
              u * (ne.longitude - nw.longitude) +
              v * (sw.longitude - nw.longitude),
        );
      }

      double meters(LatLng a, LatLng b) {
        final dLat = (a.latitude - b.latitude) * 111320;
        final dLon = (a.longitude - b.longitude) *
            111320 *
            cos(a.latitude * pi / 180);
        return sqrt(dLat * dLat + dLon * dLon);
      }

      final residuals = [
        for (final i in active) meters(all[i].world, predict(all[i].pixel)),
      ];
      final sorted = List<double>.from(residuals)..sort();
      final median = sorted[sorted.length ~/ 2];
      var worstIdx = 0;
      for (var j = 1; j < residuals.length; j++) {
        if (residuals[j] > residuals[worstIdx]) worstIdx = j;
      }
      final worst = residuals[worstIdx];
      final limit = maxResidualMeters ?? max(300, 4 * median);
      if (worst <= limit) return; // אין חריג קיצוני — סיימנו

      final i = active[worstIdx];
      all[i] = all[i].copyWith(
        verified: false,
        verifyNote:
            'סוטה ~${worst.round()}מ\' מהטרנספורמציה של שאר העוגנים',
      );
      // ממשיכים לסבב נוסף — אולי החריג הסתיר חריג נוסף.
    }
  }

  /// נוחות ל-UI: מזהה את חץ-הצפון/שושנת-הרוחות וקורא את זוויתו — **הכל
  /// בפיקסלים, בלי מודל** (מהיר, אמין, ללא תלות במנוע). מחזיר (זווית
  /// cwFromUp, resolved) — resolved=true כשהצפון חד-משמעי (אדום/חץ), false
  /// כשזה ציר בלבד (הגיאומטריה תבחר צפון/דרום). null אם לא נמצא מצפן.
  Future<({double deg, bool resolved})?> detectCompass({
    required String imagePath,
  }) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      return await RoadJunctionDetector.detectCompassInIsolate(decoded);
    } catch (_) {
      return null;
    }
  }


  // ═══ מסלול קלאסי — רישום רשת-כבישים מול OSM (Overpass + RANSAC) ═══

  /// מתאים את צמתי-הסריקה לצמתי-OSM וקטוריים של האזור. מחזיר עוגנים
  /// מאומתים (world = קואורדינטת-OSM מדויקת) או null כשההתאמה לא אמינה.
  /// תוצאת deskew: צמתים/כבישים בפריים המיושר-החתוך + פרמטרי-המיפוי חזרה
  /// לקואורדינטות התמונה המקורית (ברי-שליחה בין isolates — בלי closure).
  static ({
    List<Point<double>> junctions,
    List<bool> rounds,
    List<Point<double>> roads,
    double skew,
    int minX,
    int minY,
    int cropW,
    int cropH,
    int deskW,
    int deskH,
    int detW,
    int detH,
  })? _deskewDetectSync(img.Image detImg) {
    final skew = RoadJunctionDetector.estimateSkewDeg(detImg);
    if (skew.abs() < 2) return null; // כבר צירי — אין צורך ב-deskew
    final desk = img.copyRotate(detImg,
        angle: skew, interpolation: img.Interpolation.linear);
    // חיתוך לתוכן (מחריג מילוי-סיבוב לבן *וגם* שחור).
    var minX = desk.width, minY = desk.height, maxX = 0, maxY = 0;
    for (var y = 0; y < desk.height; y += 2) {
      for (var x = 0; x < desk.width; x += 2) {
        final p = desk.getPixel(x, y);
        if ((p.r < 245 || p.g < 245 || p.b < 245) &&
            (p.r > 18 || p.g > 18 || p.b > 18)) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (maxX - minX < 60 || maxY - minY < 60) return null;
    final cropped = img.copyCrop(desk,
        x: minX, y: minY, width: maxX - minX, height: maxY - minY);
    final det = RoadJunctionDetector.detectFull(cropped);
    final junctions = <Point<double>>[];
    final rounds = <bool>[];
    for (final f in det.features) {
      if (f.kind == MapFeatureKind.junction ||
          f.kind == MapFeatureKind.roundabout) {
        junctions.add(f.pos);
        rounds.add(f.kind == MapFeatureKind.roundabout);
      }
    }
    return (
      junctions: junctions,
      rounds: rounds,
      roads: det.roadPoints,
      skew: skew,
      minX: minX,
      minY: minY,
      cropW: maxX - minX,
      cropH: maxY - minY,
      deskW: desk.width,
      deskH: desk.height,
      detW: detImg.width,
      detH: detImg.height,
    );
  }

  /// מסובב נקודה ב-k רבעי-סיבוב (90°·k) סביב מרכז [cw]×[ch] — לטיפול
  /// באמביגואיית-90° של deskew (המפה יושרה לציר אך "מעלה" עשוי להיות
  /// 90/180/270). מדויק (בלי אינטרפולציה).
  static Point<double> _rot90(Point<double> p, int k, double cw, double ch) {
    var dx = p.x - cw / 2, dy = p.y - ch / 2;
    for (var i = 0; i < (k & 3); i++) {
      final nx = -dy, ny = dx;
      dx = nx;
      dy = ny;
    }
    return Point(dx + cw / 2, dy + ch / 2);
  }

  /// רישום גיאומטרי מול OSM — **מאוחד לכל הזוויות**. אוסף את OSM פעם אחת
  /// ומנסה עליו את **כל אסטרטגיות-הכיוון** בניקוד משותף: (א) ישיר — חלונות
  /// סביב מצפן / צפון-מדויק / ±20° (מפות בערך-ישרות); (ב) [deskew] (אם
  /// נמסר) — המפה יושרה לפי-התוכן, 4 רבעים × שארית ±12° → תופס **כל זווית**
  /// (35°/70°/…). הטוב-ביותר לפי-הניקוד מנצח חוצה-אסטרטגיות — כך "נעילה על
  /// זווית שגויה" מפסידה להתאמה טובה-יותר במקום להתקבל.
  Future<List<GeminiAnchorSuggestion>?> _classicalMatch({
    required List<Point<double>> junctionPx,
    required List<bool> scanRound,
    required List<Point<double>> roadPointsScan,
    required String areaHint,
    bool exactNorth = false,
    double? compassDeg,
    bool compassResolved = false,
    ({
      List<Point<double>> junctions,
      List<bool> rounds,
      List<Point<double>> roads,
      int cropW,
      int cropH,
      Offset Function(Offset) unmap,
    })? deskew,
  }) async {
    // bbox צמוד ליישוב — ריפוד רחב בולע יישוב שכן עם רשת-כבישים דומה
    // וגורם להתאמות-שווא (נצפה: נקודות נחתו בחיספין במקום בנוב).
    // ⚠️ ג'יאוקוד **מבוסס-מועמדים** — עמיד לשם-מקום ב**כל מיקום** בשם-הקובץ
    // ולמילות-תיאור ("מסובבת"/"עותק"). מנסים n-גרמים **יורדים** (השם המלא
    // קודם — הכי ספציפי; "כפר תבור" תופס לפני "כפר"), ואז מילים בודדות
    // שמאל→ימין. settlement-first לכל מועמד (מילת-תיאור לא תחזיר יישוב),
    // הראשון שמחזיר מנצח. cap 8 כדי לא להציף את Nominatim.
    final words =
        areaHint.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final ngrams = <String>[];
    for (var size = words.length; size >= 1; size--) {
      for (var i = 0; i + size <= words.length; i++) {
        ngrams.add(words.sublist(i, i + size).join(' '));
      }
    }
    final seen = <String>{};
    final candidates = [for (final c in ngrams) if (seen.add(c)) c].take(8);
    _Bbox? raw;
    for (final q in candidates) {
      raw = await _geocode(q, settlementOnly: true) ??
          await _geocode(q, settlementOnly: false);
      if (raw != null) break;
    }
    if (raw == null) return null;
    final dLat = (raw.north - raw.south) * 0.15;
    final dLon = (raw.east - raw.west) * 0.15;
    final bbox = (
      south: raw.south - dLat,
      west: raw.west - dLon,
      north: raw.north + dLat,
      east: raw.east + dLon,
    );
    // איסוף-OSM **פעם אחת** — משותף לכל האסטרטגיות (בלי כפילות-רשת).
    final osm = await OverpassService.fetchJunctions(bbox);
    if (osm.junctions.length < 4) return null;
    final refGeo = osm.junctions;

    // ציון-השוואה **בין כל הניסיונות** (חוצה-אסטרטגיות): inliers ראשית,
    // **חפיפת-כבישים כשובר-שוויון** — קריטי לזווית (180° סימטריית-רשת נותן
    // inliers כמעט-זהה, וחפיפת-הכבישים בוחרת את הכיוון הנכון).
    double scoreOf(MatchResult r) =>
        r.inliers * 10 - (r.roadFitMeters.isNaN ? 0.0 : r.roadFitMeters);

    // מצבי-כיוון ישירים: מצפן → ±15° סביב הזווית **וסביב שלילתה** (הסימן
    // תלוי-מוסכמה, הגיאומטריה בוחרת), ולא-מוכרע → גם +180°; צפון-מדויק
    // ±2°; אחרת בערך-צפון ±20°. תמיד כמעט-צפון כרשת-ביטחון.
    final directAttempts = <(double, double)>[
      if (compassDeg != null) ...[
        (compassDeg, 15.0),
        (-compassDeg, 15.0),
        if (!compassResolved) ...[
          (compassDeg + 180, 15.0),
          (-compassDeg - 180, 15.0),
        ],
        (0.0, 20.0),
      ] else if (exactNorth)
        (0.0, 2.0)
      else
        (0.0, 20.0),
    ];

    MatchResult? best;
    var bestScore = -double.infinity;
    var bestScanCount = junctionPx.length;
    Offset Function(Point<double>)? bestToOrig;

    // ── אסטרטגיה ישירה (בלי סיבוב-גס; פיקסל=מקור) ──
    for (final att in directAttempts) {
      final r = await AnchorMatcher.registerSweepInIsolate(
        scanPx: junctionPx,
        refGeo: refGeo,
        scanRound: scanRound,
        refRound: osm.isRoundabout,
        scanRoad: roadPointsScan.isEmpty ? null : roadPointsScan,
        refRoad: osm.roadPoints,
        maxRotationDeg: att.$2,
        centerRotationDeg: att.$1,
      );
      if (r != null && scoreOf(r) > bestScore) {
        bestScore = scoreOf(r);
        best = r;
        bestScanCount = junctionPx.length;
        bestToOrig = (px) => Offset(px.x, px.y);
      }
    }

    // ── אסטרטגיית deskew (כל הזוויות: 4 רבעים × שארית ±12°) ──
    if (deskew != null && deskew.junctions.length >= 4) {
      final cw = deskew.cropW.toDouble(), ch = deskew.cropH.toDouble();
      final unmap = deskew.unmap;
      for (var k = 0; k < 4; k++) {
        final scanCombined = [
          for (final j in deskew.junctions) _rot90(j, k, cw, ch)
        ];
        final rr = [for (final r in deskew.roads) _rot90(r, k, cw, ch)];
        final r = await AnchorMatcher.registerSweepInIsolate(
          scanPx: scanCombined,
          refGeo: refGeo,
          scanRound: deskew.rounds,
          refRound: osm.isRoundabout,
          scanRoad: rr.isEmpty ? null : rr,
          refRoad: osm.roadPoints,
          maxRotationDeg: 12.0,
          centerRotationDeg: 0.0,
        );
        if (r != null && scoreOf(r) > bestScore) {
          bestScore = scoreOf(r);
          best = r;
          bestScanCount = deskew.junctions.length;
          final kk = k;
          // מיפוי-עוגן חזרה: היפוך-הרבע (בפריים-המיושר) ואז unmap למקור.
          bestToOrig = (px) {
            final p = _rot90(px, (4 - kk) & 3, cw, ch);
            return unmap(Offset(p.x, p.y));
          };
        }
      }
    }

    // דורשים יחס-inliers סביר (יחסית לספירת-הצמתים של האסטרטגיה הזוכה) —
    // מגן מפני התאמה-חלקית מקרית.
    final minReq = max(4, (bestScanCount * 0.35).round());
    if (best == null || best.inliers < minReq) return null;

    return [
      for (final m in best.matches)
        GeminiAnchorSuggestion(
          pixel: bestToOrig!(m.pixel),
          world: m.world,
          name: m.isRoundabout ? 'כיכר' : 'צומת כבישים',
          confidence: 1,
          basis: m.isRoundabout
              ? 'התאמת כיכר מול OSM'
              : 'התאמת רשת-כבישים מול OSM',
          verified: true,
          verifyNote: 'רישום גיאומטרי (RANSAC, ${best.inliers} התאמות)',
          verifyKind: AnchorVerifyKind.geometric,
        ),
    ];
  }

  /// [settlementOnly] מגביל לתוצאות מסוג יישוב (עיר/כפר/מושב).
  Future<_Bbox?> _geocode(String query, {required bool settlementOnly}) async {
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': query,
        'format': 'json',
        'limit': '1',
        'accept-language': 'he',
        if (settlementOnly) 'featureType': 'settlement',
      });
      final resp = await http
          .get(uri, headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final list = jsonDecode(resp.body) as List;
      if (list.isEmpty) return null;
      // boundingbox: [south, north, west, east] (מחרוזות)
      final bb = ((list.first as Map<String, dynamic>)['boundingbox'] as List)
          .map((e) => double.parse(e as String))
          .toList();
      return (south: bb[0], west: bb[2], north: bb[1], east: bb[3]);
    } catch (_) {
      return null;
    }
  }

  // ═══ שלב ג' — התאמה ויזואלית מול קטע האזור (מפה + לוויין) ═══

  /// שולח את הסריקה עם הנקודות ממוספרות + קטע OSM + תצלום לוויין מיושרים
  /// של כל האזור, ומבקש מהמודל להצביע על כל נקודה בקטע-הייחוס. ההצבעות
}
