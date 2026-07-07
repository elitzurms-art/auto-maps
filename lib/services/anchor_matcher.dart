import 'dart:isolate';
import 'dart:math';

import 'package:latlong2/latlong.dart';

/// התאמה בין צומת-סריקה (פיקסל) לצומת-ייחוס (קואורדינטת עולם מדויקת).
class AnchorMatch {
  final Point<double> pixel;
  final LatLng world;
  final bool isRoundabout;
  const AnchorMatch(this.pixel, this.world, {this.isRoundabout = false});
}

/// תוצאת הרישום: ההתאמות + פרמטרי הטרנספורמציה (לאבחון).
class MatchResult {
  final List<AnchorMatch> matches;
  final double scaleMetersPerPx;
  final double rotationDeg;
  final int inliers;
  const MatchResult(
    this.matches,
    this.scaleMetersPerPx,
    this.rotationDeg,
    this.inliers,
  );
}

/// השערת-רישום אחת (אשכול-זווית מתוך מועמדי-ה-RANSAC): הטרנספורמציה
/// (פרימיטיבים ברי-שליחה בין isolates) + מדדי-איכות. הבחירה ביניהן נעשית
/// ע"י שוברי-שוויון אסימטריים (ירוק/יציאות/AI) — לא ע"י המדדים לבדם,
/// שסימטריים על עיר-רשת.
class MatchHypothesis {
  final double aRe, aIm, bRe, bIm; // w = a·z + b (מרוכבים)
  final double lat0, lon0; // מרכז מערכת-המטרים המקומית
  final double scaleMetersPerPx;
  final double rotationDeg;
  final int inliers;
  final double roadFitMeters;
  const MatchHypothesis({
    required this.aRe,
    required this.aIm,
    required this.bRe,
    required this.bIm,
    required this.lat0,
    required this.lon0,
    required this.scaleMetersPerPx,
    required this.rotationDeg,
    required this.inliers,
    required this.roadFitMeters,
  });

  /// ממפה פיקסל-סריקה ל-WGS84 לפי ההשערה.
  LatLng project(Point<double> px) {
    // z=(x,-y) — אותו היפוך-ציר כמו במַתאם.
    final wx = aRe * px.x - aIm * (-px.y) + bRe;
    final wy = aIm * px.x + aRe * (-px.y) + bIm;
    return LatLng(
      lat0 + wy / 111320.0,
      lon0 + wx / (111320.0 * cos(lat0 * pi / 180)),
    );
  }
}

/// רישום גיאומטרי (RANSAC) בין צמתי-הסריקה (פיקסלים, טרנספורמציה
/// לא-ידועה) לצמתי-הייחוס (WGS84 מדויק מ-OSM). מוצא טרנספורמציית-דמיון
/// (סיבוב+קנה-מידה+הזזה) שממקסמת inliers — עמיד לסיבוב, לקנה-מידה
/// ולעיוותי מפה-משורטטת (התאמה חלקית מבוססת-inliers). לא מודל, לא רשת.
///
/// זו החלופה לשלב-ההתאמה החזותי של ה-VLM: מדויק-פיקסל בשני הצדדים,
/// והקואורדינטה הסופית נלקחת מצומת-ה-OSM המדויק (snap), לא מהטרנספורמציה.
class AnchorMatcher {
  /// מריץ את [match] ב-Isolate (ה-RANSAC כבד — עד כמה שניות). המתודה
  /// סטטית והפרמטרים ברי-שליחה, אז אין גרירת-הקשר.
  static Future<MatchResult?> matchInIsolate({
    required List<Point<double>> scanPx,
    required List<LatLng> refGeo,
    List<bool>? scanRound,
    List<bool>? refRound,
    List<Point<double>>? scanRoad,
    List<LatLng>? refRoad,
  }) {
    return Isolate.run(() => match(
          scanPx: scanPx,
          refGeo: refGeo,
          scanRound: scanRound,
          refRound: refRound,
          scanRoad: scanRoad,
          refRoad: refRoad,
        ));
  }

