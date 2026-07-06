import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_mbtiles/flutter_map_mbtiles.dart';
import 'package:mbtiles/mbtiles.dart';
import 'package:path/path.dart' as p;

import 'ecw/ecw_tile_layer_factory.dart';
import 'ecw/ecw_tile_server.dart';

/// מקור אריחים למפת-הייחוס (רקע לנעיצת נקודות עולם).
///
/// כל מימוש מספק שכבת-אריחים ל-FlutterMap. מקורות שדורשים אתחול כבד
/// (הרצת sidecar, פתיחת בסיס-נתונים) עושים זאת ב-[activate] ומשחררים
/// ב-[deactivate]; [isReady] מציין מתי [buildTileLayer] בטוח לקריאה.
abstract class ReferenceMapSource {
  /// מזהה ייחודי (לשמירת בחירה ב-shared_preferences וכד').
  String get id;

  /// שם לתצוגה בבורר המפות (עברית / שם קובץ).
  String get displayName;

  /// נקרא כשהמקור הופך לפעיל. ברירת-מחדל: no-op. חייב להיות idempotent.
  Future<void> activate() async {}

  /// נקרא כשהמקור מפסיק להיות פעיל (שחרור משאבים). idempotent.
  Future<void> deactivate() async {}

  /// `true` כשאפשר לקרוא ל-[buildTileLayer] בבטחה.
  bool get isReady => true;

  /// שכבת האריחים ל-FlutterMap.
  Widget buildTileLayer();
}

/// מקור OSM online — ברירת המחדל, תמיד זמין.
class OsmOnlineSource implements ReferenceMapSource {
  const OsmOnlineSource();

  @override
  String get id => 'osm';

  @override
  String get displayName => 'OpenStreetMap';

  @override
  Future<void> activate() async {}

  @override
  Future<void> deactivate() async {}

  @override
  bool get isReady => true;

  @override
  Widget buildTileLayer() {
    return TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'com.elitzur.auto_maps',
      maxNativeZoom: 19,
      maxZoom: 20,
    );
  }
}

/// מקור MBTiles מקומי (raster). כל קובץ `.mbtiles` בתיקיית-הייחוס הופך
/// למקור נפרד בבורר. פותח את בסיס-הנתונים ב-[activate] וסוגר ב-[deactivate].
class MbtilesReferenceSource implements ReferenceMapSource {
  MbtilesReferenceSource({required this.filePath})
      : id = 'mbtiles:$filePath',
        displayName = p.basenameWithoutExtension(filePath);

  final String filePath;

  @override
  final String id;

  @override
  final String displayName;

  MbTiles? _mbtiles;

  @override
  bool get isReady => _mbtiles != null;

  @override
  Future<void> activate() async {
    if (_mbtiles != null) return;
    // פתיחה סינכרונית (sqlite) — עטוף ב-async כדי לא לחסום את ה-UI thread
    // מעבר לצורך, ולהתאים לחוזה של ReferenceMapSource.
    _mbtiles = MbTiles(mbtilesPath: filePath);
  }

  @override
  Future<void> deactivate() async {
    _mbtiles?.dispose();
    _mbtiles = null;
  }

  @override
  Widget buildTileLayer() {
    final m = _mbtiles;
    if (m == null) return const SizedBox.shrink();
    return TileLayer(
      tileProvider: MbTilesTileProvider(mbtiles: m, silenceTileNotFound: true),
      tileSize: 256,
      maxNativeZoom: 18,
      maxZoom: 20,
    );
  }
}

/// מקור ECW ortho — מריץ את ה-sidecar (Python + GDAL דרך OSGeo4W) על
/// קובץ `.ecw` ומגיש אריחים ל-FlutterMap. ה-sidecar עולה ב-[activate]
/// ונהרג ב-[deactivate] (וגם אוטומטית בסגירת האפליקציה דרך JobObject).
class EcwReferenceSource implements ReferenceMapSource {
  EcwReferenceSource({
    required this.ecwPath,
    required this.scriptPath,
    this.osgeo4wBat = defaultOsgeo4wBat,
  })  : id = 'ecw:$ecwPath',
        displayName = 'ECW · ${p.basenameWithoutExtension(ecwPath)}';

