import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show Offset;

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_engine.dart';
import 'road_junction_detector.dart';
import 'world_file_parser_service.dart';

/// עוגן מוצע ע"י Gemini — נקודת פיקסל על התמונה + מיקום עולם משוער.
/// כל הצעה טעונה **אישור פר-נקודה** של המשתמש לפני שהיא הופכת לנקודת התאמה.
class GeminiAnchorSuggestion {
  final Offset pixel;
  final LatLng world;
  final String name;

  /// 0–1, כפי שדיווח המודל.
  final double confidence;

  /// על סמך מה זוהה (צומת, כיכר, מבנה, נקודת גובה...).
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

/// נקודה בולטת שחולצה מהסריקה בשלב א' — עדיין ללא קואורדינטות עולם.
typedef _RawAnchor = ({
  Offset pixel, // פיקסלי-מקור
  String name,
  String basis,
  double confidence,
});

/// תוצאת שלב א': זיהוי האזור + הנקודות הבולטות.
typedef _Extraction = ({
  String regionName,
  LatLng? regionCenter,
  List<_RawAnchor> anchors,
});

/// תיבה גיאוגרפית (WGS84).
typedef _Bbox = ({double south, double west, double north, double east});

/// קטע-ייחוס מרונדר מאריחים + העיגון הגיאומטרי שלו (פיקסלי-עולם בזום).
typedef _GeoCrop = ({img.Image image, double originX, double originY, int zoom});

/// המצב האוטומטי — הצעת עוגנים למפות משורטטות/סרוקות דרך Gemini, בצנרת
/// "ראייה תחילה, זיכרון אף פעם":
///
/// 1. **חילוץ** — המודל מסמן נקודות בולטות על הסריקה בלבד (צמתים, כיכרות,
///    עיקולים, מבנים, נקודות גובה, מעיינות) ומזהה את שם האזור מהכיתוב.
///    בלי לנחש קואורדינטות עולם.
/// 2. **איתור האזור** — שם האזור (או רמז שהמשתמש הזין) עובר ג'יאוקודינג
///    אמיתי ב-Nominatim (OSM); נפילה חזרה להערכת-מרכז של המודל רק בלית
///    ברירה.
/// 3. **התאמה** — נשלפים קטע OSM + תצלום לוויין (Esri) של כל האזור,
///    מיושרים זה לזה, והמודל מצביע לכל נקודה ממוספרת על מיקומה בקטע.
///    ההצבעה מומרת ל-lat/lon במתמטיקת web-mercator.
/// 4. **אימות ועידון** — כל התאמה נבדקת שוב מול קטע OSM צמוד (z16) והמיקום
///    מעודן להצבעה מדויקת. `verified: true/false/null` על כל הצעה.
///
/// יש לולאת השלמה: אם אחרי סבב יש פחות מ-[_targetVerified] מאומתים, סבב
/// נוסף מבקש נקודות חדשות בלבד עם פידבק על מה שנדחה. המשתמש מאשר/דוחה כל
/// נקודה; המצב הידני נשאר כמו היום.
class GeminiAnchorService {
  static const _prefsKey = 'gemini_api_key';
  static const _hintPrefsKey = 'gemini_area_hint';

  /// שרשרת מודלים — לכל אחד מכסה חינמית יומית נפרדת (RPD). כשמודל מחזיר
  /// 429 (המכסה/הקצב נגמרו) עוברים לבא בתור, והבחירה נדבקת להמשך הסשן.
  static const _models = [
    'gemini-2.5-flash',
    'gemini-2.5-flash-lite',
    'gemini-2.0-flash',
  ];
  static int _modelIndex = 0;

  /// המודל שבשימוש כרגע (אחרי נפילות-חזרה של 429).
  static String get activeModel => _models[_modelIndex];

  /// `true` כשעברנו למודל חלופי כי המכסה של המודל הראשי נגמרה.
  static bool get usingFallbackModel => _modelIndex > 0;
  static const _userAgent = 'auto_maps/1.0 (github.com/elitzurms-art/auto-maps)';

  /// זום ומידות קטע מפת-הייחוס לאימות-העידון: z16 ≈ 2.4 מ'/פיקסל.
  static const _verifyZoom = 16;
  static const _verifyCropSize = 640;

  /// יעד העוגנים המאומתים: מינימום המסך (4) + רזרבה לדחייה ידנית של המשתמש.
  static const _targetVerified = 5;

  /// מקסימום סבבים: סבב ראשון + עד סבב-השלמה אחד (כל סבב = 3 קריאות מודל).
  static const _maxRounds = 2;

