import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import 'ecw/native_ecw_service.dart';

/// מקור אריחים למפת-הייחוס (רקע לנעיצת נקודות עולם).
///
/// ה-MVP מספק OSM online בלבד. הממשק בנוי כך שאפשר יהיה להוסיף מקורות
/// נוספים (למשל ECW מקומי דרך OSGeo4W) בלי לשנות את המסך — פשוט מוסיפים
/// מימוש חדש ל-[ReferenceMapController.availableSources].
abstract class ReferenceMapSource {
  /// מזהה ייחודי (לשמירת בחירה ב-shared_preferences וכד').
  String get id;

  /// שם לתצוגה בבורר המפות (עברית).
  String get displayName;

  /// שכבת האריחים ל-FlutterMap.
  Widget buildTileLayer();
}

/// מקור OSM online — ברירת המחדל היחידה ב-MVP.
class OsmOnlineSource implements ReferenceMapSource {
  const OsmOnlineSource();

  @override
  String get id => 'osm';

  @override
  String get displayName => 'OpenStreetMap';

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

/// מקור ECW מקומי — עוטף [NativeEcwService] (פענוח נייטיבי דרך GDAL/ECW) ומספק
/// שכבת אריחים ל-flutter_map. האריחים מרונדרים ב-warp על-דרישה ל-EPSG:3857, אז
/// אין צורך בהמרת CRS נוספת בצד ה-Dart.
///
/// זמין ב-Android/iOS ו-Windows (`auto_maps_ecw.dll` + GDAL של OSGeo4W מצורף).
/// הפתיחה אסינכרונית ולכן [buildTileLayer] עוטף ב-[FutureBuilder]: עד שהקובץ
/// נפתח מוצג רקע ריק, ואם הפתיחה נכשלה מוצגת הודעה קצרה.
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
      _displayName ??
      ecwPath.split(Platform.pathSeparator).last.split('/').last;

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

  /// משחרר את המשאבים הנייטיביים.
  void dispose() => _service.dispose();
}

/// בקר דק למפת-הייחוס. מנהל את רשימת המקורות והמקור הפעיל.
///
/// ל-MVP: [availableSources] מחזירה [OSM] בלבד. בעתיד (ECW/TPS) —
/// מוסיפים כאן מקורות נוספים בלי לגעת ב-UI.
class ReferenceMapController extends ChangeNotifier {
  final List<ReferenceMapSource> _sources;
  ReferenceMapSource _active;

  ReferenceMapController({
    List<ReferenceMapSource>? sources,
    List<String>? ecwPaths,
  }) : _sources = _buildSources(sources, ecwPaths),
       _active = _buildSources(sources, ecwPaths).first;

  /// בונה את רשימת המקורות: OSM (או המקורות שהוזרקו) + מקור ECW נייטיבי לכל נתיב
  /// `.ecw` שסופק, אך רק בפלטפורמה שתומכת בפענוח נייטיבי.
  static List<ReferenceMapSource> _buildSources(
    List<ReferenceMapSource>? sources,
    List<String>? ecwPaths,
  ) {
    final base = <ReferenceMapSource>[
      ...(sources ?? const [OsmOnlineSource()]),
    ];
    if (ecwPaths != null && NativeEcwService.isSupportedPlatform) {
      for (final p in ecwPaths) {
        base.add(EcwReferenceSource(p));
      }
    }
    return base;
  }

  /// כל המקורות הזמינים (OSM + מקורות ECW נייטיביים שסופקו).
  List<ReferenceMapSource> availableSources() => List.unmodifiable(_sources);

  ReferenceMapSource get active => _active;

  void setActive(ReferenceMapSource source) {
    if (_active.id == source.id) return;
    _active = source;
    notifyListeners();
  }

  /// שכבת האריחים של המקור הפעיל.
  Widget buildActiveTileLayer() => _active.buildTileLayer();
}
