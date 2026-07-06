import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_mbtiles/flutter_map_mbtiles.dart';
import 'package:mbtiles/mbtiles.dart';
import 'package:path/path.dart' as p;

import 'ecw/native_ecw_service.dart';

/// מקור אריחים למפת-הייחוס (רקע לנעיצת נקודות עולם).
///
/// כל מימוש מספק שכבת-אריחים ל-FlutterMap. מקורות שדורשים אתחול כבד
/// (פתיחת בסיס-נתונים, פענוח נייטיבי וכד') עושים זאת ב-[activate] ומשחררים
/// ב-[deactivate]; [isReady] מציין מתי [buildTileLayer] בטוח לקריאה.
///
/// ההפשטה פתוחה להרחבה — מקורות נוספים (ECW נייטיבי, MBTiles) ממשים אותה
/// ונוספים ל-[ReferenceMapController] בלי לשנות את המסך.
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

/// מקור לוויין online (Esri World Imagery) — תצלום-אוויר לזיהוי מבנים,
/// כיכרות ועיקולי כבישים שקשה לראות במפת קווים. שים לב לסדר {z}/{y}/{x}
/// (קונבנציית Esri). משמש גם כרקע "לוויין" בדיאלוג אישור עוגני ה-AI.
class SatelliteOnlineSource implements ReferenceMapSource {
  const SatelliteOnlineSource();

  @override
  String get id => 'satellite';

  @override
  String get displayName => 'לוויין (Esri)';

  @override
  Future<void> activate() async {}

  @override
  Future<void> deactivate() async {}

  @override
  bool get isReady => true;

  @override
  Widget buildTileLayer() {
    return TileLayer(
      urlTemplate:
          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
      userAgentPackageName: 'com.elitzur.auto_maps',
      maxNativeZoom: 18,
      maxZoom: 20,
    );
  }
}

/// מקור ECW מקומי — עוטף [NativeEcwService] (פענוח נייטיבי דרך GDAL/ECW) ומספק
/// שכבת אריחים ל-flutter_map. האריחים מרונדרים ב-warp על-דרישה ל-EPSG:3857, אז
/// אין צורך בהמרת CRS נוספת בצד ה-Dart.
///
/// זמין ב-Android/iOS ו-Windows (`auto_maps_ecw.dll` + GDAL מצורף). הפתיחה
/// אסינכרונית ולכן [buildTileLayer] עוטף ב-[FutureBuilder]: עד שהקובץ נפתח מוצג
/// רקע ריק, ואם הפתיחה נכשלה מוצגת הודעה קצרה.
class EcwReferenceSource implements ReferenceMapSource {
  /// נתיב מלא לקובץ ה-`.ecw`.
  final String ecwPath;

  /// שם לתצוגה בבורר (ברירת מחדל — שם הקובץ ללא סיומת).
  final String? _displayName;

  final NativeEcwService _service = NativeEcwService();
  Future<bool>? _opening;

  EcwReferenceSource(this.ecwPath, {String? displayName})
      : _displayName = displayName;

  @override
  String get id => 'ecw:$ecwPath';

  @override
  String get displayName =>
      _displayName ?? p.basenameWithoutExtension(ecwPath);

  // הפתיחה עצלה (דרך ה-FutureBuilder ב-buildTileLayer), אז activate no-op
  // ו-isReady תמיד true — ה-FutureBuilder מטפל במצב הטעינה/כשל בעצמו.
  @override
  Future<void> activate() async {}

  @override
  bool get isReady => true;

  /// פותח את הקובץ פעם אחת (idempotent). מחזיר true אם המנוע מוכן לרנדר.
  Future<bool> _ensureOpened() {
    return _opening ??= _service.open(ecwPath).then((_) => true).catchError(
      (Object e) {
        _opening = null; // אפשר ניסיון חוזר בבנייה הבאה
        return false;
      },
    );
  }

  @override
  Widget buildTileLayer() {
    return FutureBuilder<bool>(
      future: _ensureOpened(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox.shrink();
        }
        if (snap.data != true) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('טעינת קובץ ה-ECW נכשלה',
                  textDirection: TextDirection.rtl),
            ),
          );
        }
        return TileLayer(tileProvider: _service.tileProvider());
      },
    );
  }

  @override
  Future<void> deactivate() async => _service.dispose();
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
    // פתיחה סינכרונית (sqlite) — עטוף ב-async כדי להתאים לחוזה של
    // ReferenceMapSource ולאפשר אתחול-רקע במעבר-מקור.
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