  static const String defaultOsgeo4wBat = r'C:\OSGeo4W\OSGeo4W.bat';

  final String ecwPath;
  final String scriptPath;
  final String osgeo4wBat;

  @override
  final String id;

  @override
  final String displayName;

  EcwTileServer? _server;

  @override
  bool get isReady => _server?.tileUrlTemplate != null;

  @override
  Future<void> activate() async {
    if (_server?.tileUrlTemplate != null) return;
    final server = EcwTileServer(
      ecwPath: ecwPath,
      scriptPath: scriptPath,
      osgeo4wBat: osgeo4wBat,
    );
    await server.start();
    _server = server;
  }

  @override
  Future<void> deactivate() async {
    final s = _server;
    _server = null;
    await s?.stop();
  }

  @override
  Widget buildTileLayer() {
    final s = _server;
    if (s == null || s.tileUrlTemplate == null) return const SizedBox.shrink();
    return ecwTileLayer(server: s);
  }
}

/// בקר מפת-הייחוס. מנהל את רשימת המקורות והמקור הפעיל, כולל אתחול/שחרור
/// א-סינכרוני של מקורות כבדים (ECW / MBTiles) וגילוי אוטומטי של קבצי מפה
/// בתיקיית-ייחוס.
///
/// הבורר במסך מופיע אוטומטית כש-[availableSources] מחזירה יותר ממקור אחד.
class ReferenceMapController extends ChangeNotifier {
  ReferenceMapController({List<ReferenceMapSource>? sources})
      : _sources = List<ReferenceMapSource>.from(
          sources ?? const <ReferenceMapSource>[OsmOnlineSource()],
        ) {
    if (_sources.isEmpty) _sources.add(const OsmOnlineSource());
    _active = _sources.first;
  }

  final List<ReferenceMapSource> _sources;
  late ReferenceMapSource _active;
  bool _switching = false;
  String? _lastError;

  /// כל המקורות הזמינים (OSM + כל מה שהתגלה בתיקיית-הייחוס).
  List<ReferenceMapSource> availableSources() => List.unmodifiable(_sources);

  ReferenceMapSource get active => _active;

  /// `true` בזמן החלפת מקור (הרצת sidecar / פתיחת DB) — המסך יכול להציג טעינה.
  bool get isSwitching => _switching;

  /// שגיאת ההחלפה האחרונה (למשל sidecar נכשל); `null` אם הכל תקין.
  String? get lastError => _lastError;

  /// שכבת האריחים של המקור הפעיל. בזמן החלפה / לפני שהמקור מוכן — לא מצייר כלום.
  Widget buildActiveTileLayer() {
    if (_switching || !_active.isReady) return const SizedBox.shrink();
    return _active.buildTileLayer();
  }

  /// החלפת המקור הפעיל. מאתחל את החדש, ורק בהצלחה משחרר את הישן.
  /// בכשל — נשאר על המקור הקודם ומעדכן [lastError].
  Future<void> setActive(ReferenceMapSource source) async {
    if (_active.id == source.id || _switching) return;
    final prev = _active;
    _lastError = null;
    _switching = true;
    _active = source;
    notifyListeners();
    try {
      await source.activate();
    } catch (e) {
      _active = prev;
      _switching = false;
      _lastError = 'טעינת "${source.displayName}" נכשלה: $e';
      notifyListeners();
      return;
    }
    _switching = false;
    notifyListeners();
    // משחררים את הקודם רק אחרי מעבר מוצלח (OSM זול — deactivate שלו no-op).
    if (prev.id != source.id) {
      unawaited(prev.deactivate());
    }
  }

  /// מוסיף קובץ ECW יחיד (בחירת המשתמש) כמקור בבורר. מדלג אם כבר קיים או
  /// אם OSGeo4W/הסקריפט לא זמינים. מחזיר את המקור שנוסף, או `null`.
  EcwReferenceSource? addEcwFile(String ecwPath) {
    if (!ecwToolingAvailable) return null;
    final script = _resolveEcwScript();
    if (script == null) return null;
    final id = 'ecw:$ecwPath';
    if (_sources.any((s) => s.id == id)) return null;
    final src = EcwReferenceSource(ecwPath: ecwPath, scriptPath: script);
    _sources.add(src);
    notifyListeners();
    return src;
  }

