import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/elevation_service.dart';
import '../services/gdal_warp_service.dart';
import '../services/gemini_anchor_service.dart';
import '../services/grid_coord_service.dart';
import '../services/ocr_service.dart';
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

  // מצב **רשת-קואורדינטות**: הקשה על צלב-רשת → OCR קורא את הקואורדינטה
  // המודפסת (ITM/UTM) וממלא את ה-world אוטומטית. דורש Tesseract (Windows).
  bool _gridMode = false;
  bool _gridBusy = false;
  // טקסט-שלב בזמן OCR **מפורש** (⊞) — חלון-חוסם עם פס-אנימציה.
  String? _progressText;
  bool _autoTried = false; // ניסיון-אוטומטי בטעינה — פעם אחת
  bool _autoCancelled = false; // המשתמש דילג/ביטל את הזיהוי
  // זיהוי-**רקע** (בטעינה) — לא-חוסם; אינדיקטור קטן בפינה. המשתמש עובד
  // במקביל, וכשנמצאת רשת מוצג/מוצע בלי שבזבזנו זמן על מפות בלי-רשת.
  bool _autoRunning = false; // זיהוי-הרשת ברקע
  bool _autoClassicalRunning = false; // מנוע-הכבישים ברקע (במקביל לרשת)
  bool _autoGridDone = false; // הרשת סיימה (עם/בלי תוצאה)
  bool _autoRoadDone = false; // הכבישים סיימו
  bool _autoOffered = false; // הבוחר כבר הוצג (מונע כפילות)
  // תוצאות שני המנועים — נשמרות **לצמיתות** כדי שאפשר יהיה לעבור ביניהן
  // (ולחזור לידני) דרך כפתור-הבוחר הקבוע, גם אחרי שבחרנו אחת.
  List<({Offset pixel, double e, double n, String crs})>? _autoGridResult;
  List<GeminiAnchorSuggestion>? _autoRoadResult;
  // צילום העבודה-הידנית האחרונה לפני החלת אפשרות אוטומטית — לשחזור "חזרה
  // לידני". `_pointsAreAuto` מבחין בין נקודות-ידניות לנקודות-מאפשרות-אוטו.
  List<_ControlPoint>? _savedManualPoints;
  bool _pointsAreAuto = false;
  // מסך-הבחירה (hub): החץ-אחורה מציג אותו במקום לצאת; תמיד יש בו "חזור
  // לידני", וכשמנוע-אוטומטי מסיים — תוצאותיו מופיעות בו.
  bool _showChooser = false;
  String? _hintName; // שם-האזור שנגזר משם-הקובץ (לרמז המסלול-הקלאסי)
  img.Image? _scanImage; // התמונה המפוענחת (לחיתוך חלונות-OCR)
  // צלבי-רשת שנקראו: פיקסל + קואורדינטה מוקרנת (מטרים) + CRS.
  final List<({Offset pixel, double e, double n, String crs})> _gridTicks = [];
  LatLng? _mapCenteredOn; // הנקודה שעליה מפת-הווידוא כבר מורכזה

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

  // ---- פקדי-מפה נוספים (סרגל-קנה-מידה/חץ-צפון/קריאת-קואורדינטה/רשת) ----
  // שירות ההקרנה — לשימוש חוזר בהמרות WGS84↔מוקרן.
  final WorldFileParserService _projSvc = WorldFileParserService();
  // פורמט קריאת-הקואורדינטה: 0=ITM, 1=UTM 36N, 2=lat/lon.
  int _coordFormat = 0;
  // מרכז-המפה הנוכחי לקריאה (מתעדכן בזמן הזזה).
  LatLng? _cursorCenter;
  // סוג רשת-הקואורדינטות המצוירת: null=כבוי, 'itm', 'utm'.
  String? _gridType;
  // שכבת-על "כבישים ותוויות" (Esri Reference) מעל מפת-הבסיס.
  bool _roadsOverlay = false;
  // תצוגה-מקדימה מרחפת: שקיפות-השילוב ורקע-לוויין.
  double _previewOpacity = 0.6;
  bool _previewSatellite = false;
  // גובה (מטרים) במרכז-המפה — נשלף מ-API בהשהיה; null עד שנטען.
  double? _cursorElevation;
  Timer? _elevDebounce;
  // מרכז-רמז מהשם-קובץ (ג'יאוקוד) — הדקירה הראשונה במצב-ידני תיפתח שם.
  LatLng? _hintCenter;
  // מנוי לאירועי-המפה (הזזה) — מבוטל ב-dispose.
  StreamSubscription? _mapEventSub;

  // תוצאה
  WorldFileResult? _result;

  // יישור TPS למפות לא-ישרות (מצולמות/משורטטות) — זמין רק כשה-GDAL המצורף קיים
  bool _tpsMode = false;

  // מצב אוטומטי — הצעות עוגנים מ-Gemini הממתינות לאישור פר-נקודה
  List<GeminiAnchorSuggestion> _suggestions = [];
  bool _warping = false;


  @override
  void initState() {
    super.initState();
    _loadImageSize();
    _refMap.addListener(_onRefMapChanged);
    // גילוי אוטומטי של קבצי-מפה בתיקיית-הייחוס המשתמעת (reference_maps).
    _refMap.loadDefaultFolder();
    // זמינות-OCR (Tesseract) — מנוע-הרשת רץ אוטומטית בטעינה אם קיים.
    OcrService.available().then((ok) {
      if (!mounted) return;
      // מנוע-הרשת רץ **אוטומטית בטעינה** (במקביל למנוע-הכבישים). אם אין
      // OCR — מסמנים את הרשת כ"סיימה" (בלי תוצאה) כדי שהבוחר עדיין יופיע
      // עבור תוצאת-הכבישים.
      if (ok && !_autoTried) {
        _autoTried = true;
        _autoDetectGrid(silent: true);
      } else if (!ok) {
        _autoGridDone = true;
        _maybeOfferAuto();
      }
    });
    // רמז-מיקום משם-הקובץ → ואז מנוע-הכבישים ברקע (או סימון "סיים" אם אין רמז).
    _resolveFilenameHint().then((_) => _kickRoadEngine());
    // מעקב אחר הזזת-המפה — מעדכן את קריאת-הקואורדינטה ואת רשת-הקואורדינטות.
    _mapEventSub = _mapController.mapEventStream.listen((_) {
      if (!mounted) return;
      final c = _mapController.camera.center;
      setState(() => _cursorCenter = c);
      // גובה: שליפה מושהית (600ms) שלא להציף את ה-API בזמן גרירה.
      _elevDebounce?.cancel();
      _elevDebounce = Timer(const Duration(milliseconds: 600), () async {
        final e = await ElevationService.elevationAt(c);
        if (mounted) setState(() => _cursorElevation = e);
      });
    });
  }

  @override
  void dispose() {
    _elevDebounce?.cancel();
    _refMap.removeListener(_onRefMapChanged);
    _mapEventSub?.cancel();
    _transformController.dispose();
    super.dispose();
  }

  // ---- עזרי פקדי-המפה ----

  /// טקסט קריאת-הקואורדינטה של מרכז-המפה, לפי הפורמט הנבחר.
  String _coordReadout(LatLng ll) {
    switch (_coordFormat) {
      case 0: // ITM
        final p = _projSvc.wgs84ToProjected(ll, 'EPSG:2039');
        return 'ITM  E ${p.x.round()}  N ${p.y.round()}';
      case 1: // UTM 36N
        final p = _projSvc.wgs84ToProjected(ll, 'EPSG:32636');
        return 'UTM36N  E ${p.x.round()}  N ${p.y.round()}';
      default: // lat/lon
        return '${ll.latitude.toStringAsFixed(5)}, '
            '${ll.longitude.toStringAsFixed(5)}';
    }
  }

  /// מרווח-הרשת (מטרים) לפי רמת-הזום — קווים צפופים בזום גבוה.
  double _gridInterval(double zoom) {
    if (zoom >= 15) return 500;
    if (zoom >= 13) return 1000;
    return 2000;
  }

  /// בונה את קווי-רשת-הקואורדינטות (ITM/UTM) בתחום-הנראה של המפה.
  /// כל קו נדגם בכמה נקודות ומומר חזרה ל-WGS84 כדי לעקוב אחר עיוות-ההקרנה.
  List<Polyline> _buildGridLines() {
    final type = _gridType;
    if (type == null) return const [];
    final crs = type == 'utm' ? 'EPSG:32636' : 'EPSG:2039';
    final MapCamera cam;
    try {
      cam = _mapController.camera;
    } catch (_) {
      return const [];
    }
    final bounds = cam.visibleBounds;
    final sw = _projSvc.wgs84ToProjected(bounds.southWest, crs);
    final ne = _projSvc.wgs84ToProjected(bounds.northEast, crs);
    // גבולות-מוקרנים (מרחיבים מעט למקרה של סיבוב-הקרנה קל).
    final minE = min(sw.x, ne.x);
    final maxE = max(sw.x, ne.x);
    final minN = min(sw.y, ne.y);
    final maxN = max(sw.y, ne.y);
    final step = _gridInterval(cam.zoom);
    // הגנה מפני יותר מדי קווים (למשל תחום ענק בזום נמוך).
    if ((maxE - minE) / step > 200 || (maxN - minN) / step > 200) {
      return const [];
    }
    final color = Colors.orange.withValues(alpha: 0.5);
    final lines = <Polyline>[];
    const samples = 8; // דגימות לאורך כל קו — לקירוב עקומת-ההקרנה.

    // קווים אנכיים (easting קבוע), נדגמים לאורך ה-northing.
    final firstE = (minE / step).ceil() * step;
    for (double e = firstE; e <= maxE; e += step) {
      final pts = <LatLng>[];
      for (int i = 0; i <= samples; i++) {
        final n = minN + (maxN - minN) * i / samples;
        pts.add(_projSvc.projectToWgs84(e, n, crs));
      }
      lines.add(Polyline(points: pts, color: color, strokeWidth: 1));
    }
    // קווים אופקיים (northing קבוע), נדגמים לאורך ה-easting.
    final firstN = (minN / step).ceil() * step;
    for (double n = firstN; n <= maxN; n += step) {
      final pts = <LatLng>[];
      for (int i = 0; i <= samples; i++) {
        final e = minE + (maxE - minE) * i / samples;
        pts.add(_projSvc.projectToWgs84(e, n, crs));
      }
      lines.add(Polyline(points: pts, color: color, strokeWidth: 1));
    }
    return lines;
  }

  /// חישוב-מקורב של אורך סרגל-קנה-המידה: מספר-עגול של מטרים ורוחבו בפיקסלים.
  ({double widthPx, String label}) _scaleBarMetrics() {
    final MapCamera cam;
    try {
      cam = _mapController.camera;
    } catch (_) {
      return (widthPx: 0, label: '');
    }
    // מטרים-לפיקסל ב-web-mercator בקו-הרוחב הנוכחי.
    final lat = cam.center.latitude;
    final metersPerPixel =
        156543.03392 * cos(lat * pi / 180) / pow(2, cam.zoom);
    const maxBarPx = 120.0; // רוחב-מטרה מקסימלי לסרגל.
    final maxMeters = metersPerPixel * maxBarPx;
    // בחירת מספר-עגול "נחמד" (1/2/5 × עשרוני) שאינו עולה על maxMeters.
    final pow10 = pow(10, (log(maxMeters) / ln10).floor()).toDouble();
    double nice;
    if (maxMeters / pow10 >= 5) {
      nice = 5 * pow10;
    } else if (maxMeters / pow10 >= 2) {
      nice = 2 * pow10;
    } else {
      nice = pow10;
    }
    final widthPx = nice / metersPerPixel;
    final label = nice >= 1000
        ? '${(nice / 1000).toStringAsFixed(nice % 1000 == 0 ? 0 : 1)} ק"מ'
        : '${nice.round()} מ\'';
    return (widthPx: widthPx, label: label);
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

  /// גוזר שם-מקום משם-הקובץ (מסיר "מפה/מפת", מספרים, "page N") ומריץ
  /// ג'יאוקוד ב-Nominatim (מוגבל לישראל) → [_hintCenter]. הדקירה-הראשונה
  /// במצב-ידני תיפתח שם (אחר-כך ממרכזים לנקודה הקודמת דרך [_lastWorldPoint]).
  Future<void> _resolveFilenameHint() async {
    // ⚠️ בלי \b — הוא ASCII ולא תופס אותיות עבריות (משאיר "מפת" ומכשיל
    // את הג'יאוקוד). מסירים "מפה/מפת/מושב/קיבוץ" ומספרים ישירות.
    var name = p
        .basenameWithoutExtension(widget.imagePath)
        .replaceAll(RegExp(r'[_\- ]?page ?\d+', caseSensitive: false), '')
        .replaceAll(RegExp(r'מפ[הת]'), ' ')
        .replaceAll(RegExp(r'[0-9]+'), ' ')
        .replaceAll(RegExp(r'[_\-]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (name.length < 2) return;
    _hintName = name; // לרמז המסלול-הקלאסי (Overpass) — נצרך ב-_kickRoadEngine
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?q=${Uri.encodeComponent(name)}&countrycodes=il&format=json&limit=1',
      );
      final r = await http
          .get(uri, headers: {'User-Agent': 'auto_maps/1.0'})
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return;
      final list = jsonDecode(r.body) as List;
      if (list.isEmpty) return;
      final m = list.first as Map<String, dynamic>;
      final lat = double.tryParse('${m['lat']}');
      final lon = double.tryParse('${m['lon']}');
      if (lat != null && lon != null && mounted) {
        setState(() => _hintCenter = LatLng(lat, lon));
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            content: Text('אזור מהשם-קובץ: "$name" — המפה תיפתח שם'),
            duration: const Duration(seconds: 3),
          ));
      }
    } catch (_) {}
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
      _pointsAreAuto = false; // עריכה-ידנית — הנקודות שוב "ידניות"
    });
  }

  void _pickOnMap(LatLng position) {
    setState(() {
      final idx = _editingIndex ?? (_points.length - 1);
      _points[idx].world = position;
      _isOnMap = false;
      _editingIndex = null;
      _result = null;
      _pointsAreAuto = false;
    });
  }

  /// שכבת-שילוב של התמונה מעל מפת-הייחוס. `RotatedOverlayImage` מ-3 הפינות
  /// האמיתיות → מסתובב נכון למפה מסובבת; למיושרת-צפון זהה ל-OverlayImage.
  BaseOverlayImage _rotatedOverlay(WorldFileResult r, double opacity) {
    final provider = FileImage(File(widget.imagePath));
    final c = r.cornersWgs84;
    if (c != null && c.length == 4) {
      return RotatedOverlayImage(
        topLeftCorner: c[0], // NW
        bottomLeftCorner: c[3], // SW
        bottomRightCorner: c[2], // SE
        imageProvider: provider,
        opacity: opacity,
      );
    }
    return OverlayImage(
      bounds: LatLngBounds(r.southWest, r.northEast),
      imageProvider: provider,
      opacity: opacity,
    );
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
                            ...(satellite
                                ? [SatelliteOnlineSource.baseTile]
                                : _refMap.buildActiveTileLayers()),
                            if (provisional != null)
                              OverlayImageLayer(overlayImages: [
                                _rotatedOverlay(provisional, overlayOpacity),
                              ]),
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
      // יירוט כפתור-החזור: במצב-עריכה → מציג את מסך-הבחירה (hub) במקום
      // לצאת; במסך-הבחירה עצמו → יוצא כרגיל (canPop=true).
      child: PopScope(
        canPop: _showChooser,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop || _showChooser) return;
          setState(() => _showChooser = true);
        },
        child: Scaffold(
          appBar: AppBar(
            title: _showChooser
                ? const Text('בחירת מקור התאמה')
                : Text('ג\'יאורפרנס ($_completeCount / $_minPoints נקודות)'),
          ),
        body: _showChooser
            ? _buildChooserView()
            : Column(
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
      ),
    );
  }

  /// **מסך-הבחירה (hub)** — נגיש דרך כפתור-החזור. תמיד יש בו "עבודה ידנית"
  /// (גם בהתחלה, לפני שהמנועים סיימו); כשמנוע מסתיים תוצאתו מופיעה כאן.
  Widget _buildChooserView() {
    final grid = _autoGridResult;
    final road = _autoRoadResult;
    final saved = _savedManualPoints;
    final running = _autoRunning || _autoClassicalRunning;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 56),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'בחר מקור-התאמה. אפשר לעבור ביניהם בכל עת דרך '
                    'כפתור-החזור.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 15),
                  ),
                  const SizedBox(height: 24),
                  // תוצאות אוטומטיות ראשונות (רשת/כבישים), והידני **אחרון**.
                  if (grid != null) ...[
                    FilledButton.icon(
                      icon: const Icon(Icons.grid_on),
                      label:
                          Text('רשת-קואורדינטות (${grid.length} נקודות)'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.teal,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      onPressed: () {
                        setState(() => _showChooser = false);
                        _applyGridTicks(grid);
                      },
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (road != null) ...[
                    FilledButton.icon(
                      icon: const Icon(Icons.alt_route),
                      label: Text('עוגני-כבישים '
                          '(${road.where((s) => s.verified != false).length})'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.indigo,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      onPressed: () {
                        setState(() => _showChooser = false);
                        _openAdjustVerify(road);
                      },
                    ),
                    const SizedBox(height: 12),
                  ],
                  // עבודה ידנית — **תמיד** (גם בהתחלה), ותמיד אחרונה.
                  OutlinedButton.icon(
                    icon: const Icon(Icons.back_hand_outlined),
                    label: Text(saved != null && saved.isNotEmpty
                        ? 'חזרה לעבודה ידנית (${saved.length} נקודות)'
                        : 'עבודה ידנית'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    onPressed: _chooseManual,
                  ),
                  const SizedBox(height: 24),
                  if (running)
                    Column(
                      children: [
                        const Text('מריץ התאמות אוטומטיות…',
                            style: TextStyle(color: Colors.teal)),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: const LinearProgressIndicator(minHeight: 3),
                        ),
                      ],
                    )
                  else
                    // שקיפות: מנוע שסיים בלי תוצאה נרשם כאן (רץ ולא-מצא,
                    // להבדיל מ"לא-רץ") כדי שיובן למה מוצעת רק אפשרות אחת.
                    Column(
                      children: [
                        if (grid == null && _autoGridDone)
                          const Text('מנוע-הרשת: לא נמצאה רשת-קואורדינטות',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey, fontSize: 12)),
                        if (road == null && _autoRoadDone)
                          const Text('מנוע-הכבישים: לא נמצאה התאמה',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey, fontSize: 12)),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// "עבודה ידנית" מהבוחר — משחזר נקודות-ידניות שמורות (אם יש) וחוזר לעריכה.
  void _chooseManual() {
    setState(() => _showChooser = false);
    if (_savedManualPoints != null) _restoreManualPoints();
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
        // (כפתורי ✨/⊞ הוסרו — הזרימה היא האוטומטית בלבד; ידני = נעיצה רגילה.)
        // רמז למצב-הרשת
        if (_gridMode)
          Positioned(
            top: 8,
            left: 104,
            right: 8,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.teal.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'מצב רשת: הקש על צלב-רשת (פינה עם מספרי-קואורדינטה) — '
                  'הקואורדינטה תיקרא אוטומטית',
                  style: TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
          ),
        // אינדיקטור-עומס בזמן קריאת-OCR
        if (_gridBusy)
          Positioned.fill(
            child: Container(
              color: Colors.black26,
              child: Center(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.grid_on, size: 20),
                            const SizedBox(width: 8),
                            Text(
                              _progressText ?? 'קורא קואורדינטה…',
                              style: const TextStyle(fontSize: 14),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const SizedBox(
                          width: 260,
                          // אנימציה (indeterminate) שזזה כל הזמן — פס-קבוע
                          // באחוז נראה "תקוע" גם כשעובדים ברקע.
                          child: ClipRRect(
                            borderRadius: BorderRadius.all(Radius.circular(6)),
                            child: LinearProgressIndicator(minHeight: 8),
                          ),
                        ),
                        const SizedBox(height: 8),
                        // דלג — למפות בלי רשת-קואורדינטות (בזבוז זמן).
                        TextButton.icon(
                          onPressed: () => setState(() {
                            _autoCancelled = true;
                            _gridBusy = false;
                            _progressText = null;
                          }),
                          icon: const Icon(Icons.skip_next, size: 18),
                          label: const Text('דלג — נעץ ידנית'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        // אינדיקטור-רקע לא-חוסם — **בר-אינסופי** שרץ עד ששני המנועים
        // (רשת + כבישים) מסתיימים; אז מוצג הבוחר. המשתמש עובד ידנית במקביל,
        // ו-× מבטל את ההצעה (נשארים ידני).
        if (_autoRunning || _autoClassicalRunning)
          Positioned(
            top: 8,
            left: 0,
            right: 0,
            child: Center(
              child: Material(
                elevation: 3,
                borderRadius: BorderRadius.circular(14),
                color: Colors.teal.withValues(alpha: 0.94),
                child: SizedBox(
                  width: 250,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 6, 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'מריץ התאמות אוטומטיות…',
                                style: TextStyle(
                                    color: Colors.white, fontSize: 13),
                              ),
                            ),
                            InkWell(
                              onTap: () => setState(() {
                                _autoCancelled = true;
                                _autoRunning = false;
                                _autoClassicalRunning = false;
                                _autoOffered = true; // מבטל את הבוחר — ידני
                              }),
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(Icons.close,
                                    color: Colors.white, size: 16),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: const LinearProgressIndicator(
                            minHeight: 3,
                            backgroundColor: Colors.white24,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        ),
                      ],
                    ),
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
    final center = LatLng(
      (_result!.southWest.latitude + _result!.northEast.latitude) / 2,
      (_result!.southWest.longitude + _result!.northEast.longitude) / 2,
    );
    return Positioned.fill(
      child: Container(
        color: Colors.black54,
        child: Center(
          child: StatefulBuilder(
            builder: (ctx, setLocal) => FractionallySizedBox(
              widthFactor: 0.92,
              heightFactor: 0.82,
              child: Card(
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  children: [
                    // כותרת + סגירה
                    Container(
                      color: Colors.blueGrey[50],
                      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
                      child: Row(
                        children: [
                          const Icon(Icons.preview, size: 20),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text('תצוגה מקדימה — בדוק את היישור מול המפה',
                                style:
                                    TextStyle(fontWeight: FontWeight.bold)),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close),
                            tooltip: 'סגור (חזרה לעריכה)',
                            onPressed: () => setState(() => _result = null),
                          ),
                        ],
                      ),
                    ),
                    // המפה עם שילוב-שקיפות
                    Expanded(
                      child: FlutterMap(
                        options: MapOptions(
                          initialCenter: center,
                          initialZoom: 15,
                        ),
                        children: [
                          ...(_previewSatellite
                              ? [SatelliteOnlineSource.baseTile]
                              : _refMap.buildActiveTileLayers()),
                          if (_previewSatellite && _roadsOverlay)
                            ...esriRoadOverlays(),
                          OverlayImageLayer(
                            overlayImages: [
                              _rotatedOverlay(_result!, _previewOpacity),
                            ],
                          ),
                          _mapAttribution(),
                        ],
                      ),
                    ),
                    // פקדים: רקע מפה/לוויין + סליידר-שקיפות
                    Container(
                      color: Colors.blueGrey[50],
                      padding:
                          const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      child: Row(
                        children: [
                          ToggleButtons(
                            isSelected: [!_previewSatellite, _previewSatellite],
                            onPressed: (i) =>
                                setLocal(() => _previewSatellite = i == 1),
                            borderRadius: BorderRadius.circular(8),
                            constraints: const BoxConstraints(
                                minHeight: 32, minWidth: 56),
                            children: const [Text('מפה'), Text('לוויין')],
                          ),
                          const SizedBox(width: 12),
                          const Text('שקיפות'),
                          Expanded(
                            child: Slider(
                              value: _previewOpacity,
                              onChanged: (v) =>
                                  setLocal(() => _previewOpacity = v),
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

    if (_gridMode) {
      _gridTapAt(Offset(px, py));
    } else {
      _pickOnImage(Offset(px, py));
    }
  }

  /// מפענח את תמונת-הסריקה פעם אחת (ב-Isolate) לחיתוך חלונות-OCR.
  Future<img.Image?> _ensureScanImage() async {
    if (_scanImage != null) return _scanImage;
    final path = widget.imagePath;
    _scanImage = await Isolate.run(() {
      final bytes = File(path).readAsBytesSync();
      return img.decodeImage(bytes);
    });
    return _scanImage;
  }

  /// מצב רשת-קואורדינטות: הקשה על צלב → OCR קורא את הקואורדינטה המודפסת
  /// (ITM/UTM, זיהוי-CRS אוטומטי) וממלא את ה-world של הנקודה. נכשל → הודעה
  /// והנקודה מוסרת (שלא תישאר נקודה בלי-world).
  Future<void> _gridTapAt(Offset pixel) async {
    if (_gridBusy) return;
    final idx = _points.length;
    setState(() {
      _points.add(_ControlPoint(pixel: pixel));
      _isOnMap = false;
      _result = null;
      _gridBusy = true;
    });
    ({double easting, double northing, String crs})? tick;
    try {
      final scan = await _ensureScanImage();
      if (scan != null) tick = await GridCoordService.readTick(scan, pixel);
    } catch (_) {}
    if (!mounted) return;
    if (tick == null) {
      setState(() {
        _gridBusy = false;
        if (idx < _points.length) _points.removeAt(idx);
      });
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(
          content: Text('לא זוהתה קואורדינטה בנקודה — כוון על צלב-הרשת '
              '(הפינה עם המספרים) והקש שוב.'),
          duration: Duration(seconds: 4),
        ));
      return;
    }
    final world = WorldFileParserService()
        .projectToWgs84(tick.easting, tick.northing, tick.crs);
    setState(() {
      _gridBusy = false;
      _points[idx].world = world;
      _gridTicks.add((pixel: pixel, e: tick!.easting, n: tick.northing, crs: tick.crs));
    });
    // ממרכזים את מפת-הווידוא על הקואורדינטה שנקראה (כדי לא "לחפש בכל
    // הארץ"). best-effort — אם המפה עדיין לא בנויה, initialCenter יטפל.
    try {
      _mapController.move(world, 16);
    } catch (_) {}
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text('נקראה קואורדינטה (${tick.crs}): '
            'E=${tick.easting.round()} N=${tick.northing.round()}'),
        duration: const Duration(seconds: 2),
      ));
    // רשת צירית (מיושרת-צפון): 2 צלבים מספיקים. גוזרים affine-צירי
    // ומסנתזים נקודת-בקרה שלישית עקבית כדי ש-_calculate (הדורש 3) יעבוד.
    if (_gridTicks.length == 2) _synthesizeThirdGridPoint();
    _calculate();
  }

  /// מ-2 צלבי-רשת גוזר affine-צירי (E=mx·px+bx, N=my·py+by) ומוסיף נקודת-
  /// בקרה שלישית עקבית (בפינה הנגדית של המלבן) — כך הרישום מדויק-לחלוטין
  /// גם עם 2 קריאות בלבד.
  void _synthesizeThirdGridPoint() {
    final t0 = _gridTicks[0], t1 = _gridTicks[1];
    final dpx = t1.pixel.dx - t0.pixel.dx, dpy = t1.pixel.dy - t0.pixel.dy;
    if (dpx.abs() < 5 || dpy.abs() < 5) return; // כמעט על אותו ציר — לא ניתן
    final mx = (t1.e - t0.e) / dpx, bx = t0.e - (t1.e - t0.e) / dpx * t0.pixel.dx;
    final my = (t1.n - t0.n) / dpy, by = t0.n - (t1.n - t0.n) / dpy * t0.pixel.dy;
    final p3 = Offset(t1.pixel.dx, t0.pixel.dy); // פינה נגדית
    final e3 = mx * p3.dx + bx, n3 = my * p3.dy + by;
    final w3 = WorldFileParserService().projectToWgs84(e3, n3, t0.crs);
    _points.add(_ControlPoint(pixel: p3)..world = w3);
  }

  /// **זיהוי-רשת אוטומטי** — מריץ OCR מלא, מזהה ומזווג את תוויות-הקואורדינטה
  /// לבד, מציב את נקודות-הבקרה, מחשב ומציג תצוגה-מקדימה. נכשל → הודעה
  /// והמשתמש יכול להקיש ידנית.
  ///
  /// [silent] (טעינה-אוטומטית) → **לא-חוסם**: אינדיקטור קטן בפינה, המשתמש
  /// עובד במקביל, וכשנמצאת רשת (ולא התחיל ידנית) — מוצגת התצוגה-המקדימה.
  /// מפורש (⊞) → חלון-חוסם עם פס. מפה בלי-רשת → בשקט, בלי בזבוז-הפרעה.
  Future<void> _autoDetectGrid({bool silent = false}) async {
    if (_gridBusy || _autoRunning) return;
    _autoCancelled = false;
    setState(() {
      if (silent) {
        _autoRunning = true;
      } else {
        _gridBusy = true;
        _progressText = 'מתחיל זיהוי-רשת-קואורדינטות…';
      }
    });
    var ticks = const <({Offset pixel, double e, double n, String crs})>[];
    try {
      final scan = await _ensureScanImage();
      if (scan != null) {
        // ⚠️ timeout קשיח — OCR (Tesseract) על תמונה מוגדלת ×3 יכול להיות
        // איטי/להיתקע (Process.run בלי-timeout); גבול-עליון משחרר את הבר.
        ticks = await GridCoordService.autoDetectTicks(
          scan,
          onProgress: (status, frac) {
            if (!mounted || _autoCancelled) return;
            // ברקע (silent) הבר קבוע-טקסט ("מריץ התאמות…"); רק במודל (⊞)
            // מציגים את שלב-ההתקדמות.
            if (!silent) setState(() => _progressText = status);
          },
        ).timeout(
          Duration(seconds: silent ? 45 : 90),
          onTimeout: () =>
              const <({Offset pixel, double e, double n, String crs})>[],
        );
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _gridBusy = false;
      _autoRunning = false;
      _progressText = null;
    });
    if (_autoCancelled) return;
    // הרצה **מפורשת** (⊞) → מציבים ומציגים מיד.
    if (!silent) {
      if (ticks.length < 2) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(const SnackBar(
            content: Text('לא זוהתה רשת — הקש ידנית על 2 צלבי-רשת (⊞), '
                'או נעץ נקודות ידנית.'),
            duration: Duration(seconds: 4),
          ));
        return;
      }
      _applyGridTicks(ticks);
      return;
    }
    // **רקע** — שומרים את התוצאה וממתינים גם למנוע-הכבישים; הבוחר יוצג
    // כששניהם סיימו (`_maybeOfferAuto`).
    _autoGridDone = true;
    if (ticks.length >= 2) _autoGridResult = ticks;
    _maybeOfferAuto();
  }

  /// נקרא בסיום כל מנוע-רקע. כששני המנועים סיימו ולפחות אחד מצא תוצאה:
  /// אם המשתמש עדיין לא נעץ ידנית — פותח מיד את מסך-הבחירה; אם כבר עובד
  /// ידנית — סנאקבר עדין 'הצג' (כפתור-החזור תמיד יחזיר לבוחר ממילא).
  void _maybeOfferAuto() {
    if (!_autoGridDone || !_autoRoadDone) return;
    if (_autoOffered || !mounted) return;
    if (_autoGridResult == null && _autoRoadResult == null) return;
    _autoOffered = true;
    if (_points.any((p) => p.isComplete)) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          content: const Text('התאמות אוטומטיות מוכנות'),
          duration: const Duration(seconds: 10),
          action: SnackBarAction(
              label: 'הצג', onPressed: () => setState(() => _showChooser = true)),
        ));
      return;
    }
    setState(() => _showChooser = true);
  }

  /// משחזר את הנקודות-הידניות שצולמו לפני החלת האפשרות האוטומטית.
  void _restoreManualPoints() {
    final saved = _savedManualPoints;
    if (saved == null) return;
    setState(() {
      _points
        ..clear()
        ..addAll([
          for (final pt in saved) _ControlPoint(pixel: pt.pixel)..world = pt.world,
        ]);
      _gridTicks.clear();
      _suggestions = [];
      _isOnMap = false;
      _result = null;
      _pointsAreAuto = false; // חזרנו לידני
    });
    if (_points.where((p) => p.isComplete).length >= 3) _calculate();
  }

  /// לפני שהחלת אפשרות אוטומטית דורסת את הנקודות — מצלמת את העבודה-הידנית
  /// האחרונה (רק אם הנקודות הנוכחיות ידניות, לא אפשרות-אוטו קודמת), כדי
  /// שאפשר יהיה לחזור אליה. מעברי אוטו→אוטו לא דורסים את הצילום.
  void _captureManualBeforeAuto() {
    if (!_pointsAreAuto) {
      _savedManualPoints = [
        for (final pt in _points)
          _ControlPoint(pixel: pt.pixel)..world = pt.world,
      ];
    }
    _pointsAreAuto = true;
  }

  /// מציב את נקודות-הבקרה מצלבי-הרשת, מסנתז נקודה-3 ומחשב → תצוגה-מקדימה.
  void _applyGridTicks(
      List<({Offset pixel, double e, double n, String crs})> ticks) {
    _captureManualBeforeAuto();
    setState(() {
      _points.clear();
      _gridTicks.clear();
      for (final t in ticks) {
        final w = WorldFileParserService().projectToWgs84(t.e, t.n, t.crs);
        _points.add(_ControlPoint(pixel: t.pixel)..world = w);
        _gridTicks.add((pixel: t.pixel, e: t.e, n: t.n, crs: t.crs));
      }
      _result = null;
    });
    if (_gridTicks.length == 2) _synthesizeThirdGridPoint();
    _calculate();
  }

  /// מפעיל את מנוע-הכבישים ברקע אם יש רמז-שם; אחרת מסמן אותו כ"סיים" (בלי
  /// תוצאה) כדי שהבוחר עדיין יופיע עבור תוצאת-הרשת.
  void _kickRoadEngine() {
    if (!mounted) return;
    if (_hintName == null) {
      _autoRoadDone = true;
      _maybeOfferAuto();
      return;
    }
    _autoClassicalMatch();
  }

  /// **מנוע-הכבישים ברקע** — במקביל לזיהוי-הרשת. קורא קודם את **חץ-הצפון**
  /// (כמו ב-✨ הידני) ומעביר אותו למסלול-הקלאסי (Overpass+RANSAC) עם
  /// רמז-שם-הקובץ. שומר את התוצאה וממתין לשני המנועים (`_maybeOfferAuto`).
  Future<void> _autoClassicalMatch() async {
    if (_hintName == null || _autoClassicalRunning) return;
    if (_imageWidth == 0) await _loadImageSize();
    if (!mounted || _imageWidth == 0) return;
    setState(() => _autoClassicalRunning = true);
    try {
      // זיהוי-מצפן קלאסי (מחזק את המסלול-הישיר). suggestAnchors מנסה עכשiv
      // **את כל אסטרטגיות-הכיוון בקריאה אחת** (ישיר + deskew-לכל-הזוויות)
      // ובוחר את הטובה לפי-איכות — אין צורך בקריאה שנייה.
      // ⚠️ timeout קשיח — Overpass יכול לתקוע עד 75ש', וזיהוי-כפול
      // (ישיר+deskew) כבד. גבול-עליון כדי שהבר לא ייתקע; חריגה ⇒ בלי תוצאה.
      final compass = await GeminiAnchorService()
          .detectCompass(imagePath: widget.imagePath)
          .timeout(const Duration(seconds: 20), onTimeout: () => null);
      if (!mounted) return;
      final suggestions = await GeminiAnchorService()
          .suggestAnchors(
            imagePath: widget.imagePath,
            imageWidth: _imageWidth,
            imageHeight: _imageHeight,
            areaHint: _hintName,
            compassDeg: compass?.deg,
            compassResolved: compass?.resolved ?? false,
          )
          .timeout(const Duration(seconds: 50), onTimeout: () => const []);
      if (!mounted) return;
      final usable = suggestions.where((s) => s.verified != false).toList();
      if (usable.length >= 3) _autoRoadResult = suggestions;
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() {
          _autoClassicalRunning = false;
          _autoRoadDone = true;
        });
        _maybeOfferAuto();
      }
    }
  }

  /// פותח את מסך הכוונון-ואישור עם הצעות-העוגנים ומחיל את המאושרות.
  Future<void> _openAdjustVerify(
      List<GeminiAnchorSuggestion> suggestions) async {
    final approved = await Navigator.push<List<({Offset pixel, LatLng world})>>(
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
    _captureManualBeforeAuto();
    setState(() {
      _points
        ..clear()
        ..addAll([
          for (final a in approved)
            _ControlPoint(pixel: a.pixel)..world = a.world,
        ]);
      _suggestions = [];
      _isOnMap = false;
      _result = null;
    });
    // לא מאשרים-ויוצאים אוטומטית (בשונה מ-✨ הידני) — מציגים תצוגה-מקדימה
    // ונשארים במסך, כדי שאפשר יהיה לעבור לרשת/לידני מכפתור-הבוחר.
    _calculate();
  }

  // ═══ מצב מפה ═══

  /// קרדיט-מקור למפה (חובה משפטית לאריחי OSM/Esri/OpenTopoMap). מוצג
  /// קבוע בתחתית, כמו ב-navigate.
  Widget _mapAttribution() {
    final id = _refMap.active.id;
    final src = id.startsWith('osm')
        ? '© OpenStreetMap contributors'
        : id.startsWith('topo')
            ? '© OpenTopoMap (CC-BY-SA), © OpenStreetMap'
            : id.startsWith('satellite')
                ? 'לוויין © Esri, Maxar, Earthstar Geographics'
                : '© OpenStreetMap';
    return SimpleAttributionWidget(
      source: Text(src, style: const TextStyle(fontSize: 10)),
      backgroundColor: Colors.white.withValues(alpha: 0.75),
    );
  }

  Widget _buildMapView() {
    final sources = _refMap.availableSources();
    // מרכוז-אקטיבי: ה-MapController ה"דביק" זוכר מרכז ישן ומתעלם מ-
    // initialCenter ברי-בנייה. יעד: הנקודה-האחרונה (אחרי הדקירה הראשונה),
    // אחרת רמז-שם-הקובץ (הדקירה הראשונה) — מזיזים כשהיעד השתנה.
    final target = _lastWorldPoint ?? _hintCenter;
    final zoom = _lastWorldPoint != null ? 16.0 : 14.0;
    if (target != null && target != _mapCenteredOn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        try {
          _mapController.move(target, zoom);
          _mapCenteredOn = target;
        } catch (_) {}
      });
    }
    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: target ?? const LatLng(31.5, 34.8),
            initialZoom: target != null ? zoom : 8,
          ),
          children: [
            ..._refMap.buildActiveTileLayers(),
            // שכבת-על כבישים/תוויות (toggle) — מעל מפת-הבסיס
            if (_roadsOverlay) ...esriRoadOverlays(),
            // רשת-קואורדינטות (ITM/UTM) — נצבעת מתחת למרקרים
            if (_gridType != null)
              PolylineLayer(polylines: _buildGridLines()),
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
            _mapAttribution(),
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
        // חץ-צפון + כפתור-רשת (המפות מיושרות-צפון) — פינה שמאלית-עליונה
        Positioned(
          top: 8,
          left: 8,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // חץ-צפון סטטי
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: const [
                    BoxShadow(color: Colors.black26, blurRadius: 2),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.navigation, size: 18, color: Colors.red),
                    Text(
                      'צ',
                      style: TextStyle(
                        fontSize: 9,
                        height: 1,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey[800],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              // בורר רשת-הקואורדינטות: כבוי / ITM / UTM
              Material(
                elevation: 2,
                borderRadius: BorderRadius.circular(8),
                color: _gridType != null ? Colors.orange[50] : Colors.white,
                child: PopupMenuButton<String>(
                  tooltip: 'רשת קואורדינטות',
                  icon: Icon(
                    Icons.grid_on,
                    size: 20,
                    color: _gridType != null
                        ? Colors.orange[800]
                        : Colors.grey[700],
                  ),
                  onSelected: (v) => setState(
                    () => _gridType = v == 'off' ? null : v,
                  ),
                  itemBuilder: (ctx) => [
                    _gridMenuItem('off', 'ללא רשת', _gridType == null),
                    _gridMenuItem('itm', 'רשת ITM', _gridType == 'itm'),
                    _gridMenuItem('utm', 'רשת UTM 36N', _gridType == 'utm'),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              // toggle כבישים/תוויות מעל מפת-הבסיס (בעיקר לוויין)
              Material(
                elevation: 2,
                borderRadius: BorderRadius.circular(8),
                color: _roadsOverlay ? Colors.teal[50] : Colors.white,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => setState(() => _roadsOverlay = !_roadsOverlay),
                  child: Tooltip(
                    message: 'כבישים ותוויות (מעל הלוויין)',
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: Icon(
                        Icons.add_road,
                        size: 20,
                        color:
                            _roadsOverlay ? Colors.teal[800] : Colors.grey[700],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // סרגל קנה-מידה — פינה שמאלית-תחתית
        Positioned(
          left: 12,
          bottom: 40,
          child: IgnorePointer(child: _buildScaleBar()),
        ),
        // קריאת-קואורדינטה של מרכז-המפה — מרכז-תחתון; הקשה מחליפה פורמט
        Positioned(
          bottom: 12,
          left: 0,
          right: 0,
          child: Center(
            child: Material(
              elevation: 2,
              borderRadius: BorderRadius.circular(6),
              color: Colors.black.withValues(alpha: 0.6),
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => setState(() => _coordFormat = (_coordFormat + 1) % 3),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  child: Text(
                    // ⚠️ בלי _mapController.camera כאן — הוא לא מאותחל עד
                    // שה-FlutterMap נבנה (LateInitializationError בבנייה).
                    '${_coordReadout(_cursorCenter ?? _lastWorldPoint ?? const LatLng(31.5, 34.8))}'
                    '${_cursorElevation != null ? '  ·  גובה ${_cursorElevation!.round()}מ\'' : ''}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontFeatures: [ui.FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ),
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

  /// פריט בבורר רשת-הקואורדינטות עם סימון-בחירה.
  PopupMenuItem<String> _gridMenuItem(String value, String label, bool sel) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (sel)
            const Icon(Icons.check, size: 16, color: Colors.orange)
          else
            const SizedBox(width: 16),
          const SizedBox(width: 6),
          Text(label),
        ],
      ),
    );
  }

  /// סרגל קנה-מידה מותאם (flutter_map 6.2.1 חסר Scalebar מובנה).
  Widget _buildScaleBar() {
    final m = _scaleBarMetrics();
    if (m.widthPx <= 0) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          color: Colors.white.withValues(alpha: 0.7),
          child: Text(
            m.label,
            style: const TextStyle(fontSize: 11, color: Colors.black87),
          ),
        ),
        Container(
          width: m.widthPx,
          height: 6,
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: Colors.black87, width: 2),
              right: BorderSide(color: Colors.black87, width: 2),
              bottom: BorderSide(color: Colors.black87, width: 2),
            ),
            color: Colors.white.withValues(alpha: 0.4),
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
