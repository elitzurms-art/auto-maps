import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../services/gemini_anchor_service.dart';
import '../services/overpass_service.dart';
import '../services/reference_map_controller.dart';
import '../services/world_file_parser_service.dart';

/// עוגן בר-עריכה במסך הכיוון.
class _Anchor {
  Offset pixel; // פיקסלי-מקור
  LatLng world;
  bool rejected;
  final String name;
  final AnchorVerifyKind kind;
  _Anchor({
    required this.pixel,
    required this.world,
    required this.name,
    required this.kind,
    this.rejected = false,
  });
}

/// מסך "כוונון ואישור" — בד-שילוב יחיד: מפת-ייחוס במסך מלא + הסריקה
/// שקופה מעליה (סליידר שקיפות תמידי), עם פינים לכל עוגן. **הכל מאושר
/// כברירת-מחדל** — המשתמש רק פוסל או מזיז נקודות שגויות ("את זו או את זו":
/// צד-העולם על המפה, צד-הסריקה בבועית). "אשר הכל" → ייצוא.
class AdjustVerifyScreen extends StatefulWidget {
  final String imagePath;
  final int imageWidth;
  final int imageHeight;
  final List<GeminiAnchorSuggestion> suggestions;
  final ReferenceMapController refMap;

  const AdjustVerifyScreen({
    super.key,
    required this.imagePath,
    required this.imageWidth,
    required this.imageHeight,
    required this.suggestions,
    required this.refMap,
  });

  @override
  State<AdjustVerifyScreen> createState() => _AdjustVerifyScreenState();
}

class _AdjustVerifyScreenState extends State<AdjustVerifyScreen> {
  final MapController _map = MapController();
  final GlobalKey _mapKey = GlobalKey();
  late final List<_Anchor> _anchors;
  int? _selected;
  double _opacity = 0.55;
  bool _satellite = false;

  // צד-הגרירה של העוגן הנבחר: false=עולם(OSM), true=סריקה. הבחירה בכפתור
  // (לא לפי פיקסל) פותרת "נקודה על נקודה" — גוררים את הצד שנבחר, לא את
  // מה שבמקרה למעלה.
  bool _activeSideScan = false;
  bool _draggingHandle = false; // בזמן גרירת-הידית משביתים גרירת-מפה

  // צמתי-OSM לאזור (best-effort, ל"הצמד לצומת"); ריק עד שהטעינה מצליחה.
  List<LatLng> _osmJunctions = const [];
  bool _osmLoading = false;

  static const Distance _dist = Distance();

  @override
  void initState() {
    super.initState();
    _anchors = [
      for (final s in widget.suggestions)
        _Anchor(
          pixel: s.pixel,
          world: s.world,
          name: s.name,
          kind: s.verifyKind,
          rejected: s.verified == false,
        ),
    ];
    _loadOsm();
  }

