import 'dart:io';

import 'package:flutter_map/flutter_map.dart';

import 'ecw_gdal_decoder.dart';
import 'ecw_gdal_tile_provider.dart';

/// מטא-דאטה של קובץ ECW פתוח.
class EcwMetadata {
  /// רוחב הראסטר בפיקסלים (במערכת המקור).
  final int width;

  /// גובה הראסטר בפיקסלים (במערכת המקור).
  final int height;

  /// ה-SRS של המקור כ-WKT (למשל ITM/EPSG:2039 או UTM). עשוי להיות ריק.
  final String srs;

  /// גרסת ה-GDAL הנייטיבית שנטענה (למשל "3.12.1").
  final String gdalVersion;

  const EcwMetadata({
    required this.width,
    required this.height,
    required this.srs,
    required this.gdalVersion,
  });
}

/// **שירות ECW נייטיבי עצמאי לנייד (Android + iOS).**
///
/// עוטף את [EcwGdalService] (FFI ל-GDAL/ECW ב-isolate ייעודי) ומספק ממשק נקי:
/// פתיחת קובץ `.ecw`, קריאת מטא-דאטה, ורינדור אריחי `flutter_map` על-דרישה
/// (warp ל-Web Mercator / EPSG:3857).
///
/// **הפרדת אחריות מכוונת:** השירות הזה עצמאי לחלוטין ו**אינו** מחווט ל-
/// `reference_map_controller.dart` ואינו יוצר `EcwReferenceSource` — החיווט
/// למקורות-מפה הוא באחריות רכיב אחר. ראה [tileProvider] ל-tile-provider מוכן
/// לשילוב, ואת ה-TODO בתחתית הקובץ ל"תפר-החיבור" המיועד.
///
/// **זמינות פלטפורמה:** Android/iOS בלבד. במחשב (Windows/macOS/Linux) הנתיב
/// הנייטיבי אינו מקומפל — [isSupportedPlatform] יחזיר false ו-[open] יזרוק
/// אם ייקרא. במחשב יש להשתמש בנתיב GDAL/Python חיצוני (מחוץ לשירות הזה).
class NativeEcwService {
  NativeEcwService();

  final EcwGdalService _gdal = EcwGdalService(poolSize: 1);
  EcwMetadata? _metadata;
  String? _openPath;

  /// האם הפלטפורמה הנוכחית תומכת בפענוח ECW נייטיבי (Android/iOS בלבד).
  static bool get isSupportedPlatform => Platform.isAndroid || Platform.isIOS;

  /// האם קובץ נפתח בהצלחה והשירות מוכן לרנדר אריחים.
  bool get isReady => _gdal.isReady;

  /// המטא-דאטה של הקובץ הפתוח, או null אם עדיין לא נפתח.
  EcwMetadata? get metadata => _metadata;

  /// הנתיב לקובץ ה-ECW הפתוח, או null.
  String? get openPath => _openPath;

  /// פותח קובץ `.ecw` ומכין את מנוע הרינדור.
  ///
  /// מחזיר את ה-[EcwMetadata] בהצלחה, או זורק [EcwUnsupportedPlatformException]
  /// במחשב / [EcwOpenException] אם הפתיחה נכשלה (קובץ פגום, GDAL לא נטען וכו').
  Future<EcwMetadata> open(String ecwPath) async {
    if (!isSupportedPlatform) {
      throw const EcwUnsupportedPlatformException();
    }
    final ok = await _gdal.open(ecwPath);
    if (!ok) {
      throw EcwOpenException(ecwPath);
    }
    _openPath = ecwPath;
    final meta = EcwMetadata(
      width: _gdal.width,
      height: _gdal.height,
      srs: _gdal.srs,
      gdalVersion: _gdal.gdalVersion,
    );
    _metadata = meta;
    return meta;
  }

  /// יוצר [TileProvider] ל-`flutter_map` שמרנדר אריחים מהקובץ הפתוח.
  /// חובה לקרוא [open] בהצלחה קודם.
  TileProvider tileProvider({int tileSize = 256}) {
    return EcwGdalTileProvider(service: _gdal, tileSize: tileSize);
  }

  /// משחרר את כל המשאבים הנייטיביים (isolate + dataset פתוח).
  void dispose() {
    _gdal.dispose();
    _metadata = null;
    _openPath = null;
  }
}

/// נזרק כאשר מנסים לפתוח ECW על פלטפורמה ללא הנתיב הנייטיבי (מחשב).
class EcwUnsupportedPlatformException implements Exception {
  const EcwUnsupportedPlatformException();
  @override
  String toString() =>
      'פענוח ECW נייטיבי זמין ב-Android/iOS בלבד (לא ב-${Platform.operatingSystem}).';
}

/// נזרק כאשר GDAL נכשל בפתיחת קובץ ה-ECW.
class EcwOpenException implements Exception {
  final String path;
  const EcwOpenException(this.path);
  @override
  String toString() => 'פתיחת קובץ ECW נכשלה: $path';
}

// ────────────────────────── תפר-חיבור (integration seam) ──────────────────────────
//
// TODO(reference-map): חיווט למקורות-המפה נעשה ברכיב נפרד (לא כאן, כדי למנוע
// התנגשות מיזוג). כדי לחבר את ה-ECW הנייטיבי ל-מפת-הייחוס:
//
//   1) ב-`EcwReferenceSource` (רכיב אחר) החזק מופע `NativeEcwService`.
//   2) קרא `await service.open(ecwPath)` וקבל `EcwMetadata` (רוחב/גובה/SRS).
//   3) הזרם `service.tileProvider()` לתוך `TileLayer(tileProvider: ...)` של
//      flutter_map — האריחים כבר ב-EPSG:3857 (אותה מערכת כמו OSM), אז אין צורך
//      בהמרת CRS נוספת בצד ה-Dart.
//   4) בסגירת המקור קרא `service.dispose()`.
//
// אין לייבא את `native_ecw_service.dart` מתוך `reference_map_controller.dart`
// בקומיט הזה — הותרת החיבור פתוחה בכוונה.
