import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// תיבה גיאוגרפית (WGS84).
typedef GeoBbox = ({double south, double west, double north, double east});

/// שליפת **צמתי-כביש וקטוריים** מ-OpenStreetMap דרך Overpass API — במקום
/// ניתוח-פיקסלים של אריחים. צומת = צומת-גרף שבו נפגשים ≥2 קטעי-דרך,
/// עם קואורדינטת lat/lon **מדויקת**. מחזיר גם את גרף-הקִשוריות (איזה
/// צמתים מחוברים ישירות בכביש) — לאילוץ ההתאמה.
class OverpassService {
  // כמה שרתי-Overpass; נשלחת בקשה במקביל לכולם והמהיר שמחזיר 200 מנצח —
  // עמיד לשרת איטי/חסום ולבעיות-רשת נקודתיות (למשל IPv6 שנתקע על חלק
  // מהשרתים בסביבות מסוימות).
  static const _endpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
    'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
  ];

  static const _userAgent = 'auto_maps/1.0 (github.com/elitzurms-art/auto-maps)';

  /// סוגי-כביש שנשלפים — הדרכים שמצוירות במפת-יישוב (בלי שבילים/מדרגות).
  static const _highwayRegex =
      '^(motorway|trunk|primary|secondary|tertiary|unclassified|'
      'residential|living_street|service|road)\$';

  /// צומת מאותר: מיקום + מספר-סידורי + שכנים (אינדקסים) בגרף הכבישים.
  /// השכנים משמשים לאילוץ-טופולוגיה בהתאמה. [isRoundabout] מסמן אילו
  /// צמתים הם מרכזי-כיכר — לאילוץ כיכר↔כיכר בהתאמה.
  final List<LatLng> junctions;
  final List<Set<int>> neighbors;
  final List<bool> isRoundabout;

  /// נקודות-כביש מצופפות (כל ~15מ' לאורך כל דרך) — צורת רשת-הכבישים,
  /// לשבירת אמביגואיית-הסיבוב (חפיפת-כבישים במַתאם).
  final List<LatLng> roadPoints;

  /// קווי-כביש (פוליגונים לפי דרך) — צורת הרשת כווקטורים, לרישום
  /// מבוסס-קווים (כביש ארוך יחיד נותן כיוון+קנה-מידה מהתאמה אחת).
  final List<List<LatLng>> roadLines;

  OverpassService._(this.junctions, this.neighbors, this.isRoundabout,
      this.roadPoints, this.roadLines);

  /// שולף את רשת-הכבישים ב-[bbox], מחשב צמתים (client-side מ-`out geom`)
  /// ומאשכל צמתים קרובים (< [clusterMeters]). זורק על כשל-רשת.
  static Future<OverpassService> fetchJunctions(
    GeoBbox bbox, {
    double clusterMeters = 18,
  }) async {
    final query =
        '[out:json][timeout:60];'
        '(way["highway"~"$_highwayRegex"]'
        '(${bbox.south},${bbox.west},${bbox.north},${bbox.east}););'
        'out geom;';

    final body = await _post(query);
    return parseJunctions(body, clusterMeters: clusterMeters);
  }

  /// פרסור תשובת-Overpass (`out geom`) לצמתים+קִשוריות. חשוף לבדיקות
  /// (הזנת JSON שנשלף בנפרד) ולעקיפת בעיות-רשת של הסביבה.
  static OverpassService parseJunctions(
    String body, {
    double clusterMeters = 18,
  }) {
    final elements = (jsonDecode(body)['elements'] as List)
        .cast<Map<String, dynamic>>();

    // מעבר ראשון: כיכרות. דרך עם junction=roundabout/circular = טבעת;
    // מרכז-הכיכר = צנטרואיד הטבעת (נקודה אחת), ונודי-הטבעת עצמם מוחרגים
    // מהצמתים הרגילים — אחרת כיכר אחת יוצרת אשכול צמתים במקום נקודה אחת
    // (וזה מה שגרם לכיכר-בסריקה להתאים לצומת-רגיל).
    final roundaboutNodes = <int>{};
    final roundaboutCenters = <LatLng>[];
    for (final w in elements) {
      if (w['type'] != 'way') continue;
      final j = (w['tags'] as Map?)?['junction'];
      if (j != 'roundabout' && j != 'circular') continue;
      final geom = (w['geometry'] as List?)?.cast<Map<String, dynamic>>();
      final ids = (w['nodes'] as List?)?.cast<int>();
      if (geom == null || geom.isEmpty || ids == null) continue;
      var lat = 0.0, lon = 0.0;
      for (final g in geom) {
        lat += (g['lat'] as num).toDouble();
        lon += (g['lon'] as num).toDouble();
      }
      roundaboutCenters.add(LatLng(lat / geom.length, lon / geom.length));
      roundaboutNodes.addAll(ids);
    }

    // ספירת-הופעות של כל צומת-רשת + קִשוריות בין צמתי-רשת סמוכים בדרך.
    // נודי-טבעת מוחרגים (מיוצגים ע"י מרכז-הכיכר). ובמקביל: ציפוף
    // נקודות-כביש (כל ~15מ') לאורך כל דרך — לחפיפת-הכבישים.
    final dist = const Distance();
    final roadPoints = <LatLng>[];
    final roadLines = <List<LatLng>>[];
    final nodeCount = <int, int>{};
    final nodeCoord = <int, LatLng>{};
    final nodeAdj = <int, Set<int>>{};
    for (final w in elements) {
      if (w['type'] != 'way') continue;
      final ids = (w['nodes'] as List?)?.cast<int>();
      final geom = (w['geometry'] as List?)?.cast<Map<String, dynamic>>();
      if (ids == null || geom == null || ids.length != geom.length) continue;
      roadLines.add([
        for (final g in geom)
          LatLng((g['lat'] as num).toDouble(), (g['lon'] as num).toDouble()),
      ]);
      LatLng? prev;
      for (var i = 0; i < ids.length; i++) {
        final id = ids[i];
        final coord = LatLng(
          (geom[i]['lat'] as num).toDouble(),
          (geom[i]['lon'] as num).toDouble(),
        );
        // ציפוף נקודות-כביש בין הקודקוד הקודם לנוכחי (כל 15מ').
        if (prev != null) {
          final d = dist(prev, coord);
          final steps = (d / 15).ceil().clamp(1, 40);
          for (var s = 1; s <= steps; s++) {
            final t = s / steps;
            roadPoints.add(LatLng(
              prev.latitude + (coord.latitude - prev.latitude) * t,
              prev.longitude + (coord.longitude - prev.longitude) * t,
            ));
          }
        } else {
          roadPoints.add(coord);
        }
        prev = coord;
        if (roundaboutNodes.contains(id)) continue;
        nodeCount[id] = (nodeCount[id] ?? 0) + 1;
        nodeCoord[id] = coord;
        if (i > 0 && !roundaboutNodes.contains(ids[i - 1])) {
          nodeAdj.putIfAbsent(id, () => {}).add(ids[i - 1]);
          nodeAdj.putIfAbsent(ids[i - 1], () => {}).add(id);
        }
      }
    }

    // צומת אמיתי = מופיע ב-≥2 דרכים (הצטלבות) או דרגת-גרף ≥3.
    final junctionIds = <int>[
      for (final e in nodeCount.entries)
        if (e.value >= 2 || (nodeAdj[e.key]?.length ?? 0) >= 3) e.key,
    ];

    // אשכול צמתים קרובים (הצטלבות שמיוצגת בכמה node-ים) → מרכז ממוזג.
    final used = <int>{};
    final clusters = <List<int>>[];
    for (final id in junctionIds) {
      if (used.contains(id)) continue;
      final group = <int>[id];
      used.add(id);
      for (final other in junctionIds) {
        if (used.contains(other)) continue;
        if (dist(nodeCoord[id]!, nodeCoord[other]!) <= clusterMeters) {
          group.add(other);
          used.add(other);
        }
      }
      clusters.add(group);
    }

    // מיפוי node→אינדקס-אשכול, ואיחוד קִשוריות ברמת-אשכול.
    final nodeToCluster = <int, int>{};
    for (var c = 0; c < clusters.length; c++) {
      for (final id in clusters[c]) {
        nodeToCluster[id] = c;
      }
    }
    final junctions = <LatLng>[];
    final neighbors = <Set<int>>[];
    final isRoundabout = <bool>[];
    for (var c = 0; c < clusters.length; c++) {
      var lat = 0.0, lon = 0.0;
      final adj = <int>{};
      for (final id in clusters[c]) {
        lat += nodeCoord[id]!.latitude;
        lon += nodeCoord[id]!.longitude;
        for (final n in nodeAdj[id] ?? const <int>{}) {
          final nc = nodeToCluster[n];
          if (nc != null && nc != c) adj.add(nc);
        }
      }
      junctions.add(LatLng(lat / clusters[c].length, lon / clusters[c].length));
      neighbors.add(adj);
      isRoundabout.add(false);
    }
    // מרכזי-הכיכר נוספים כצמתים מסומנים (בלי קִשוריות-גרף — לא נדרשת).
    for (final center in roundaboutCenters) {
      junctions.add(center);
      neighbors.add(const {});
      isRoundabout.add(true);
    }

    return OverpassService._(
        junctions, neighbors, isRoundabout, roadPoints, roadLines);
  }

  /// מרכז השטחים הירוקים ב-[bbox] (landuse/leisure) — "מצפן" אסימטרי
  /// לשבירת אמביגואיית-הסיבוב: ההשערה הנכונה ממפה את הכתם-הירוק שבסריקה
  /// אל הירוק האמיתי. null כשאין ירוק מספק.
  static Future<LatLng?> fetchGreenCentroid(GeoBbox bbox) async {
    final query =
        '[out:json][timeout:45];('
        'way["landuse"~"^(grass|meadow|recreation_ground|farmland|orchard|'
        'vineyard|forest|village_green)\$"]'
        '(${bbox.south},${bbox.west},${bbox.north},${bbox.east});'
        'way["leisure"~"^(park|pitch|garden|playground|sports_centre)\$"]'
        '(${bbox.south},${bbox.west},${bbox.north},${bbox.east});'
        ');out geom;';
    final body = await _post(query);
    final elements =
        (jsonDecode(body)['elements'] as List).cast<Map<String, dynamic>>();
    // צנטרואיד משוקלל-שטח (שטח מקורב לפי נוסחת-שרוך על geom).
    var sumLat = 0.0, sumLon = 0.0, sumW = 0.0;
    for (final w in elements) {
      final geom = (w['geometry'] as List?)?.cast<Map<String, dynamic>>();
      if (geom == null || geom.length < 3) continue;
      var area = 0.0, cLat = 0.0, cLon = 0.0;
      for (var i = 0; i < geom.length; i++) {
        final a = geom[i], b = geom[(i + 1) % geom.length];
        final cross = (a['lon'] as num).toDouble() * (b['lat'] as num) -
            (b['lon'] as num).toDouble() * (a['lat'] as num);
        area += cross.toDouble();
        cLat += (a['lat'] as num).toDouble();
        cLon += (a['lon'] as num).toDouble();
      }
      final wgt = area.abs();
      if (wgt < 1e-12) continue;
      sumLat += (cLat / geom.length) * wgt;
      sumLon += (cLon / geom.length) * wgt;
      sumW += wgt;
    }
    if (sumW < 1e-12) return null;
    return LatLng(sumLat / sumW, sumLon / sumW);
  }

  /// צנטרואידים של שטחי-ירק ומים ב-[bbox] — **נקודה לכל פוליגון**, מסווגת
  /// ל-`green`/`water`. משמש כ"מצפן" רב-נקודתי לרישום (כתמי-ירק/מים בסריקה
  /// ↔ הפוליגונים האמיתיים). שאילתה אחת; סיווג לפי התגים; מסנן פוליגוני-רעש
  /// זעירים; ממוין לפי שטח יורד (הגדולים תחילה).
  static Future<List<({LatLng center, String kind})>> fetchLanduseCentroids(
    GeoBbox bbox,
  ) async {
    final bb = '(${bbox.south},${bbox.west},${bbox.north},${bbox.east})';
    final query =
        '[out:json][timeout:60];('
        'way["landuse"~"^(grass|meadow|recreation_ground|farmland|orchard|'
        'vineyard|forest|village_green|cemetery|reservoir)\$"]$bb;'
        'way["leisure"~"^(park|pitch|garden|playground|sports_centre|'
        'golf_course|stadium|swimming_pool)\$"]$bb;'
        'way["natural"~"^(wood|water)\$"]$bb;'
        ');out geom;';
    final body = await _post(query);
    final elements =
        (jsonDecode(body)['elements'] as List).cast<Map<String, dynamic>>();
    // סף-שטח מינימלי (בערך deg²) לסינון פוליגוני-רעש זעירים.
    const minArea = 1e-8;
    final regions = <({LatLng center, String kind, double area})>[];
    for (final w in elements) {
      final geom = (w['geometry'] as List?)?.cast<Map<String, dynamic>>();
      if (geom == null || geom.length < 3) continue;
      // צנטרואיד משוקלל-שטח פר-פוליגון (נוסחת-שרוך, כמו fetchGreenCentroid).
      var area = 0.0, cLat = 0.0, cLon = 0.0;
      for (var i = 0; i < geom.length; i++) {
        final a = geom[i], b = geom[(i + 1) % geom.length];
        final cross = (a['lon'] as num).toDouble() * (b['lat'] as num) -
            (b['lon'] as num).toDouble() * (a['lat'] as num);
        area += cross.toDouble();
        cLat += (a['lat'] as num).toDouble();
        cLon += (a['lon'] as num).toDouble();
      }
      final wgt = area.abs();
      if (wgt < minArea) continue;
      // סיווג לפי התגים: מים (natural=water / landuse=reservoir /
      // leisure=swimming_pool) — אחרת ירוק.
      final tags = (w['tags'] as Map?)?.cast<String, dynamic>() ?? const {};
      final isWater = tags['natural'] == 'water' ||
          tags['landuse'] == 'reservoir' ||
          tags['leisure'] == 'swimming_pool';
      regions.add((
        center: LatLng(cLat / geom.length, cLon / geom.length),
        kind: isWater ? 'water' : 'green',
        area: wgt,
      ));
    }
    // הגדולים תחילה.
    regions.sort((a, b) => b.area.compareTo(a.area));
    return [for (final r in regions) (center: r.center, kind: r.kind)];
  }

  /// נקודות-מִתאר של גבול-היישוב ב-[bbox] — הפוליגון הגדול-בשטח מבין
  /// שטחי-מגורים/יישוב/גבול, מצופף כל ~15מ' לאורך הטבעת (כמו roadPoints).
  /// משמש לאילוץ קנה-מידה/מיקום ברישום. רשימה ריקה כשלא נמצא מִתאר (לא זורק).
  static Future<List<LatLng>> fetchPerimeterPoints(GeoBbox bbox) async {
    final bb = '(${bbox.south},${bbox.west},${bbox.north},${bbox.east})';
    final query =
        '[out:json][timeout:60];('
        'way["landuse"="residential"]$bb;'
        'way["place"~"^(village|hamlet|town|isolated_dwelling)\$"]$bb;'
        'way["boundary"]$bb;'
        'relation["landuse"="residential"]$bb;'
        'relation["place"~"^(village|hamlet|town|isolated_dwelling)\$"]$bb;'
        'relation["boundary"]$bb;'
        ');out geom;';
    final body = await _post(query);
    final elements =
        (jsonDecode(body)['elements'] as List).cast<Map<String, dynamic>>();
    // איסוף מועמדי-פוליגון: geometry של דרכים + geometry של חברי-יחסים.
    final polys = <List<Map<String, dynamic>>>[];
    for (final e in elements) {
      final geom = (e['geometry'] as List?)?.cast<Map<String, dynamic>>();
      if (geom != null && geom.length >= 3) polys.add(geom);
      final members = (e['members'] as List?)?.cast<Map<String, dynamic>>();
      if (members != null) {
        for (final m in members) {
          final mg = (m['geometry'] as List?)?.cast<Map<String, dynamic>>();
          if (mg != null && mg.length >= 3) polys.add(mg);
        }
      }
    }
    if (polys.isEmpty) return const [];
    // הפוליגון הגדול-בשטח = מִתאר היישוב (נוסחת-שרוך).
    List<Map<String, dynamic>>? best;
    var bestArea = 0.0;
    for (final geom in polys) {
      var area = 0.0;
      for (var i = 0; i < geom.length; i++) {
        final a = geom[i], b = geom[(i + 1) % geom.length];
        area += (a['lon'] as num).toDouble() * (b['lat'] as num) -
            (b['lon'] as num).toDouble() * (a['lat'] as num);
      }
      final wgt = area.abs();
      if (wgt > bestArea) {
        bestArea = wgt;
        best = geom;
      }
    }
    if (best == null) return const [];
    // ציפוף נקודות לאורך המִתאר (כל ~15מ', כמו roadPoints).
    final dist = const Distance();
    final ring = [
      for (final g in best)
        LatLng((g['lat'] as num).toDouble(), (g['lon'] as num).toDouble()),
    ];
    final points = <LatLng>[];
    for (var i = 0; i < ring.length; i++) {
      final prev = ring[i];
      final next = ring[(i + 1) % ring.length];
      points.add(prev);
      final d = dist(prev, next);
      final steps = (d / 15).ceil().clamp(1, 200);
      for (var s = 1; s < steps; s++) {
        final t = s / steps;
        points.add(LatLng(
          prev.latitude + (next.latitude - prev.latitude) * t,
          prev.longitude + (next.longitude - prev.longitude) * t,
        ));
      }
    }
    return points;
  }

  static Future<String> _post(String query) async {
    // קידוד מפורש של גוף-הטופס (כמו --data-urlencode של curl) — שליחת Map
    // ל-http.post גרמה לבקשה ש-Overpass "תקע" עליה עד timeout.
    final payload = 'data=${Uri.encodeQueryComponent(query)}';

    // מרוץ: בקשה במקביל לכל השרתים; ה-Completer מסתיים בראשון עם 200.
    final done = Completer<String>();
    var failures = 0;
    for (final url in _endpoints) {
      () async {
        try {
          final resp = await http
              .post(
                Uri.parse(url),
                headers: {
                  'Content-Type': 'application/x-www-form-urlencoded',
                  'User-Agent': _userAgent,
                },
                body: payload,
              )
              .timeout(const Duration(seconds: 75));
          if (resp.statusCode == 200 && !done.isCompleted) {
            done.complete(utf8.decode(resp.bodyBytes));
            return;
          }
        } catch (_) {}
        // כל שרת שנכשל; אם כולם נכשלו — מסיימים בשגיאה.
        if (++failures == _endpoints.length && !done.isCompleted) {
          done.completeError(
            const HttpException('כל שרתי Overpass לא זמינים'),
          );
        }
      }();
    }
    return done.future;
  }
}
