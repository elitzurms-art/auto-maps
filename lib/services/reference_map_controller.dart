import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

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

/// בקר דק למפת-הייחוס. מנהל את רשימת המקורות והמקור הפעיל.
///
/// ל-MVP: [availableSources] מחזירה [OSM] בלבד. בעתיד (ECW/TPS) —
/// מוסיפים כאן מקורות נוספים בלי לגעת ב-UI.
class ReferenceMapController extends ChangeNotifier {
  final List<ReferenceMapSource> _sources;
  ReferenceMapSource _active;

  ReferenceMapController({List<ReferenceMapSource>? sources})
      : _sources = sources ?? const [OsmOnlineSource()],
        _active = (sources ?? const [OsmOnlineSource()]).first;

  /// כל המקורות הזמינים (MVP: OSM בלבד).
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
