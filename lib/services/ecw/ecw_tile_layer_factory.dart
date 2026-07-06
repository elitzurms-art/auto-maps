import 'package:flutter_map/flutter_map.dart';

import 'ecw_tile_server.dart';

/// Helper שמייצר `TileLayer` של flutter_map שצורך מהשרת ECW.
///
/// יש לקרוא [EcwTileServer.start] לפני הפעלה של ה-Widget, ולהעביר את
/// אותו instance של [server].
TileLayer ecwTileLayer({
  required EcwTileServer server,
  int minZoom = 7,
  int maxZoom = 18,
}) {
  final tmpl = server.tileUrlTemplate;
  if (tmpl == null) {
    throw StateError('EcwTileServer not started — call server.start() first');
  }
  return TileLayer(
    urlTemplate: tmpl,
    tileSize: 256,
    minZoom: minZoom.toDouble(),
    maxZoom: maxZoom.toDouble(),
    userAgentPackageName: 'com.navigate.ecw_tile_server',
  );
}