  /// [scanPx] — צמתי-סריקה בפיקסלי-מקור. [refGeo] — צמתי-ייחוס.
  /// [scanRound]/[refRound] — דגלי-כיכר (נאכף כיכר↔כיכר בהקצאה הסופית).
  /// [scanRoad]/[refRoad] — נקודות-כביש (סריקה בפיקסלים, ייחוס ב-WGS84):
  /// כשניתנות, המַתאם **מדרג את מועמדי-ה-RANSAC לפי חפיפת-כבישים** ולא
  /// לפי ספירת-inliers בלבד — זה שובר את אמביגואיית-הסיבוב (הכבישים אינם
  /// סימטריים) ומאמת שהרישום נכון. מחזיר null כשאין רישום או כשהחפיפה
  /// הטובה ביותר גרועה (אמביגואי — עדיף נפילה-חזרה ל-AI).
  static MatchResult? match({
    required List<Point<double>> scanPx,
    required List<LatLng> refGeo,
    List<bool>? scanRound,
    List<bool>? refRound,
    List<Point<double>>? scanRoad,
    List<LatLng>? refRoad,
    int minInliers = 4,
    double inlierMeters = 45,
    double roadGateMeters = 16,
    int iterations = 50000,
    int seed = 12345,
  }) {
    if (scanPx.length < minInliers || refGeo.length < minInliers) return null;

    // ייחוס → מטרים מקומיים (equirectangular סביב מרכז-האזור; מדויק על
    // פני יישוב). מטרים עושים את סף-ה-inlier אינטואיטיבי.
    var lat0 = 0.0, lon0 = 0.0;
    for (final g in refGeo) {
      lat0 += g.latitude;
      lon0 += g.longitude;
    }
    lat0 /= refGeo.length;
    lon0 /= refGeo.length;
    final mPerLat = 111320.0;
    final mPerLon = 111320.0 * cos(lat0 * pi / 180);
    final ref = [
      for (final g in refGeo)
        _C((g.longitude - lon0) * mPerLon, (g.latitude - lat0) * mPerLat),
    ];
    // y-מסך מצביע למטה, y-מטרים (צפון) למעלה — היפוך חד-פעמי, אחרת
    // הדמיון w=az+b נאלץ להתאים תמונת-ראי (שורש כל הזוויות השגויות).
    final scan = [for (final p in scanPx) _C(p.x, -p.y)];

    // קנה-מידה צפוי = מוטת-הייחוס(מ') / מוטת-הסריקה(px). מגביל את מרחב
    // ההשערות ומונע קריסה לפתרון-שווא זעיר.
    final scanSpan = _span(scan);
    final refSpan = _span(ref);
    if (scanSpan < 1 || refSpan < 1) return null;
    final expScale = refSpan / scanSpan;
    final minScale = expScale * 0.35, maxScale = expScale * 2.8;

    // זוגות-ייחוס ממוינים לפי אורך — לדגימה תואמת-אורך (חיפוש בינארי).
    final refPairs = <(double, int, int)>[];
    for (var a = 0; a < ref.length; a++) {
      for (var b = a + 1; b < ref.length; b++) {
        refPairs.add(((ref[a] - ref[b]).abs, a, b));
      }
    }
    refPairs.sort((x, y) => x.$1.compareTo(y.$1));
    final refLens = [for (final p in refPairs) p.$1];

    final rng = Random(seed);
    final thr2 = inlierMeters * inlierMeters;

    // אוסף עד K מועמדים מובילים לפי inliers (ולא רק את הטוב ביותר) —
    // כדי לדרג אותם אחר-כך לפי חפיפת-כבישים.
    const kCand = 25;
    final cands = <(int, _C, _C)>[]; // (inliers, a, b)
    var minCandInliers = 0;

    for (var iter = 0; iter < iterations; iter++) {
      // זוג-סריקה אקראי; מחפשים זוג-ייחוס באורך תואם לקנה-המידה הצפוי —
      // כך כמעט כל השערה סבירה, וההתאמה האמיתית נדגמת בהסתברות גבוהה.
      final i = rng.nextInt(scan.length);
      final k = rng.nextInt(scan.length);
      if (k == i) continue;
      final dzLen = (scan[i] - scan[k]).abs;
      if (dzLen < scanSpan * 0.15) continue; // זוג קצר מדי — לא יציב
      // חלון-דגימה = בדיוק גבולות-הסקאלה המותרים — עקבי, בלי הטיה כפולה
      // (חלון צר סביב המשוער פספס את הסקאלה הנכונה כשהמשוער מוטה).
      final lo = _lowerBound(refLens, dzLen * minScale);
      final hi = _lowerBound(refLens, dzLen * maxScale);
      if (hi <= lo) continue;
      final rp = refPairs[lo + rng.nextInt(hi - lo)];
      final (j, l) = rng.nextBool() ? (rp.$2, rp.$3) : (rp.$3, rp.$2);

      final dz = scan[i] - scan[k];
      final dw = ref[j] - ref[l];
      final a = dw / dz;
      final scale = a.abs;
      if (scale < minScale || scale > maxScale) continue;
      final b = ref[j] - a * scan[i];

      var inliers = 0;
      for (final z in scan) {
        final w = a * z + b;
        var best = double.infinity;
        for (final r in ref) {
          final d2 = (w - r).abs2;
          if (d2 < best) best = d2;
        }
        if (best <= thr2) inliers++;
      }
      if (inliers >= minInliers &&
          (cands.length < kCand || inliers > minCandInliers)) {
        cands.add((inliers, a, b));
        cands.sort((x, y) => y.$1.compareTo(x.$1));
        if (cands.length > kCand) cands.removeLast();
        minCandInliers = cands.last.$1;
      }
    }

    if (cands.isEmpty) return null;

    // נקודות-כביש למטרים (אם ניתנו) — לדירוג חפיפת-כבישים.
    final scanRoadC =
        scanRoad == null ? null : [for (final p in scanRoad) _C(p.x, -p.y)];
    final refRoadC = refRoad == null
        ? null
        : [
            for (final g in refRoad)
              _C((g.longitude - lon0) * mPerLon, (g.latitude - lat0) * mPerLat),
          ];
    final useRoad = scanRoadC != null &&
        refRoadC != null &&
        scanRoadC.length >= 10 &&
        refRoadC.length >= 10;

    // לכל מועמד: עידון ICP, ואז ניקוד — חפיפת-כבישים (אם יש) או inliers.
    _C? bestA;
    _C? bestB;
    var bestScore = double.infinity; // נמוך=טוב
    var bestRoadMean = double.infinity;
    for (final cand in cands) {
      var a = cand.$2, b = cand.$3;
      for (var round = 0; round < 3; round++) {
        final ps = _correspondences(scan, ref, a, b, thr2, scanRound, refRound);
        if (ps.length < minInliers) break;
        final fit = _fitSimilarity(
          [for (final p in ps) scan[p.$1]],
          [for (final p in ps) ref[p.$2]],
        );
        a = fit.$1;
        b = fit.$2;
      }
      double score;
      double roadMean = 0;
      if (useRoad) {
        roadMean = _roadFit(scanRoadC, refRoadC, a, b);
        score = roadMean; // מטרים ממוצעים לנקודת-כביש — נמוך=מתיישר
      } else {
        // בלי כבישים: נשארים על inliers (שלילי כדי ש"נמוך=טוב").
        final ps = _correspondences(scan, ref, a, b, thr2, scanRound, refRound);
        score = -ps.length.toDouble();
      }
      if (score < bestScore) {
        bestScore = score;
        bestRoadMean = roadMean;
        bestA = a;
        bestB = b;
      }
    }

    if (bestA == null) return null;
    // שער-אימות: אם אפילו החפיפה הטובה גרועה — הרישום אמביגואי/שגוי,
    // עדיף להחזיר null (נפילה-חזרה ל-AI) מלהציג עוגנים בזווית הפוכה.
    if (useRoad && bestRoadMean > roadGateMeters) return null;

    return buildResult(
      scanPx: scanPx,
      refGeo: refGeo,
      scanRound: scanRound,
      refRound: refRound,
      aRe: bestA.re,
      aIm: bestA.im,
      bRe: bestB!.re,
      bIm: bestB.im,
      minInliers: minInliers,
      inlierMeters: inlierMeters,
    );
  }

