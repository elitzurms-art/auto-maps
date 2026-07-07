// אימות ויזואלי: מצייר את העוגנים המותאמים על הסריקה (שמאל) ומולם על
// מוזאיקת-OSM אמיתית של האזור (ימין). אם התבניות תואמות (עד סיבוב) —
// ההתאמה נכונה. הרצה:
//   dart run tool/match_verify.dart "<image>" south west north east "<out.png>"
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
  final scan = <Point<double>>[];
  final scanRound = <bool>[];
  for (final f in det.features) {
    if (f.kind == MapFeatureKind.junction ||
        f.kind == MapFeatureKind.roundabout) {
      scan.add(f.pos);
      scanRound.add(f.kind == MapFeatureKind.roundabout);
    }
  }
  final osm = await OverpassService.fetchJunctions(bbox);
  final res = AnchorMatcher.match(
    scanPx: scan,
    refGeo: osm.junctions,
    scanRound: scanRound,
    refRound: osm.isRoundabout,
    scanRoad: det.roadPoints,
    refRoad: osm.roadPoints,
    roadGateMeters: 9999, // אבחון: לא לדחות — רוצים לראות את הבחירה
  );
  if (res == null) {
    print('NO MATCH (road-gate rejected — ambiguous)');
    exitCode = 1;
    return;
  }
  print('${res.inliers} matches, scale ${res.scaleMetersPerPx.toStringAsFixed(3)}');

  // שמאל: הסריקה מוקטנת ל-700 עם עיגולים ממוספרים.
  final left = img.copyResize(im,
      width: im.width >= im.height ? 700 : null,
      height: im.width >= im.height ? null : 700);
  final sx = left.width / im.width, sy = left.height / im.height;
  final magenta = img.ColorRgb8(230, 0, 200);
  for (var i = 0; i < res.matches.length; i++) {
    final x = (res.matches[i].pixel.x * sx).round();
    final y = (res.matches[i].pixel.y * sy).round();
    img.drawCircle(left, x: x, y: y, radius: 12, color: magenta);
    img.fillCircle(left, x: x, y: y, radius: 3, color: magenta);
    img.drawString(left, '${i + 1}',
        font: img.arial24, x: x + 10, y: y - 26, color: magenta);
  }

  // ימin: מוזאיקת OSM של ה-bbox בזום מתאים.
  var z = 16;
  while (z > 12 &&
      max(lonPx(bbox.east, z) - lonPx(bbox.west, z),
              latPx(bbox.south, z) - latPx(bbox.north, z)) >
          900) {
    z--;
  }
  final x0 = lonPx(bbox.west, z), y0 = latPx(bbox.north, z);
  final w = (lonPx(bbox.east, z) - x0).round();
  final h = (latPx(bbox.south, z) - y0).round();
  final tx0 = (x0 / 256).floor(), ty0 = (y0 / 256).floor();
  final tx1 = ((x0 + w) / 256).floor(), ty1 = ((y0 + h) / 256).floor();
  final canvas = img.Image(
      width: (tx1 - tx0 + 1) * 256, height: (ty1 - ty0 + 1) * 256, numChannels: 3);
  final fetches = <Future<void>>[];
  for (var tx = tx0; tx <= tx1; tx++) {
    for (var ty = ty0; ty <= ty1; ty++) {
      fetches.add(() async {
        final tile = await _tile(z, tx, ty);
        if (tile != null) {
          img.compositeImage(canvas, tile,
              dstX: (tx - tx0) * 256, dstY: (ty - ty0) * 256);
        }
      }());
    }
  }
  await Future.wait(fetches);
  var right = img.copyCrop(canvas,
      x: (x0 - tx0 * 256).round(), y: (y0 - ty0 * 256).round(), width: w, height: h);
  for (var i = 0; i < res.matches.length; i++) {
    final m = res.matches[i];
    final x = (lonPx(m.world.longitude, z) - x0).round();
    final y = (latPx(m.world.latitude, z) - y0).round();
    img.drawCircle(right, x: x, y: y, radius: 10, color: magenta);
    img.fillCircle(right, x: x, y: y, radius: 3, color: magenta);
    img.drawString(right, '${i + 1}',
        font: img.arial24, x: x + 8, y: y - 26, color: magenta);
  }

  // ── פאנל 3: שיטוח (warp) הסריקה על ה-OSM לפי העוגנים — המבחן המכריע:
  //    אם הכבישים מתיישרים, הסיבוב נכון; אם מסובב, זו אמביגואיות-הסיבוב.
  //    world→scanPixel affine (least-squares) → inverse-map כל פיקסל-OSM.
  final n = res.matches.length;
  // world מקומי (מטרים) סביב מרכז, כמו במַתאם.
  var lat0 = 0.0, lon0 = 0.0;
  for (final m in res.matches) {
    lat0 += m.world.latitude;
    lon0 += m.world.longitude;
  }
  lat0 /= n;
  lon0 /= n;
  final mLat = 111320.0, mLon = 111320.0 * cos(lat0 * pi / 180);
  // פותרים [wx,wy,1]→[px] ו-→[py] ב-least squares (6 מקדמים).
  final A = <List<double>>[], bx = <double>[], by = <double>[];
  for (final m in res.matches) {
    final wx = (m.world.longitude - lon0) * mLon;
    final wy = (m.world.latitude - lat0) * mLat;
    A.add([wx, wy, 1]);
    bx.add(m.pixel.x);
    by.add(m.pixel.y);
  }
  final cx = _lstsq3(A, bx), cy = _lstsq3(A, by);
  final osmCrop = img.copyResize(right, height: left.height); // כבר יש right
  // right הנוכחי הוא ה-OSM עם סמנים; נשתמש במקור לפני הסמנים? פשוט
  // משטחים על עותק שלו.
  final warp = img.Image.from(right);
  for (var oy = 0; oy < right.height; oy++) {
    for (var ox = 0; ox < right.width; ox++) {
      // פיקסל-OSM → world-mercator → מטרים מקומיים
      final worldX = x0 + ox * (w / right.width);
      final worldY = y0 + oy * (h / right.height);
      final lon = worldX / (256 * (1 << z)) * 360 - 180;
      final t = pi * (1 - 2 * worldY / (256 * (1 << z)));
      final lat = atan((exp(t) - exp(-t)) / 2) * 180 / pi;
      final wx = (lon - lon0) * mLon, wy = (lat - lat0) * mLat;
      final sx = (cx[0] * wx + cx[1] * wy + cx[2]);
      final sy = (cy[0] * wx + cy[1] * wy + cy[2]);
      final rx = sx.round(), ry = sy.round();
      if (rx < 0 || ry < 0 || rx >= im.width || ry >= im.height) continue;
      final sp = im.getPixel(rx, ry);
      final op = warp.getPixel(ox, oy);
      // blend 50%
      warp.setPixelRgb(ox, oy, (sp.r + op.r) ~/ 2, (sp.g + op.g) ~/ 2,
          (sp.b + op.b) ~/ 2);
    }
  }

  // הרכבה: סריקה | OSM+סמנים | שיטוח-חופף.
  right = img.copyResize(right, height: left.height);
  final warpR = img.copyResize(warp, height: left.height);
  final combo = img.Image(
      width: left.width + right.width + warpR.width + 40, height: left.height);
  img.fill(combo, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(combo, left, dstX: 0, dstY: 0);
  img.compositeImage(combo, right, dstX: left.width + 20, dstY: 0);
  img.compositeImage(combo, warpR, dstX: left.width + right.width + 40, dstY: 0);
  File(args[5]).writeAsBytesSync(img.encodePng(combo));
  print('wrote ${args[5]} (scale=${res.scaleMetersPerPx.toStringAsFixed(3)} '
      'rot=${res.rotationDeg.toStringAsFixed(1)})');
}

