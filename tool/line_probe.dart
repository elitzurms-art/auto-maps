// רישום מבוסס-קווים: מתחקה קווי-כביש בסריקה, שולף קווי-OSM, מוצא
// טרנספורמציה לפי התאמת-וקטורים, ומשטח על ה-OSM לאימות.
// dart run tool/line_probe.dart "<image>" south west north east "<out.png>"
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';

import 'package:auto_maps/services/anchor_matcher.dart';
import 'package:auto_maps/services/overpass_service.dart';
import 'package:auto_maps/services/road_junction_detector.dart';

double lonPx(double lon, int z) => (lon + 180) / 360 * 256 * (1 << z);
double latPx(double lat, int z) {
  final s = sin(lat * pi / 180).clamp(-0.9999, 0.9999);
  return (0.5 - log((1 + s) / (1 - s)) / (4 * pi)) * 256 * (1 << z);
}

Future<void> main(List<String> args) async {
  final im = img.decodeImage(File(args[0]).readAsBytesSync())!;
  final bbox = (
    south: double.parse(args[1]),
    west: double.parse(args[2]),
    north: double.parse(args[3]),
    east: double.parse(args[4]),
  );
  final det = RoadJunctionDetector.detectFull(im);
  stdout.writeln('scan polylines: ${det.polylines.length}, roadPts: ${det.roadPoints.length}');
  final osm = await OverpassService.fetchJunctions(bbox);
  stdout.writeln('OSM roadLines: ${osm.roadLines.length}, roadPts: ${osm.roadPoints.length}');

  final hyps = AnchorMatcher.lineRegister(
    scanLines: det.polylines,
    refLines: osm.roadLines,
    scanRoad: det.roadPoints,
    refRoad: osm.roadPoints,
  );
  stdout.writeln('--- ${hyps.length} line hypotheses ---');
  for (final h in hyps) {
    stdout.writeln('rot=${h.rotationDeg.toStringAsFixed(1)}° '
        'scale=${h.scaleMetersPerPx.toStringAsFixed(3)} '
        'roadFit=${h.roadFitMeters.toStringAsFixed(1)}m');
  }
  if (hyps.isEmpty) {
    exitCode = 1;
    return;
  }
  final h = hyps.first;

  // שיטוח הסריקה על מוזאיקת-OSM לפי ההשערה הטובה.
  var z = 16;
  while (z > 12 &&
      max(lonPx(bbox.east, z) - lonPx(bbox.west, z),
              latPx(bbox.south, z) - latPx(bbox.north, z)) >
          1000) {
    z--;
  }
  final x0 = lonPx(bbox.west, z), y0 = latPx(bbox.north, z);
  final w = (lonPx(bbox.east, z) - x0).round(), hh = (latPx(bbox.south, z) - y0).round();
  final tx0 = (x0 / 256).floor(), ty0 = (y0 / 256).floor();
  final tx1 = ((x0 + w) / 256).floor(), ty1 = ((y0 + hh) / 256).floor();
  final canvas = img.Image(width: (tx1 - tx0 + 1) * 256, height: (ty1 - ty0 + 1) * 256, numChannels: 3);
  final fetches = <Future<void>>[];
  for (var tx = tx0; tx <= tx1; tx++) {
    for (var ty = ty0; ty <= ty1; ty++) {
      fetches.add(() async {
        final t = await _tile(z, tx, ty);
        if (t != null) img.compositeImage(canvas, t, dstX: (tx - tx0) * 256, dstY: (ty - ty0) * 256);
      }());
    }
  }
  await Future.wait(fetches);
  final osmCrop = img.copyCrop(canvas, x: (x0 - tx0 * 256).round(), y: (y0 - ty0 * 256).round(), width: w, height: hh);

  // world→scanPixel inverse (מ-a,b של ההשערה): px = Re/Im של (w-b)/a, y מהופך.
  final warp = img.Image.from(osmCrop);
  final aRe = h.aRe, aIm = h.aIm, den = aRe * aRe + aIm * aIm;
  final lat0 = h.lat0, lon0 = h.lon0, mLon = 111320.0 * cos(lat0 * pi / 180);
  for (var oy = 0; oy < hh; oy++) {
    for (var ox = 0; ox < w; ox++) {
      final wpx = x0 + ox, wpy = y0 + oy;
      final lon = wpx / (256 * (1 << z)) * 360 - 180;
      final tt = pi * (1 - 2 * wpy / (256 * (1 << z)));
      final lat = atan((exp(tt) - exp(-tt)) / 2) * 180 / pi;
      final wx = (lon - lon0) * mLon, wy = (lat - lat0) * 111320.0;
      final ux = wx - h.bRe, uy = wy - h.bIm;
      final sx = (ux * aRe + uy * aIm) / den;
      final syFlipped = (uy * aRe - ux * aIm) / den;
      final sy = -syFlipped;
      final rx = sx.round(), ry = sy.round();
      if (rx < 0 || ry < 0 || rx >= im.width || ry >= im.height) continue;
      final sp = im.getPixel(rx, ry);
      final op = warp.getPixel(ox, oy);
      warp.setPixelRgb(ox, oy, (sp.r + op.r) ~/ 2, (sp.g + op.g) ~/ 2, (sp.b + op.b) ~/ 2);
    }
  }
  final left = img.copyResize(im, width: 640);
  final rW = img.copyResize(warp, height: left.height);
  final combo = img.Image(width: left.width + rW.width + 20, height: left.height);
  img.fill(combo, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(combo, left, dstX: 0, dstY: 0);
  img.compositeImage(combo, rW, dstX: left.width + 20, dstY: 0);
  File(args[5]).writeAsBytesSync(img.encodePng(combo));
  stdout.writeln('wrote ${args[5]} (best rot=${h.rotationDeg.toStringAsFixed(1)} scale=${h.scaleMetersPerPx.toStringAsFixed(3)} roadFit=${h.roadFitMeters.toStringAsFixed(1)})');
}

Future<img.Image?> _tile(int z, int x, int y) async {
  try {
    final r = await http.get(Uri.parse('https://tile.openstreetmap.org/$z/$x/$y.png'),
        headers: {'User-Agent': 'auto_maps/1.0'}).timeout(const Duration(seconds: 20));
    if (r.statusCode == 200) return img.decodeImage(r.bodyBytes);
  } catch (_) {}
  return null;
}