  /// בונה [MatchResult] (התאמות 1-1 + snap ל-OSM) מטרנספורמציה נתונה —
  /// למשל השערה שנבחרה ע"י שובר-שוויון.
  static MatchResult? buildResult({
    required List<Point<double>> scanPx,
    required List<LatLng> refGeo,
    List<bool>? scanRound,
    List<bool>? refRound,
    required double aRe,
    required double aIm,
    required double bRe,
    required double bIm,
    int minInliers = 4,
    double inlierMeters = 45,
  }) {
    var lat0 = 0.0, lon0 = 0.0;
    for (final g in refGeo) {
      lat0 += g.latitude;
      lon0 += g.longitude;
    }
    lat0 /= refGeo.length;
    lon0 /= refGeo.length;
    final mPerLat = 111320.0;
    final mPerLon = 111320.0 * cos(lat0 * pi / 180);
    final ref = [
      for (final g in refGeo)
        _C((g.longitude - lon0) * mPerLon, (g.latitude - lat0) * mPerLat),
    ];
    // y-מסך מצביע למטה, y-מטרים (צפון) למעלה — היפוך חד-פעמי, אחרת
    // הדמיון w=az+b נאלץ להתאים תמונת-ראי (שורש כל הזוויות השגויות).
    final scan = [for (final p in scanPx) _C(p.x, -p.y)];
    final a = _C(aRe, aIm), b = _C(bRe, bIm);
    final thr2 = inlierMeters * inlierMeters;

    final pairs = _correspondences(scan, ref, a, b, thr2, scanRound, refRound);
    final matches = [
      for (final p in pairs)
        AnchorMatch(
          scanPx[p.$1],
          refGeo[p.$2],
          isRoundabout: refRound?[p.$2] ?? false,
        ),
    ];
    if (matches.length < minInliers) return null;

    final rotDeg = atan2(a.im, a.re) * 180 / pi;
    return MatchResult(matches, a.abs, rotDeg, matches.length);
  }

