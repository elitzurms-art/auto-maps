import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../services/gemini_anchor_service.dart';
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
  late final List<_Anchor> _anchors;
  int? _selected;
  double _opacity = 0.55;
  bool _satellite = false;
  bool _placingOnMap = false; // מצב "הזז על המפה" — ההקשה הבאה קובעת מיקום

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
  }

  List<_Anchor> get _active =>
      _anchors.where((a) => !a.rejected).toList(growable: false);

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

  void _onMapTap(LatLng p) {
    if (_placingOnMap && _selected != null) {
      setState(() {
        _anchors[_selected!].world = p;
        _placingOnMap = false;
      });
    } else {
      setState(() => _selected = null);
    }
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

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('כוונון ואישור'),
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
              mapController: _map,
              options: MapOptions(
                initialCenter: _center,
                initialZoom: 15,
                onTap: (_, p) => _onMapTap(p),
                interactionOptions: InteractionOptions(
                  // בזמן "הזז על המפה" משביתים גרירה כדי שהקשה תיקלט נקי
                  flags: _placingOnMap
                      ? InteractiveFlag.none
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
                  for (var i = 0; i < _anchors.length; i++) _worldMarker(i),
                ]),
              ],
            ),

            // הנחיה בזמן מצב-הזזה על המפה
            if (_placingOnMap)
              Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'הקש על המיקום הנכון במפה',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),

            // סרגל תחתון: שקיפות + פעולות הנקודה הנבחרת
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _bottomBar(approved, rejected),
            ),
          ],
        ),
      ),
    );
  }

  /// סמן-העולם (🟠) — המיקום האמיתי ב-OSM; היעד. גרירה דרך "הזז על המפה".
  Marker _worldMarker(int i) {
    final a = _anchors[i];
    final sel = _selected == i;
    final color = a.rejected
        ? Colors.red
        : (a.kind == AnchorVerifyKind.geometric ? Colors.teal : Colors.green);
    return Marker(
      point: a.world,
      width: 46,
      height: 46,
      child: GestureDetector(
        onTap: () => setState(() {
          _selected = sel ? null : i;
          _placingOnMap = false;
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
                  color: sel ? Colors.amber : color,
                  width: sel ? 3 : 2,
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
                a.kind == AnchorVerifyKind.geometric
                    ? Icons.architecture
                    : Icons.remove_red_eye,
                size: 12,
                color: color,
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
          _selected = sel ? null : i;
          _placingOnMap = false;
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

  Widget _bottomBar(int approved, int rejected) {
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
            _selectedActions(sel),
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

  Widget _selectedActions(int sel) {
    final a = _anchors[sel];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'נקודה ${sel + 1} · ${a.name}'
          '${a.kind == AnchorVerifyKind.geometric ? ' · אומת גיאומטרית' : a.kind == AnchorVerifyKind.vision ? ' · אומת ראייה' : ''}',
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
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
                onPressed: () => setState(() {
                  a.rejected = true;
                  _placingOnMap = false;
                }),
                icon: const Icon(Icons.close),
                label: const Text('פסול'),
              ),
            FilledButton.tonalIcon(
              onPressed: a.rejected
                  ? null
                  : () => setState(() => _placingOnMap = true),
              icon: const Icon(Icons.place),
              label: const Text('הזז על המפה'),
            ),
            FilledButton.tonalIcon(
              onPressed: a.rejected ? null : () => _moveOnScan(sel),
              icon: const Icon(Icons.crop),
              label: const Text('הזז על הסריקה'),
            ),
            TextButton(
              onPressed: () => setState(() {
                _selected = null;
                _placingOnMap = false;
              }),
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
