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
    final scan = [for (final p in scanPx) _C(p.x, p.y)];

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
      final target = dzLen * expScale;
      final lo = _lowerBound(refLens, target * 0.7);
      final hi = _lowerBound(refLens, target * 1.3);
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
        scanRoad == null ? null : [for (final p in scanRoad) _C(p.x, p.y)];
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

    final a = bestA, b = bestB!;
    // התאמות סופיות 1-1 (חמדני לפי מרחק), עם snap לקואורדינטת-OSM המדויקת.
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