  /// מחזיר את אשכולות-ההשערות המובילים (עד [maxHypotheses], מובחנים
  /// בזווית ≥20°), כל אחד אחרי עידון-ICP ועם ציון חפיפת-כבישים. הבחירה
  /// ביניהם — בשוברי-השוויון האסימטריים של הקורא.
  static Future<List<MatchHypothesis>> hypothesesInIsolate({
    required List<Point<double>> scanPx,
    required List<LatLng> refGeo,
    List<Point<double>>? scanRoad,
    List<LatLng>? refRoad,
    int maxHypotheses = 4,
  }) {
    return Isolate.run(() => hypotheses(
          scanPx: scanPx,
          refGeo: refGeo,
          scanRoad: scanRoad,
          refRoad: refRoad,
          maxHypotheses: maxHypotheses,
        ));
  }

  static List<MatchHypothesis> hypotheses({
    required List<Point<double>> scanPx,
    required List<LatLng> refGeo,
    List<Point<double>>? scanRoad,
    List<LatLng>? refRoad,
    int maxHypotheses = 4,
    int minInliers = 4,
    double inlierMeters = 45,
    int iterations = 50000,
    int seed = 12345,
  }) {
    if (scanPx.length < minInliers || refGeo.length < minInliers) {
      return const [];
    }
    var lat0 = 0.0, lon0 = 0.0;
    for (final g in refGeo) {
      lat0 += g.latitude;
      lon0 += g.longitude;
    }
    lat0 /= refGeo.length;
    lon0 /= refGeo.length;
    final mPerLat = 111320.0;
    final mPerLon = 111320.0 * cos(lat0 * pi / 180);
    final ref = [
      for (final g in refGeo)
        _C((g.longitude - lon0) * mPerLon, (g.latitude - lat0) * mPerLat),
    ];
    // y-מסך מצביע למטה, y-מטרים (צפון) למעלה — היפוך חד-פעמי, אחרת
    // הדמיון w=az+b נאלץ להתאים תמונת-ראי (שורש כל הזוויות השגויות).
    final scan = [for (final p in scanPx) _C(p.x, -p.y)];

    final scanSpan = _span(scan);
    final refSpan = _span(ref);
    if (scanSpan < 1 || refSpan < 1) return const [];
    final expScale = refSpan / scanSpan;
    final minScale = expScale * 0.35, maxScale = expScale * 2.8;

    final refPairs = <(double, int, int)>[];
    for (var a = 0; a < ref.length; a++) {
      for (var b = a + 1; b < ref.length; b++) {
        refPairs.add(((ref[a] - ref[b]).abs, a, b));
      }
    }
    refPairs.sort((x, y) => x.$1.compareTo(y.$1));
    final refLens = [for (final p in refPairs) p.$1];

    final rng = Random(seed);
    // סף-inlier ב**פיקסלי-סריקה** (שם מקור השגיאה — יד רועדת), מומר
    // למטרים לפי קנה-המידה של כל השערה. סף קבוע-במטרים נותן לפתרונות
    // בקנה-מידה קטן "דיוק בחינם" (שגיאות-הפיקסלים מתכווצות) — והקריסה
    // תמיד ניצחה. 1.5% ממוטת-הסריקה ≈ 70px על מפה 5000px.
    final thrPx = scanSpan * 0.015;
    const kCand = 40;
    final cands = <(int, _C, _C)>[];
    var minCandInliers = 0;

    for (var iter = 0; iter < iterations; iter++) {
      final i = rng.nextInt(scan.length);
      final k = rng.nextInt(scan.length);
      if (k == i) continue;
      final dzLen = (scan[i] - scan[k]).abs;
      if (dzLen < scanSpan * 0.15) continue;
      // חלון-דגימה = בדיוק גבולות-הסקאלה המותרים — עקבי, בלי הטיה כפולה
      // (חלון צר סביב המשוער פספס את הסקאלה הנכונה כשהמשוער מוטה).
      final lo = _lowerBound(refLens, dzLen * minScale);
      final hi = _lowerBound(refLens, dzLen * maxScale);
      if (hi <= lo) continue;
      final rp = refPairs[lo + rng.nextInt(hi - lo)];
      final (j, l) = rng.nextBool() ? (rp.$2, rp.$3) : (rp.$3, rp.$2);
      final dz = scan[i] - scan[k];
      final dw = ref[j] - ref[l];
      final a = dw / dz;
      if (a.abs < minScale || a.abs > maxScale) continue;
      final b = ref[j] - a * scan[i];

      final thr2 = pow(thrPx * a.abs, 2).toDouble();
      var inliers = 0;
      for (final z in scan) {
        final w = a * z + b;
        var best = double.infinity;
        for (final r in ref) {
          final d2 = (w - r).abs2;
          if (d2 < best) best = d2;
        }
        if (best <= thr2) inliers++;
      }
      if (inliers >= minInliers &&
          (cands.length < kCand || inliers > minCandInliers)) {
        cands.add((inliers, a, b));
        cands.sort((x, y) => y.$1.compareTo(x.$1));
        if (cands.length > kCand) cands.removeLast();
        minCandInliers = cands.last.$1;
      }
    }
    if (cands.isEmpty) return const [];

    final scanRoadC =
        scanRoad == null ? null : [for (final p in scanRoad) _C(p.x, -p.y)];
    final refRoadC = refRoad == null
        ? null
        : [
            for (final g in refRoad)
              _C((g.longitude - lon0) * mPerLon, (g.latitude - lat0) * mPerLat),
          ];
    final useRoad = scanRoadC != null &&
        refRoadC != null &&
        scanRoadC.length >= 10 &&
        refRoadC.length >= 10;

    // עידון כל מועמד + אשכול לפי זווית: שומרים את הטוב (inliers) מכל אשכול.
    final out = <MatchHypothesis>[];
    for (final cand in cands) {
      var a = cand.$2, b = cand.$3;
      for (var round = 0; round < 3; round++) {
        final thr2c = pow(thrPx * a.abs, 2).toDouble();
        final ps = _correspondences(scan, ref, a, b, thr2c, null, null);
        if (ps.length < minInliers) break;
        final fit = _fitSimilarity(
          [for (final p in ps) scan[p.$1]],
          [for (final p in ps) ref[p.$2]],
        );
        a = fit.$1;
        b = fit.$2;
      }
      final rot = atan2(a.im, a.re) * 180 / pi;
      // אשכול-זווית קיים? (הפרש מעגלי < 20°)
      final dup = out.any((h) {
        var d = (h.rotationDeg - rot).abs() % 360;
        if (d > 180) d = 360 - d;
        return d < 20;
      });
      if (dup) continue;
      final thr2f = pow(thrPx * a.abs, 2).toDouble();
      final ps = _correspondences(scan, ref, a, b, thr2f, null, null);
      if (ps.length < minInliers) continue;
      out.add(MatchHypothesis(
        aRe: a.re,
        aIm: a.im,
        bRe: b.re,
        bIm: b.im,
        lat0: lat0,
        lon0: lon0,
        scaleMetersPerPx: a.abs,
        rotationDeg: rot,
        inliers: ps.length,
        roadFitMeters:
            useRoad ? _roadFit(scanRoadC, refRoadC, a, b) : double.nan,
      ));
      if (out.length >= maxHypotheses) break;
    }
    return out;
  }

