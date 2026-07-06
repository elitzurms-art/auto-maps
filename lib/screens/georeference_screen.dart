import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../services/reference_map_controller.dart';
import '../services/world_file_parser_service.dart';

/// נקודת התאמה — pixel על התמונה + world על המפה
class _ControlPoint {
  Offset pixel;
  LatLng? world;

  _ControlPoint({required this.pixel});

  bool get isComplete => world != null;
}

/// מסך Georeferencing — נעיצת נקודות פיקסל↔עולם וחישוב טרנספורמציה affine.
/// מחזיר [WorldFileResult] דרך Navigator.pop כשמאשרים.
class GeoreferenceScreen extends StatefulWidget {
  final String imagePath;

  const GeoreferenceScreen({required this.imagePath, super.key});

  @override
  State<GeoreferenceScreen> createState() => _GeoreferenceScreenState();
}

class _GeoreferenceScreenState extends State<GeoreferenceScreen> {
  bool _isOnMap = false;
  final List<_ControlPoint> _points = [];
  int? _editingIndex;

  // מקור מפת-הרקע — OSM + מקורות מקומיים שהתגלו (MBTiles / ECW)
  final ReferenceMapController _refMap = ReferenceMapController();
  String? _lastShownError;

  // תמונה
  int _imageWidth = 0;
  int _imageHeight = 0;
  static const _maxDisplayDim = 1500.0;
  final TransformationController _transformController =
      TransformationController();
  final GlobalKey _imageViewKey = GlobalKey();
  bool _crosshairMode = false; // false = לחיצה ישירה, true = צלב + כפתור

  /// סקאלה מ-pixels אמיתיים ל-display
  double get _displayScale {
    if (_imageWidth == 0 || _imageHeight == 0) return 1.0;
    final maxDim = max(_imageWidth, _imageHeight).toDouble();
    return maxDim > _maxDisplayDim ? _maxDisplayDim / maxDim : 1.0;
  }

  double get _displayWidth => _imageWidth * _displayScale;
  double get _displayHeight => _imageHeight * _displayScale;

  // מפה
  final MapController _mapController = MapController();

  // תוצאה
  WorldFileResult? _result;

  @override
  void initState() {
    super.initState();
    _loadImageSize();
    _refMap.addListener(_onRefMapChanged);
    // גילוי אוטומטי של קבצי-מפה בתיקיית-הייחוס המשתמעת (reference_maps).
    _refMap.loadDefaultFolder();
  }

  @override
  void dispose() {
    _refMap.removeListener(_onRefMapChanged);
    _transformController.dispose();
    super.dispose();
  }