  /// טוען צמתי-OSM לאזור-העוגנים (best-effort) — מאפשר "הצמד לצומת".
  /// כשל-רשת לא מפיל: האימות-הגיאומטרי (שאריות/עקביות) עובד בלעדיו.
  Future<void> _loadOsm() async {
    if (_anchors.isEmpty) return;
    setState(() => _osmLoading = true);
    try {
      var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
      for (final a in _anchors) {
        minLat = a.world.latitude < minLat ? a.world.latitude : minLat;
        maxLat = a.world.latitude > maxLat ? a.world.latitude : maxLat;
        minLon = a.world.longitude < minLon ? a.world.longitude : minLon;
        maxLon = a.world.longitude > maxLon ? a.world.longitude : maxLon;
      }
      final dLat = (maxLat - minLat) * 0.2 + 0.002;
      final dLon = (maxLon - minLon) * 0.2 + 0.002;
      final osm = await OverpassService.fetchJunctions((
        south: minLat - dLat,
        west: minLon - dLon,
        north: maxLat + dLat,
        east: maxLon + dLon,
      ));
      if (!mounted) return;
      setState(() {
        _osmJunctions = osm.junctions;
        _osmLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _osmLoading = false);
    }
  }

  List<_Anchor> get _active =>
      _anchors.where((a) => !a.rejected).toList(growable: false);

  List<int> get _activeIdx => [
        for (var i = 0; i < _anchors.length; i++)
          if (!_anchors[i].rejected) i,
      ];

  /// שארית leave-one-out לכל עוגן פעיל: מרחק (מ') בין מיקום-העולם שלו
  /// לבין החיזוי מ-affine שהותאם ל**כל שאר** העוגנים. עוגן שסוטה = חשוד
  /// (התאמה שגויה / החלפת-נקודות) — רדאר-חשד גיאומטרי טהור, בלי AI.
  Map<int, double> _residuals() {
    final res = <int, double>{};
    // בזמן גרירה מדלגים (N התאמות-affine לכל אירוע-תנועה = לאג); הרדאר
    // מתרענן ברגע שחרור-הידית.
    if (_draggingHandle) return res;
    final act = _activeIdx;
    if (act.length < 4) return res; // צריך ≥3 אחרים לבניית affine
    for (final i in act) {
      final others = [
        for (final j in act)
          if (j != i) (pixel: _anchors[j].pixel, world: _anchors[j].world),
      ];
      try {
        final prov = WorldFileParserService.calculateFromControlPoints(
          points: others,
          imageWidth: widget.imageWidth,
          imageHeight: widget.imageHeight,
        );
        final pred = _projectScan(_anchors[i].pixel, prov);
        if (pred != null) res[i] = _dist(pred, _anchors[i].world);
      } catch (_) {}
    }
    return res;
  }

  /// סף-חשד: חורג מ-max(45מ', 2.5×חציון-השאריות).
  double _suspectThreshold(Map<int, double> res) {
    if (res.isEmpty) return double.infinity;
    final vals = res.values.toList()..sort();
    final median = vals[vals.length ~/ 2];
    return (2.5 * median).clamp(45.0, double.infinity);
  }

  /// תיקון גיאומטרי א' — "יישר לעקביות": מזיז את צד-העולם של העוגן אל
  /// החיזוי מ-affine של כל השאר. מתקן החלפת-נקודות/התאמה שגויה בלי OSM.
  void _snapToConsensus(int i) {
    final others = [
      for (final j in _activeIdx)
        if (j != i) (pixel: _anchors[j].pixel, world: _anchors[j].world),
    ];
    if (others.length < 3) return;
    try {
      final prov = WorldFileParserService.calculateFromControlPoints(
        points: others,
        imageWidth: widget.imageWidth,
        imageHeight: widget.imageHeight,
      );
      final pred = _projectScan(_anchors[i].pixel, prov);
      if (pred != null) setState(() => _anchors[i].world = pred);
    } catch (_) {}
  }

  /// תיקון גיאומטרי ב' — "הצמד לצומת": מזיז את צד-העולם לצומת-OSM הקרוב
  /// ביותר (עד ~120מ'). מיישר לאמת-הקרקע, לא רק לעקביות-פנימית.
  void _snapToJunction(int i) {
    if (_osmJunctions.isEmpty) return;
    final w = _anchors[i].world;
    LatLng? best;
    var bestD = 120.0; // לא נצמיד לצומת רחוק מדי
    for (final j in _osmJunctions) {
      final d = _dist(w, j);
      if (d < bestD) {
        bestD = d;
        best = j;
      }
    }
    if (best != null) setState(() => _anchors[i].world = best!);
  }

  /// affine זמני מהעוגנים הפעילים — לשילוב-השקוף החי.
  WorldFileResult? _provisional() {
    final act = _active;
    if (act.length < 3) return null;
    try {
      return WorldFileParserService.calculateFromControlPoints(
        points: [for (final a in act) (pixel: a.pixel, world: a.world)],
        imageWidth: widget.imageWidth,
        imageHeight: widget.imageHeight,
      );
    } catch (_) {
      return null;
    }
  }

  LatLng get _center {
    final act = _active.isNotEmpty ? _active : _anchors;
    var lat = 0.0, lon = 0.0;
    for (final a in act) {
      lat += a.world.latitude;
      lon += a.world.longitude;
    }
    return LatLng(lat / act.length, lon / act.length);
  }

  /// מטיל פיקסל-סריקה לעולם לפי ה-affine הנוכחי (אינטרפולציה בי-לינארית
  /// של 4 הפינות) — מראה **היכן הסריקה נוחתת** מול המיקום ב-OSM.
  LatLng? _projectScan(Offset px, WorldFileResult prov) {
    final c = prov.cornersWgs84;
    final LatLng nw, ne, se, sw;
    if (c != null && c.length == 4) {
      nw = c[0];
      ne = c[1];
      se = c[2];
      sw = c[3];
    } else {
      nw = LatLng(prov.northEast.latitude, prov.southWest.longitude);
      ne = prov.northEast;
      se = LatLng(prov.southWest.latitude, prov.northEast.longitude);
      sw = prov.southWest;
    }
    final u = (px.dx / widget.imageWidth).clamp(0.0, 1.0);
    final v = (px.dy / widget.imageHeight).clamp(0.0, 1.0);
    LatLng lerp(LatLng a, LatLng b, double t) => LatLng(
          a.latitude + (b.latitude - a.latitude) * t,
          a.longitude + (b.longitude - a.longitude) * t,
        );
    final top = lerp(nw, ne, u);
    final bottom = lerp(sw, se, u);
    return lerp(top, bottom, v);
  }

  /// היפוך [_projectScan]: עולם → פיקסל-סריקה (פתרון affine מ-4 הפינות).
  /// world = NW + u·(NE−NW) + v·(SW−NW) → פותרים u,v ואז px=u·W, py=v·H.
  Offset? _invProject(LatLng w, WorldFileResult prov) {
    final c = prov.cornersWgs84;
    final LatLng nw, ne, sw;
    if (c != null && c.length == 4) {
      nw = c[0];
      ne = c[1];
      sw = c[3];
    } else {
      nw = LatLng(prov.northEast.latitude, prov.southWest.longitude);
      ne = prov.northEast;
      sw = prov.southWest;
    }
    final e1x = ne.longitude - nw.longitude, e1y = ne.latitude - nw.latitude;
    final e2x = sw.longitude - nw.longitude, e2y = sw.latitude - nw.latitude;
    final det = e1x * e2y - e1y * e2x;
    if (det.abs() < 1e-12) return null;
    final dx = w.longitude - nw.longitude, dy = w.latitude - nw.latitude;
    final u = (dx * e2y - dy * e2x) / det;
    final v = (e1x * dy - e1y * dx) / det;
    return Offset(
      (u * widget.imageWidth).clamp(0.0, widget.imageWidth.toDouble()),
      (v * widget.imageHeight).clamp(0.0, widget.imageHeight.toDouble()),
    );
  }

  /// ממיר מיקום-מסך גלובלי ל-LatLng לפי מצלמת-המפה.
  LatLng? _globalToLatLng(Offset global) {
    final box = _mapKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final local = box.globalToLocal(global);
    return _map.camera.offsetToCrs(local);
  }

  /// מיישם גרירה של הצד-הנבחר: מזיז את צד-העולם (world) ישירות, או את
  /// צד-הסריקה (pixel — דרך היפוך ה-affine).
  void _applyDrag(int i, Offset global) {
    final ll = _globalToLatLng(global);
    if (ll == null) return;
    setState(() {
      if (_activeSideScan) {
        final prov = _provisional();
        if (prov == null) return;
        final px = _invProject(ll, prov);
        if (px != null) _anchors[i].pixel = px;
      } else {
        _anchors[i].world = ll;
      }
    });
  }

  /// ידית-הגרירה הגדולה לצד-הנבחר. Listener תופס מיד את מגע-האצבע (לפני
  /// שהמפה מספיקה) — גרירה חלקה, בלי התנגשות z-order.
  Marker _dragHandle(int i, WorldFileResult prov) {
    final a = _anchors[i];
    final pos = _activeSideScan
        ? (_projectScan(a.pixel, prov) ?? a.world)
        : a.world;
    final color = _activeSideScan ? Colors.blue : Colors.green;
    return Marker(
      point: pos,
      width: 60,
      height: 60,
      child: Listener(
        onPointerDown: (_) => setState(() => _draggingHandle = true),
        onPointerMove: (e) => _applyDrag(i, e.position),
        onPointerUp: (_) => setState(() => _draggingHandle = false),
        child: Container(
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.25),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.amber, width: 3),
          ),
          child: Icon(Icons.open_with, color: color, size: 26),
        ),
      ),
    );
  }

  Future<void> _moveOnScan(int idx) async {
    final a = _anchors[idx];
    final result = await showDialog<Offset>(
      context: context,
      builder: (ctx) => _ScanCropDialog(
        imagePath: widget.imagePath,
        imageWidth: widget.imageWidth,
        imageHeight: widget.imageHeight,
        initial: a.pixel,
        name: a.name,
      ),
    );
    if (result != null) setState(() => a.pixel = result);
  }

  void _approveAll() {
    final pts = [
      for (final a in _active) (pixel: a.pixel, world: a.world),
    ];
    Navigator.pop(context, pts);
  }

  @override
  Widget build(BuildContext context) {
    final prov = _provisional();
    final approved = _active.length;
    final rejected = _anchors.length - approved;
    final residuals = _residuals();
    final threshold = _suspectThreshold(residuals);
    final suspects =
        residuals.entries.where((e) => e.value > threshold).length;
    final medianRes = residuals.isEmpty
        ? null
        : (residuals.values.toList()..sort())[residuals.length ~/ 2];

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('כוונון ואישור'),
              if (medianRes != null)
                Text(
                  'עקביות: ${medianRes.round()} מ׳ חציון'
                  '${suspects > 0 ? '  ·  ⚠ $suspects חשודות' : '  ·  ✓ ללא חריגות'}',
                  style: TextStyle(
                    fontSize: 12,
                    color: suspects > 0 ? Colors.amber : Colors.white70,
                  ),
                ),
            ],
          ),
          actions: [
            // מתג מפה/לוויין
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('מפה')),
                  ButtonSegment(value: true, label: Text('לוויין')),
                ],
                selected: {_satellite},
                onSelectionChanged: (s) =>
                    setState(() => _satellite = s.first),
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: FilledButton.icon(
                onPressed: approved >= 3 ? _approveAll : null,
                icon: const Icon(Icons.check),
                label: Text('אשר הכל ($approved)'),
              ),
            ),
          ],
        ),
        body: Stack(
          children: [
            FlutterMap(
              key: _mapKey,
              mapController: _map,
              options: MapOptions(
                initialCenter: _center,
                initialZoom: 15,
                onTap: (_, __) => setState(() => _selected = null),
                interactionOptions: InteractionOptions(
                  // בזמן גרירת-ידית משביתים גרירת-מפה כדי שהתנועה תזיז את הפין
                  flags: _draggingHandle
                      ? (InteractiveFlag.all & ~InteractiveFlag.drag)
                      : InteractiveFlag.all,
                ),
              ),
              children: [
                _satellite
                    ? const SatelliteOnlineSource().buildTileLayer()
                    : widget.refMap.buildActiveTileLayer(),
                if (prov != null)
                  OverlayImageLayer(
                    overlayImages: [
                      OverlayImage(
                        bounds: LatLngBounds(
                          prov.southWest,
                          prov.northEast,
                        ),
                        imageProvider: FileImage(File(widget.imagePath)),
                        opacity: _opacity,
                      ),
                    ],
                  ),
                // קווי-שגיאה: מחברים "היכן הסריקה נוחתת" ל"מיקום ב-OSM".
                if (prov != null)
                  PolylineLayer(
                    polylines: [
                      for (var i = 0; i < _anchors.length; i++)
                        if (!_anchors[i].rejected)
                          if (_projectScan(_anchors[i].pixel, prov)
                              case final sp?)
                            Polyline(
                              points: [sp, _anchors[i].world],
                              color: _selected == i
                                  ? Colors.amber
                                  : Colors.orange.withValues(alpha: 0.7),
                              strokeWidth: _selected == i ? 3 : 2,
                            ),
                    ],
                  ),
                // שכבה 1 — סמן-סריקה (היכן הצומת של הסריקה נוחת).
                if (prov != null)
                  MarkerLayer(markers: [
                    for (var i = 0; i < _anchors.length; i++)
                      if (!_anchors[i].rejected)
                        if (_projectScan(_anchors[i].pixel, prov)
                            case final sp?)
                          _scanMarker(i, sp),
                  ]),
                // שכבה 2 — סמן-עולם (המיקום האמיתי ב-OSM).
                MarkerLayer(markers: [
                  for (var i = 0; i < _anchors.length; i++)
                    _worldMarker(
                        i, (residuals[i] ?? 0) > threshold && !_anchors[i].rejected),
                ]),
                // שכבה 3 — ידית-גרירה גדולה לצד-הנבחר של העוגן הנבחר (תמיד
                // למעלה; פותרת נקודה-על-נקודה).
                if (_selected != null &&
                    !_anchors[_selected!].rejected &&
                    prov != null)
                  MarkerLayer(markers: [_dragHandle(_selected!, prov)]),
              ],
            ),

            // סרגל תחתון: שקיפות + פעולות הנקודה הנבחרת
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _bottomBar(approved, rejected, residuals, threshold),
            ),
          ],
        ),
      ),
    );
  }

  /// סמן-העולם (🟢) — המיקום האמיתי ב-OSM; היעד. [suspect] = השארית שלו
  /// חורגת → מסגרת-אזהרה כתומה (רדאר-החשד הגיאומטרי).
  Marker _worldMarker(int i, bool suspect) {
    final a = _anchors[i];
    final sel = _selected == i;
    final color = a.rejected
        ? Colors.red
        : suspect
            ? Colors.orange
            : (a.kind == AnchorVerifyKind.geometric
                ? Colors.teal
                : Colors.green);
    return Marker(
      point: a.world,
      width: 46,
      height: 46,
      child: GestureDetector(
        onTap: () => setState(() {
          _selected = sel ? null : i;
          _activeSideScan = false; // בחירת עוגן → צד-ברירת-מחדל: OSM
        }),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: sel ? 30 : 24,
              height: sel ? 30 : 24,
              decoration: BoxDecoration(
                color:
                    a.rejected ? Colors.white : color.withValues(alpha: 0.9),
                shape: BoxShape.circle,
                border: Border.all(
                  color: sel
                      ? Colors.amber
                      : (suspect ? Colors.deepOrange : color),
                  width: sel || suspect ? 3 : 2,
                ),
                boxShadow: const [
                  BoxShadow(color: Colors.black38, blurRadius: 2),
                ],
              ),
              alignment: Alignment.center,
              child: a.rejected
                  ? Icon(Icons.close, size: 16, color: Colors.red[700])
                  : Text(
                      '${i + 1}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
            if (!a.rejected)
              Icon(
                suspect
                    ? Icons.warning
                    : (a.kind == AnchorVerifyKind.geometric
                        ? Icons.architecture
                        : Icons.remove_red_eye),
                size: 12,
                color: suspect ? Colors.deepOrange : color,
              ),
          ],
        ),
      ),
    );
  }

  /// סמן-הסריקה (🔵 חלול) — היכן הצומת של הסריקה נוחת לפי ה-affine הנוכחי.
  /// הפער בינו לסמן-העולם = שגיאת-העוגן. עריכה דרך "הזז על הסריקה".
  Marker _scanMarker(int i, LatLng at) {
    final sel = _selected == i;
    return Marker(
      point: at,
      width: 30,
      height: 30,
      child: GestureDetector(
        onTap: () => setState(() {
          _selected = i;
          _activeSideScan = true; // הקשה על סמן-הסריקה → צד-סריקה פעיל
        }),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.85),
            shape: BoxShape.circle,
            border: Border.all(
              color: sel ? Colors.amber : Colors.blue,
              width: sel ? 3 : 2,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            '${i + 1}',
            style: TextStyle(
              color: Colors.blue[800],
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomBar(int approved, int rejected, Map<int, double> residuals,
      double threshold) {
    final sel = _selected;
    return Container(
      color: Colors.black.withValues(alpha: 0.72),
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        8 + MediaQuery.of(context).padding.bottom + 48, // רווח תחתון ~1.5ס"מ
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // סליידר שקיפות תמידי
          Row(
            children: [
              const Icon(Icons.opacity, color: Colors.white70, size: 18),
              Expanded(
                child: Slider(
                  value: _opacity,
                  onChanged: (v) => setState(() => _opacity = v),
                ),
              ),
              Text('${(_opacity * 100).round()}%',
                  style: const TextStyle(color: Colors.white70)),
            ],
          ),
          if (sel == null) ...[
            // מקרא: מה משמעות שני הסמנים והקו.
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              children: [
                _legendDot(Colors.blue, 'היכן הסריקה נוחתת', filled: false),
                _legendDot(Colors.green, 'המיקום ב-OSM'),
                const Text('· קו = שגיאה',
                    style: TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              rejected == 0
                  ? 'מאושרות: $approved · הקש על פין לפסילה/הזזה'
                  : 'מאושרות: $approved · נפסלו: $rejected',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ] else
            _selectedActions(sel, residuals[sel], threshold),
        ],
      ),
    );
  }

  Widget _legendDot(Color c, String label, {bool filled = true}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: filled ? c : Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: c, width: 2),
          ),
        ),
        const SizedBox(width: 4),
        Text(label,
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }

  Widget _selectedActions(int sel, double? residual, double threshold) {
    final a = _anchors[sel];
    final suspect = residual != null && residual > threshold && !a.rejected;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'נקודה ${sel + 1} · ${a.name}'
          '${a.kind == AnchorVerifyKind.geometric ? ' · אומת גיאומטרית' : a.kind == AnchorVerifyKind.vision ? ' · אומת ראייה' : ''}',
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
        if (residual != null && !a.rejected)
          Text(
            suspect
                ? '⚠ חשודה — סטייה ${residual.round()} מ׳ מהעקביות'
                : 'סטייה ${residual.round()} מ׳ (בטווח)',
            style: TextStyle(
              color: suspect ? Colors.orangeAccent : Colors.white60,
              fontSize: 12,
              fontWeight: suspect ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        if (!a.rejected) ...[
          const SizedBox(height: 6),
          // בחירת צד-הגרירה (פותר נקודה-על-נקודה): גוררים את הצד שנבחר.
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: false,
                icon: Icon(Icons.circle, size: 14, color: Colors.green),
                label: Text('OSM'),
              ),
              ButtonSegment(
                value: true,
                icon: Icon(Icons.circle_outlined, size: 14, color: Colors.blue),
                label: Text('סריקה'),
              ),
            ],
            selected: {_activeSideScan},
            onSelectionChanged: (s) =>
                setState(() => _activeSideScan = s.first),
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
          ),
          const SizedBox(height: 2),
          const Text(
            'גרור את הידית הצהובה ⤡ להזזת הצד שנבחר',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          alignment: WrapAlignment.center,
          children: [
            if (a.rejected)
              FilledButton.tonalIcon(
                onPressed: () => setState(() => a.rejected = false),
                icon: const Icon(Icons.restore),
                label: const Text('שחזר'),
              )
            else
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red[100],
                  foregroundColor: Colors.red[900],
                ),
                onPressed: () => setState(() => a.rejected = true),
                icon: const Icon(Icons.close),
                label: const Text('פסול'),
              ),
            // תיקון גיאומטרי א' — יישור לעקביות (בלי OSM).
            if (!a.rejected && _activeIdx.length >= 4)
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  backgroundColor: suspect ? Colors.amber[200] : null,
                ),
                onPressed: () => _snapToConsensus(sel),
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('יישר לעקביות'),
              ),
            // תיקון גיאומטרי ב' — הצמד לצומת-OSM הקרוב (כשנטען).
            if (!a.rejected && _osmJunctions.isNotEmpty)
              FilledButton.tonalIcon(
                onPressed: () => _snapToJunction(sel),
                icon: const Icon(Icons.my_location),
                label: const Text('הצמד לצומת'),
              )
            else if (!a.rejected && _osmLoading)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            // עריכת צד-הסריקה בזום מדויק (חלופה לגרירה על המפה).
            FilledButton.tonalIcon(
              onPressed: a.rejected ? null : () => _moveOnScan(sel),
              icon: const Icon(Icons.crop),
              label: const Text('סריקה בזום'),
            ),
            TextButton(
              onPressed: () => setState(() => _selected = null),
              child: const Text('סגור', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ],
    );
  }
}