/// בקר מפת-הייחוס. מנהל את רשימת המקורות והמקור הפעיל, כולל אתחול/שחרור
/// א-סינכרוני של מקורות כבדים (MBTiles / ECW) וגילוי אוטומטי של קבצי מפה
/// בתיקיית-ייחוס.
///
/// הבורר במסך מופיע אוטומטית כש-[availableSources] מחזירה יותר ממקור אחד.
/// אפשר להוסיף מקורות נוספים ידנית דרך [addSource] / [addEcwFile].
class ReferenceMapController extends ChangeNotifier {
  ReferenceMapController({List<ReferenceMapSource>? sources})
      : _sources = List<ReferenceMapSource>.from(
          sources ??
              const <ReferenceMapSource>[
                OsmOnlineSource(),
                SatelliteOnlineSource(),
              ],
        ) {
    if (_sources.isEmpty) _sources.add(const OsmOnlineSource());
    _active = _sources.first;
  }

  final List<ReferenceMapSource> _sources;
  late ReferenceMapSource _active;
  bool _switching = false;
  String? _lastError;

  /// כל המקורות הזמינים (OSM + כל מה שהתגלה בתיקיית-הייחוס / נוסף ידנית).
  List<ReferenceMapSource> availableSources() => List.unmodifiable(_sources);

  ReferenceMapSource get active => _active;

  /// `true` בזמן החלפת מקור (פתיחת DB / אתחול) — המסך יכול להציג טעינה.
  bool get isSwitching => _switching;

  /// שגיאת ההחלפה האחרונה; `null` אם הכל תקין.
  String? get lastError => _lastError;

  /// שכבת האריחים של המקור הפעיל. בזמן החלפה / לפני שהמקור מוכן — לא מצייר כלום.
  Widget buildActiveTileLayer() {
    if (_switching || !_active.isReady) return const SizedBox.shrink();
    return _active.buildTileLayer();
  }

  /// הוספת מקור בודד לבורר. מדלג אם מזהה זהה כבר קיים. מחזיר `true` אם נוסף.
  bool addSource(ReferenceMapSource source) {
    if (_sources.any((s) => s.id == source.id)) return false;
    _sources.add(source);
    notifyListeners();
    return true;
  }

  /// הוספת קובץ `.ecw` יחיד כמקור (בורר קובץ ידני). no-op אם הפלטפורמה אינה
  /// תומכת בפענוח ECW נייטיבי.
  bool addEcwFile(String ecwPath) {
    if (!NativeEcwService.isSupportedPlatform) return false;
    return addSource(EcwReferenceSource(ecwPath));
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

  /// סורק תיקיית-מפות ומוסיף כל קובץ מפה נתמך (`.mbtiles` / `.ecw`) כמקור נפרד
  /// בבורר. מקורות-תיקייה קודמים מוסרים (החלפת התיקייה הפעילה); מקורות שנוספו
  /// באמצעים אחרים (OSM / [addSource]) נשמרים.
  Future<void> loadFolder(String folderPath) async {
    final dir = Directory(folderPath);
    if (!dir.existsSync()) return;

    final activeId = _active.id;
    _sources.removeWhere((s) => _folderDerivedIds.contains(s.id));
    _folderDerivedIds.clear();

    final files = dir.listSync(followLinks: false).whereType<File>().toList()
      ..sort((a, b) => p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase()));

    for (final f in files) {
      final ext = p.extension(f.path).toLowerCase();
      ReferenceMapSource? src;
      if (ext == '.mbtiles') {
        src = MbtilesReferenceSource(filePath: f.path);
      } else if (ext == '.ecw' && NativeEcwService.isSupportedPlatform) {
        src = EcwReferenceSource(f.path);
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

  /// תיקיית-הייחוס המשתמעת — הראשונה מבין המועמדות שקיימת.
  static String? defaultFolder() {
    return _firstExistingDir(<String>[
      p.join(Directory.current.path, 'reference_maps'),
      p.join(File(Platform.resolvedExecutable).parent.path, 'reference_maps'),
    ]);
  }

  static String? _firstExistingDir(List<String> candidates) {
    for (final c in candidates) {
      if (Directory(c).existsSync()) return c;
    }
    return null;
  }
}