// least-squares פתרון של A·c = b כאשר A הוא Nx3 (נורמל-משוואות 3x3).
List<double> _lstsq3(List<List<double>> a, List<double> b) {
  final ata = List.generate(3, (_) => List.filled(3, 0.0));
  final atb = List.filled(3, 0.0);
  for (var r = 0; r < a.length; r++) {
    for (var i = 0; i < 3; i++) {
      atb[i] += a[r][i] * b[r];
      for (var j = 0; j < 3; j++) {
        ata[i][j] += a[r][i] * a[r][j];
      }
    }
  }
  // אלימינציית גאוס 3x3
  for (var i = 0; i < 3; i++) {
    var piv = ata[i][i];
    if (piv.abs() < 1e-12) piv = 1e-12;
    for (var j = 0; j < 3; j++) {
      ata[i][j] /= piv;
    }
    atb[i] /= piv;
    for (var k = 0; k < 3; k++) {
      if (k == i) continue;
      final f = ata[k][i];
      for (var j = 0; j < 3; j++) {
        ata[k][j] -= f * ata[i][j];
      }
      atb[k] -= f * atb[i];
    }
  }
  return atb;
}

Future<img.Image?> _tile(int z, int x, int y) async {
  final urls = [
    'https://tile.openstreetmap.org/$z/$x/$y.png',
    'https://a.tile.openstreetmap.de/$z/$x/$y.png',
  ];
  final done = Completer<img.Image?>();
  var fails = 0;
  for (final url in urls) {
    () async {
      try {
        final r = await http.get(Uri.parse(url),
            headers: {'User-Agent': 'auto_maps/1.0'}).timeout(const Duration(seconds: 20));
        if (r.statusCode == 200 && !done.isCompleted) {
          done.complete(img.decodeImage(r.bodyBytes));
          return;
        }
      } catch (_) {}
      if (++fails == urls.length && !done.isCompleted) done.complete(null);
    }();
  }
  return done.future;
}
