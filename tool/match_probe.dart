// בוחן המסלול הקלאסי המלא על מפה אמיתית: גלאי-צמתים על הסריקה →
// Overpass (צמתי-OSM וקטוריים) → RANSAC → עוגנים פיקסל↔עולם.
// הרצה: dart run tool/match_probe.dart "<image>" south west north east
import 'dart:io';
import 'dart:math';

import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';

import 'package:auto_maps/services/anchor_matcher.dart';
import 'package:auto_maps/services/overpass_service.dart';
import 'package:auto_maps/services/road_junction_detector.dart';

Future<void> main(List<String> args) async {
  final im = img.decodeImage(File(args[0]).readAsBytesSync())!;
  final bbox = (
    south: double.parse(args[1]),
    west: double.parse(args[2]),
    north: double.parse(args[3]),
    east: double.parse(args[4]),
  );
  print('image ${im.width}x${im.height}');

  final feats = RoadJunctionDetector.detect(im);
  final scan = [
    for (final f in feats)
      if (f.kind == MapFeatureKind.junction ||
          f.kind == MapFeatureKind.roundabout)
        f.pos,
  ];
  print('scan junctions/roundabouts: ${scan.length}');

  final sw = Stopwatch()..start();
  final osm = await OverpassService.fetchJunctions(bbox);
  print('OSM junctions: ${osm.junctions.length} (Overpass ${sw.elapsedMilliseconds}ms)');

  sw.reset();
  final result = AnchorMatcher.match(scanPx: scan, refGeo: osm.junctions);
  print('RANSAC ${sw.elapsedMilliseconds}ms');
  if (result == null) {
    print('NO MATCH');
    exitCode = 1;
    return;
  }
  print('=== ${result.inliers} התאמות | scale=${result.scaleMetersPerPx.toStringAsFixed(3)} m/px'
      ' | rot=${result.rotationDeg.toStringAsFixed(1)}° ===');
  for (final m in result.matches) {
    print('  px(${m.pixel.x.round()},${m.pixel.y.round()}) -> '
        '${m.world.latitude.toStringAsFixed(5)},${m.world.longitude.toStringAsFixed(5)}');
  }

  // שפיות: כל העוגנים חייבים להתלכד על טרנספורמציה אחת — בדיקת פיזור
  // שיורי (residual) גס לפי זוגות.
  if (result.matches.length >= 2) {
    final d = const Distance();
    final a = result.matches;
    var worst = 0.0;
    for (var i = 0; i < a.length; i++) {
      for (var j = i + 1; j < a.length; j++) {
        final pxDist =
            sqrt(pow(a[i].pixel.x - a[j].pixel.x, 2) + pow(a[i].pixel.y - a[j].pixel.y, 2));
        final mDist = d(a[i].world, a[j].world);
        if (pxDist > 1) {
          final ratio = mDist / pxDist; // m/px מקומי
          final dev = (ratio - result.scaleMetersPerPx).abs() / result.scaleMetersPerPx;
          if (dev > worst) worst = dev;
        }
      }
    }
    print('worst pairwise scale deviation: ${(worst * 100).toStringAsFixed(0)}%');
  }
}
