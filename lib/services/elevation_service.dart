import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// שירות-גובה מקוון — מחזיר גובה (מטרים מעל פני-הים) לנקודה דרך
/// **open-meteo** (חינם, בלי מפתח, מבוסס Copernicus DEM ~90מ'). עם מטמון
/// קטן כדי לא לחזור על אותה נקודה. כשל-רשת → null (לא מפיל את ה-UI).
class ElevationService {
  static final Map<String, double> _cache = {};

  static Future<double?> elevationAt(LatLng ll) async {
    final key =
        '${ll.latitude.toStringAsFixed(4)},${ll.longitude.toStringAsFixed(4)}';
    final cached = _cache[key];
    if (cached != null) return cached;
    try {
      final uri = Uri.parse(
        'https://api.open-meteo.com/v1/elevation'
        '?latitude=${ll.latitude.toStringAsFixed(5)}'
        '&longitude=${ll.longitude.toStringAsFixed(5)}',
      );
      final r = await http.get(uri).timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final list = j['elevation'] as List?;
      if (list == null || list.isEmpty) return null;
      final e = (list.first as num).toDouble();
      if (_cache.length > 500) _cache.clear();
      _cache[key] = e;
      return e;
    } catch (_) {
      return null;
    }
  }
}