  /// חיפוש-מכוון-משואה: כשיש "משואה" אסימטרית מותאמת-מראש בשני הצדדים
  /// (מרכז הכתם-הירוק בסריקה ↔ מרכז הירוק ב-OSM), כל צירוף של
  /// (צומת-סריקה, צומת-ייחוס) + המשואה נותן טרנספורמציה מלאה — סריקה
  /// **דטרמיניסטית** של כל הצירופים (~1-2K), בלי הגרלות ובלי סימטריה:
  /// המשואה שוברת את הכיוון מהבנייה. מחזיר השערות מובחנות-זווית ממוינות
  /// לפי inliers.
  static Future<List<MatchHypothesis>> hypothesesWithBeaconInIsolate({
    required List<Point<double>> scanPx,
    required List<LatLng> refGeo,
    required Point<double> scanBeacon,
    required LatLng refBeacon,
    List<Point<double>>? scanRoad,
    List<LatLng>? refRoad,
    int maxHypotheses = 4,
  }) {
    return Isolate.run(() => hypothesesWithBeacon(
          scanPx: scanPx,
          refGeo: refGeo,
          scanBeacon: scanBeacon,
          refBeacon: refBeacon,
          scanRoad: scanRoad,
          refRoad: refRoad,
          maxHypotheses: maxHypotheses,
        ));
  }

