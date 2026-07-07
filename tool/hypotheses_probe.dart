// מפת-ההשערות: אילו אשכולות-זווית RANSAC מוצא, ומה אומר שובר-השוויון
// הירוק (מרכז-הכתם-הירוק בסריקה מול מרכז-הירוק ב-OSM) על כל השערה.
// הרצה: dart run tool/hypotheses_probe.dart "<image>" south west north east
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
  final out = StringBuffer();

  final det = RoadJunctionDetector.detectFull(im);
  final scan = <Point<double>>[];
  for (final f in det.features) {
    if (f.kind == MapFeatureKind.junction ||
        f.kind == MapFeatureKind.roundabout) {
      scan.add(f.pos);
    }
  }
  out.writeln('scan junctions: ${scan.length}, roadPts: ${det.roadPoints.length}');

  final osm = await OverpassService.fetchJunctions(bbox);
  out.writeln('OSM junctions: ${osm.junctions.length}, roadPts: ${osm.roadPoints.length}');

  // ── שובר-שוויון ירוק: מרכז הפיקסלים הירוקים בסריקה ──
  var gx = 0.0, gy = 0.0, gn = 0;
  final wImg = im.width, hImg = im.height;
  for (var y = 0; y < hImg; y += 4) {
    for (var x = 0; x < wImg; x += 4) {
      final p = im.getPixel(x, y);
      if (p.g > p.r + 20 && p.g > p.b + 20 && p.g > 120) {
        gx += x.toDouble();
        gy += y.toDouble();
        gn++;
      }
    }
  }
  final hasScanGreen = gn > (wImg / 4) * (hImg / 4) * 0.01;
  final scanGreen =
      hasScanGreen ? Point(gx / gn, gy / gn) : null;
  out.writeln('scan green: n=$gn center=$scanGreen');

  // ירוק ב-OSM (Overpass landuse/leisure)
  final refGreen = await _fetchOsmGreen(bbox);
  out.writeln('OSM green centroid: $refGreen');

  final hyps = (scanGreen != null && refGreen != null)
      ? AnchorMatcher.hypothesesWithBeacon(
          scanPx: scan,
          refGeo: osm.junctions,
          scanBeacon: scanGreen,
          refBeacon: refGreen,
          scanRoad: det.roadPoints,
          refRoad: osm.roadPoints,
        )
      : AnchorMatcher.hypotheses(
          scanPx: scan,
          refGeo: osm.junctions,
          scanRoad: det.roadPoints,
          refRoad: osm.roadPoints,
        );
  out.writeln('--- ${hyps.length} hypotheses (beacon=${scanGreen != null && refGreen != null}) ---');
  const d = Distance();
  for (final h in hyps) {
    var line = 'rot=${h.rotationDeg.toStringAsFixed(1)}° '
        'scale=${h.scaleMetersPerPx.toStringAsFixed(3)} '
        'inliers=${h.inliers} roadFit=${h.roadFitMeters.toStringAsFixed(1)}m';
    if (scanGreen != null && refGreen != null) {
      final projected = h.project(scanGreen);
      final greenErr = d(projected, refGreen);
      line += ' | greenErr=${greenErr.round()}m';
    }
    out.writeln(line);
  }
  final f = File(r'C:\auto maps\tool\_hyps_result.txt');
  f.writeAsStringSync(out.toString());
  stdout.write(out.toString());
}

Future<LatLng?> _fetchOsmGreen(GeoBbox bbox) async {
  try {
    final green = await OverpassService.fetchGreenCentroid(bbox);
    return green;
  } catch (e) {
    stderr.writeln('green fetch failed: $e');
    return null;
  }
}
