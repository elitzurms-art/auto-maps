import 'dart:convert';
import 'dart:io';
import 'dart:math';
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

  /// תוצאת האימות מול מפת-הייחוס: `true` — המודל איתר את הנקודה בקטע מפה
  /// אמיתי (OSM) והקואורדינטות עודנו לפי ההצבעה; `false` — האימות דחה את
  /// ההצעה; `null` — האימות לא בוצע (אין רשת / כשל טכני).
  final bool? verified;

  /// הסבר קצר מהמאמת (מוצג בדיאלוג האישור).
  final String? verifyNote;

  const GeminiAnchorSuggestion({
    required this.pixel,
    required this.world,
    required this.name,
    required this.confidence,
    required this.basis,
    this.verified,
    this.verifyNote,
  });

  GeminiAnchorSuggestion copyWith({
    LatLng? world,
    bool? verified,
    String? verifyNote,
  }) {
    return GeminiAnchorSuggestion(
      pixel: pixel,
      world: world ?? this.world,
      name: name,
      confidence: confidence,
      basis: basis,
      verified: verified ?? this.verified,
      verifyNote: verifyNote ?? this.verifyNote,
    );
  }
}

/// המצב האוטומטי — הצעת עוגנים סמנטית למפות משורטטות/סרוקות דרך Gemini:
/// המודל מזהה נקודות חדות — צמתים, כיכרות, עיקולי כבישים, מבנים ספציפיים,
/// רשת ית"מ מודפסת, נקודות גובה ומעיינות — ומציע זוגות פיקסל↔עולם (שמות
/// יישובים משמשים רק כרמז אזור, לא כעוגן). אחרי ההצעה רץ **שלב אימות**:
/// לכל עוגן נשלף קטע מפת-ייחוס אמיתי (אריחי OSM) סביב הקואורדינטות שהוצעו,
/// והמודל מתבקש להצביע על הנקודה בקטע — הקואורדינטות מעודנות לפי ההצבעה
/// במקום להסתמך על הזיכרון הגיאוגרפי של המודל. המשתמש מאשר/דוחה כל נקודה;
/// המצב הידני נשאר כמו היום.
class GeminiAnchorService {
  static const _prefsKey = 'gemini_api_key';
  static const _model = 'gemini-2.5-flash';
  static const _userAgent = 'auto_maps/1.0 (github.com/elitzurms-art/auto-maps)';

  /// זום ומידות קטע מפת-הייחוס לאימות: z16 ≈ 2.4 מ'/פיקסל, 640px ≈ 1.5 ק"מ.
  static const _verifyZoom = 16;
  static const _verifyCropSize = 640;