  void _onRefMapChanged() {
    // הצגת שגיאת-טעינה (למשל sidecar של ECW נכשל) פעם אחת.
    final err = _refMap.lastError;
    if (err != null && err != _lastShownError && mounted) {
      _lastShownError = err;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(err)));
      });
    }
    setState(() {});
  }

  /// בחירת תיקיית-מפות — סורק ומוסיף כל קובץ מפה נתמך כמקור בבורר.
  Future<void> _pickReferenceFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'בחר תיקיית מפות ייחוס',
    );
    if (dir == null) return;
    await _refMap.loadFolder(dir);
    if (!mounted) return;
    final count = _refMap.availableSources().length - 1; // מלבד OSM
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
          content: Text(count > 0
              ? 'נטענו $count מקורות מפה מהתיקייה'
              : 'לא נמצאו קבצי מפה נתמכים בתיקייה')));
  }

  Future<void> _loadImageSize() async {
    final bytes = await File(widget.imagePath).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() {
      _imageWidth = frame.image.width;
      _imageHeight = frame.image.height;
    });
    frame.image.dispose();
  }

  void _pickOnImage(Offset pixelPosition) {
    setState(() {
      if (_editingIndex != null) {
        _points[_editingIndex!].pixel = pixelPosition;
        _points[_editingIndex!].world = null;
      } else {
        _points.add(_ControlPoint(pixel: pixelPosition));
      }
      _isOnMap = true;
      _result = null;
    });
  }

  void _pickOnMap(LatLng position) {
    setState(() {
      final idx = _editingIndex ?? (_points.length - 1);
      _points[idx].world = position;
      _isOnMap = false;
      _editingIndex = null;
      _result = null;
    });
  }

  void _calculate() {
    final complete = _points.where((p) => p.isComplete).toList();
    if (complete.length < 3) return;

    try {
      final result = WorldFileParserService.calculateFromControlPoints(
        points: complete
            .map((p) => (pixel: p.pixel, world: p.world!))
            .toList(),
        imageWidth: _imageWidth,
        imageHeight: _imageHeight,
      );
      setState(() => _result = result);
    } catch (e) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text('שגיאת חישוב: $e')),
        );
    }
  }

  void _confirm() {
    if (_result == null) return;
    Navigator.pop(context, _result);
  }

  void _editPoint(int index) {
    setState(() {
      _editingIndex = index;
      _isOnMap = false;
    });
  }

  void _deletePoint(int index) {
    setState(() {
      _points.removeAt(index);
      _result = null;
    });
  }

  void _showPointMenu(int index) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('ערוך נקודה'),
              onTap: () {
                Navigator.pop(ctx);
                _editPoint(index);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('מחק נקודה',
                  style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _deletePoint(index);
              },
            ),
          ],
        ),
      ),
    );
  }

  static const _minPoints = 4;

  int get _completeCount => _points.where((p) => p.isComplete).length;

  /// הנקודה האחרונה שנדקרה על המפה (לפתיחת המפה באותו אזור)
  LatLng? get _lastWorldPoint {
    for (int i = _points.length - 1; i >= 0; i--) {
      if (_points[i].world != null) return _points[i].world;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final canCalculate = _completeCount >= _minPoints && _result == null;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text('ג\'יאורפרנס ($_completeCount / $_minPoints נקודות)'),
        ),
        body: Column(
          children: [
            Expanded(
              child: _isOnMap ? _buildMapView() : _buildImageView(),
            ),

            // הוראה
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              color: _isOnMap ? Colors.blue[50] : Colors.orange[50],
              child: Text(
                _isOnMap
                    ? 'סמן על המפה את מיקום הנקודה שנדקרה בתמונה'
                    : 'סמן נקודה מזוהה על התמונה (פינה, צומת, ציון דרך)',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _isOnMap ? Colors.blue[700] : Colors.orange[800],
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),

            // chips נקודות
            if (_points.isNotEmpty)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  children: List.generate(_points.length, (i) {
                    final p = _points[i];
                    final isEditing = _editingIndex == i;
                    return Padding(
                      padding: const EdgeInsetsDirectional.only(end: 6),
                      child: ActionChip(
                        avatar: Icon(
                          p.isComplete
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          size: 16,
                          color: p.isComplete ? Colors.green : Colors.orange,
                        ),
                        label: Text(
                          '${i + 1}',
                          style: TextStyle(
                            fontWeight: isEditing
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: isEditing ? Colors.blue : null,
                          ),
                        ),
                        backgroundColor: isEditing ? Colors.blue[50] : null,
                        onPressed:
                            p.isComplete ? () => _showPointMenu(i) : null,
                      ),
                    );
                  }),
                ),
              ),

            // כפתורים
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: _result != null
                  ? _buildResultButtons()
                  : _buildPickButtons(canCalculate),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPickButtons(bool canCalculate) {
    return Row(
      children: [
        if (_isOnMap || _crosshairMode)
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _isOnMap
                  ? () => _pickOnMap(_mapController.camera.center)
                  : () => _pickOnImageCrosshair(),
              icon: const Icon(Icons.my_location),
              label: const Text('נעץ נקודה'),
            ),
          ),
        if (canCalculate) ...[
          if (_isOnMap) const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _calculate,
              icon: const Icon(Icons.calculate),
              label: const Text('חשב'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildResultButtons() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => setState(() => _result = null),
            icon: const Icon(Icons.add_location),
            label: const Text('הוסף נקודות'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _confirm,
            icon: const Icon(Icons.check),
            label: const Text('אשר'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  // ═══ מצב תמונה ═══

  Widget _buildImageView() {
    if (_imageWidth == 0) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      key: _imageViewKey,
      children: [
        GestureDetector(
          onTapUp: _crosshairMode
              ? null
              : (details) => _onImageTap(details.localPosition),
          child: InteractiveViewer(
            transformationController: _transformController,
            minScale: 0.5,
            maxScale: 10.0,
            constrained: false,
            child: SizedBox(
              width: _displayWidth,
              height: _displayHeight,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Image.file(
                    File(widget.imagePath),
                    width: _displayWidth,
                    height: _displayHeight,
                    fit: BoxFit.fill,
                  ),
                  // מרקרים אדומים ממוספרים
                  ..._buildImageMarkers(),
                ],
              ),
            ),
          ),
        ),
        // צלב במרכז (רק במצב צלב)
        if (_crosshairMode)
          const Positioned.fill(
            child: IgnorePointer(
              child: Center(child: _Crosshair(color: Colors.red)),
            ),
          ),
        // כפתור toggle צלב/לחיצה
        Positioned(
          top: 8,
          left: 8,
          child: Material(
            color: _crosshairMode ? Colors.red[50] : Colors.white,
            elevation: 2,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _crosshairMode = !_crosshairMode),
              child: SizedBox(
                width: 40,
                height: 40,
                child: Icon(
                  _crosshairMode ? Icons.gps_fixed : Icons.touch_app,
                  color: _crosshairMode ? Colors.red : Colors.grey[700],
                  size: 22,
                ),
              ),
            ),
          ),
        ),
        // תצוגה מקדימה
        if (_result != null) _buildPreviewOverlay(),
      ],
    );
  }

  Widget _buildPreviewOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black26,
        child: Center(
          child: SizedBox(
            height: 200,
            width: double.infinity,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: FlutterMap(
                  options: MapOptions(
                    initialCenter: LatLng(
                      (_result!.southWest.latitude +
                              _result!.northEast.latitude) /
                          2,
                      (_result!.southWest.longitude +
                              _result!.northEast.longitude) /
                          2,
                    ),
                    initialZoom: 13,
                  ),
                  children: [
                    _refMap.buildActiveTileLayer(),
                    OverlayImageLayer(
                      overlayImages: [
                        OverlayImage(
                          bounds: LatLngBounds(
                              _result!.southWest, _result!.northEast),
                          imageProvider: FileImage(File(widget.imagePath)),
                          opacity: 0.7,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// מרקרים אדומים ממוספרים על התמונה
  List<Widget> _buildImageMarkers() {
    final scale = _displayScale;
    return _points.asMap().entries.map((entry) {
      final i = entry.key;
      final p = entry.value;
      return Positioned(
        left: p.pixel.dx * scale - 12,
        top: p.pixel.dy * scale - 12,
        child: GestureDetector(
          onPanUpdate: (details) {
            setState(() {
              _points[i].pixel = Offset(
                p.pixel.dx + details.delta.dx / scale,
                p.pixel.dy + details.delta.dy / scale,
              );
              _result = null;
            });
          },
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: Colors.red,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
            child: Center(
              child: Text(
                '${i + 1}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  /// מצב צלב — דקירה במרכז המסך
  void _pickOnImageCrosshair() {
    final renderBox =
        _imageViewKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    _onImageTap(renderBox.size.center(Offset.zero));
  }

  /// לחיצה ישירה על התמונה — המרה מ-screen coords ל-pixel coords
  void _onImageTap(Offset screenPosition) {
    final matrix = _transformController.value;
    final inverted = Matrix4.inverted(matrix);
    final displayPoint = MatrixUtils.transformPoint(inverted, screenPosition);

    final scale = _displayScale;
    final px = (displayPoint.dx / scale).clamp(0.0, _imageWidth.toDouble());
    final py = (displayPoint.dy / scale).clamp(0.0, _imageHeight.toDouble());

    _pickOnImage(Offset(px, py));
  }

  // ═══ מצב מפה ═══

  Widget _buildMapView() {
    final sources = _refMap.availableSources();
    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _lastWorldPoint ?? const LatLng(31.5, 34.8),
            initialZoom: _lastWorldPoint != null ? 14 : 8,
          ),
          children: [
            _refMap.buildActiveTileLayer(),
            // מרקרים ירוקים ממוספרים של נקודות שנדקרו
            MarkerLayer(
              markers: _points
                  .asMap()
                  .entries
                  .where((e) => e.value.isComplete)
                  .map((entry) => Marker(
                        point: entry.value.world!,
                        width: 24,
                        height: 24,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.green,
                            shape: BoxShape.circle,
                            border:
                                Border.all(color: Colors.white, width: 2),
                          ),
                          child: Center(
                            child: Text(
                              '${entry.key + 1}',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ],
        ),
        // סרגל מקורות-מפה: בורר (כשיש יותר ממקור אחד) + הוספת תיקייה/ECW
        Positioned(
          top: 8,
          right: 8,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (sources.length > 1)
                Material(
                  elevation: 2,
                  borderRadius: BorderRadius.circular(8),
                  child: PopupMenuButton<ReferenceMapSource>(
                    icon: const Icon(Icons.layers),
                    tooltip: 'בחר מקור מפה',
                    onSelected: _refMap.setActive,
                    itemBuilder: (ctx) => sources
                        .map((s) => PopupMenuItem(
                              value: s,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (s.id == _refMap.active.id)
                                    const Icon(Icons.check,
                                        size: 16, color: Colors.green)
                                  else
                                    const SizedBox(width: 16),
                                  const SizedBox(width: 6),
                                  Text(s.displayName),
                                ],
                              ),
                            ))
                        .toList(),
                  ),
                ),
              const SizedBox(height: 6),
              Material(
                elevation: 2,
                borderRadius: BorderRadius.circular(8),
                child: IconButton(
                  icon: const Icon(Icons.folder_open),
                  tooltip: 'בחר תיקיית מפות',
                  onPressed: _pickReferenceFolder,
                ),
              ),
            ],
          ),
        ),
        // מחוון טעינה בזמן החלפת מקור (הרצת sidecar / פתיחת DB)
        if (_refMap.isSwitching)
          const Positioned.fill(
            child: IgnorePointer(
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
        // צלב במרכז
        const Positioned.fill(
          child: IgnorePointer(
            child: Center(child: _Crosshair(color: Colors.blue)),
          ),
        ),
      ],
    );
  }
}

/// צלב דקירה
class _Crosshair extends StatelessWidget {
  final Color color;
  const _Crosshair({required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: CustomPaint(painter: _CrosshairPainter(color)),
    );
  }
}

class _CrosshairPainter extends CustomPainter {
  final Color color;
  _CrosshairPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final cx = size.width / 2;
    final cy = size.height / 2;
    const gap = 4.0;
    canvas.drawLine(Offset(0, cy), Offset(cx - gap, cy), paint);
    canvas.drawLine(Offset(cx + gap, cy), Offset(size.width, cy), paint);
    canvas.drawLine(Offset(cx, 0), Offset(cx, cy - gap), paint);
    canvas.drawLine(Offset(cx, cy + gap), Offset(cx, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
