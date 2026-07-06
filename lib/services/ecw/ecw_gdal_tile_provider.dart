import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';

import 'ecw_gdal_decoder.dart';

/// קבוע Web Mercator — חצי היקף העולם במטרים (EPSG:3857).
const double _kWebMercatorHalf = 20037508.342789244;

/// flutter_map TileProvider שמרנדר אריחים מקובץ ECW בודד דרך GDAL (warp
/// על-דרישה ל-Web Mercator). בניגוד ל-JP2 (אריחים מוכנים מראש בתיקייה), פה יש
/// קובץ מקור אחד גדול ב-CRS מקורי (ITM/UTM), וכל אריח XYZ מחושב warp נפרד.
///
/// כל הרינדור עובר דרך [EcwGdalService] שמחזיק dataset יחיד פתוח ב-isolate
/// ייעודי — חייב להיות `open()` לפני שמשתמשים ב-provider.
class EcwGdalTileProvider extends TileProvider {
  final EcwGdalService service;
  final int tileSize;

  EcwGdalTileProvider({required this.service, this.tileSize = 256});

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return _EcwTileImageProvider(
      service: service,
      z: coordinates.z,
      x: coordinates.x,
      y: coordinates.y,
      tileSize: tileSize,
    );
  }
}

class _EcwTileImageProvider extends ImageProvider<_EcwTileImageProvider> {
  final EcwGdalService service;
  final int z, x, y, tileSize;

  _EcwTileImageProvider({
    required this.service,
    required this.z,
    required this.x,
    required this.y,
    required this.tileSize,
  });

  @override
  Future<_EcwTileImageProvider> obtainKey(ImageConfiguration cfg) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
      _EcwTileImageProvider key, ImageDecoderCallback decode) {
    return OneFrameImageStreamCompleter(_load());
  }

  Future<ImageInfo> _load() async {
    // bbox של אריח XYZ ב-EPSG:3857 (Web Mercator meters).
    final n = 1 << z; // 2^z
    final tileMeters = (2 * _kWebMercatorHalf) / n;
    final minx = -_kWebMercatorHalf + x * tileMeters;
    final maxx = -_kWebMercatorHalf + (x + 1) * tileMeters;
    final maxy = _kWebMercatorHalf - y * tileMeters;
    final miny = _kWebMercatorHalf - (y + 1) * tileMeters;

    final rgba =
        await service.renderTile(minx, miny, maxx, maxy, size: tileSize);
    if (rgba == null) {
      throw _EcwTileException('ECW render failed @ $z/$x/$y');
    }
    final image = await _toUiImage(rgba, tileSize);
    return ImageInfo(image: image);
  }

  static Future<ui.Image> _toUiImage(Uint8List rgba, int size) async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      size,
      size,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  @override
  bool operator ==(Object other) =>
      other is _EcwTileImageProvider &&
      other.z == z &&
      other.x == x &&
      other.y == y &&
      identical(other.service, service);

  @override
  int get hashCode => Object.hash(service, z, x, y);
}

class _EcwTileException implements Exception {
  final String message;
  _EcwTileException(this.message);
  @override
  String toString() => message;
}