  static Future<String?> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_prefsKey)?.trim();
    return (key == null || key.isEmpty) ? null : key;
  }

  static Future<void> setApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, key.trim());
  }

  /// יעד העוגנים המאומתים: מינימום המסך (4) + רזרבה לדחייה ידנית של המשתמש.
  static const _targetVerified = 5;

  /// מקסימום סבבי-בקשה: סבב ראשון + עד 2 סבבי-השלמה כשחסרים מאומתים.
  static const _maxRounds = 3;

  /// שולח את תמונת המפה ל-Gemini ומחזיר עוגנים מוצעים — כולל שלב אימות מול
  /// מפת-ייחוס (ראה [GeminiAnchorSuggestion.verified]).
  ///
  /// הסבב הראשון מבקש עד 12 עוגנים (מרווח-ביטחון מעל 4 המינימום — חלק יידחו
  /// באימות). אם אחרי אימות יש פחות מ-[_targetVerified] מאומתים, רצים עד
  /// [_maxRounds]-1 סבבי-השלמה: המודל מקבל את רשימת מה שכבר הוצע (כולל מה
  /// נדחה ולמה) ומתבקש להציע עוגנים חדשים באזורים שטרם כוסו. הלולאה נעצרת
  /// כשמגיעים ליעד, כשהמודל לא מחזיר כלום חדש, או כשהאימות נופל טכנית.
  ///
  /// התמונה מוקטנת לצלע-מקסימום 1600px לפני השליחה (חוסך רוחב-פס ומדייק את
  /// המודל); הקואורדינטות מוחזרות בפיקסלים של התמונה שנשלחה וממופות חזרה
  /// למימדי המקור [imageWidth]×[imageHeight].
  ///
  /// [onStatus] — עדכוני התקדמות לתצוגה ("מזהה עוגנים...", "מאמת...").
  Future<List<GeminiAnchorSuggestion>> suggestAnchors({
    required String imagePath,
    required int imageWidth,
    required int imageHeight,
    required String apiKey,
    void Function(String status)? onStatus,
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

    final all = <GeminiAnchorSuggestion>[];
    // מרחק מינימלי בין עוגנים (פיקסלי-מקור) — מסנן כפילויות בין סבבים.
    final minSep = max(imageWidth, imageHeight) * 0.02;

    for (var round = 1; round <= _maxRounds; round++) {
      onStatus?.call(
        round == 1
            ? 'מזהה עוגנים במפה (Gemini)...'
            : 'מזהה עוגנים נוספים (סבב $round)...',
      );
      final fresh = await _requestSuggestions(
        sentJpeg: jpeg,
        sentWidth: sent.width,
        sentHeight: sent.height,
        scaleX: scaleX,
        scaleY: scaleY,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        apiKey: apiKey,
        previous: all,
      );
      final newOnes = fresh
          .where(
            (s) => all.every((e) => (e.pixel - s.pixel).distance >= minSep),
          )
          .toList();
      if (newOnes.isEmpty) break; // המודל מיצה את המפה — אין טעם בסבב נוסף

      onStatus?.call('מאמת עוגנים מול מפת הייחוס...');
      try {
        all.addAll(
          await _verifyAnchors(
            sent: sent,
            suggestions: newOnes,
            apiKey: apiKey,
            scaleX: scaleX,
            scaleY: scaleY,
          ),
        );
      } catch (_) {
        // האימות נפל טכנית (רשת?) — מחזירים "לא אומת" ולא ממשיכים לסבב
        // נוסף: בלי אימות אי-אפשר לדעת כמה חסרים.
        all.addAll(newOnes);
        break;
      }
      if (all.where((s) => s.verified == true).length >= _targetVerified) {
        break;
      }
    }
    return all;
  }

  /// סבב-בקשה אחד: מחזיר הצעות גולמיות (פיקסלים בממדי-המקור, לפני אימות).
  /// [previous] — עוגנים מסבבים קודמים; כשלא ריק, הפרומפט דורש חדשים בלבד.
  Future<List<GeminiAnchorSuggestion>> _requestSuggestions({
    required List<int> sentJpeg,
    required int sentWidth,
    required int sentHeight,
    required double scaleX,
    required double scaleY,
    required int imageWidth,
    required int imageHeight,
    required String apiKey,
    required List<GeminiAnchorSuggestion> previous,
  }) async {
    var prompt =
        '''
אתה עוזר ג'יאורפרנס. לפניך תמונת מפה (סרוקה, מצולמת או משורטטת ביד), ככל הנראה של אזור בישראל. גודל התמונה שנשלחה אליך: ${sentWidth}x$sentHeight פיקסלים.

זהה עד 12 עוגנים שאפשר למקם בביטחון גבוה בעולם האמיתי. עוגן טוב הוא **נקודה חדה** — מקום שאפשר להצביע עליו בפיקסל בודד גם בתמונה וגם בעולם. סדר עדיפות:
1. צמתים ומחלפים של כבישים (במיוחד ממוספרים) — מרכז הצומת המדויק
2. כיכרות — מרכז הכיכר
3. עיקולי כבישים מובהקים — קודקוד העיקול
4. מבנים ספציפיים מזוהים (מגדל מים, מבנה ציבור בולט, אנדרטה) — מרכז המבנה
5. נקודות ציון של רשת ישראל החדשה (ית"מ) אם מודפסת על המפה — הצטלבות קווי הרשת
6. נקודות גובה מסומנות (ספרת גובה עם נקודה/משולש) — מיקום סימן הנקודה
7. מעיינות מסומנים — מיקום סימן המעיין
8. פרטי טופוגרפיה חדים אחרים (פסגת הר מסומנת, קצה מאגר, שפך נחל)

שמות יישובים/אתרים כתובים על המפה הם רמז חשוב לזיהוי האזור, אבל **אל תשתמש בתווית שם עצמה כעוגן** — היא מודפסת על שטח ולא על נקודה מדויקת. במקום זה, השתמש בשם כדי לזהות צומת/כיכר/מבנה סמוכים ועגון אותם.

לכל עוגן החזר:
- pixelX, pixelY: מיקום הנקודה בתמונה שנשלחה (0,0 בפינה השמאלית-עליונה)
- lat, lon: קואורדינטות WGS84 של אותה נקודה בעולם האמיתי
- name: שם קצר בעברית
- confidence: 0-1 (כלול רק עוגנים עם 0.5 ומעלה)
- basis: על סמך מה זיהית (שם כתוב / צומת כבישים / רשת קואורדינטות)

העדף פיזור רחב של העוגנים על פני המפה. אם אינך מזהה כלום בביטחון — החזר מערך ריק.''';

    if (previous.isNotEmpty) {
      final lines = previous
          .map((s) {
            final px = (s.pixel.dx / scaleX).round();
            final py = (s.pixel.dy / scaleY).round();
            final status = switch (s.verified) {
              true => 'אומת מול מפת-ייחוס',
              false =>
                'נדחה באימות${s.verifyNote == null ? '' : ' (${s.verifyNote})'}',
              null => 'לא אומת',
            };
            return '- "${s.name}" בפיקסל ($px,$py) — $status';
          })
          .join('\n');
      prompt +=
          '''


בסבבים קודמים כבר הוצעו העוגנים הבאים:
$lines

הצע עד 8 עוגנים **חדשים בלבד** — אל תחזור על עוגן קיים או על נקודה סמוכה לו. למד מהעוגנים שנדחו (כנראה זיהוי-אזור שגוי או נקודה לא-חדה), והעדף אזורים במפה שטרם כוסו בעוגנים.''';
    }

    final body = {
      'contents': [
        {
          'parts': [
            {'text': prompt},
            {
              'inline_data': {
                'mime_type': 'image/jpeg',
                'data': base64Encode(sentJpeg),
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

    final text = await _generate(body, apiKey);
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

  // ═══ שלב האימות ═══

  /// לכל עוגן: קטע מהמפה הסרוקה (צלב סגול על הנקודה) + קטע מפת-ייחוס אמיתי
  /// (אריחי OSM, z16) שמרכזו בקואורדינטות שהוצעו. קריאת Gemini אחת מקבלת את
  /// כל הזוגות ומצביעה לכל עוגן על הפיקסל המתאים בקטע-הייחוס; ההצבעה מומרת
  /// חזרה ל-lat/lon מדויק (מתמטיקת web-mercator, לא זיכרון המודל).
  Future<List<GeminiAnchorSuggestion>> _verifyAnchors({
    required img.Image sent,
    required List<GeminiAnchorSuggestion> suggestions,
    required String apiKey,
    required double scaleX,
    required double scaleY,
  }) async {
    // שליפת קטעי-הייחוס במקביל; עוגן שהשליפה שלו נכשלה נשאר "לא אומת".
    final crops =
        await Future.wait<({img.Image image, double originX, double originY})?>(
      suggestions.map((s) async {
        try {
          return await _fetchReferenceCrop(s.world);
        } catch (_) {
          return null;
        }
      }),
    );

    final parts = <Map<String, dynamic>>[];
    final verifiable = <int>[]; // אינדקסים ב-suggestions, לפי סדר הצירוף
    for (var i = 0; i < suggestions.length; i++) {
      final crop = crops[i];
      if (crop == null) continue;
      final s = suggestions[i];
      final k = verifiable.length + 1;
      verifiable.add(i);
      final srcCrop = _cropWithCrosshair(
        sent,
        s.pixel.dx / scaleX,
        s.pixel.dy / scaleY,
      );
      parts.add({
        'text': 'עוגן $k — "${s.name}". קטע מהמפה הסרוקה, הצלב הסגול מסמן '
            'את העוגן המוצע:',
      });
      parts.add({
        'inline_data': {
          'mime_type': 'image/jpeg',
          'data': base64Encode(img.encodeJpg(srcCrop, quality: 85)),
        },
      });
      parts.add({
        'text': 'עוגן $k — קטע מפת ייחוס (OSM) בגודל '
            '$_verifyCropSize×$_verifyCropSize פיקסלים, שמרכזו בקואורדינטות '
            'שהוצעו לעוגן:',
      });
      parts.add({
        'inline_data': {
          'mime_type': 'image/jpeg',
          'data': base64Encode(img.encodeJpg(crop.image, quality: 85)),
        },
      });
    }
    if (verifiable.isEmpty) return suggestions;

    final prompt =
        '''
אתה מאמת עוגני ג'יאורפרנס. לפניך ${verifiable.length} זוגות תמונות. בכל זוג:
- תמונה ראשונה: קטע מהמפה הסרוקה, עם צלב סגול על עוגן מוצע.
- תמונה שנייה: קטע ממפת ייחוס (OSM) שמרכזו בקואורדינטות שהוצעו לאותו עוגן.

לכל עוגן, מצא בקטע מפת-הייחוס את הנקודה המדויקת שמתאימה לצלב הסגול (אותו צומת / כיכר / עיקול / מבנה / מעיין):
- אם מצאת — verdict="confirmed", ו-mapX,mapY = מיקום הפיקסל של הנקודה בקטע מפת-הייחוס (0,0 בפינה השמאלית-עליונה, גודל הקטע $_verifyCropSize×$_verifyCropSize).
- אם הנקודה אינה בקטע, או שהזיהוי המקורי נראה שגוי — verdict="rejected".
- note: הסבר קצר בעברית (למשל "הצומת נמצא, הוזז 120מ' מערבה" / "אין כיכר כזו בקטע").

היה קפדן: עדיף לדחות עוגן מפוקפק מאשר לאשר עוגן שגוי.''';

    final body = {
      'contents': [
        {
          'parts': [
            {'text': prompt},
            ...parts,
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
              'anchorIndex': {'type': 'NUMBER'},
              'verdict': {
                'type': 'STRING',
                'enum': ['confirmed', 'rejected'],
              },
              'mapX': {'type': 'NUMBER'},
              'mapY': {'type': 'NUMBER'},
              'confidence': {'type': 'NUMBER'},
              'note': {'type': 'STRING'},
            },
            'required': ['anchorIndex', 'verdict', 'mapX', 'mapY', 'note'],
          },
        },
      },
    };

    final text = await _generate(body, apiKey);
    final verdicts = (jsonDecode(text) as List).cast<Map<String, dynamic>>();

    final out = List<GeminiAnchorSuggestion>.from(suggestions);
    for (final v in verdicts) {
      final k = (v['anchorIndex'] as num?)?.toInt();
      if (k == null || k < 1 || k > verifiable.length) continue;
      final i = verifiable[k - 1];
      final note = v['note'] as String? ?? '';
      if (v['verdict'] != 'confirmed') {
        out[i] = out[i].copyWith(verified: false, verifyNote: note);
        continue;
      }
      final mapX = (v['mapX'] as num).toDouble();
      final mapY = (v['mapY'] as num).toDouble();
      final crop = crops[i]!;
      if (mapX < 0 ||
          mapY < 0 ||
          mapX > _verifyCropSize ||
          mapY > _verifyCropSize) {
        // אישר אבל הצביע מחוץ לקטע — לא סומכים על זה.
        out[i] = out[i].copyWith(
          verified: false,
          verifyNote: 'ההצבעה חרגה מקטע-הייחוס',
        );
        continue;
      }
      // הצבעה בתוך הקטע → lat/lon מדויק מהמיקום בקטע (עידון הקואורדינטות).
      final refined = _worldPxToLatLng(
        crop.originX + mapX,
        crop.originY + mapY,
        _verifyZoom,
      );
      out[i] = out[i].copyWith(
        world: refined,
        verified: true,
        verifyNote: note.isEmpty ? null : note,
      );
    }
    return out;
  }

  /// קטע מהמפה הסרוקה סביב העוגן (בקואורדינטות התמונה המוקטנת), עם צלב סגול.
  img.Image _cropWithCrosshair(img.Image src, double px, double py) {
    const size = 384;
    final w = min(size, src.width);
    final h = min(size, src.height);
    final x = (px - w / 2).round().clamp(0, src.width - w);
    final y = (py - h / 2).round().clamp(0, src.height - h);
    final crop = img.copyCrop(src, x: x, y: y, width: w, height: h);
    final ax = (px - x).round().clamp(0, w - 1);
    final ay = (py - y).round().clamp(0, h - 1);
    final color = img.ColorRgb8(230, 0, 230);
    img.drawCircle(crop, x: ax, y: ay, radius: 12, color: color);
    img.drawLine(
      crop,
      x1: ax - 22,
      y1: ay,
      x2: ax + 22,
      y2: ay,
      color: color,
      thickness: 3,
    );
    img.drawLine(
      crop,
      x1: ax,
      y1: ay - 22,
      x2: ax,
      y2: ay + 22,
      color: color,
      thickness: 3,
    );
    return crop;
  }

  /// מרכיב קטע מפת-ייחוס [size]×[size] סביב [center] מאריחי OSM (z=[zoom]).
  /// מחזיר גם את ראשית הקטע בפיקסלי-עולם של הזום — להמרת הצבעה→lat/lon.
  Future<({img.Image image, double originX, double originY})>
      _fetchReferenceCrop(
    LatLng center, {
    int zoom = _verifyZoom,
    int size = _verifyCropSize,
  }) async {
    final cx = _lonToWorldPx(center.longitude, zoom);
    final cy = _latToWorldPx(center.latitude, zoom);
    final half = size / 2;
    final tx0 = ((cx - half) / 256).floor();
    final ty0 = ((cy - half) / 256).floor();
    final tx1 = ((cx + half) / 256).floor();
    final ty1 = ((cy + half) / 256).floor();
    final maxTile = (1 << zoom) - 1;

    final canvas = img.Image(
      width: (tx1 - tx0 + 1) * 256,
      height: (ty1 - ty0 + 1) * 256,
      numChannels: 3,
    );
    final fetches = <Future<void>>[];
    for (var tx = tx0; tx <= tx1; tx++) {
      for (var ty = ty0; ty <= ty1; ty++) {
        if (tx < 0 || ty < 0 || tx > maxTile || ty > maxTile) continue;
        final dstX = (tx - tx0) * 256;
        final dstY = (ty - ty0) * 256;
        fetches.add(() async {
          final resp = await http
              .get(
                Uri.parse('https://tile.openstreetmap.org/$zoom/$tx/$ty.png'),
                headers: {'User-Agent': _userAgent},
              )
              .timeout(const Duration(seconds: 20));
          if (resp.statusCode != 200) {
            throw HttpException('אריח OSM החזיר ${resp.statusCode}');
          }
          final tile = img.decodeImage(resp.bodyBytes);
          if (tile == null) throw const FormatException('פענוח אריח נכשל');
          img.compositeImage(canvas, tile, dstX: dstX, dstY: dstY);
        }());
      }
    }
    await Future.wait(fetches);

    final cropX = (cx - half - tx0 * 256).round();
    final cropY = (cy - half - ty0 * 256).round();
    return (
      image: img.copyCrop(canvas, x: cropX, y: cropY, width: size, height: size),
      originX: tx0 * 256.0 + cropX,
      originY: ty0 * 256.0 + cropY,
    );
  }

  // ═══ web-mercator (פיקסלי-עולם בזום נתון, אריח 256) ═══

  static double _lonToWorldPx(double lon, int zoom) =>
      (lon + 180) / 360 * 256 * (1 << zoom);

  static double _latToWorldPx(double lat, int zoom) {
    final s = sin(lat * pi / 180).clamp(-0.9999, 0.9999);
    return (0.5 - log((1 + s) / (1 - s)) / (4 * pi)) * 256 * (1 << zoom);
  }

  static LatLng _worldPxToLatLng(double x, double y, int zoom) {
    final n = 256.0 * (1 << zoom);
    final lon = x / n * 360 - 180;
    final t = pi * (1 - 2 * y / n);
    final lat = atan((exp(t) - exp(-t)) / 2) * 180 / pi;
    return LatLng(lat, lon);
  }

  // ═══ קריאת Gemini משותפת ═══

  /// שולח בקשת generateContent ומחזיר את טקסט התשובה (JSON לפי הסכימה).
  Future<String> _generate(Map<String, dynamic> body, String apiKey) async {
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
        .timeout(const Duration(seconds: 120));

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
    return text;
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
