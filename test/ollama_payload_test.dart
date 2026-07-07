import 'package:flutter_test/flutter_test.dart';

import 'package:auto_maps/services/ai_engine.dart';

void main() {
  test('המרת גוף-Gemini לבקשת Ollama chat', () {
    final body = {
      'contents': [
        {
          'parts': [
            {'text': 'פרומפט ראשי'},
            {
              'inline_data': {'mime_type': 'image/jpeg', 'data': 'AAAA'},
            },
            {'text': 'עוגן 1 — קטע ייחוס:'},
            {
              'inline_data': {'mime_type': 'image/jpeg', 'data': 'BBBB'},
            },
          ],
        },
      ],
      'generationConfig': {
        'temperature': 0.1,
        'response_mime_type': 'application/json',
        'response_schema': {
          'type': 'ARRAY',
          'items': {
            'type': 'OBJECT',
            'properties': {
              'x': {'type': 'NUMBER'},
              'ok': {'type': 'BOOLEAN'},
              'verdict': {
                'type': 'STRING',
                'enum': ['confirmed', 'rejected'],
              },
            },
            'required': ['x', 'ok'],
          },
        },
      },
    };

    final out = AiEngine.geminiBodyToOllamaChat(body, 'qwen2.5vl:7b');

    expect(out['model'], 'qwen2.5vl:7b');
    expect(out['stream'], false);
    expect((out['options'] as Map)['temperature'], 0.1);

    final msg = (out['messages'] as List).single as Map;
    expect(msg['role'], 'user');
    expect(msg['images'], ['AAAA', 'BBBB']);
    final content = msg['content'] as String;
    // הטקסטים לפי הסדר, עם מצייני-מיקום ממוספרים לתמונות
    expect(
      content.indexOf('פרומפט ראשי'),
      lessThan(content.indexOf('[תמונה 1 מצורפת]')),
    );
    expect(
      content.indexOf('עוגן 1'),
      lessThan(content.indexOf('[תמונה 2 מצורפת]')),
    );

    // סכימה: טיפוסים באותיות קטנות, מבנה ו-enum נשמרים
    final fmt = out['format'] as Map;
    expect(fmt['type'], 'array');
    final items = fmt['items'] as Map;
    expect(items['type'], 'object');
    expect(((items['properties'] as Map)['x'] as Map)['type'], 'number');
    expect(((items['properties'] as Map)['ok'] as Map)['type'], 'boolean');
    expect(
      ((items['properties'] as Map)['verdict'] as Map)['enum'],
      ['confirmed', 'rejected'],
    );
    expect(items['required'], ['x', 'ok']);
  });
}
