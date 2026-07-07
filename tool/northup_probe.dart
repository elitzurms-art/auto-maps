// מבחן ההשערה "המפה בזווית הנכונה": נועל סיבוב=0 (צפון-למעלה), מחפש רק
// קנה-מידה s והזזה b (מהמשואה הירוקה), מדרג לפי חפיפת-כבישים, ומשטח.
// dart run tool/northup_probe.dart "<image>" south west north east "<out.png>"
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';

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
  final osm = await OverpassService.fetchJunctions(bbox);

  // משואה ירוקה.
  var gx = 0.0, gy = 0.0, gn = 0;
  for (var y = 0; y < im.height; y += 4) {
    for (var x = 0; x < im.width; x += 4) {
      final p = im.getPixel(x, y);
      if (p.g > p.r + 20 && p.g > p.b + 20 && p.g > 120) { gx += x; gy += y; gn++; }
    }
  }
  final gS = Point(gx / gn, gy / gn);
  final gR = await OverpassService.fetchGreenCentroid(bbox);
  stdout.writeln('scanGreen=$gS refGreen=$gR');

  // מרכז-מטרים.
  var lat0 = 0.0, lon0 = 0.0;
  for (final g in osm.roadPoints) { lat0 += g.latitude; lon0 += g.longitude; }
  lat0 /= osm.roadPoints.length; lon0 /= osm.roadPoints.length;
  final mLon = 111320.0 * cos(lat0 * pi / 180);
  List<double> toM(LatLng g) => [(g.longitude - lon0) * mLon, (g.latitude - lat0) * 111320.0];
  // נקודות-כביש למטרים.
  final refR = [for (final g in osm.roadPoints) toM(g)];
  // סריקה: (x, -y).
  final scanR = [for (final p in det.roadPoints) [p.x, -p.y]];
  final gSm = [gS.x, -gS.y];
  final gRm = toM(gR!);

  // טווח קנה-מידה מהמוטות.
  double span(List<List<double>> pts) {
    var minX = 1e30, maxX = -1e30, minY = 1e30, maxY = -1e30;
    for (final p in pts) { minX = min(minX, p[0]); maxX = max(maxX, p[0]); minY = min(minY, p[1]); maxY = max(maxY, p[1]); }
    return sqrt(pow(maxX-minX,2)+pow(maxY-minY,2));
  }
  final exp = span(refR) / span(scanR);
  stdout.writeln('expScale=${exp.toStringAsFixed(3)}');

  // חיפוש קנה-מידה (סיבוב=0): b מהמשואה הירוקה. חפיפה חד-כיוונית מהירה.
  double roadFit(double s, double bx, double by) {
    final stepS = (scanR.length / 200).ceil();
    final stepR = (refR.length / 1500).ceil();
    var sum = 0.0; var n = 0;
    for (var i = 0; i < scanR.length; i += stepS) {
      final wx = s * scanR[i][0] + bx, wy = s * scanR[i][1] + by;
      var best = 1600.0;
      for (var j = 0; j < refR.length; j += stepR) {
        final d = pow(wx - refR[j][0], 2) + pow(wy - refR[j][1], 2);
        if (d < best) best = d.toDouble();
      }
      sum += sqrt(best); n++;
    }
    return sum / n;
  }
  // צמתי-סריקה (x,-y) וצמתי-OSM למטרים.
  final scanJ = [
    for (final f in det.features)
      if (f.kind == MapFeatureKind.junction || f.kind == MapFeatureKind.roundabout)
        [f.pos.x, -f.pos.y]
  ];
  final refJ = [for (final g in osm.junctions) toM(g)];

  // RANSAC נעול-סיבוב: זוג-סריקה + זוג-OSM שכיוונם מקביל (סיבוב 0) →
  // s=|dw|/|dz|, b מנקודה. ניקוד: כמה צמתי-סריקה נופלים ליד צומת-OSM.
  final rng = Random(7);
  var bestS = exp, bestBx = gRm[0] - exp * gSm[0], bestBy = gRm[1] - exp * gSm[1];
  var bestInl = -1;
  for (var iter = 0; iter < 200000; iter++) {
    final i = rng.nextInt(scanJ.length), k = rng.nextInt(scanJ.length);
    if (i == k) continue;
    final zx = scanJ[i][0] - scanJ[k][0], zy = scanJ[i][1] - scanJ[k][1];
    final zl = sqrt(zx*zx + zy*zy);
    if (zl < 50) continue;
    final j = rng.nextInt(refJ.length), l = rng.nextInt(refJ.length);
    if (j == l) continue;
    final wx = refJ[j][0] - refJ[l][0], wy = refJ[j][1] - refJ[l][1];
    final wl = sqrt(wx*wx + wy*wy);
    if (wl < 20) continue;
    // כיוון מקביל? (סיבוב 0)
    final cosang = (zx*wx + zy*wy) / (zl*wl);
    if (cosang < 0.985) continue; // < ~10°
    final s = wl / zl;
    if (s < exp*0.4 || s > exp*2.5) continue;
    final bx = refJ[j][0] - s*scanJ[i][0], by = refJ[j][1] - s*scanJ[i][1];
    var inl = 0;
    for (final z in scanJ) {
      final tx = s*z[0]+bx, ty = s*z[1]+by;
      var best = 900.0; // 30מ'
      for (final r in refJ) { final d = pow(tx-r[0],2)+pow(ty-r[1],2); if (d < best) best = d.toDouble(); }
      if (best < 900) inl++;
    }
    if (inl > bestInl) { bestInl = inl; bestS = s; bestBx = bx; bestBy = by; }
  }
  final bestFit = roadFit(bestS, bestBx, bestBy);
  stdout.writeln('BEST rot-locked RANSAC: scale=${bestS.toStringAsFixed(3)} inliers=$bestInl/${scanJ.length} roadFit=${bestFit.toStringAsFixed(1)}m');

  // שיטוח.
  var z = 16;
  while (z > 12 && max(lonPx(bbox.east, z) - lonPx(bbox.west, z), latPx(bbox.south, z) - latPx(bbox.north, z)) > 1000) { z--; }
  final x0 = lonPx(bbox.west, z), y0 = latPx(bbox.north, z);
  final w = (lonPx(bbox.east, z) - x0).round(), hh = (latPx(bbox.south, z) - y0).round();
  final tx0 = (x0/256).floor(), ty0 = (y0/256).floor(), tx1 = ((x0+w)/256).floor(), ty1 = ((y0+hh)/256).floor();
  final canvas = img.Image(width: (tx1-tx0+1)*256, height: (ty1-ty0+1)*256, numChannels: 3);
  final fetches = <Future<void>>[];
  for (var tx = tx0; tx <= tx1; tx++) { for (var ty = ty0; ty <= ty1; ty++) {
    fetches.add(() async { final t = await _tile(z, tx, ty); if (t != null) img.compositeImage(canvas, t, dstX: (tx-tx0)*256, dstY: (ty-ty0)*256); }());
  }}
  await Future.wait(fetches);
  final warp = img.copyCrop(canvas, x: (x0-tx0*256).round(), y: (y0-ty0*256).round(), width: w, height: hh);
  for (var oy = 0; oy < hh; oy++) { for (var ox = 0; ox < w; ox++) {
    final wpx = x0 + ox, wpy = y0 + oy;
    final lon = wpx / (256*(1<<z)) * 360 - 180;
    final tt = pi * (1 - 2*wpy/(256*(1<<z)));
    final lat = atan((exp2(tt) - exp2(-tt))/2) * 180/pi;
    final wx = (lon-lon0)*mLon, wy = (lat-lat0)*111320.0;
    final sx = (wx - bestBx)/bestS, syf = (wy - bestBy)/bestS, sy = -syf;
    final rx = sx.round(), ry = sy.round();
    if (rx<0||ry<0||rx>=im.width||ry>=im.height) continue;
    final sp = im.getPixel(rx, ry), op = warp.getPixel(ox, oy);
    warp.setPixelRgb(ox, oy, (sp.r+op.r)~/2, (sp.g+op.g)~/2, (sp.b+op.b)~/2);
  }}
  final left = img.copyResize(im, width: 640);
  final rW = img.copyResize(warp, height: left.height);
  final combo = img.Image(width: left.width + rW.width + 20, height: left.height);
  img.fill(combo, color: img.ColorRgb8(255,255,255));
  img.compositeImage(combo, left, dstX: 0, dstY: 0);
  img.compositeImage(combo, rW, dstX: left.width+20, dstY: 0);
  File(args[5]).writeAsBytesSync(img.encodePng(combo));
  stdout.writeln('wrote ${args[5]}');
}

double exp2(double x) => exp(x);

Future<img.Image?> _tile(int z, int x, int y) async {
  try {
    final r = await http.get(Uri.parse('https://tile.openstreetmap.org/$z/$x/$y.png'), headers: {'User-Agent': 'auto_maps/1.0'}).timeout(const Duration(seconds: 20));
    if (r.statusCode == 200) return img.decodeImage(r.bodyBytes);
  } catch (_) {}
  return null;
}