  /// סורק תיקיית-מפות ומוסיף כל קובץ מפה נתמך (`.mbtiles`, `.ecw`) כמקור
  /// נפרד בבורר. מקורות-תיקייה קודמים מוסרים (החלפת התיקייה הפעילה).
  /// מקורות ECW נוספים רק אם כלי OSGeo4W זמינים (degrade gracefully).
  Future<void> loadFolder(String folderPath) async {
    final dir = Directory(folderPath);
    if (!dir.existsSync()) return;

    // הסרת מקורות-תיקייה קודמים (משאירים OSM + מקורות שנוספו ידנית נשמרים
    // אם הם עדיין מצביעים לתוך התיקייה החדשה — אבל הדרך הפשוטה: להשאיר את
    // כל מה שאינו נגזר-תיקייה, ולבנות מחדש את הנגזרים).
    final activeId = _active.id;
    _sources.removeWhere((s) => _folderDerivedIds.contains(s.id));
    _folderDerivedIds.clear();

    final script = _resolveEcwScript();
    final ecwOk = ecwToolingAvailable && script != null;

    final files = dir
        .listSync(followLinks: false)
        .whereType<File>()
        .toList()
      ..sort((a, b) =>
          p.basename(a.path).toLowerCase().compareTo(
              p.basename(b.path).toLowerCase()));

    for (final f in files) {
      final ext = p.extension(f.path).toLowerCase();
      ReferenceMapSource? src;
      if (ext == '.mbtiles') {
        src = MbtilesReferenceSource(filePath: f.path);
      } else if (ext == '.ecw' && ecwOk) {
        src = EcwReferenceSource(ecwPath: f.path, scriptPath: script);
      }
      if (src == null) continue;
      if (_sources.any((s) => s.id == src!.id)) continue;
      _sources.add(src);
      _folderDerivedIds.add(src.id);
    }

    // אם המקור הפעיל הוסר בסריקה — נופלים חזרה ל-OSM.
    if (!_sources.any((s) => s.id == activeId)) {
      _active = _sources.first;
    }
    notifyListeners();
  }

  /// טוען את תיקיית-הייחוס המשתמעת (`reference_maps` ליד ה-exe / ב-cwd),
  /// אם קיימת. no-op אם אין תיקייה כזו.
  Future<void> loadDefaultFolder() async {
    final def = defaultFolder();
    if (def != null) await loadFolder(def);
  }

  final Set<String> _folderDerivedIds = <String>{};

  @override
  void dispose() {
    for (final s in _sources) {
      unawaited(s.deactivate());
    }
    super.dispose();
  }

  // ═══ עזרי-מיקום (resolve של קבצים/תיקיות בזמן ריצה) ═══

  /// `true` אם OSGeo4W.bat (עם דרייבר ECW) קיים במחשב.
  static bool get ecwToolingAvailable =>
      Platform.isWindows &&
      File(EcwReferenceSource.defaultOsgeo4wBat).existsSync();

  /// תיקיית-הייחוס המשתמעת — הראשונה מבין המועמדות שקיימת.
  static String? defaultFolder() {
    return _firstExistingDir(<String>[
      p.join(Directory.current.path, 'reference_maps'),
      p.join(File(Platform.resolvedExecutable).parent.path, 'reference_maps'),
    ]);
  }

  /// איתור סקריפט ה-sidecar (`ecw_tile_server.py`) בזמן ריצה.
  static String? _resolveEcwScript() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return _firstExistingFile(<String>[
      p.join(Directory.current.path, 'scripts', 'ecw_tile_server.py'),
      p.join(exeDir, 'scripts', 'ecw_tile_server.py'),
      // build\windows\x64\runner\Debug\<app>.exe → שורש הפרויקט (5 רמות מעלה)
      p.normalize(p.join(exeDir, '..', '..', '..', '..', '..', 'scripts',
          'ecw_tile_server.py')),
    ]);
  }

  static String? _firstExistingDir(List<String> candidates) {
    for (final c in candidates) {
      if (Directory(c).existsSync()) return c;
    }
    return null;
  }

  static String? _firstExistingFile(List<String> candidates) {
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }
}
