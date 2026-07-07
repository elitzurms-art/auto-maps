import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/ai_engine.dart';
import '../services/gdal_warp_service.dart';
import '../services/gemini_anchor_service.dart';
import '../services/reference_map_controller.dart';
import '../services/world_file_parser_service.dart';
import 'adjust_verify_screen.dart';

/// נקודת התאמה — pixel על התמונה + world על המפה
class _ControlPoint {
  Offset pixel;
  LatLng? world;

  _ControlPoint({required this.pixel});

  bool get isComplete => world != null;
}

/// תוצאת מסך הנעיצה — ה-bounds/פינות + אופן הטרנספורמציה.
///
/// כש-[transform] הוא `"tps"`, [warpedImagePath] מצביע על ה-PNG המיושר
/// שנוצר (זו התמונה לייצוא במקום המקור); ב-affine הוא null.
class GeoreferenceOutcome {
  final WorldFileResult result;
  final String transform;
  final String? warpedImagePath;

  const GeoreferenceOutcome({
    required this.result,
    required this.transform,
    this.warpedImagePath,
  });
}

/// מסך Georeferencing — נעיצת נקודות פיקסל↔עולם וחישוב טרנספורמציה affine,
/// עם יישור TPS אופציונלי למפות לא-ישרות והצעת עוגנים אוטומטית (Gemini).
/// מחזיר [GeoreferenceOutcome] דרך Navigator.pop כשמאשרים.
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

  // יישור TPS למפות לא-ישרות (מצולמות/משורטטות) — זמין רק כשה-GDAL המצורף קיים
  bool _tpsMode = false;

  // מצב אוטומטי — הצעות עוגנים מ-Gemini הממתינות לאישור פר-נקודה
  List<GeminiAnchorSuggestion> _suggestions = [];
  bool _aiBusy = false;
  bool _warping = false;


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
      ..showSnackBar(
        SnackBar(
          content: Text(
            count > 0
                ? 'נטענו $count מקורות מפה מהתיקייה'
                : 'לא נמצאו קבצי מפה נתמכים בתיקייה',
          ),
        ),
      );
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
        points: complete.map((p) => (pixel: p.pixel, world: p.world!)).toList(),
        imageWidth: _imageWidth,
        imageHeight: _imageHeight,
      );
      setState(() => _result = result);
    } catch (e) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('שגיאת חישוב: $e')));
    }
  }

  Future<void> _confirm() async {
    final result = _result;
    if (result == null || _warping) return;

    // affine רגיל — התמונה המקורית + הפינות המחושבות.
    if (!_tpsMode) {
      Navigator.pop(
        context,
        GeoreferenceOutcome(result: result, transform: 'affine'),
      );
      return;
    }

    // TPS — מיישרים את הרסטר עצמו (gdalwarp -tps בתהליך) ומחזירים את
    // ה-PNG המיושר + הפינות שלו. הצרכן ב-LiveMaps לא משתנה.
    setState(() => _warping = true);
    try {
      final complete = _points.where((pt) => pt.isComplete).toList();
      final tmp = await getTemporaryDirectory();
      final dst = p.join(
        tmp.path,
        'tps_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      final warped = await GdalWarpService.warpTps(
        srcImagePath: widget.imagePath,
        points: complete
            .map((pt) => (pixel: pt.pixel, world: pt.world!))
            .toList(),
        dstPngPath: dst,
      );
      if (!mounted) return;
      Navigator.pop(
        context,
        GeoreferenceOutcome(
          result: warped.result,
          transform: 'tps',
          warpedImagePath: warped.pngPath,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _warping = false);
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('יישור TPS נכשל: $e')));
    }
  }

  // ═══ גלאי הצמתים המקומי (בלי AI, בלי רשת) ═══

  /// מציג/מסתיר את צמתי-הגלאי על התמונה. הריצה ב-Isolate (הדילול כבד).
  // ═══ מצב אוטומטי — הצעת עוגנים (Gemini) ═══

  Future<void> _runAiSuggest() async {
    if (_aiBusy) return;
    // מפתח API נדרש רק במנוע-הענן; מודל מקומי (Ollama) לא צריך.
    var key = '';
    if (await AiEngine.engine() == AiEngine.gemini) {
      var k = await GeminiAnchorService.getApiKey();
      k ??= await _promptApiKey();
      if (k == null || !mounted) return;
      key = k;
    }
    if (!mounted) return;

    // רמז-מיקום — מנחה את איתור האזור (שלב הג'יאוקודינג); null = ביטול.
    final opts = await _promptAreaHint();
    if (opts == null || !mounted) return;

    setState(() => _aiBusy = true);
    try {
      final suggestions = await GeminiAnchorService().suggestAnchors(
        imagePath: widget.imagePath,
        imageWidth: _imageWidth,
        imageHeight: _imageHeight,
        apiKey: key,
        areaHint: opts.hint.isEmpty ? null : opts.hint,
        northUp: opts.northUp,
        onStatus: (status) {
          if (!mounted) return;
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              SnackBar(
                content: Text(status),
                duration: const Duration(minutes: 2),
              ),
            );
        },
      );
      if (!mounted) return;
      // עוגנים שנדחו כבר באימות מסומנים verified:false — המסך החדש
      // יראה אותם פסולים-כברירת-מחדל (המשתמש יכול לשחזר).
      final usable = suggestions.where((s) => s.verified != false).toList();
      if (usable.length < 3) {
        final rejected = suggestions.length - usable.length;
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text('לא נמצאו מספיק עוגנים'
                  '${rejected > 0 ? ' ($rejected נדחו)' : ''} — נעץ ידנית'),
              duration: const Duration(seconds: 6),
            ),
          );
        return;
      }
      ScaffoldMessenger.of(context).clearSnackBars();
      // מסך "כוונון ואישור" — בד-שילוב יחיד, הכל מאושר כברירת-מחדל.
      final approved =
          await Navigator.push<List<({Offset pixel, LatLng world})>>(
        context,
        MaterialPageRoute(
          builder: (_) => AdjustVerifyScreen(
            imagePath: widget.imagePath,
            imageWidth: _imageWidth,
            imageHeight: _imageHeight,
            suggestions: suggestions,
            refMap: _refMap,
          ),
        ),
      );
      if (!mounted || approved == null || approved.length < 3) return;
      setState(() {
        _points
          ..clear()
          ..addAll([
            for (final a in approved) _ControlPoint(pixel: a.pixel)..world = a.world,
          ]);
        _suggestions = [];
        _isOnMap = false;
        _result = null;
      });
      _calculate();
      if (_result != null) await _confirm();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('הצעת עוגנים נכשלה: $e')));
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  Future<String?> _promptApiKey() async {
    final ctrl = TextEditingController();
    final key = await showDialog<String>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('מפתח Gemini API'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'להצעת עוגנים אוטומטית נדרש מפתח API של Google '
                'Gemini (נשמר מקומית במכשיר).\nאפשר להנפיק חינם ב-'
                'aistudio.google.com/apikey',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'API Key',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('ביטול'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('שמור'),
            ),
          ],
        ),
      ),
    );
    if (key == null || key.isEmpty) return null;
    await GeminiAnchorService.setApiKey(key);
    return key;
  }

  /// דיאלוג רמז-מיקום לפני ההרצה. מחזיר את הטקסט ('' = בלי רמז) או null
  /// בביטול. הרמז נשמר לפריפיל בהרצה הבאה.
  Future<({String hint, bool northUp})?> _promptAreaHint() async {
    final ctrl = TextEditingController(
      text: await GeminiAnchorService.getAreaHint() ?? '',
    );
    if (!mounted) return null;
    var northUp = true; // רוב מפות-היישוב מיושרות-צפון
    final result = await showDialog<({String hint, bool northUp})>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: StatefulBuilder(
          builder: (ctx, setDlg) => AlertDialog(
            title: const Text('רמז מיקום (אופציונלי)'),
            // גלילה — במסך-טלפון עם מקלדת פתוחה התוכן חורג (פס צהוב-שחור).
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'שם היישוב/האזור של המפה עוזר לאתר את האזור לפני '
                    'התאמת הנקודות.',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'למשל: נוב רמת הגולן',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (v) =>
                        Navigator.pop(ctx, (hint: v.trim(), northUp: northUp)),
                  ),
                  CheckboxListTile(
                    value: northUp,
                    onChanged: (v) => setDlg(() => northUp = v ?? true),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('המפה מיושרת לצפון (צפון למעלה)'),
                    subtitle: const Text(
                      'מומלץ למפות יישוב — התאמה מהירה ומדויקת בהרבה. '
                      'בטל רק אם המפה מסובבת.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('ביטול'),
              ),
              ElevatedButton.icon(
                onPressed: () => Navigator.pop(
                    ctx, (hint: ctrl.text.trim(), northUp: northUp)),
                icon: const Icon(Icons.auto_awesome),
                label: const Text('הרץ'),
              ),
            ],
          ),
        ),
      ),
    );
    if (result != null && result.hint.isNotEmpty) {
      await GeminiAnchorService.setAreaHint(result.hint);
    }
    return result;
  }

  /// אישור/דחייה של הצעת-עוגן בודדת — הלב של "אישור פר-נקודה".
  ///
  /// הדיאלוג מציג את הנקודה על מפת-ייחוס (מפה/לוויין), וכשיש מספיק נקודות
  /// (3+ מאושרות+מוצעות) — גם את המפה החדשה עצמה שקופה מעל הרקע, עם סליידר
  /// שקיפות, כדי לשפוט ויזואלית אם העיגון נכון.
  void _showSuggestionDialog(int index) {
    final s = _suggestions[index];

    // affine זמני מכל הנקודות הידועות (מאושרות + כל ההצעות) — רק לתצוגת
    // השילוב-השקוף; לא נשמר. bounds מיושר-צירים, אז סיבוב יוצג בקירוב.
    WorldFileResult? provisional;
    final ctrlPts = [
      ..._points
          .where((p) => p.isComplete)
          .map((p) => (pixel: p.pixel, world: p.world!)),
      ..._suggestions.map((g) => (pixel: g.pixel, world: g.world)),
    ];
    if (ctrlPts.length >= 3 && _imageWidth > 0) {
      try {
        provisional = WorldFileParserService.calculateFromControlPoints(
          points: ctrlPts,
          imageWidth: _imageWidth,
          imageHeight: _imageHeight,
        );
      } catch (_) {}
    }

    double overlayOpacity = 0.55;
    bool satellite = false;

    showDialog<void>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: StatefulBuilder(
          builder: (ctx, setDlg) => Dialog(
            insetPadding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.auto_awesome,
                          color: Colors.purple,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            s.name,
                            style: Theme.of(ctx).textTheme.titleMedium,
                          ),
                        ),
                        _verificationBadge(s),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'זוהה לפי: ${s.basis} · ביטחון: '
                          '${(s.confidence * 100).round()}%',
                          style: const TextStyle(fontSize: 13),
                        ),
                        if (s.verifyNote != null && s.verifyNote!.isNotEmpty)
                          Text(
                            'אימות: ${s.verifyNote}',
                            style: TextStyle(
                              fontSize: 12,
                              color: s.verified == false
                                  ? Colors.red[700]
                                  : Colors.grey[700],
                            ),
                          ),
                        Text(
                          '${s.world.latitude.toStringAsFixed(6)}, '
                          '${s.world.longitude.toStringAsFixed(6)}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // הנקודה על מפת-הייחוס, עם שילוב-שקוף של המפה החדשה
                  SizedBox(
                    height: 300,
                    child: Stack(
                      children: [
                        FlutterMap(
                          options: MapOptions(
                            initialCenter: s.world,
                            initialZoom: 15,
                          ),
                          children: [
                            satellite
                                ? const SatelliteOnlineSource().buildTileLayer()
                                : _refMap.buildActiveTileLayer(),
                            if (provisional != null)
                              OverlayImageLayer(
                                overlayImages: [
                                  OverlayImage(
                                    bounds: LatLngBounds(
                                      provisional.southWest,
                                      provisional.northEast,
                                    ),
                                    imageProvider: FileImage(
                                      File(widget.imagePath),
                                    ),
                                    opacity: overlayOpacity,
                                  ),
                                ],
                              ),
                            MarkerLayer(
                              markers: [
                                Marker(
                                  point: s.world,
                                  width: 30,
                                  height: 30,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: Colors.purple,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 2,
                                      ),
                                      boxShadow: const [
                                        BoxShadow(
                                          color: Colors.black38,
                                          blurRadius: 4,
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.auto_awesome,
                                      color: Colors.white,
                                      size: 15,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        // בורר רקע: מפת-הייחוס הפעילה / לוויין
                        Positioned(
                          top: 8,
                          left: 8,
                          child: Material(
                            elevation: 2,
                            borderRadius: BorderRadius.circular(8),
                            child: SegmentedButton<bool>(
                              style: const ButtonStyle(
                                visualDensity: VisualDensity.compact,
                              ),
                              segments: const [
                                ButtonSegment(
                                  value: false,
                                  label: Text('מפה'),
                                  icon: Icon(Icons.map, size: 16),
                                ),
                                ButtonSegment(
                                  value: true,
                                  label: Text('לוויין'),
                                  icon: Icon(Icons.satellite_alt, size: 16),
                                ),
                              ],
                              selected: {satellite},
                              onSelectionChanged: (sel) =>
                                  setDlg(() => satellite = sel.first),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // סליידר שקיפות המפה החדשה מעל הרקע
                  if (provisional != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.opacity,
                            size: 18,
                            color: Colors.grey,
                          ),
                          const SizedBox(width: 4),
                          const Text(
                            'שקיפות המפה החדשה',
                            style: TextStyle(fontSize: 12),
                          ),
                          Expanded(
                            child: Slider(
                              value: overlayOpacity,
                              onChanged: (v) =>
                                  setDlg(() => overlayOpacity = v),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Text(
                        'שילוב-שקוף של המפה החדשה יוצג כשיש 3+ נקודות/הצעות',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton.icon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            setState(() => _suggestions.removeAt(index));
                          },
                          icon: const Icon(Icons.close, color: Colors.red),
                          label: const Text(
                            'דחה',
                            style: TextStyle(color: Colors.red),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            setState(() {
                              _points.add(
                                _ControlPoint(pixel: s.pixel)
                                  ..world = s.world,
                              );
                              _suggestions.removeAt(index);
                              _result = null;
                            });
                          },
                          icon: const Icon(Icons.check),
                          label: const Text('אשר נקודה'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// תג סטטוס האימות של הצעת-עוגן (אומת / נכשל / לא בוצע).
  Widget _verificationBadge(GeminiAnchorSuggestion s) {
    final (color, icon, label) = switch (s.verified) {
      true => (Colors.green, Icons.verified, 'אומת מול המפה'),
      false => (Colors.red, Icons.gpp_bad, 'נכשל באימות'),
      null => (Colors.grey, Icons.help_outline, 'לא אומת'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, color: color)),
        ],
      ),
    );
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
            if (_points[index].isComplete)
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
              title: const Text(
                'מחק נקודה',
                style: TextStyle(color: Colors.red),
              ),
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
          actions: [
            // מצב אוטומטי — הצעת עוגנים מ-Gemini עם אישור פר-נקודה
            _aiBusy
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14),
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.auto_awesome),
                    tooltip: 'הצעת עוגנים אוטומטית (AI)',
                    onPressed: _runAiSuggest,
                  ),
          ],
        ),
        body: Column(
          children: [
            Expanded(child: _isOnMap ? _buildMapView() : _buildImageView()),

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
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
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
                        // גם נקודה לא-גמורה (נעיצת-סרק) חייבת להיות ניתנת
                        // למחיקה — אחרת אין דרך לבטל אותה.
                        onPressed: () => _showPointMenu(i),
                      ),
                    );
                  }),
                ),
              ),

            // יישור TPS למפות לא-ישרות (מצולמות/משורטטות ביד)
            if (GdalWarpService.isSupportedPlatform)
              SwitchListTile(
                dense: true,
                value: _tpsMode,
                onChanged: _warping
                    ? null
                    : (v) => setState(() => _tpsMode = v),
                title: const Text('מפה לא ישרה — יישור עיוותים (TPS)'),
                subtitle: _tpsMode
                    ? const Text('מומלץ 5+ נקודות מפוזרות על כל המפה')
                    : null,
                secondary: const Icon(Icons.transform),
              ),

            // כפתורים — SafeArea + רווח תחתון ~1.5 ס"מ כדי לא להיחתך ע"י
            // סרגל הניווט/gesture bar במובייל (כלל גלובלי לכל המסכים).
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 56),
                child: _result != null
                    ? _buildResultButtons()
                    : _buildPickButtons(canCalculate),
              ),
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
            onPressed: _warping ? null : _confirm,
            icon: _warping
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.check),
            label: Text(
              _warping
                  ? 'מיישר (TPS)...'
                  : _tpsMode
                  ? 'אשר ויישר (TPS)'
                  : 'אשר',
            ),
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
                  // הצעות AI סגולות — ממתינות לאישור פר-נקודה
                  ..._buildSuggestionMarkers(),
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
                            _result!.southWest,
                            _result!.northEast,
                          ),
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
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  /// סמני הצעות-AI סגולים על התמונה; לחיצה פותחת אישור/דחייה.
  /// צבע המסגרת משקף את תוצאת האימות מול מפת-הייחוס: ירוק — אומת,
  /// אדום — נכשל, לבן — לא בוצע.
  List<Widget> _buildSuggestionMarkers() {
    final scale = _displayScale;
    return _suggestions.asMap().entries.map((entry) {
      final i = entry.key;
      final s = entry.value;
      final borderColor = switch (s.verified) {
        true => Colors.greenAccent,
        false => Colors.redAccent,
        null => Colors.white,
      };
      return Positioned(
        left: s.pixel.dx * scale - 14,
        top: s.pixel.dy * scale - 14,
        child: GestureDetector(
          onTap: () => _showSuggestionDialog(i),
          child: Tooltip(
            message: s.name,
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: Colors.purple,
                shape: BoxShape.circle,
                border: Border.all(color: borderColor, width: 2),
                boxShadow: const [
                  BoxShadow(color: Colors.black38, blurRadius: 4),
                ],
              ),
              child: const Icon(
                Icons.auto_awesome,
                color: Colors.white,
                size: 14,
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
    // כשיש הצעות-AI ממתינות — לחיצה ישירה על התמונה (לא על סמן) לא נועצת
    // נקודה חדשה: היא הייתה מוסיפה נקודת-סרק ומעבירה למצב-מפה, ומאבדת את
    // זרימת אישור-ההצעות. להוספה ידנית מכוונת יש את מצב-הצלב.
    if (_suggestions.isNotEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'יש הצעות AI ממתינות — לחץ על סמן סגול לאישור. '
              'להוספה ידנית עבור למצב-צלב (הכפתור בפינה).',
            ),
            duration: Duration(seconds: 3),
          ),
        );
      return;
    }

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
                  .map(
                    (entry) => Marker(
                      point: entry.value.world!,
                      width: 24,
                      height: 24,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: Center(
                          child: Text(
                            '${entry.key + 1}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
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
                        .map(
                          (s) => PopupMenuItem(
                            value: s,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (s.id == _refMap.active.id)
                                  const Icon(
                                    Icons.check,
                                    size: 16,
                                    color: Colors.green,
                                  )
                                else
                                  const SizedBox(width: 16),
                                const SizedBox(width: 6),
                                Text(s.displayName),
                              ],
                            ),
                          ),
                        )
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