/// דיאלוג "הזז על הסריקה" — מציג את הסריקה עם צלב במיקום הנוכחי; הקשה
/// על התמונה קובעת פיקסל חדש (עם זום/הזזה דרך InteractiveViewer לדיוק).
class _ScanCropDialog extends StatefulWidget {
  final String imagePath;
  final int imageWidth;
  final int imageHeight;
  final Offset initial;
  final String name;
  const _ScanCropDialog({
    required this.imagePath,
    required this.imageWidth,
    required this.imageHeight,
    required this.initial,
    required this.name,
  });

  @override
  State<_ScanCropDialog> createState() => _ScanCropDialogState();
}

class _ScanCropDialogState extends State<_ScanCropDialog> {
  late Offset _px = widget.initial;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  const Icon(Icons.crop, size: 20),
                  const SizedBox(width: 8),
                  Expanded(child: Text('הזז על הסריקה · ${widget.name}')),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'הקש על המיקום המדויק של הנקודה בסריקה (אפשר לצבוט לזום).',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: LayoutBuilder(
                builder: (ctx, constraints) {
                  // התאמת התמונה ל-box תוך שמירת יחס — ממפים הקשה לפיקסל.
                  final boxW = constraints.maxWidth;
                  final boxH = constraints.maxHeight.isFinite
                      ? constraints.maxHeight
                      : 420.0;
                  final scale = (boxW / widget.imageWidth)
                      .clamp(0.0, boxH / widget.imageHeight);
                  final dispW = widget.imageWidth * scale;
                  final dispH = widget.imageHeight * scale;
                  return SizedBox(
                    width: boxW,
                    height: boxH,
                    child: Center(
                      child: SizedBox(
                        width: dispW,
                        height: dispH,
                        child: InteractiveViewer(
                          maxScale: 8,
                          child: GestureDetector(
                            onTapDown: (d) {
                              setState(() {
                                _px = Offset(
                                  (d.localPosition.dx / dispW *
                                          widget.imageWidth)
                                      .clamp(0, widget.imageWidth.toDouble()),
                                  (d.localPosition.dy / dispH *
                                          widget.imageHeight)
                                      .clamp(0, widget.imageHeight.toDouble()),
                                );
                              });
                            },
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: Image.file(
                                    File(widget.imagePath),
                                    fit: BoxFit.fill,
                                  ),
                                ),
                                Positioned(
                                  left: _px.dx * scale - 12,
                                  top: _px.dy * scale - 12,
                                  child: const Icon(
                                    Icons.add,
                                    color: Colors.red,
                                    size: 24,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('ביטול'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, _px),
                    child: const Text('אישור'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
