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

  OverpassService._(this.junctions, this.neighbors, this.isRoundabout);

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
    // נודי-טבעת מוחרגים (מיוצגים ע"י מרכז-הכיכר).
    final nodeCount = <int, int>{};
    final nodeCoord = <int, LatLng>{};
    final nodeAdj = <int, Set<int>>{};
    for (final w in elements) {
      if (w['type'] != 'way') continue;
      final ids = (w['nodes'] as List?)?.cast<int>();
      final geom = (w['geometry'] as List?)?.cast<Map<String, dynamic>>();
      if (ids == null || geom == null || ids.length != geom.length) continue;
      for (var i = 0; i < ids.length; i++) {
        final id = ids[i];
        if (roundaboutNodes.contains(id)) continue;
        nodeCount[id] = (nodeCount[id] ?? 0) + 1;
        nodeCoord[id] = LatLng(
          (geom[i]['lat'] as num).toDouble(),
          (geom[i]['lon'] as num).toDouble(),
        );
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
    final dist = const Distance();
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

    return OverpassService._(junctions, neighbors, isRoundabout);
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