  static List<MatchHypothesis> hypothesesWithBeacon({
    required List<Point<double>> scanPx,
    required List<LatLng> refGeo,
    required Point<double> scanBeacon,
    required LatLng refBeacon,
    List<Point<double>>? scanRoad,
    List<LatLng>? refRoad,
    int maxHypotheses = 4,
    int minInliers = 4,
  }) {
    if (scanPx.length < minInliers || refGeo.length < minInliers) {
      return const [];
    }
    var lat0 = 0.0, lon0 = 0.0;
    for (final g in refGeo) {
      lat0 += g.latitude;
      lon0 += g.longitude;
    }
    lat0 /= refGeo.length;
    lon0 /= refGeo.length;
    final mPerLat = 111320.0;
    final mPerLon = 111320.0 * cos(lat0 * pi / 180);
    final ref = [
      for (final g in refGeo)
        _C((g.longitude - lon0) * mPerLon, (g.latitude - lat0) * mPerLat),
    ];
    // y-מסך מצביע למטה, y-מטרים (צפון) למעלה — היפוך חד-פעמי, אחרת
    // הדמיון w=az+b נאלץ להתאים תמונת-ראי (שורש כל הזוויות השגויות).
    final scan = [for (final p in scanPx) _C(p.x, -p.y)];
    final sBeacon = _C(scanBeacon.x, -scanBeacon.y);
    final rBeacon = _C(
      (refBeacon.longitude - lon0) * mPerLon,
      (refBeacon.latitude - lat0) * mPerLat,
    );

    final scanSpan = _span(scan);
    final refSpan = _span(ref);
    if (scanSpan < 1 || refSpan < 1) return const [];
    final expScale = refSpan / scanSpan;
    final minScale = expScale * 0.3, maxScale = expScale * 3.2;
    final thrPx = scanSpan * 0.015;

    final scanRoadC =
        scanRoad == null ? null : [for (final p in scanRoad) _C(p.x, -p.y)];
    final refRoadC = refRoad == null
        ? null
        : [
            for (final g in refRoad)
              _C((g.longitude - lon0) * mPerLon, (g.latitude - lat0) * mPerLat),
          ];
    final useRoad = scanRoadC != null &&
        refRoadC != null &&
        scanRoadC.length >= 10 &&
        refRoadC.length >= 10;

    // סריקה ממצה של כל הצירופים (משואה + צומת אחד = טרנספורמציה).
    final seeds = <(int, _C, _C)>[];
    for (final s in scan) {
      final dz = s - sBeacon;
      if (dz.abs < scanSpan * 0.12) continue; // קרוב מדי למשואה — לא יציב
      for (final r in ref) {
        final dw = r - rBeacon;
        final a = dw / dz;
        if (a.abs < minScale || a.abs > maxScale) continue;
        final b = rBeacon - a * sBeacon;
        final thr2 = pow(thrPx * a.abs, 2).toDouble();
        var inliers = 0;
        for (final z in scan) {
          final w = a * z + b;
          var best = double.infinity;
          for (final rr in ref) {
            final d2 = (w - rr).abs2;
            if (d2 < best) best = d2;
          }
          if (best <= thr2) inliers++;
        }
        if (inliers >= minInliers) seeds.add((inliers, a, b));
      }
    }
    if (seeds.isEmpty) return const [];
    seeds.sort((x, y) => y.$1.compareTo(x.$1));

    // עידון ICP + אשכול-זווית (כמו ב-hypotheses).
    final out = <MatchHypothesis>[];
    for (final seed in seeds) {
      var a = seed.$2, b = seed.$3;
      for (var round = 0; round < 3; round++) {
        final thr2c = pow(thrPx * a.abs, 2).toDouble();
        final ps = _correspondences(scan, ref, a, b, thr2c, null, null);
        if (ps.length < minInliers) break;
        final fit = _fitSimilarity(
          [for (final p in ps) scan[p.$1]],
          [for (final p in ps) ref[p.$2]],
        );
        a = fit.$1;
        b = fit.$2;
      }
      final rot = atan2(a.im, a.re) * 180 / pi;
      final dup = out.any((h) {
        var d = (h.rotationDeg - rot).abs() % 360;
        if (d > 180) d = 360 - d;
        return d < 20;
      });
      if (dup) continue;
      // המשואה חייבת להישאר נאמנה גם אחרי העידון — אחרת ההשערה זנחה
      // את העוגן ששבר את הסימטריה.
      final beaconErr = (a * sBeacon + b - rBeacon).abs;
      if (beaconErr > refSpan * 0.25) continue;
      final thr2f = pow(thrPx * a.abs, 2).toDouble();
      final ps = _correspondences(scan, ref, a, b, thr2f, null, null);
      if (ps.length < minInliers) continue;
      out.add(MatchHypothesis(
        aRe: a.re,
        aIm: a.im,
        bRe: b.re,
        bIm: b.im,
        lat0: lat0,
        lon0: lon0,
        scaleMetersPerPx: a.abs,
        rotationDeg: rot,
        inliers: ps.length,
        roadFitMeters:
            useRoad ? _roadFit(scanRoadC, refRoadC, a, b) : double.nan,
      ));
      if (out.length >= maxHypotheses) break;
    }
    return out;
  }

