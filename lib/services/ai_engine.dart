import 'package:shared_preferences/shared_preferences.dart';

/// בורר מנוע-ה-AI של המצב האוטומטי: Gemini בענן (ברירת-מחדל) או מודל
/// מקומי דרך שרת Ollama — למשל Qwen2.5-VL על מכונה חזקה, גם ברשת
/// המקומית (הכתובת ניתנת להגדרה). ההגדרות נשמרות ב-shared_preferences.
///
/// הצנרת בונה בקשות בפורמט Gemini; [geminiBodyToOllamaChat] ממיר אותן
/// לבקשת `/api/chat` של Ollama — כולל המרת ה-responseSchema ל-JSON Schema
/// סטנדרטי (Ollama אוכף פלט-מובנה דרך השדה `format`).
class AiEngine {
  static const gemini = 'gemini';
  static const ollama = 'ollama';

  static const _engineKey = 'ai_engine';
  static const _urlKey = 'ollama_url';
  static const _modelKey = 'ollama_model';

  static const defaultOllamaUrl = 'http://localhost:11434';
  // 3b — הקל ביותר שרץ על CPU/‏iGPU. במכונה חזקה (M4/GPU) שדרג ל-7b/32b.
  static const defaultOllamaModel = 'qwen2.5vl:3b';

  static Future<String> engine() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_engineKey) ?? gemini;
  }

  static Future<void> setEngine(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_engineKey, value);
  }

  static Future<String> ollamaUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_urlKey)?.trim();
    return (v == null || v.isEmpty) ? defaultOllamaUrl : v;
  }

  static Future<void> setOllamaUrl(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_urlKey, value.trim());
  }

  static Future<String> ollamaModel() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_modelKey)?.trim();
    return (v == null || v.isEmpty) ? defaultOllamaModel : v;
  }

  static Future<void> setOllamaModel(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modelKey, value.trim());
  }

  /// ממיר גוף-בקשה בפורמט Gemini ל-body של `POST /api/chat` ב-Ollama.
  ///
  /// ב-Ollama הודעה היא טקסט אחד + רשימת תמונות, בלי שזירה — לכן כל קטעי
  /// הטקסט משורשרים לפי הסדר עם מציין-מיקום "[תמונה N מצורפת]" במקום כל
  /// תמונה; הפרומפטים שלנו ממילא ממספרים את התמונות, אז ההקשר נשמר.
  static Map<String, dynamic> geminiBodyToOllamaChat(
    Map<String, dynamic> body,
    String model,
  ) {
    final parts =
        (((body['contents'] as List).first as Map)['parts'] as List)
            .cast<Map<String, dynamic>>();
    final text = StringBuffer();
    final images = <String>[];
    for (final part in parts) {
      if (part.containsKey('text')) {
        text.writeln(part['text']);
      } else if (part.containsKey('inline_data')) {
        images.add((part['inline_data'] as Map)['data'] as String);
        text.writeln('[תמונה ${images.length} מצורפת]');
      }
    }
    final genCfg =
        (body['generationConfig'] as Map<String, dynamic>?) ?? const {};
    final schema = genCfg['response_schema'];
    return {
      'model': model,
      'stream': false,
      if (schema != null) 'format': lowerSchemaTypes(schema),
      'options': {
        'temperature': (genCfg['temperature'] as num?) ?? 0.1,
      },
      'messages': [
        {
          'role': 'user',
          'content': text.toString(),
          if (images.isNotEmpty) 'images': images,
        },
      ],
    };
  }

  /// סכימת Gemini משתמשת בטיפוסים באותיות גדולות (OBJECT/ARRAY/...);
  /// JSON Schema סטנדרטי — קטנות. ההמרה רקורסיבית ושומרת את שאר המבנה.
  static dynamic lowerSchemaTypes(dynamic node) {
    if (node is Map) {
      return {
        for (final e in node.entries)
          e.key: (e.key == 'type' && e.value is String)
              ? (e.value as String).toLowerCase()
              : lowerSchemaTypes(e.value),
      };
    }
    if (node is List) return [for (final v in node) lowerSchemaTypes(v)];
    return node;
  }
}
