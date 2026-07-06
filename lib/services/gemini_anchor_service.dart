import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Offset;

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// עוגן מוצע ע"י Gemini — נקודת פיקסל על התמונה + מיקום עולם משוער.
/// כל הצעה טעונה **אישור פר-נקודה** של המשתמש לפני שהיא הופכת לנקודת התאמה.
class GeminiAnchorSuggestion {
  final Offset pixel;
  final LatLng world;
  final String name;

  /// 0–1, כפי שדיווח המודל.
  final double confidence;

  /// על סמך מה זוהה (שם יישוב, צומת, רשת ית"מ...).
  final String basis;

  const GeminiAnchorSuggestion({
    required this.pixel,
    required this.world,
    required this.name,
    required this.confidence,
    required this.basis,
  });
}

/// המצב האוטומטי — הצעת עוגנים סמנטית למפות משורטטות/סרוקות דרך Gemini:
/// המודל מזהה שמות יישובים, צמתים, ציוני-דרך ורשת ית"מ מודפסת, ומציע
/// זוגות פיקסל↔עולם. המשתמש מאשר/דוחה כל נקודה; המצב הידני נשאר כמו היום.
class GeminiAnchorService {
  static const _prefsKey = 'gemini_api_key';
  static const _model = 'gemini-2.5-flash';

  static Future<String?> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_prefsKey)?.trim();
    return (key == null || key.isEmpty) ? null : key;
  }

  static Future<void> setApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, key.trim());
  }

  /// שולח את תמונת המפה ל-Gemini ומחזיר עוגנים מוצעים (עד 8).
  ///
  /// התמונה מוקטנת לצלע-מקסימום 1600px לפני השליחה (חוסך רוחב-פס ומדייק את
  /// המודל); הקואורדינטות מוחזרות בפיקסלים של התמונה שנשלחה וממופות חזרה
  /// למימדי המקור [imageWidth]×[imageHeight].
  Future<List<GeminiAnchorSuggestion>> suggestAnchors({
    required String imagePath,
    required int imageWidth,
    required int imageHeight,
    required String apiKey,
  }) async {
    final bytes = await File(imagePath).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw const FormatException('פענוח תמונת המפה נכשל');
    }

    // הקטנה ל-1600px מקסימום + JPEG — מספיק ל-OCR של שמות, קטן לרשת.
    const maxDim = 1600;
    img.Image sent = decoded;
    if (decoded.width > maxDim || decoded.height > maxDim) {
      sent = decoded.width >= decoded.height
          ? img.copyResize(decoded, width: maxDim)
          : img.copyResize(decoded, height: maxDim);
    }
    final jpeg = img.encodeJpg(sent, quality: 85);
    final scaleX = imageWidth / sent.width;
    final scaleY = imageHeight / sent.height;

    final prompt =
        '''
אתה עוזר ג'יאורפרנס. לפניך תמונת מפה (סרוקה, מצולמת או משורטטת ביד), ככל הנראה של אזור בישראל. גודל התמונה שנשלחה אליך: ${sent.width}x${sent.height} פיקסלים.

זהה עד 8 עוגנים שאפשר למקם בביטחון גבוה בעולם האמיתי, לפי:
- שמות יישובים/אתרים כתובים על המפה (OCR)
- צמתים/מחלפים של כבישים ממוספרים
- נקודות ציון של רשת ישראל החדשה (ית"מ) אם מודפסת על המפה
- ציוני דרך מובהקים (הר, מאגר, חוף)

לכל עוגן החזר:
- pixelX, pixelY: מיקום הנקודה בתמונה שנשלחה (0,0 בפינה השמאלית-עליונה)
- lat, lon: קואורדינטות WGS84 של אותה נקודה בעולם האמיתי
- name: שם קצר בעברית
- confidence: 0-1 (כלול רק עוגנים עם 0.5 ומעלה)
- basis: על סמך מה זיהית (שם כתוב / צומת כבישים / רשת קואורדינטות)

העדף פיזור רחב של העוגנים על פני המפה. אם אינך מזהה כלום בביטחון — החזר מערך ריק.''';

    final body = {
      'contents': [
        {
          'parts': [
            {'text': prompt},
            {
              'inline_data': {
                'mime_type': 'image/jpeg',
                'data': base64Encode(jpeg),
              },
            },
          ],
        },
      ],
      'generationConfig': {
        'response_mime_type': 'application/json',
        'response_schema': {
          'type': 'ARRAY',
          'items': {
            'type': 'OBJECT',
            'properties': {
              'pixelX': {'type': 'NUMBER'},
              'pixelY': {'type': 'NUMBER'},
              'lat': {'type': 'NUMBER'},
              'lon': {'type': 'NUMBER'},
              'name': {'type': 'STRING'},
              'confidence': {'type': 'NUMBER'},
              'basis': {'type': 'STRING'},
            },
            'required': [
              'pixelX',
              'pixelY',
              'lat',
              'lon',
              'name',
              'confidence',
              'basis',
            ],
          },
        },
      },
    };

    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$_model:generateContent',
    );
    final resp = await http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': apiKey,
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 90));

    if (resp.statusCode != 200) {
      throw HttpException(
        'Gemini החזיר ${resp.statusCode}: ${_apiError(resp.body)}',
      );
    }

    final root = jsonDecode(resp.body) as Map<String, dynamic>;
    final text =
        (((root['candidates'] as List?)?.firstOrNull
                    as Map<String, dynamic>?)?['content']?['parts']
                as List?)
            ?.map((p) => (p as Map<String, dynamic>)['text'] as String? ?? '')
            .join();
    if (text == null || text.isEmpty) {
      throw const FormatException('Gemini החזיר תשובה ריקה');
    }

    final list = jsonDecode(text) as List;
    return [
      for (final e in list.cast<Map<String, dynamic>>())
        GeminiAnchorSuggestion(
          pixel: Offset(
            ((e['pixelX'] as num).toDouble() * scaleX).clamp(
              0,
              imageWidth.toDouble(),
            ),
            ((e['pixelY'] as num).toDouble() * scaleY).clamp(
              0,
              imageHeight.toDouble(),
            ),
          ),
          world: LatLng(
            (e['lat'] as num).toDouble(),
            (e['lon'] as num).toDouble(),
          ),
          name: e['name'] as String? ?? '',
          confidence: (e['confidence'] as num?)?.toDouble() ?? 0,
          basis: e['basis'] as String? ?? '',
        ),
    ];
  }

  String _apiError(String body) {
    try {
      final m = jsonDecode(body) as Map<String, dynamic>;
      return (m['error'] as Map<String, dynamic>?)?['message'] as String? ??
          body;
    } catch (_) {
      return body.length > 200 ? body.substring(0, 200) : body;
    }
  }
}
