import 'dart:isolate';
import 'dart:math';

import 'package:latlong2/latlong.dart';

/// התאמה בין צומת-סריקה (פיקסל) לצומת-ייחוס (קואורדינטת עולם מדויקת).
class AnchorMatch {
  final Point<double> pixel;
  final LatLng world;
  const AnchorMatch(this.pixel, this.world);
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
  }) {
    return Isolate.run(() => match(scanPx: scanPx, refGeo: refGeo));
  }

  /// [scanPx] — צמתי-סריקה בפיקסלי-מקור. [refGeo] — צמתי-ייחוס.
  /// מחזיר null כשלא נמצא רישום עם לפחות [minInliers] התאמות.
  static MatchResult? match({
    required List<Point<double>> scanPx,
    required List<LatLng> refGeo,
    int minInliers = 4,
    double inlierMeters = 45,
    int iterations = 40000,
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
    _C? bestA;
    _C? bestB;
    var bestInliers = 0;

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
      // שני הכיוונים של זוג-הייחוס.
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
      if (inliers > bestInliers) {
        bestInliers = inliers;
        bestA = a;
        bestB = b;
      }
    }

    if (bestA == null || bestInliers < minInliers) return null;

    // עידון: least-squares דמיון מכל ה-inliers (התכתבות nearest), 2 סבבים.
    var a = bestA, b = bestB!;
    for (var round = 0; round < 2; round++) {
      final pairs = _correspondences(scan, ref, a, b, thr2);
      if (pairs.length < minInliers) break;
      final fit = _fitSimilarity(
        [for (final p in pairs) scan[p.$1]],
        [for (final p in pairs) ref[p.$2]],
      );
      a = fit.$1;
      b = fit.$2;
    }

    // התאמות סופיות 1-1 (חמדני לפי מרחק), עם snap לקואורדינטת-OSM המדויקת.
    final pairs = _correspondences(scan, ref, a, b, thr2);
    final matches = [
      for (final p in pairs) AnchorMatch(scanPx[p.$1], refGeo[p.$2]),
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
  ) {
    final cand = <(double, int, int)>[];
    for (var s = 0; s < scan.length; s++) {
      final w = a * scan[s] + b;
      for (var r = 0; r < ref.length; r++) {
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
