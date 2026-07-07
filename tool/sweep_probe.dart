// בודק את סריקת-הזווית (registerSweep) על מפה מסובבת: מוצא את הזווית,
// מיישם, ומשטח על OSM לאימות ויזואלי.
// dart run tool/sweep_probe.dart "<image>" south west north east "<out.png>"
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

Future<img.Image?> tile(int z, int x, int y) async {
  try {
    final r = await http.get(
        Uri.parse('https://tile.openstreetmap.org/$z/$x/$y.png'),
        headers: {'User-Agent': 'auto_maps/1.0'}).timeout(const Duration(seconds: 20));
    if (r.statusCode == 200) return img.decodeImage(r.bodyBytes);
  } catch (_) {}
  return null;
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
  final scan = <Point<double>>[];
  final rnd = <bool>[];
  for (final f in det.features) {
    if (f.kind == MapFeatureKind.junction ||
        f.kind == MapFeatureKind.roundabout) {
      scan.add(f.pos);
      rnd.add(f.kind == MapFeatureKind.roundabout);
    }
  }
  stdout.writeln('scan junctions: ${scan.length}, roadPts: ${det.roadPoints.length}');
  final osm = await OverpassService.fetchJunctions(bbox);
  stdout.writeln('OSM junctions: ${osm.junctions.length}');

  final res = AnchorMatcher.registerSweep(
    scanPx: scan,
    refGeo: osm.junctions,
    scanRound: rnd,
    refRound: osm.isRoundabout,
    scanRoad: det.roadPoints,
    refRoad: osm.roadPoints,
  );
  if (res == null) {
    stdout.writeln('SWEEP: null');
    exitCode = 1;
    return;
  }
  stdout.writeln('SWEEP: matches=${res.matches.length} '
      'scale=${res.scaleMetersPerPx.toStringAsFixed(3)} '
      'rot=${res.rotationDeg.toStringAsFixed(1)}°');

  // fit s,b (rot-locked at found angle) from matches for the warp.
  var lat0 = 0.0, lon0 = 0.0;
  for (final g in osm.roadPoints) {
    lat0 += g.latitude;
    lon0 += g.longitude;
  }
  lat0 /= osm.roadPoints.length;
  lon0 /= osm.roadPoints.length;
  final mLon = 111320.0 * cos(lat0 * pi / 180);
  double wx(double lon) => (lon - lon0) * mLon;
  double wy(double lat) => (lat - lat0) * 111320.0;
  // affine a (complex) + b from matches: w = a·z + b, z=(x,-y).
  final theta = res.rotationDeg * pi / 180;
  final rre = cos(theta), rim = sin(theta);
  // solve scale s and b: use two-point closed form via least squares on s.
  var zcx = 0.0, zcy = 0.0, wcx = 0.0, wcy = 0.0;
  final n = res.matches.length.toDouble();
  for (final m in res.matches) {
    // u = rot·z
    final zx = m.pixel.x, zy = -m.pixel.y;
    final ux = rre * zx - rim * zy, uy = rim * zx + rre * zy;
    zcx += ux;
    zcy += uy;
    wcx += wx(m.world.longitude);
    wcy += wy(m.world.latitude);
  }
  zcx /= n;
  zcy /= n;
  wcx /= n;
  wcy /= n;
  var num = 0.0, den = 0.0;
  for (final m in res.matches) {
    final zx = m.pixel.x, zy = -m.pixel.y;
    final ux = rre * zx - rim * zy - zcx, uy = rim * zx + rre * zy - zcy;
    final wpx = wx(m.world.longitude) - wcx, wpy = wy(m.world.latitude) - wcy;
    num += ux * wpx + uy * wpy;
    den += ux * ux + uy * uy;
  }
  final s = num / den;
  final aRe = s * rre, aIm = s * rim; // a = s·rot
  final bx = wcx - s * zcx, by = wcy - s * zcy;
  final adet = aRe * aRe + aIm * aIm;

  var z = 16;
  while (z > 12 &&
      max(lonPx(bbox.east, z) - lonPx(bbox.west, z),
              latPx(bbox.south, z) - latPx(bbox.north, z)) >
          1000) {
    z--;
  }
  final x0 = lonPx(bbox.west, z), y0 = latPx(bbox.north, z);
  final w = (lonPx(bbox.east, z) - x0).round(),
      hh = (latPx(bbox.south, z) - y0).round();
  final tx0 = (x0 / 256).floor(),
      ty0 = (y0 / 256).floor(),
      tx1 = ((x0 + w) / 256).floor(),
      ty1 = ((y0 + hh) / 256).floor();
  final canvas = img.Image(
      width: (tx1 - tx0 + 1) * 256, height: (ty1 - ty0 + 1) * 256, numChannels: 3);
  final fs = <Future<void>>[];
  for (var tx = tx0; tx <= tx1; tx++) {
    for (var ty = ty0; ty <= ty1; ty++) {
      fs.add(() async {
        final t = await tile(z, tx, ty);
        if (t != null) {
          img.compositeImage(canvas, t,
              dstX: (tx - tx0) * 256, dstY: (ty - ty0) * 256);
        }
      }());
    }
  }
  await Future.wait(fs);
  final warp = img.copyCrop(canvas,
      x: (x0 - tx0 * 256).round(),
      y: (y0 - ty0 * 256).round(),
      width: w,
      height: hh);
  for (var oy = 0; oy < hh; oy++) {
    for (var ox = 0; ox < w; ox++) {
      final wpx = x0 + ox, wpy = y0 + oy;
      final lon = wpx / (256 * (1 << z)) * 360 - 180;
      final tt = pi * (1 - 2 * wpy / (256 * (1 << z)));
      final lat = atan((exp(tt) - exp(-tt)) / 2) * 180 / pi;
      final X = wx(lon), Y = wy(lat);
      // z = a^{-1}(w - b): ((w-b)·conj(a))/|a|²
      final ux = X - bx, uy = Y - by;
      final sx = (ux * aRe + uy * aIm) / adet;
      final syFlip = (uy * aRe - ux * aIm) / adet;
      final px = sx.round(), py = (-syFlip).round();
      if (px < 0 || py < 0 || px >= im.width || py >= im.height) continue;
      final sp = im.getPixel(px, py), op = warp.getPixel(ox, oy);
      warp.setPixelRgb(
          ox, oy, (sp.r + op.r) ~/ 2, (sp.g + op.g) ~/ 2, (sp.b + op.b) ~/ 2);
    }
  }
  final left = img.copyResize(im, width: 640);
  final rW = img.copyResize(warp, height: left.height);
  final combo = img.Image(width: left.width + rW.width + 20, height: left.height);
  img.fill(combo, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(combo, left, dstX: 0, dstY: 0);
  img.compositeImage(combo, rW, dstX: left.width + 20, dstY: 0);
  File(args[5]).writeAsBytesSync(img.encodePng(combo));
  stdout.writeln('wrote ${args[5]}');
}