  static Future<String?> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_prefsKey)?.trim();
    return (key == null || key.isEmpty) ? null : key;
  }

  static Future<void> setApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, key.trim());
  }

  /// רמז-המיקום האחרון שהמשתמש הזין (לפריפיל בדיאלוג).
  static Future<String?> getAreaHint() async {
    final prefs = await SharedPreferences.getInstance();
    final hint = prefs.getString(_hintPrefsKey)?.trim();
    return (hint == null || hint.isEmpty) ? null : hint;
  }

  static Future<void> setAreaHint(String hint) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_hintPrefsKey, hint.trim());
  }

  /// מריץ את הצנרת המלאה ומחזיר עוגנים מוצעים.
  ///
  /// [areaHint] — טקסט חופשי מהמשתמש ("נוב רמת הגולן") שמנחה את איתור
  /// האזור; עדיף על שם שהמודל קרא מהמפה. [onStatus] — עדכוני התקדמות.
  ///
  /// התמונה מוקטנת לצלע-מקסימום 1600px לפני השליחה; הפיקסלים המוחזרים הם
  /// בממדי-המקור [imageWidth]×[imageHeight].
  Future<List<GeminiAnchorSuggestion>> suggestAnchors({
    required String imagePath,
    required int imageWidth,
    required int imageHeight,
    required String apiKey,
    String? areaHint,
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

    // שם המנוע הפעיל להצגה בהודעות-הסטטוס.
    final engineName =
        await AiEngine.engine() == AiEngine.ollama ? 'מודל מקומי' : 'Gemini';

    // גלאי הצמתים הקלאסי — עיבוד-תמונה מקומי, מדויק-פיקסל, בלי מכסות.
    // כשהוא מוצא מספיק מועמדים, Gemini רק *בוחר ומתאר* (סמנטיקה) במקום
    // *להצביע* (גיאומטריה) — מחסל את סחף-ההצבעה ומייתר את שלב ההצמדה.
    onStatus?.call('מאתר צמתים ומאפיינים על הסריקה (עיבוד-תמונה)...');
    var cvCandidates = const <MapFeature>[];
    try {
      // דרך המתודה הסטטית — closure מקומי כאן גורר את onStatus (הקשר widget)
      // שאינו בר-שליחה ל-Isolate.
      cvCandidates = await RoadJunctionDetector.detectInIsolate(sent);
    } catch (_) {}
    final useCv = cvCandidates.length >= 4;
    final usedCandidates = <int>{};
    final candidatesJpeg =
        useCv ? _markCandidates(sent, cvCandidates) : null;

    final all = <GeminiAnchorSuggestion>[];
    // פידבק לסבבי-השלמה + פיקסלים לדדופ (כולל נקודות שנפלו בהתאמה).
    final feedback = <String>[];
    final usedPixels = <Offset>[];
    // מרחק מינימלי בין עוגנים (פיקסלי-מקור) — מסנן כפילויות בין סבבים.
    final minSep = max(imageWidth, imageHeight) * 0.02;
    _Bbox? bbox;
    String regionLabel = '';

    for (var round = 1; round <= _maxRounds; round++) {
      onStatus?.call(
        round == 1
            ? (useCv
                  ? 'בוחר עוגנים מהצמתים שאותרו ($engineName)...'
                  : 'מסמן נקודות בולטות במפה ($engineName)...')
            : 'עוגנים נוספים (סבב $round)...',
      );
      final extraction = useCv
          ? await _selectFromCandidates(
              markedJpeg: candidatesJpeg!,
              candidates: cvCandidates,
              used: usedCandidates,
              scaleX: scaleX,
              scaleY: scaleY,
              imageWidth: imageWidth,
              imageHeight: imageHeight,
              apiKey: apiKey,
              areaHint: areaHint,
              feedback: feedback,
            )
          : await _extractAnchors(
              sentJpeg: jpeg,
              sentWidth: sent.width,
              sentHeight: sent.height,
              imageWidth: imageWidth,
              imageHeight: imageHeight,
              apiKey: apiKey,
              areaHint: areaHint,
              feedback: feedback,
            );
      var fresh = extraction.anchors
          .where(
            (a) => usedPixels.every((p) => (p - a.pixel).distance >= minSep),
          )
          .toList();
      if (fresh.isEmpty) break; // המודל מיצה את המפה

      // הצמדה: הצבעה חוזרת בתוך קטע מוגדל סביב כל נקודה — מתקנת את חוסר
      // הדיוק של הצבעה בתמונה מלאה. נקודה שהאלמנט שלה לא נמצא בקטע היא
      // הצבעת-סרק של שלב החילוץ — נזרקת (עם פידבק לסבב הבא). כשל טכני של
      // כל השלב לא מפיל — נשארים עם המיקומים הגסים.
      // במסלול ה-CV אין צורך: המועמדים כבר מדויקי-פיקסל מהגלאי.
      if (!useCv) {
        onStatus?.call('מדייק את הנקודות על הסריקה...');
        try {
          final snap = await _snapAnchors(
            sent: sent,
            anchors: fresh,
            apiKey: apiKey,
            scaleX: scaleX,
            scaleY: scaleY,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
          );
          for (final (name, pixel) in snap.dropped) {
            usedPixels.add(pixel);
            final px = (pixel.dx / scaleX).round();
            final py = (pixel.dy / scaleY).round();
            feedback.add(
              '- "$name" בפיקסל ($px,$py) — האלמנט המתואר לא נמצא במיקום שסומן',
            );
          }
          fresh = snap.kept;
        } catch (_) {}
        if (fresh.isEmpty) continue; // הכל נפל בהצמדה — סבב חדש עם הפידבק
      }

      // איתור האזור — פעם אחת, בסבב הראשון שמצליח.
      if (bbox == null) {
        onStatus?.call('מאתר את האזור...');
        final resolved = await _resolveRegion(extraction, areaHint);
        bbox = resolved.bbox;
        regionLabel = resolved.label;
      }

      onStatus?.call('מתאים נקודות מול מפה ולוויין ($regionLabel)...');
      final match = await _matchInRegion(
        sent: sent,
        anchors: fresh,
        bbox: bbox,
        regionLabel: regionLabel,
        apiKey: apiKey,
        scaleX: scaleX,
        scaleY: scaleY,
      );
      for (final a in fresh) {
        usedPixels.add(a.pixel);
      }
      for (final (name, pixel, note) in match.dropped) {
        final px = (pixel.dx / scaleX).round();
        final py = (pixel.dy / scaleY).round();
        feedback.add('- "$name" בפיקסל ($px,$py) — לא אותר באזור ($note)');
      }
      if (match.found.isEmpty) continue; // אולי הסבב הבא ימצא נקודות טובות

      // אימות ועידון ב-z16 — כשל טכני לא מפיל: מחזירים "לא אומת" ועוצרים.
      onStatus?.call('מאמת ומעדן עוגנים מול מפת הייחוס...');
      List<GeminiAnchorSuggestion> checked;
      try {
        checked = await _verifyAnchors(
          sent: sent,
          suggestions: match.found,
          apiKey: apiKey,
          scaleX: scaleX,
          scaleY: scaleY,
        );
      } catch (_) {
        all.addAll(match.found);
        break;
      }
      all.addAll(checked);
      for (final s in checked) {
        final px = (s.pixel.dx / scaleX).round();
        final py = (s.pixel.dy / scaleY).round();
        final status = switch (s.verified) {
          true => 'אומת',
          false => 'נדחה באימות${s.verifyNote == null ? '' : ' (${s.verifyNote})'}',
          null => 'לא אומת',
        };
        feedback.add('- "${s.name}" בפיקסל ($px,$py) — $status');
      }
      if (all.where((s) => s.verified == true).length >= _targetVerified) {
        break;
      }
    }
    // הגנת-תפרים: עוגן שעבר "החלפת-זהות" באחד המעברים בין השלבים (הוצמד
    // לצומת דומה, הותאם למקום שגוי-אך-דומה) יכול לחמוק מהאימות המקומי —
    // אבל הוא יסטה מהטרנספורמציה המשותפת של שאר העוגנים. סינון מתמטי, בלי
    // מודל.
    _applyGeometricConsistency(all, imageWidth, imageHeight);
    return all;
  }

  /// מסנן חריגים גיאומטריים: מתאים affine לכל העוגנים, מחשב סטייה פר-עוגן
  /// (מטרים בין העולם-בפועל לעולם-החזוי מהטרנספורמציה), ופוסל איטרטיבית את
  /// החריג הגרוע כל עוד הוא קיצוני (מעל [max(300מ', 4×חציון)]). סף נדיב —
  /// מפות משורטטות/מצולמות מעוותות באמת, וסטיות של עשרות מטרים לגיטימיות.
  void _applyGeometricConsistency(
    List<GeminiAnchorSuggestion> all,
    int imageWidth,
    int imageHeight,
  ) {
    while (true) {
      final active = [
        for (var i = 0; i < all.length; i++)
          if (all[i].verified != false) i,
      ];
      if (active.length < 4) return; // מעט מדי בשביל לזהות חריג בביטחון

      final WorldFileResult fit;
      try {
        fit = WorldFileParserService.calculateFromControlPoints(
          points: [
            for (final i in active)
              (pixel: all[i].pixel, world: all[i].world),
          ],
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        );
      } catch (_) {
        return; // נקודות קו-לינאריות וכד' — אין התאמה, אין סינון
      }
      final nw = fit.nw, ne = fit.ne, sw = fit.sw;
      if (nw == null || ne == null || sw == null) return;

      // עולם-חזוי לפיקסל: אינטרפולציה מהפינות (מדויקת עבור affine).
      LatLng predict(Offset px) {
        final u = px.dx / imageWidth;
        final v = px.dy / imageHeight;
        return LatLng(
          nw.latitude +
              u * (ne.latitude - nw.latitude) +
              v * (sw.latitude - nw.latitude),
          nw.longitude +
              u * (ne.longitude - nw.longitude) +
              v * (sw.longitude - nw.longitude),
        );
      }

      double meters(LatLng a, LatLng b) {
        final dLat = (a.latitude - b.latitude) * 111320;
        final dLon = (a.longitude - b.longitude) *
            111320 *
            cos(a.latitude * pi / 180);
        return sqrt(dLat * dLat + dLon * dLon);
      }

      final residuals = [
        for (final i in active) meters(all[i].world, predict(all[i].pixel)),
      ];
      final sorted = List<double>.from(residuals)..sort();
      final median = sorted[sorted.length ~/ 2];
      var worstIdx = 0;
      for (var j = 1; j < residuals.length; j++) {
        if (residuals[j] > residuals[worstIdx]) worstIdx = j;
      }
      final worst = residuals[worstIdx];
      if (worst <= max(300, 4 * median)) return; // אין חריג קיצוני — סיימנו

      final i = active[worstIdx];
      all[i] = all[i].copyWith(
        verified: false,
        verifyNote:
            'סוטה ~${worst.round()}מ\' מהטרנספורמציה של שאר העוגנים',
      );
      // ממשיכים לסבב נוסף — אולי החריג הסתיר חריג נוסף.
    }
  }

  // ═══ שלב א' — חילוץ נקודות מהסריקה (ראייה בלבד) ═══

  /// מבקש מהמודל לסמן נקודות בולטות **על התמונה בלבד** ולזהות את שם האזור
  /// מהכיתוב — בלי לנחש קואורדינטות עולם לנקודות.
  Future<_Extraction> _extractAnchors({
    required List<int> sentJpeg,
    required int sentWidth,
    required int sentHeight,
    required int imageWidth,
    required int imageHeight,
    required String apiKey,
    required String? areaHint,
    required List<String> feedback,
  }) async {
    var prompt =
        '''
אתה עוזר ג'יאורפרנס. לפניך תמונת מפה (סרוקה, מצולמת או משורטטת ביד), ככל הנראה של אזור בישראל. גודל התמונה שנשלחה אליך: ${sentWidth}x$sentHeight פיקסלים.

יש לך שתי משימות. **אל תנחש קואורדינטות עולם לנקודות** — ההתאמה למפה אמיתית תיעשה בשלב נפרד.

משימה 1 — זהה את האזור: קרא את הכיתוב על המפה (כותרת, שם יישוב, שמות רחובות, מספרי כבישים) והחזר:
- regionName: שם היישוב/האזור (בעברית)
- regionLat, regionLon: הערכה גסה בלבד של מרכז האזור ב-WGS84 (0,0 אם אין לך מושג)
${(areaHint != null && areaHint.trim().isNotEmpty) ? '\nהמשתמש מסר רמז מיקום: "${areaHint.trim()}" — התחשב בו בזיהוי האזור בלבד, לא בתיאור הנקודות.\n' : ''}
משימה 2 — סמן עד 12 נקודות בולטות על התמונה. נקודה טובה היא **נקודה חדה** — מקום שאפשר להצביע עליו בפיקסל בודד גם בשרטוט וגם במפה אמיתית של האזור. סדר עדיפות:
1. צמתים ומחלפים של כבישים (במיוחד ממוספרים) — מרכז הצומת המדויק
2. כיכרות — מרכז הכיכר
3. עיקולי כבישים מובהקים — קודקוד העיקול
4. מבנים ספציפיים מזוהים (מגדל מים, מבנה ציבור בולט, אנדרטה) — מרכז המבנה
5. נקודות ציון של רשת ישראל החדשה (ית"מ) אם מודפסת על המפה — הצטלבות קווי הרשת
6. נקודות גובה מסומנות (ספרת גובה עם נקודה/משולש) — מיקום סימן הנקודה
7. מעיינות מסומנים — מיקום סימן המעיין
8. פרטי טופוגרפיה חדים אחרים (פסגת הר מסומנת, קצה מאגר, שפך נחל)

תוויות שם של יישובים/אתרים אינן עוגן — הן מודפסות על שטח ולא על נקודה. השתמש בהן רק לזיהוי האזור.

**כלל ברזל: תאר אך ורק את מה שמצויר או כתוב בתמונה הזו.** אל תשתמש בידע שלך על המקום — אל תזכיר שם של כיכר/רחוב/מבנה שאינו כתוב על המפה עצמה, גם אם אתה מזהה את היישוב ובטוח בשם. תיאור נכון: "צומת T בין הדרך הראשית לרחוב שלישי מצפון". תיאור פסול: שם מקום מהזיכרון שלא מופיע בתמונה.

לכל נקודה החזר:
- x, y: מיקום הנקודה בסולם מנורמל 0-1000 של התמונה (x: 0=הקצה השמאלי, 1000=הקצה הימני; y: 0=למעלה, 1000=למטה)
- name: תיאור ויזואלי קצר בעברית של מה שרואים בתמונה (למשל "צומת T בכניסה הדרומית", "כיכר בקצה הרחוב הראשי"); אם כתוב שם על המפה ליד הנקודה — מותר לצטט אותו
- confidence: 0-1 (כלול רק נקודות עם 0.5 ומעלה)
- basis: סוג הנקודה (צומת / כיכר / עיקול / מבנה / נקודת גובה / מעיין) + מה בתמונה מגדיר אותה

העדף פיזור רחב על פני כל המפה. אם אין נקודות ראויות — החזר anchors ריק.''';

    if (feedback.isNotEmpty) {
      prompt +=
          '''


בסבבים קודמים כבר נוסו הנקודות הבאות:
${feedback.join('\n')}

הצע נקודות **חדשות בלבד** — אל תחזור על נקודה קיימת או סמוכה לה. למד ממה שנדחה או לא אותר, והעדף אזורים במפה שטרם כוסו.''';
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
          'type': 'OBJECT',
          'properties': {
            'regionName': {'type': 'STRING'},
            'regionLat': {'type': 'NUMBER'},
            'regionLon': {'type': 'NUMBER'},
            'anchors': {
              'type': 'ARRAY',
              'items': {
                'type': 'OBJECT',
                'properties': {
                  'x': {'type': 'NUMBER'},
                  'y': {'type': 'NUMBER'},
                  'name': {'type': 'STRING'},
                  'confidence': {'type': 'NUMBER'},
                  'basis': {'type': 'STRING'},
                },
                'required': ['x', 'y', 'name', 'confidence', 'basis'],
              },
            },
          },
          'required': ['regionName', 'regionLat', 'regionLon', 'anchors'],
        },
      },
    };

    final text = await _generate(body, apiKey);
    final root = jsonDecode(text) as Map<String, dynamic>;
    final lat = (root['regionLat'] as num?)?.toDouble() ?? 0;
    final lon = (root['regionLon'] as num?)?.toDouble() ?? 0;
    final center = (lat.abs() < 0.001 && lon.abs() < 0.001)
        ? null
        : LatLng(lat, lon);
    // הקואורדינטות מנורמלות 0-1000 (הסולם ש-Gemini מאומן להצביע בו) —
    // ההמרה לפיקסלי-מקור אצלנו.
    final anchors = <_RawAnchor>[
      for (final e in (root['anchors'] as List? ?? const [])
          .cast<Map<String, dynamic>>())
        (
          pixel: Offset(
            ((e['x'] as num).toDouble() / 1000 * imageWidth).clamp(
              0,
              imageWidth.toDouble(),
            ),
            ((e['y'] as num).toDouble() / 1000 * imageHeight).clamp(
              0,
              imageHeight.toDouble(),
            ),
          ),
          name: e['name'] as String? ?? '',
          basis: e['basis'] as String? ?? '',
          confidence: (e['confidence'] as num?)?.toDouble() ?? 0,
        ),
    ];
    return (
      regionName: root['regionName'] as String? ?? '',
      regionCenter: center,
      anchors: anchors,
    );
  }

  // ═══ מסלול ה-CV — בחירת עוגנים מתוך צמתים שאותרו אלגוריתמית ═══

  /// מסמן את מועמדי-הגלאי על עותק הסריקה: טבעת+נקודה סגולות ומספר לצידן.
  List<int> _markCandidates(img.Image sent, List<MapFeature> cands) {
    final marked = img.Image.from(sent);
    final purple = img.ColorRgb8(180, 0, 200);
    for (var i = 0; i < cands.length; i++) {
      final x = cands[i].pos.x.round().clamp(0, sent.width - 1);
      final y = cands[i].pos.y.round().clamp(0, sent.height - 1);
      img.fillCircle(marked, x: x, y: y, radius: 3, color: purple);
      img.drawCircle(marked, x: x, y: y, radius: 11, color: purple);
      img.drawString(
        marked,
        '${i + 1}',
        font: img.arial14,
        x: min(x + 13, sent.width - 26),
        y: max(y - 18, 0),
        color: purple,
      );
    }
    return img.encodeJpg(marked, quality: 85);
  }

  /// Gemini בוחר עוגנים מתוך המועמדים הממוספרים (ומזהה את האזור) — בלי
  /// להצביע בעצמו: הפיקסל נלקח מהגלאי, מדויק. [used] מתעדכן בבחירות.
  Future<_Extraction> _selectFromCandidates({
    required List<int> markedJpeg,
    required List<MapFeature> candidates,
    required Set<int> used,
    required double scaleX,
    required double scaleY,
    required int imageWidth,
    required int imageHeight,
    required String apiKey,
    required String? areaHint,
    required List<String> feedback,
  }) async {
    final typeLines = <String, List<int>>{};
    for (var i = 0; i < candidates.length; i++) {
      typeLines
          .putIfAbsent(
            RoadJunctionDetector.kindLabel(candidates[i].kind),
            () => [],
          )
          .add(i + 1);
    }
    final typesText = typeLines.entries
        .map((e) => '${e.key}: ${e.value.join(",")}')
        .join(' · ');

    var prompt =
        '''
אתה עוזר ג'יאורפרנס. לפניך תמונת מפה (סרוקה, מצולמת או משורטטת ביד), ככל הנראה של אזור בישראל, ועליה ${candidates.length} מועמדי-עוגן שסומנו **אלגוריתמית** (טבעות סגולות ממוספרות 1-${candidates.length}). מיקומי הטבעות מדויקים; חלק מהמועמדים עשויים להיות רעש (מפגש-קווים שאינו צומת דרכים, קצה מסגרת, סמל).

סוג כל מועמד לפי הגלאי: $typesText

משימה 1 — זהה את האזור: קרא את הכיתוב על המפה (כותרת, שם יישוב, שמות רחובות, מספרי כבישים) והחזר:
- regionName: שם היישוב/האזור (בעברית)
- regionLat, regionLon: הערכה גסה בלבד של מרכז האזור ב-WGS84 (0,0 אם אין לך מושג)
${(areaHint != null && areaHint.trim().isNotEmpty) ? '\nהמשתמש מסר רמז מיקום: "${areaHint.trim()}" — התחשב בו בזיהוי האזור בלבד.\n' : ''}
משימה 2 — בחר עד 12 מועמדים שהם עוגנים אמיתיים ושימושיים: צומת דרכים, כיכר, קצה-דרך (מבוי סתום) או עיקול ברור. העדף פיזור רחב על פני המפה, ואל תבחר מועמד שנראה רעש.

**כלל ברזל: תאר אך ורק את מה שמצויר או כתוב בתמונה.** אל תשתמש בשם מקום מהזיכרון שלך שאינו כתוב על המפה עצמה.

לכל בחירה החזר:
- candidateIndex: מספר המועמד (1-${candidates.length})
- name: תיאור ויזואלי קצר בעברית ("צומת T בכניסה הדרומית"); שם כתוב על המפה ליד הנקודה מותר לצטט
- confidence: 0-1
- basis: סוג הנקודה (צומת / כיכר / קצה דרך / עיקול)''';

    if (used.isNotEmpty) {
      prompt +=
          '\n\nאל תבחר את המועמדים שכבר נוסו בסבבים קודמים: '
          '${(used.toList()..sort()).join(', ')}.';
    }
    if (feedback.isNotEmpty) {
      prompt += '\n\nתוצאות הסבבים הקודמים:\n${feedback.join('\n')}';
    }

    final body = {
      'contents': [
        {
          'parts': [
            {'text': prompt},
            {
              'inline_data': {
                'mime_type': 'image/jpeg',
                'data': base64Encode(markedJpeg),
              },
            },
          ],
        },
      ],
      'generationConfig': {
        'response_mime_type': 'application/json',
        'response_schema': {
          'type': 'OBJECT',
          'properties': {
            'regionName': {'type': 'STRING'},
            'regionLat': {'type': 'NUMBER'},
            'regionLon': {'type': 'NUMBER'},
            'picks': {
              'type': 'ARRAY',
              'items': {
                'type': 'OBJECT',
                'properties': {
                  'candidateIndex': {'type': 'NUMBER'},
                  'name': {'type': 'STRING'},
                  'confidence': {'type': 'NUMBER'},
                  'basis': {'type': 'STRING'},
                },
                'required': ['candidateIndex', 'name', 'confidence', 'basis'],
              },
            },
          },
          'required': ['regionName', 'regionLat', 'regionLon', 'picks'],
        },
      },
    };

    final text = await _generate(body, apiKey);
    final root = jsonDecode(text) as Map<String, dynamic>;
    final lat = (root['regionLat'] as num?)?.toDouble() ?? 0;
    final lon = (root['regionLon'] as num?)?.toDouble() ?? 0;
    final center = (lat.abs() < 0.001 && lon.abs() < 0.001)
        ? null
        : LatLng(lat, lon);
    final anchors = <_RawAnchor>[];
    for (final e in (root['picks'] as List? ?? const [])
        .cast<Map<String, dynamic>>()) {
      final idx = (e['candidateIndex'] as num?)?.toInt();
      if (idx == null || idx < 1 || idx > candidates.length) continue;
      if (!used.add(idx)) continue; // כבר נוסה / כפילות בתשובה
      final c = candidates[idx - 1];
      anchors.add((
        pixel: Offset(
          (c.pos.x * scaleX).clamp(0, imageWidth.toDouble()),
          (c.pos.y * scaleY).clamp(0, imageHeight.toDouble()),
        ),
        name: e['name'] as String? ?? '',
        basis: e['basis'] as String? ??
            RoadJunctionDetector.kindLabel(c.kind),
        confidence: (e['confidence'] as num?)?.toDouble() ?? 0,
      ));
    }
    return (
      regionName: root['regionName'] as String? ?? '',
      regionCenter: center,
      anchors: anchors,
    );
  }

  // ═══ שלב א'2 — הצמדת הנקודות (הצבעה מדויקת בקטע מוגדל) ═══

  /// הצבעה בתמונה מלאה סוחפת עשרות פיקסלים; הצבעה בקטע קטן מדויקת בהרבה.
  /// לכל נקודה נשלח קטע ~384px סביב המיקום הגס (בלי סימון, כדי לא להטות)
  /// והמודל מצביע מחדש על מרכז האלמנט. נקודה שהאלמנט שלה לא נמצא בקטע —
  /// הצבעת-סרק של שלב החילוץ — מוחזרת ב-dropped ונזרקת מהצנרת.
  Future<({List<_RawAnchor> kept, List<(String, Offset)> dropped})>
      _snapAnchors({
    required img.Image sent,
    required List<_RawAnchor> anchors,
    required String apiKey,
    required double scaleX,
    required double scaleY,
    required int imageWidth,
    required int imageHeight,
  }) async {
    const cropSize = 384;
    final parts = <Map<String, dynamic>>[];
    final crops = <({int x, int y, int w, int h})>[];
    for (var i = 0; i < anchors.length; i++) {
      final cx = anchors[i].pixel.dx / scaleX;
      final cy = anchors[i].pixel.dy / scaleY;
      final w = min(cropSize, sent.width);
      final h = min(cropSize, sent.height);
      final x = (cx - w / 2).round().clamp(0, sent.width - w);
      final y = (cy - h / 2).round().clamp(0, sent.height - h);
      crops.add((x: x, y: y, w: w, h: h));
      final crop = img.copyCrop(sent, x: x, y: y, width: w, height: h);
      parts.add({
        'text': 'קטע ${i + 1} — אמור להכיל: "${anchors[i].name}" '
            '(${anchors[i].basis}):',
      });
      parts.add({
        'inline_data': {
          'mime_type': 'image/jpeg',
          'data': base64Encode(img.encodeJpg(crop, quality: 85)),
        },
      });
    }

    final prompt =
        '''
לפניך ${anchors.length} קטעים מוגדלים מתוך מפה סרוקה/משורטטת. מעל כל קטע מפורט אלמנט שתואר בשלב קודם — **ייתכן שהוא באמת נמצא בקטע וייתכן שלא** (התיאור הקודם היה גס ולעיתים שגוי).

לכל קטע:
- רק אם אתה **רואה בבירור** את האלמנט המתואר (קווי דרכים שנפגשים, עיגול כיכר, צורת מבנה) — found=true, ו-x,y בסולם מנורמל 0-1000 של הקטע (x: 0=שמאל, 1000=ימין; y: 0=למעלה, 1000=למטה).
- אם אינך רואה אותו, או שבמקום יש רק שטח ריק/מגרשים — found=false. **אל תנחש ואל תבחר "הכי קרוב"** — עדיף found=false מהצבעה על כלום.

דייק: לצומת — נקודת המפגש של צירי הדרכים; לכיכר — מרכז העיגול; לעיקול — קודקוד הפנייה; למבנה — מרכז המבנה.''';

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
              'index': {'type': 'NUMBER'},
              'found': {'type': 'BOOLEAN'},
              'x': {'type': 'NUMBER'},
              'y': {'type': 'NUMBER'},
            },
            'required': ['index', 'found', 'x', 'y'],
          },
        },
      },
    };

    final text = await _generate(body, apiKey);
    final results = (jsonDecode(text) as List).cast<Map<String, dynamic>>();

    // null = לא הוצמדה (found=false / הצבעה לא-תקינה / לא הוחזרה תשובה).
    final snapped = List<_RawAnchor?>.filled(anchors.length, null);
    for (final r in results) {
      final k = (r['index'] as num?)?.toInt();
      if (k == null || k < 1 || k > anchors.length) continue;
      if (r['found'] != true) continue;
      final nx = (r['x'] as num).toDouble();
      final ny = (r['y'] as num).toDouble();
      if (nx < 0 || ny < 0 || nx > 1000 || ny > 1000) continue;
      final c = crops[k - 1];
      final sentX = c.x + nx / 1000 * c.w;
      final sentY = c.y + ny / 1000 * c.h;
      final a = anchors[k - 1];
      snapped[k - 1] = (
        pixel: Offset(
          (sentX * scaleX).clamp(0, imageWidth.toDouble()),
          (sentY * scaleY).clamp(0, imageHeight.toDouble()),
        ),
        name: a.name,
        basis: a.basis,
        confidence: a.confidence,
      );
    }
    return (
      kept: [
        for (var i = 0; i < anchors.length; i++)
          if (snapped[i] != null) snapped[i]!,
      ],
      dropped: [
        for (var i = 0; i < anchors.length; i++)
          if (snapped[i] == null) (anchors[i].name, anchors[i].pixel),
      ],
    );
  }

  // ═══ שלב ב' — איתור האזור (ג'יאוקודינג אמיתי) ═══

  /// קובע את תיבת-החיפוש: רמז המשתמש (עדיפות ראשונה) או שם האזור שהמודל
  /// קרא — דרך Nominatim; נפילה חזרה למרכז שהמודל העריך. זורק כשאין כלום.
  Future<({_Bbox bbox, String label})> _resolveRegion(
    _Extraction extraction,
    String? areaHint,
  ) async {
    final queries = <String>[
      if (areaHint != null && areaHint.trim().isNotEmpty) areaHint.trim(),
      if (extraction.regionName.trim().isNotEmpty)
        extraction.regionName.trim(),
    ];
    // קודם חיפוש-יישוב (מפות הן לרוב של יישוב; חיפוש חופשי עלול להחזיר
    // מבנה/רחוב בעל שם דומה), ואז חיפוש חופשי. עם ריווח — מדיניות Nominatim.
    var first = true;
    for (final settlementOnly in [true, false]) {
      for (final q in queries) {
        if (!first) await Future.delayed(const Duration(milliseconds: 1100));
        first = false;
        final bbox = await _geocode(q, settlementOnly: settlementOnly);
        if (bbox != null) return (bbox: _padBbox(bbox), label: q);
      }
    }
    final center = extraction.regionCenter;
    if (center != null) {
      return (
        bbox: _padBbox((
          south: center.latitude - 0.012,
          west: center.longitude - 0.014,
          north: center.latitude + 0.012,
          east: center.longitude + 0.014,
        )),
        label: extraction.regionName.trim().isEmpty
            ? 'הערכת המודל'
            : extraction.regionName.trim(),
      );
    }
    throw const HttpException(
      'זיהוי האזור נכשל — הזן רמז מיקום (שם היישוב/האזור) ונסה שוב',
    );
  }

  /// חיפוש Nominatim (OSM). מחזיר null על כל כשל — למעבר לנפילה-חזרה.
  /// [settlementOnly] מגביל לתוצאות מסוג יישוב (עיר/כפר/מושב).
  Future<_Bbox?> _geocode(String query, {required bool settlementOnly}) async {
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': query,
        'format': 'json',
        'limit': '1',
        'accept-language': 'he',
        if (settlementOnly) 'featureType': 'settlement',
      });
      final resp = await http
          .get(uri, headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final list = jsonDecode(resp.body) as List;
      if (list.isEmpty) return null;
      // boundingbox: [south, north, west, east] (מחרוזות)
      final bb = ((list.first as Map<String, dynamic>)['boundingbox'] as List)
          .map((e) => double.parse(e as String))
          .toList();
      return (south: bb[0], west: bb[2], north: bb[1], east: bb[3]);
    } catch (_) {
      return null;
    }
  }

  /// ריפוד 20% + מינימום ~2.5 ק"מ לכל צלע — שהמפה המשורטטת לא תחרוג מהקטע.
  _Bbox _padBbox(_Bbox b) {
    var dLat = b.north - b.south;
    var dLon = b.east - b.west;
    final cLat = (b.north + b.south) / 2;
    final cLon = (b.east + b.west) / 2;
    dLat = max(dLat * 1.4, 0.022);
    dLon = max(dLon * 1.4, 0.026);
    return (
      south: cLat - dLat / 2,
      west: cLon - dLon / 2,
      north: cLat + dLat / 2,
      east: cLon + dLon / 2,
    );
  }

  // ═══ שלב ג' — התאמה ויזואלית מול קטע האזור (מפה + לוויין) ═══

  /// שולח את הסריקה עם הנקודות ממוספרות + קטע OSM + תצלום לוויין מיושרים
  /// של כל האזור, ומבקש מהמודל להצביע על כל נקודה בקטע-הייחוס. ההצבעות
  /// מומרות ל-lat/lon; נקודות שלא אותרו מוחזרות ב-dropped עם הסיבה.
  Future<
      ({
        List<GeminiAnchorSuggestion> found,
        List<(String, Offset, String)> dropped,
      })> _matchInRegion({
    required img.Image sent,
    required List<_RawAnchor> anchors,
    required _Bbox bbox,
    required String regionLabel,
    required String apiKey,
    required double scaleX,
    required double scaleY,
  }) async {
    final crops = await _fetchRegionCrops(bbox);
    final osm = crops.osm;
    final sat = crops.sat;

    // סימון הנקודות על עותק הסריקה: טבעת+נקודה סגולות ומספר לצידן.
    final marked = img.Image.from(sent);
    final purple = img.ColorRgb8(180, 0, 200);
    for (var i = 0; i < anchors.length; i++) {
      final ax = (anchors[i].pixel.dx / scaleX).round().clamp(0, sent.width - 1);
      final ay =
          (anchors[i].pixel.dy / scaleY).round().clamp(0, sent.height - 1);
      img.fillCircle(marked, x: ax, y: ay, radius: 4, color: purple);
      img.drawCircle(marked, x: ax, y: ay, radius: 14, color: purple);
      img.drawString(
        marked,
        '${i + 1}',
        font: img.arial24,
        x: min(ax + 17, sent.width - 30),
        y: max(ay - 26, 0),
        color: purple,
      );
    }

    final anchorLines = [
      for (var i = 0; i < anchors.length; i++)
        '${i + 1}. "${anchors[i].name}" (${anchors[i].basis})',
    ].join('\n');

    final prompt =
        '''
אתה מתאים נקודות בין מפה משורטטת/סרוקה למפה אמיתית של אזור "$regionLabel".

תמונה 1: המפה הסרוקה, עם ${anchors.length} נקודות ממוספרות (טבעות סגולות):
$anchorLines

תמונה 2: קטע מפת OSM של האזור, גודל ${osm.image.width}x${osm.image.height} פיקסלים.
${sat != null ? 'תמונה 3: תצלום לוויין של **בדיוק אותו קטע** — אותם גבולות ואותו גודל, פיקסל-לפיקסל מיושר לתמונה 2. השתמש בו לזיהוי מבנים, כיכרות ומגרשים שלא מסומנים ב-OSM.' : ''}

המפה הסרוקה עשויה להיות מסובבת, בקנה-מידה שונה, ולא מדויקת — התאם לפי **צורת רשת הכבישים** (טופולוגיה: אילו דרכים נפגשות, סדר הצמתים, כיכרות, עיקולים) ולפי מבנים בולטים, לא לפי מרחקים מדויקים.

לכל נקודה ממוספרת, מצא את מיקומה בקטע-הייחוס:
- אם מצאת — found=true, ‏refX,refY = המיקום בתמונה 2 בסולם מנורמל 0-1000 (refX: 0=הקצה השמאלי, 1000=הימני; refY: 0=למעלה, 1000=למטה).
- אם הנקודה מחוץ לקטע או שאינך בטוח — found=false.
- note: הסבר קצר בעברית.

היה קפדן: עדיף found=false מהתאמה שגויה. אם האזור כולו לא תואם לסריקה — החזר הכל found=false וכתוב זאת ב-note.''';

    final body = {
      'contents': [
        {
          'parts': [
            {'text': prompt},
            {
              'inline_data': {
                'mime_type': 'image/jpeg',
                'data': base64Encode(img.encodeJpg(marked, quality: 85)),
              },
            },
            {
              'inline_data': {
                'mime_type': 'image/jpeg',
                'data': base64Encode(img.encodeJpg(osm.image, quality: 85)),
              },
            },
            if (sat != null)
              {
                'inline_data': {
                  'mime_type': 'image/jpeg',
                  'data': base64Encode(img.encodeJpg(sat.image, quality: 85)),
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
              'anchorIndex': {'type': 'NUMBER'},
              'found': {'type': 'BOOLEAN'},
              'refX': {'type': 'NUMBER'},
              'refY': {'type': 'NUMBER'},
              'note': {'type': 'STRING'},
            },
            'required': ['anchorIndex', 'found', 'refX', 'refY', 'note'],
          },
        },
      },
    };

    final text = await _generate(body, apiKey);
    final results = (jsonDecode(text) as List).cast<Map<String, dynamic>>();

    final found = <GeminiAnchorSuggestion>[];
    final dropped = <(String, Offset, String)>[];
    final seen = <int>{};
    for (final r in results) {
      final k = (r['anchorIndex'] as num?)?.toInt();
      if (k == null || k < 1 || k > anchors.length || !seen.add(k)) continue;
      final a = anchors[k - 1];
      final note = r['note'] as String? ?? '';
      // refX/refY מנורמלים 0-1000 של קטע-הייחוס.
      final refX = (r['refX'] as num).toDouble();
      final refY = (r['refY'] as num).toDouble();
      final inBounds = refX >= 0 && refY >= 0 && refX <= 1000 && refY <= 1000;
      if (r['found'] != true || !inBounds) {
        dropped.add((a.name, a.pixel, note.isEmpty ? 'לא אותר' : note));
        continue;
      }
      found.add(
        GeminiAnchorSuggestion(
          pixel: a.pixel,
          world: _worldPxToLatLng(
            osm.originX + refX / 1000 * osm.image.width,
            osm.originY + refY / 1000 * osm.image.height,
            osm.zoom,
          ),
          name: a.name,
          confidence: a.confidence,
          basis: a.basis,
        ),
      );
    }
    // נקודות שהמודל התעלם מהן בתשובה — נחשבות כלא-אותרו.
    for (var i = 0; i < anchors.length; i++) {
      if (!seen.contains(i + 1)) {
        dropped.add((anchors[i].name, anchors[i].pixel, 'לא הוחזרה תשובה'));
      }
    }
    return (found: found, dropped: dropped);
  }

  /// קטע OSM + תצלום לוויין (Esri) מיושרים של כל ה-bbox. הזום נבחר כך
  /// שהצלע הארוכה ≤ ~1400px. כשל בלוויין לא מפיל — מחזיר sat=null.
  Future<({_GeoCrop osm, _GeoCrop? sat})> _fetchRegionCrops(_Bbox bbox) async {
    var zoom = 16;
    while (zoom > 11) {
      final w = _lonToWorldPx(bbox.east, zoom) - _lonToWorldPx(bbox.west, zoom);
      final h =
          _latToWorldPx(bbox.south, zoom) - _latToWorldPx(bbox.north, zoom);
      if (max(w, h) <= 1400) break;
      zoom--;
    }
    final x0 = _lonToWorldPx(bbox.west, zoom);
    final y0 = _latToWorldPx(bbox.north, zoom);
    final w = (_lonToWorldPx(bbox.east, zoom) - x0).round().clamp(384, 1600);
    final h = (_latToWorldPx(bbox.south, zoom) - y0).round().clamp(384, 1600);

    final osm = await _stitchCrop(
      x0: x0,
      y0: y0,
      width: w,
      height: h,
      zoom: zoom,
      tileUrl: (z, x, y) => 'https://tile.openstreetmap.org/$z/$x/$y.png',
    );
    _GeoCrop? sat;
    try {
      sat = await _stitchCrop(
        x0: x0,
        y0: y0,
        width: w,
        height: h,
        zoom: zoom,
        tileUrl: (z, x, y) =>
            'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/$z/$y/$x',
      );
    } catch (_) {
      sat = null;
    }
    return (osm: osm, sat: sat);
  }

  // ═══ שלב ד' — אימות ועידון פר-עוגן ב-z16 ═══

  /// לכל עוגן: קטע מהמפה הסרוקה (צלב סגול על הנקודה) + קטע מפת-ייחוס אמיתי
  /// (אריחי OSM, z16) שמרכזו בקואורדינטות של שלב ההתאמה. קריאת Gemini אחת
  /// מקבלת את כל הזוגות ומצביעה לכל עוגן על הפיקסל המתאים בקטע-הייחוס;
  /// ההצבעה מומרת חזרה ל-lat/lon מדויק (מתמטיקת web-mercator).
  Future<List<GeminiAnchorSuggestion>> _verifyAnchors({
    required img.Image sent,
    required List<GeminiAnchorSuggestion> suggestions,
    required String apiKey,
    required double scaleX,
    required double scaleY,
  }) async {
    // שליפת קטעי-הייחוס במקביל; עוגן שהשליפה שלו נכשלה נשאר "לא אומת".
    final crops = await Future.wait<_GeoCrop?>(
      suggestions.map((s) async {
        try {
          return await _fetchVerifyCrop(s.world);
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
            '$_verifyCropSize×$_verifyCropSize פיקסלים, שמרכזו במיקום '
            'שהותאם לעוגן:',
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
- תמונה שנייה: קטע ממפת ייחוס (OSM) שמרכזו במיקום שהותאם לאותו עוגן.

לכל עוגן, מצא בקטע מפת-הייחוס את הנקודה המדויקת שמתאימה לצלב הסגול (אותו צומת / כיכר / עיקול / מבנה / מעיין):
- אם מצאת — verdict="confirmed", ו-mapX,mapY = המיקום בקטע מפת-הייחוס בסולם מנורמל 0-1000 (mapX: 0=הקצה השמאלי, 1000=הימני; mapY: 0=למעלה, 1000=למטה).
- אם הנקודה אינה בקטע, או שההתאמה נראית שגויה — verdict="rejected".
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
      // mapX/mapY מנורמלים 0-1000 של קטע-האימות.
      final mapX = (v['mapX'] as num).toDouble();
      final mapY = (v['mapY'] as num).toDouble();
      final crop = crops[i]!;
      if (mapX < 0 || mapY < 0 || mapX > 1000 || mapY > 1000) {
        // אישר אבל הצביע מחוץ לקטע — לא סומכים על זה.
        out[i] = out[i].copyWith(
          verified: false,
          verifyNote: 'ההצבעה חרגה מקטע-הייחוס',
        );
        continue;
      }
      // הצבעה בתוך הקטע → lat/lon מדויק מהמיקום בקטע (עידון הקואורדינטות).
      final refined = _worldPxToLatLng(
        crop.originX + mapX / 1000 * crop.image.width,
        crop.originY + mapY / 1000 * crop.image.height,
        crop.zoom,
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

  /// קטע-אימות z16 [_verifyCropSize]² שמרכזו [center].
  Future<_GeoCrop> _fetchVerifyCrop(LatLng center) {
    final cx = _lonToWorldPx(center.longitude, _verifyZoom);
    final cy = _latToWorldPx(center.latitude, _verifyZoom);
    return _stitchCrop(
      x0: cx - _verifyCropSize / 2,
      y0: cy - _verifyCropSize / 2,
      width: _verifyCropSize,
      height: _verifyCropSize,
      zoom: _verifyZoom,
      tileUrl: (z, x, y) => 'https://tile.openstreetmap.org/$z/$x/$y.png',
    );
  }

  /// מרכיב קטע [width]×[height] מאריחי 256 שראשיתו בפיקסל-עולם ([x0],[y0]).
  Future<_GeoCrop> _stitchCrop({
    required double x0,
    required double y0,
    required int width,
    required int height,
    required int zoom,
    required String Function(int z, int x, int y) tileUrl,
  }) async {
    final tx0 = (x0 / 256).floor();
    final ty0 = (y0 / 256).floor();
    final tx1 = ((x0 + width) / 256).floor();
    final ty1 = ((y0 + height) / 256).floor();
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
        final url = tileUrl(zoom, tx, ty);
        fetches.add(() async {
          final resp = await http
              .get(Uri.parse(url), headers: {'User-Agent': _userAgent})
              .timeout(const Duration(seconds: 20));
          if (resp.statusCode != 200) {
            throw HttpException('אריח החזיר ${resp.statusCode}');
          }
          final tile = img.decodeImage(resp.bodyBytes);
          if (tile == null) throw const FormatException('פענוח אריח נכשל');
          img.compositeImage(canvas, tile, dstX: dstX, dstY: dstY);
        }());
      }
    }
    await Future.wait(fetches);

    final cropX = (x0 - tx0 * 256).round();
    final cropY = (y0 - ty0 * 256).round();
    return (
      image: img.copyCrop(
        canvas,
        x: cropX,
        y: cropY,
        width: width,
        height: height,
      ),
      originX: tx0 * 256.0 + cropX,
      originY: ty0 * 256.0 + cropY,
      zoom: zoom,
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

  /// שולח את הבקשה למנוע הפעיל ומחזיר את טקסט התשובה (JSON לפי הסכימה).
  /// ‏Gemini: על 429 (מכסה/קצב) עובר אוטומטית למודל הבא בשרשרת [_models].
  /// מנוע מקומי (Ollama): הבקשה מומרת ונשלחת לשרת המוגדר בהגדרות.
  Future<String> _generate(Map<String, dynamic> body, String apiKey) async {
    // temperature נמוך לכל הקריאות — הצבעות עקביות, פחות "יצירתיות".
    (body['generationConfig'] as Map<String, dynamic>)['temperature'] ??= 0.1;

    if (await AiEngine.engine() == AiEngine.ollama) {
      return _generateOllama(body);
    }

    http.Response? resp;
    for (var i = _modelIndex; i < _models.length; i++) {
      final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/${_models[i]}:generateContent',
      );
      resp = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': apiKey,
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 120));
      if (resp.statusCode == 429) continue; // המכסה נגמרה — המודל הבא
      _modelIndex = i; // נדבק למודל שעבד (לא חוזרים לנסות את שנגמר)
      break;
    }

    if (resp!.statusCode == 429) {
      throw const HttpException(
        'מכסת Gemini החינמית נגמרה בכל המודלים (429) — היא מתאפסת בסביבות '
        '10:00 בבוקר שעון ישראל, או שאפשר להפעיל חיוב בפרויקט',
      );
    }
    if (resp.statusCode != 200) {
      throw HttpException(
        'Gemini החזיר ${resp.statusCode}: ${_apiError(resp.body)}',
      );
    }

    final root = jsonDecode(resp.body) as Map<String, dynamic>;
    final candidate =
        (root['candidates'] as List?)?.firstOrNull as Map<String, dynamic>?;
    // תשובה חתוכה (MAX_TOKENS) או חסומה (SAFETY וכד') — כשל מפורש, לא
    // פרסור של JSON חלקי.
    final finishReason = candidate?['finishReason'] as String?;
    if (finishReason != null && finishReason != 'STOP') {
      throw HttpException('Gemini עצר באמצע התשובה ($finishReason)');
    }
    final text = (candidate?['content']?['parts'] as List?)
        ?.map((p) => (p as Map<String, dynamic>)['text'] as String? ?? '')
        .join();
    if (text == null || text.isEmpty) {
      throw const FormatException('Gemini החזיר תשובה ריקה');
    }
    return text;
  }

  /// קריאה למודל מקומי דרך Ollama ‏(/api/chat, פלט-מובנה דרך `format`).
  /// timeout ארוך — מודל-ראייה מקומי עם כמה תמונות יכול לקחת דקות.
  Future<String> _generateOllama(Map<String, dynamic> body) async {
    final url = await AiEngine.ollamaUrl();
    final model = await AiEngine.ollamaModel();
    final payload = AiEngine.geminiBodyToOllamaChat(body, model);
    final http.Response resp;
    try {
      resp = await http
          .post(
            Uri.parse('$url/api/chat'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(minutes: 10));
    } on Exception catch (e) {
      throw HttpException(
        'שרת Ollama לא זמין ב-$url ($e) — ודא שהוא רץ ושהמודל "$model" '
        'מותקן (ollama pull $model)',
      );
    }
    if (resp.statusCode != 200) {
      throw HttpException(
        'Ollama החזיר ${resp.statusCode}: ${_apiError(utf8.decode(resp.bodyBytes))}',
      );
    }
    final root = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final content =
        (root['message'] as Map<String, dynamic>?)?['content'] as String?;
    if (content == null || content.isEmpty) {
      throw const FormatException('Ollama החזיר תשובה ריקה');
    }
    return content;
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