  /// שתי-משואות: זוג התאמות ידועות-סמנטית (למשל ירוק↔ירוק + כיכר↔כיכר)
  /// נותן טרנספורמציה **דטרמיניסטית** — בלי שום ניחוש-פיוס. עבור כל צירוף
  /// משואה-B (כיכרות: יתכנו כמה בכל צד) נבנית השערה, מעודנת ב-ICP,
  /// ומדורגת לפי inliers. הסימטריה שבורה מהבנייה בשתי נקודות אמת.
  static List<MatchHypothesis> twoBeaconHypotheses({
    required List<Point<double>> scanPx,
    required List<LatLng> refGeo,
    required Point<double> scanBeaconA,
    required LatLng refBeaconA,
    required List<Point<double>> scanBeaconsB,
    required List<LatLng> refBeaconsB,
    List<Point<double>>? scanRoad,
    List<LatLng>? refRoad,
    int maxHypotheses = 4,
    int minInliers = 4,
  }) {
    if (scanPx.isEmpty || refGeo.isEmpty) return const [];
    var lat0 = 0.0, lon0 = 0.0;
    for (final g in refGeo) {
      lat0 += g.latitude;
      lon0 += g.longitude;
    }
    lat0 /= refGeo.length;
    lon0 /= refGeo.length;
    final mPerLat = 111320.0;
    final mPerLon = 111320.0 * cos(lat0 * pi / 180);
    _C toM(LatLng g) =>
        _C((g.longitude - lon0) * mPerLon, (g.latitude - lat0) * mPerLat);
    final ref = [for (final g in refGeo) toM(g)];
    // y-מסך מצביע למטה, y-מטרים (צפון) למעלה — היפוך חד-פעמי, אחרת
    // הדמיון w=az+b נאלץ להתאים תמונת-ראי (שורש כל הזוויות השגויות).
    final scan = [for (final p in scanPx) _C(p.x, -p.y)];
    final gS = _C(scanBeaconA.x, -scanBeaconA.y);
    final gR = toM(refBeaconA);

    final scanSpan = _span(scan);
    final refSpan = _span(ref);
    if (scanSpan < 1 || refSpan < 1) return const [];
    final expScale = refSpan / scanSpan;
    final thrPx = scanSpan * 0.015;

    final scanRoadC =
        scanRoad == null ? null : [for (final p in scanRoad) _C(p.x, -p.y)];
    final refRoadC =
        refRoad == null ? null : [for (final g in refRoad) toM(g)];
    final useRoad = scanRoadC != null &&
        refRoadC != null &&
        scanRoadC.length >= 10 &&
        refRoadC.length >= 10;

    final out = <MatchHypothesis>[];
    final seeds = <(int, _C, _C)>[];
    for (final bS in scanBeaconsB) {
      final zB = _C(bS.x, -bS.y);
      final dz = zB - gS;
      if (dz.abs < scanSpan * 0.08) continue;
      for (final bR in refBeaconsB) {
        final dw = toM(bR) - gR;
        final a = dw / dz;
        if (a.abs < expScale * 0.3 || a.abs > expScale * 3.2) continue;
        final b = gR - a * gS;
        final thr2 = pow(thrPx * a.abs, 2).toDouble();
        var inliers = 0;
        for (final z in scan) {
          final w = a * z + b;
          var best = double.infinity;
          for (final rr in ref) {
            final d2 = (w - rr).abs2;
            if (d2 < best) best = d2;
          }
          if (best <= thr2) inliers++;
        }
        seeds.add((inliers, a, b));
      }
    }
    if (seeds.isEmpty) return const [];
    seeds.sort((x, y) => y.$1.compareTo(x.$1));

    for (final seed in seeds) {
      var a = seed.$2, b = seed.$3;
      for (var round = 0; round < 3; round++) {
        final thr2c = pow(thrPx * a.abs, 2).toDouble();
        final ps = _correspondences(scan, ref, a, b, thr2c, null, null);
        if (ps.length < minInliers) break;
        final fit = _fitSimilarity(
          [for (final p in ps) scan[p.$1]],
          [for (final p in ps) ref[p.$2]],
        );
        a = fit.$1;
        b = fit.$2;
      }
      final rot = atan2(a.im, a.re) * 180 / pi;
      final dup = out.any((h) {
        var d = (h.rotationDeg - rot).abs() % 360;
        if (d > 180) d = 360 - d;
        return d < 20;
      });
      if (dup) continue;
      final thr2f = pow(thrPx * a.abs, 2).toDouble();
      final ps = _correspondences(scan, ref, a, b, thr2f, null, null);
      if (ps.length < minInliers) continue;
      out.add(MatchHypothesis(
        aRe: a.re,
        aIm: a.im,
        bRe: b.re,
        bIm: b.im,
        lat0: lat0,
        lon0: lon0,
        scaleMetersPerPx: a.abs,
        rotationDeg: rot,
        inliers: ps.length,
        roadFitMeters:
            useRoad ? _roadFit(scanRoadC, refRoadC, a, b) : double.nan,
      ));
      if (out.length >= maxHypotheses) break;
    }
    return out;
  }

  /// התאמות 1-1: לכל צומת-סריקה הצומת-ייחוס הקרוב ביותר תחת הסף, בסדר
  /// מרחק עולה, כל ייחוס פעם אחת.
  static List<(int, int)> _correspondences(
    List<_C> scan,
    List<_C> ref,
    _C a,
    _C b,
    double thr2,
    List<bool>? scanRound,
    List<bool>? refRound,
  ) {
    final cand = <(double, int, int)>[];
    for (var s = 0; s < scan.length; s++) {
      final w = a * scan[s] + b;
      for (var r = 0; r < ref.length; r++) {
        // אילוץ-סוג: כיכר מתאימה רק לכיכר (ולהפך).
        if (scanRound != null &&
            refRound != null &&
            scanRound[s] != refRound[r]) {
          continue;
        }
        final d2 = (w - ref[r]).abs2;
        if (d2 <= thr2) cand.add((d2, s, r));
      }
    }
    cand.sort((x, y) => x.$1.compareTo(y.$1));
    final usedScan = <int>{}, usedRef = <int>{};
    final out = <(int, int)>[];
    for (final c in cand) {
      if (usedScan.contains(c.$2) || usedRef.contains(c.$3)) continue;
      usedScan.add(c.$2);
      usedRef.add(c.$3);
      out.add((c.$2, c.$3));
    }
    return out;
  }

