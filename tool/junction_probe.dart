// בוחן לגלאי-הצמתים: מצייר "מפת יישוב" סינתטית (דרכים עבות + טקסט-רעש),
// מריץ את RoadJunctionDetector ובודק שכל צומת-אמת נמצא ושאין הצפת-רעש.
// הרצה: dart run tool/junction_probe.dart  (שומר PNG מסומן ב-%TEMP%)
import 'dart:io';
import 'dart:math';

import 'package:image/image.dart' as img;

import 'package:auto_maps/services/road_junction_detector.dart';

void main() {
  const w = 1400, h = 1000;
  final map = img.Image(width: w, height: h);
  img.fill(map, color: img.ColorRgb8(235, 235, 230)); // רקע אפרפר-בהיר

  // דרכים אפור-בינוני — בהירות מהטקסט/מקרא, כמו במפות שכונה אמיתיות
  // (מקרה שמפיל סף-אוצו נאיבי שמתכייל על האלמנטים הכהים בלבד).
  final road = img.ColorRgb8(120, 120, 125);
  const roadW = 14;

  void thickLine(int x1, int y1, int x2, int y2) {
    img.drawLine(map, x1: x1, y1: y1, x2: x2, y2: y2,
        color: road, thickness: roadW);
  }

  // רשת דרכים: 2 אופקיות, 3 אנכיות, אלכסון — צמתים ידועים
  thickLine(60, 250, 1340, 250);
  thickLine(60, 700, 1340, 700);
  thickLine(300, 60, 300, 940);
  thickLine(750, 60, 750, 940);
  thickLine(1150, 60, 1150, 940);
  thickLine(300, 700, 750, 250); // אלכסון בין שני צמתים

  final truth = <Point<int>>[
    const Point(300, 250), const Point(750, 250), const Point(1150, 250),
    const Point(300, 700), const Point(750, 700), const Point(1150, 700),
  ];

  // טקסט-רעש: קווים דקים שמדמים כתב (חייבים להימחק ע"י הפתיחה)
  final rng = Random(7);
  final ink = img.ColorRgb8(30, 30, 30);
  for (var i = 0; i < 260; i++) {
    final x = 40 + rng.nextInt(w - 100);
    final y = 40 + rng.nextInt(h - 80);
    if ((y - 250).abs() < 30 || (y - 700).abs() < 30) continue;
    img.drawLine(map, x1: x, y1: y, x2: x + 6 + rng.nextInt(18), y2: y,
        color: ink, thickness: 2);
    img.drawLine(map, x1: x, y1: y, x2: x, y2: y + 3 + rng.nextInt(8),
        color: ink, thickness: 2);
  }

  // כיכר-טבעת מחוברת לרשת: טבעת דרך סביב אי-רקע עגול
  img.fillCircle(map, x: 1000, y: 480, radius: 34, color: road);
  img.fillCircle(map, x: 1000, y: 480, radius: 18,
      color: img.ColorRgb8(235, 235, 230));
  thickLine(1000, 514, 1000, 700); // חיבור לרשת שלא תימחק כרכיב מוצק

  // תיבת-מקרא מלאה (כחול כהה + טקסט לבן) — אסור שייצאו ממנה מועמדים
  img.fillRect(map, x1: 80, y1: 800, x2: 420, y2: 950,
      color: img.ColorRgb8(20, 90, 180));
  img.drawString(map, 'LEGEND BOX', font: img.arial24, x: 140, y: 860,
      color: img.ColorRgb8(255, 255, 255));

  final sw = Stopwatch()..start();
  final found = RoadJunctionDetector.detect(map, debugDir: Platform.environment["PROBE_DEBUG"]);
  sw.stop();

  var legendNoise = 0;
  for (final f in found) {
    if (f.pos.x >= 70 && f.pos.x <= 430 && f.pos.y >= 790 && f.pos.y <= 960) {
      legendNoise++;
    }
  }
  print('legend-box noise: $legendNoise (must be 0)');

  final junctions = [
    for (final f in found)
      if (f.kind == MapFeatureKind.junction) f.pos,
  ];
  var failures = 0;
  for (final t in truth) {
    final best = junctions.isEmpty
        ? double.infinity
        : junctions
            .map((f) => sqrt(pow(f.x - t.x, 2) + pow(f.y - t.y, 2)))
            .reduce(min);
    if (best > 12) {
      failures++;
      print('MISS junction (${t.x},${t.y}) — nearest candidate ${best.toStringAsFixed(1)}px away');
    }
  }
  // רעש: צמתים רחוקים מכל צומת-אמת ומחוץ לאלכסון
  var noise = 0;
  for (final f in junctions) {
    final nearTruth = truth
        .map((t) => sqrt(pow(f.x - t.x, 2) + pow(f.y - t.y, 2)))
        .reduce(min);
    // על האלכסון (300,700)->(750,250) קצוות נחשבים צמתים אמיתיים
    if (nearTruth > 40) noise++;
  }
  final byKind = <MapFeatureKind, int>{};
  for (final f in found) {
    byKind[f.kind] = (byKind[f.kind] ?? 0) + 1;
  }
  print('found ${found.length} candidates in ${sw.elapsedMilliseconds}ms; '
      'noise(far-from-truth junctions)=$noise; kinds=$byKind');
  // הדרכים מסתיימות ב-(x,60)/(x,940) — חייבים קצוות-דרך
  final deadEnds = byKind[MapFeatureKind.deadEnd] ?? 0;
  if (deadEnds == 0) print('WARN: no dead-ends detected');
  // כיכר-הטבעת ב-(1000,480) חייבת להתגלות במרחק ≤12px מהמרכז
  final rb = [
    for (final f in found)
      if (f.kind == MapFeatureKind.roundabout) f.pos,
  ];
  final rbHit = rb.any(
      (r) => sqrt(pow(r.x - 1000, 2) + pow(r.y - 480, 2)) <= 12);
  print(rbHit ? 'roundabout FOUND at center' : 'ROUNDABOUT MISSED');
  if (!rbHit) failures++;

  // פלט ויזואלי
  for (final f in found) {
    img.drawCircle(map, x: f.pos.x.round(), y: f.pos.y.round(), radius: 10,
        color: img.ColorRgb8(200, 0, 200));
  }
  final out =
      '${Platform.environment['TEMP'] ?? Directory.systemTemp.path}\\junction_probe.png';
  File(out).writeAsBytesSync(img.encodePng(map));
  print('wrote $out');
  print(failures == 0 ? 'ALL JUNCTIONS FOUND' : '$failures MISSED');
  exitCode = (failures == 0 && legendNoise == 0) ? 0 : 1;
}