  /// חפיפת-כבישים דו-כיוונית (Chamfer): ממוצע המרחקים סריקה→ייחוס
  /// **ו**ייחוס→סריקה, קטום ל-40מ'. הכיוון ההפוך (ייחוס→סריקה) מעניש
  /// כיסוי-חלקי — פתרון מכווץ שנכנס בפינת-היישוב יקבל מרחק גדול כי רוב
  /// כבישי-היישוב רחוקים ממנו. נמוך = הכבישים מתיישרים = הרישום נכון.
  /// שובר גם את אמביגואיית-הסיבוב וגם את דגנרציית-הכיווץ. דוגם לזירוז.
  static double _roadFit(List<_C> scanRoad, List<_C> refRoad, _C a, _C b) {
    const cap = 40.0 * 40.0;
    final stepS = (scanRoad.length / 160).ceil().clamp(1, 1 << 20);
    final stepR = (refRoad.length / 1600).ceil().clamp(1, 1 << 20);

    // סריקה (מומרת) → כביש-ייחוס.
    final scanW = <_C>[];
    for (var si = 0; si < scanRoad.length; si += stepS) {
      scanW.add(a * scanRoad[si] + b);
    }
    final refS = <_C>[];
    for (var ri = 0; ri < refRoad.length; ri += stepR) {
      refS.add(refRoad[ri]);
    }
    if (scanW.isEmpty || refS.isEmpty) return double.infinity;

    var fwd = 0.0;
    for (final w in scanW) {
      var best = cap;
      for (final r in refS) {
        final d2 = (w - r).abs2;
        if (d2 < best) best = d2;
      }
      fwd += sqrt(best);
    }
    var bwd = 0.0;
    for (final r in refS) {
      var best = cap;
      for (final w in scanW) {
        final d2 = (r - w).abs2;
        if (d2 < best) best = d2;
      }
      bwd += sqrt(best);
    }
    return 0.5 * (fwd / scanW.length + bwd / refS.length);
  }

  /// least-squares של טרנספורמציית-דמיון w=a·z+b ממערך התאמות (מרוכב).
  static (_C, _C) _fitSimilarity(List<_C> z, List<_C> w) {
    final n = z.length;
    var zc = const _C(0, 0), wc = const _C(0, 0);
    for (var i = 0; i < n; i++) {
      zc = zc + z[i];
      wc = wc + w[i];
    }
    zc = zc / _C(n.toDouble(), 0);
    wc = wc / _C(n.toDouble(), 0);
    var num = const _C(0, 0);
    var den = 0.0;
    for (var i = 0; i < n; i++) {
      final zp = z[i] - zc;
      final wp = w[i] - wc;
      num = num + zp.conj * wp; // Σ conj(z')·w'
      den += zp.abs2;
    }
    final a = den < 1e-12 ? const _C(1, 0) : num / _C(den, 0);
    final b = wc - a * zc;
    return (a, b);
  }
}

/// מוטת קבוצת-נקודות (המרחק הזוגי המקסימלי, בקירוב — לפי bbox).
double _span(List<_C> pts) {
  var minX = double.infinity, maxX = -double.infinity;
  var minY = double.infinity, maxY = -double.infinity;
  for (final p in pts) {
    if (p.re < minX) minX = p.re;
    if (p.re > maxX) maxX = p.re;
    if (p.im < minY) minY = p.im;
    if (p.im > maxY) maxY = p.im;
  }
  return sqrt(pow(maxX - minX, 2) + pow(maxY - minY, 2)).toDouble();
}

/// אינדקס ראשון ב-[sorted] (עולה) שערכו ≥ [target].
int _lowerBound(List<double> sorted, double target) {
  var lo = 0, hi = sorted.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (sorted[mid] < target) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// מספר מרוכב מינימלי (הימנעות מתלות חיצונית; רץ ב-Isolate).
class _C {
  final double re, im;
  const _C(this.re, this.im);

  _C operator +(_C o) => _C(re + o.re, im + o.im);
  _C operator -(_C o) => _C(re - o.re, im - o.im);
  _C operator *(_C o) => _C(re * o.re - im * o.im, re * o.im + im * o.re);
  _C operator /(_C o) {
    final d = o.re * o.re + o.im * o.im;
    return _C((re * o.re + im * o.im) / d, (im * o.re - re * o.im) / d);
  }

  _C get conj => _C(re, -im);
  double get abs2 => re * re + im * im;
  double get abs => sqrt(abs2);
}
