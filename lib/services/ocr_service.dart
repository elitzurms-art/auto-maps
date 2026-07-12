import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';

/// מילה שזוהתה: טקסט + מרכז-תיבה בקואורדינטות התמונה המקורית + גובה-
/// התיבה בפיקסלי-מקור (‏h — למדידת גודל-תווית וכיול-ההגדלה).
typedef OcrWord = ({String text, double cx, double cy, double h});

/// סיבוב-אריח למעבר-האנכי: ‏ccw = הכיוון המקובל בגיליונות (כיתוב מלמטה-
/// למעלה); ‏cw = נפילה-לאחור לגיליונות עם כיתוב-אנכי הפוך.
enum _TileRot { none, ccw, cw }

/// עטיפת-OCR לקריאת תוויות-קואורדינטה מודפסות ממפות-סקר/קדסטרליות
/// (נתיב "רשת-קואורדינטות") — **Tesseract בכל הפלטפורמות** (זהות-מנוע):
/// - **Windows/desktop** — tesseract.exe כ-subprocess (מצורף ליד ה-exe).
/// - **Android/iOS** — Tesseract נייטיבי (flutter_tesseract_ocr) עם אותו
///   `eng.traineddata` בדיוק (‏assets/tessdata, זהה לבנדל-הדסקטופ).
///
/// **הכנת-התמונה ב-Skia** (`readGridLabels`): תוויות-רשת הן טקסט קטן
/// שדורש הגדלה ×3, אבל הגדלת כל-התמונה מפוצצת זיכרון-מובייל וב-Dart
/// (‏package:image) לוקחת דקות. לכן: אריחים חופפים, כל אריח מוגדל
/// (ומסובב, למעבר-האנכי) ב-`Canvas.drawImageRect` — קוד נייטיבי, עשרות-
/// מילישניות במקום שניות — וקידוד-PNG נייטיבי של Skia. רץ על ה-isolate
/// הראשי (חובה ל-Skia/platform-channels); העבודה הכבדה כולה נייטיבית.
///
/// ⚠️ ML Kit נוסה (2026-07-12) ונפסל: על תוויות-מפה קטנות הוא גם איטי
/// (דקות) וגם חלש (2 צפונים מ-466 מילים באושה, מול פענוח-מלא ב-Tesseract).
class OcrService {
  static String? _cached;
  static bool _resolved = false;
  static String? _tessdataDir; // כשמשתמשים ב-Tesseract המצורף (Windows)

  static bool get _mobile => Platform.isAndroid || Platform.isIOS;

  /// נתיב ל-tesseract.exe. סדר-עדיפות: **מצורף ליד ה-exe** (`tesseract/`,
  /// עצמאי — בלי התקנה) → מותקן (Program Files) → PATH. null אם לא נמצא.
  static Future<String?> tesseractPath() async {
    if (_resolved) return _cached;
    _resolved = true;
    if (Platform.isWindows) {
      // 1) מצורף ליד ה-exe (bundle) — עצמאי.
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final bundled = '$exeDir\\tesseract\\tesseract.exe';
      if (File(bundled).existsSync()) {
        _cached = bundled;
        final td = '$exeDir\\tesseract\\tessdata';
        if (Directory(td).existsSync()) _tessdataDir = td;
        return bundled;
      }
      // 2) מותקן.
      const candidates = [
        r'C:\Program Files\Tesseract-OCR\tesseract.exe',
        r'C:\Program Files (x86)\Tesseract-OCR\tesseract.exe',
      ];
      for (final c in candidates) {
        if (File(c).existsSync()) {
          _cached = c;
          return c;
        }
      }
    }
    // 3) חיפוש ב-PATH.
    try {
      final r = await Process.run(
          Platform.isWindows ? 'where' : 'which', ['tesseract']);
      if (r.exitCode == 0) {
        final p = (r.stdout as String).split('\n').first.trim();
        if (p.isNotEmpty && File(p).existsSync()) {
          _cached = p;
          return p;
        }
      }
    } catch (_) {}
    return null;
  }

  /// ארגומנטי-בסיס: כשמשתמשים ב-Tesseract המצורף מעבירים --tessdata-dir
  /// (אין TESSDATA_PREFIX במערכת). ‏AUTO_MAPS_TESSDATA דורס — לטסטים
  /// (ה-Tesseract המותקן ב-Program Files חסר את מודל-העברית).
  static List<String> _tessdataArgs() {
    final env = Platform.environment['AUTO_MAPS_TESSDATA'];
    final td = (env != null && Directory(env).existsSync()) ? env : _tessdataDir;
    return td == null ? const [] : ['--tessdata-dir', td];
  }

  /// מנוע-OCR זמין? במובייל תמיד (Tesseract נייטיבי + tessdata ב-assets);
  /// בדסקטופ — אם נמצא tesseract.exe.
  static Future<bool> available() async =>
      _mobile || (await tesseractPath()) != null;

  /// מידות-תמונה מהכותרת בלבד (בלי פענוח-פיקסלים) — לשערי-הסלמת-הגדלה.
  static Future<(int, int)> imageSize(String path) async {
    final buf = await ui.ImmutableBuffer.fromUint8List(
        await File(path).readAsBytes());
    final desc = await ui.ImageDescriptor.encoded(buf);
    final size = (desc.width, desc.height);
    desc.dispose();
    buf.dispose();
    return size;
  }

  /// מריץ OCR על קובץ-תמונה עם whitelist-ספרות (+פסיק). מחזיר את הפלט
  /// הגולמי, או מחרוזת ריקה בכשל. [psm] — מצב-פילוח (7=שורה, 11=דליל).
  static Future<String> readDigits(String imagePath, {int psm = 11}) async {
    if (_mobile) {
      try {
        return await FlutterTesseractOcr.extractText(
          imagePath,
          language: 'eng',
          args: {
            'psm': '$psm',
            'tessedit_char_whitelist': '0123456789,',
          },
        );
      } catch (e) {
        debugPrint('[OCR] mobile extractText failed: $e');
        return '';
      }
    }
    final t = await tesseractPath();
    if (t == null) return '';
    try {
      final r = await Process.run(t, [
        imagePath,
        'stdout',
        ..._tessdataArgs(),
        '--psm',
        '$psm',
        '-c',
        'tessedit_char_whitelist=0123456789,',
      ]);
      return r.exitCode == 0 ? (r.stdout as String) : '';
    } catch (_) {
      return '';
    }
  }

  /// מזהה-ריצה לקובצי-האריחים הזמניים — שתי ריצות-מנוע חופפות (או שני
  /// טסטים במקביל) עם אותם שמות-קבצים דורסות זו את זו וקוראות זבל.
  static int _runSeq = 0;

  // ── קריאת-תוויות מכל התמונה (איתור-הרשת האוטומטי) ──
  // ⚠️ הכיול האמפירי (אושה): **אריח-ה-OCR** (אחרי הגדלה) חייב להיות
  // ≤ ~1650px — ב-psm 11 גוש-תוכן צפוף גורם ל-Tesseract לזרוק תווית
  // מבודדת כרעש. ההגדלה עצמה **אדפטיבית** (שלב-גישוש): Tesseract אוהב
  // ספרות ~20-40px — סריקה קטנה (אושה: תווית 13px) צריכה ×3; רינדור-PDF
  // גדול (תווית ~40px) רץ ×1 עם אריחי-מקור גדולים פי-9 → הרבה פחות אריחים.
  static const _ocrTilePx = 1650; // צלע-אריח-OCR (אחרי הגדלה) — הסף המכויל
  static const _probeUpscale = 3; // הגדלת שלב-הגישוש (הרגישה ביותר)
  static const _targetGlyphPx = 38; // גובה-ספרה מיטבי ל-Tesseract

  /// קורא את תוויות-התמונה בשני כיוונים — אופקי ([OcrWord] ב-normal)
  /// ואנכי (vertical — כל אריח מסובב 90°) — **בקואורדינטות התמונה
  /// המקורית**. [onTile] מדווח התקדמות; [isEnough] מאפשר עצירה-מוקדמת.
  ///
  /// עם [looksLikeLabel] הזרימה היא **גישוש→כיול→טבעות**:
  /// 1. גישוש: פינות + אמצעי-שוליים ב-×3 (תוויות חיות בשולי-הגיליון).
  /// 2. נמצאה תווית → ההגדלה מכוילת מגובהּ הנמדד, וסריקת-הטבעות ממשיכה
  ///    בקנה-המידה הנכון (מפה גדולה = אריחים גדולים = מעט אריחים).
  /// 3. הגישוש ריק → משלימים את טבעות-השוליים ב-×3; עדיין כלום →
  ///    פסק-דין "אין רשת" בלי לסרוק את פנים-המפה (מפות-כבישים יוצאות מהר).
  static Future<({List<OcrWord> normal, List<OcrWord> vertical})>
      readGridLabels(
    String imagePath, {
    int psm = 11,
    void Function(int done, int total)? onTile,
    bool Function(List<OcrWord> normal, List<OcrWord> vertical)? isEnough,
    bool Function(String text)? looksLikeLabel,
  }) async {
    final sw = Stopwatch()..start();
    final runId = _runSeq++;
    final bytes = await File(imagePath).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final im = frame.image;
    codec.dispose();
    try {
      // דילוג על אריחים כמעט-ריקים (שולי-נייר) — דגימת-כהות דלילה על
      // ה-RGBA הגולמי.
      final raw = (await im.toByteData(format: ui.ImageByteFormat.rawRgba))!
          .buffer
          .asUint8List();
      bool blank(ui.Rect r) {
        var dark = 0, n = 0;
        for (var y = r.top.toInt(); y < r.bottom.toInt(); y += 4) {
          for (var x = r.left.toInt(); x < r.right.toInt(); x += 4) {
            final o = (y * im.width + x) * 4;
            final lum =
                0.299 * raw[o] + 0.587 * raw[o + 1] + 0.114 * raw[o + 2];
            if (lum < 160) dark++;
            n++;
          }
        }
        return n == 0 || dark / n < 0.002;
      }

      final normal = <OcrWord>[];
      final vertical = <OcrWord>[];
      final processed = <String>{}; // אריחים שכבר נקראו (מפתח: מיקום+הגדלה)
      final scanned = <(ui.Rect, int)>[]; // לנפילת-האחור של האנכי-ההפוך
      var done = 0;
      var estTotal = 1;
      // דסקטופ = subprocess נפרד לכל אריח → מקבול לפי ליבות; מובייל =
      // בריכת 3 מופעים בפלאגין (vendored) → מקבול-2 זהיר.
      final batch =
          _mobile ? 2 : (Platform.numberOfProcessors - 2).clamp(4, 10);

      Future<void> sweep(List<ui.Rect> rects, int upscale) async {
        final todo = [
          for (final r in rects)
            if (!blank(r) && processed.add('${r.left}_${r.top}_$upscale')) r,
        ];
        scanned.addAll([for (final r in todo) (r, upscale)]);
        for (var i = 0; i < todo.length; i += batch) {
          await Future.wait(todo.skip(i).take(batch).map((r) async {
            normal.addAll(await _ocrTile(im, r,
                rot: _TileRot.none, psm: psm, upscale: upscale, runId: runId));
            onTile?.call(++done, estTotal);
            vertical.addAll(await _ocrTile(im, r,
                rot: _TileRot.ccw, psm: psm, upscale: upscale, runId: runId));
            onTile?.call(++done, estTotal);
          }));
        }
      }

      bool enough() =>
          isEnough != null &&
          isEnough(_dedupWords(normal), _dedupWords(vertical));
      List<double> labelHeights() => [
            for (final w in [...normal, ...vertical])
              if (looksLikeLabel != null && looksLikeLabel(w.text)) w.h,
          ];
      int countOf(List<List<ui.Rect>> rr) =>
          rr.fold<int>(0, (s, r) => s + r.length) * 2;

      final probeRings = _tileRings(
          im.width, im.height, _ocrTilePx ~/ _probeUpscale, 140);
      String phase;
      if (looksLikeLabel == null) {
        // בלי מסווג-תוויות (טסטים) — סריקת-טבעות קבועה ב-×3.
        estTotal = countOf(probeRings);
        for (final ring in probeRings) {
          await sweep(ring, _probeUpscale);
          if (enough()) break;
        }
        phase = 'קבוע ×$_probeUpscale';
      } else {
        // ── שלב-גישוש: פינות + אמצעי-שוליים ──
        final probe = _probeRects(probeRings.first, im.width, im.height);
        estTotal = probe.length * 2;
        await sweep(probe, _probeUpscale);
        var hs = labelHeights();
        if (hs.isEmpty) {
          // אין תווית בגישוש → משלימים את שולי-הגיליון (טבעות 0-1) ב-×3.
          estTotal = countOf([...probeRings.take(2)]);
          for (final ring in probeRings.take(2)) {
            await sweep(ring, _probeUpscale);
            if (enough()) break;
          }
          hs = labelHeights();
          if (hs.isEmpty) {
            // גם השוליים ריקים → אין רשת. לא סורקים את פנים-המפה.
            phase = 'אין-רשת (שוליים ריקים)';
          } else if (enough()) {
            phase = 'שוליים ×$_probeUpscale';
          } else {
            // יש תוויות אבל לא מספיק — ממשיכים פנימה ב-×3.
            estTotal = countOf(probeRings);
            for (final ring in probeRings.skip(2)) {
              await sweep(ring, _probeUpscale);
              if (enough()) break;
            }
            phase = 'מלא ×$_probeUpscale';
          }
        } else if (enough()) {
          phase = 'גישוש בלבד';
        } else {
          // ── כיול: הגדלה מגובה-התווית הנמדד, אריח-מקור בהתאם ──
          hs.sort();
          final labelH = hs[hs.length ~/ 2];
          final upscale =
              (_targetGlyphPx / labelH).round().clamp(1, _probeUpscale);
          // חפיפה ≥ רוחב-תווית (7 ספרות+פסיק ≈ ×12 מגובה-הספרה).
          final overlap = (labelH * 12).clamp(140.0, 400.0).round();
          final rings = _tileRings(
              im.width, im.height, _ocrTilePx ~/ upscale, overlap);
          estTotal = countOf(rings);
          for (final ring in rings) {
            await sweep(ring, upscale);
            if (enough()) break;
          }
          phase = 'מכויל ×$upscale (תווית ${labelH.round()}px)';
        }
        // ── נפילה-לאחור: כיתוב-אנכי הפוך ──
        // יש תוויות אופקיות אבל אף מילה **אנכית** לא נראית-כתווית — כנראה
        // גיליון שבו הכיתוב-האנכי הפוך (CW במקום CCW המקובל). סורקים שוב
        // את האריחים שכבר נקראו, בסיבוב הנגדי (עצירה ברגע שמספיק).
        final anyVertical = vertical
            .any((w) => looksLikeLabel(w.text));
        if (!enough() && labelHeights().isNotEmpty && !anyVertical) {
          estTotal += scanned.length;
          for (var i = 0; i < scanned.length; i += batch) {
            await Future.wait(scanned.skip(i).take(batch).map((s) async {
              vertical.addAll(await _ocrTile(im, s.$1,
                  rot: _TileRot.cw, psm: psm, upscale: s.$2, runId: runId));
              onTile?.call(++done, estTotal);
            }));
            if (enough()) break;
          }
          phase += ' +אנכי-הפוך';
        }
      }
      final n = _dedupWords(normal), v = _dedupWords(vertical);
      debugPrint('[OCR] grid-labels [$phase]: ${processed.length} tiles in '
          '${sw.elapsedMilliseconds}ms → ${n.length} normal + '
          '${v.length} vertical words');
      return (normal: n, vertical: v);
    } finally {
      im.dispose();
    }
  }

  /// קריאת **טקסט-חופשי** (עברית) מכל התמונה באריחי-Skia — למנוע
  /// שמות-המקומות. שמות מודפסים גדולים מספיק ברזולוציה טבעית — ‏×1
  /// (נמדד: ‏×2 דווקא הרע את הקריאה); כיוון אופקי בלבד. מחזיר מילים
  /// בקואורדינטות-המקור.
  static Future<List<OcrWord>> readTextWords(
    String imagePath, {
    int psm = 11,
    int upscale = 1,
    void Function(int done, int total)? onTile,
  }) async {
    final sw = Stopwatch()..start();
    final runId = _runSeq++;
    final bytes = await File(imagePath).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final im = frame.image;
    codec.dispose();
    try {
      final raw = (await im.toByteData(format: ui.ImageByteFormat.rawRgba))!
          .buffer
          .asUint8List();
      bool blank(ui.Rect r) {
        var dark = 0, n = 0;
        for (var y = r.top.toInt(); y < r.bottom.toInt(); y += 4) {
          for (var x = r.left.toInt(); x < r.right.toInt(); x += 4) {
            final o = (y * im.width + x) * 4;
            final lum =
                0.299 * raw[o] + 0.587 * raw[o + 1] + 0.114 * raw[o + 2];
            if (lum < 160) dark++;
            n++;
          }
        }
        return n == 0 || dark / n < 0.002;
      }

      final rings = _tileRings(im.width, im.height, _ocrTilePx ~/ upscale, 200);
      final rects = [
        for (final ring in rings)
          for (final r in ring)
            if (!blank(r)) r,
      ];
      final words = <OcrWord>[];
      final batch =
          _mobile ? 2 : (Platform.numberOfProcessors - 2).clamp(4, 10);
      var done = 0;
      for (var i = 0; i < rects.length; i += batch) {
        await Future.wait(rects.skip(i).take(batch).map((r) async {
          final wUp = (r.width * upscale).roundToDouble();
          final hUp = (r.height * upscale).roundToDouble();
          final rec = ui.PictureRecorder();
          ui.Canvas(rec).drawImageRect(
            im,
            r,
            ui.Rect.fromLTWH(0, 0, wUp, hUp),
            ui.Paint()..filterQuality = ui.FilterQuality.high,
          );
          final pic = rec.endRecording();
          final tile = await pic.toImage(wUp.round(), hUp.round());
          pic.dispose();
          final png = await tile.toByteData(format: ui.ImageByteFormat.png);
          tile.dispose();
          if (png == null) return;
          final tp = '${Directory.systemTemp.path}/_amtxt_${pid}_${runId}_'
              '${r.left.round()}_${r.top.round()}.png';
          await File(tp).writeAsBytes(
              png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes));
          // ⚠️ heb-בלבד: ערבוב heb+eng יוצר תחרות-כתבים ומרסק את הקריאה
          // (נמדד: "הגדוד העברי"→"TITAN"); שמות-מפה בארץ עבריים ממילא.
          final ws = await _wordsOfFile(tp,
              psm: psm, lang: 'heb', digitsOnly: false);
          words.addAll([
            for (final w in ws)
              (
                text: w.text,
                cx: r.left + w.cx / upscale,
                cy: r.top + w.cy / upscale,
                h: w.h / upscale,
              ),
          ]);
          onTile?.call(++done, rects.length);
        }));
      }
      final d = _dedupWords(words);
      debugPrint('[OCR] text-words: ${rects.length} tiles in '
          '${sw.elapsedMilliseconds}ms → ${d.length} words');
      return d;
    } finally {
      im.dispose();
    }
  }

  /// אריחי-הגישוש: 4 פינות + 4 אמצעי-שוליים מתוך הטבעת-החיצונית.
  static List<ui.Rect> _probeRects(List<ui.Rect> ring0, int w, int h) {
    final targets = <ui.Offset>[
      const ui.Offset(0, 0),
      ui.Offset(w.toDouble(), 0),
      ui.Offset(0, h.toDouble()),
      ui.Offset(w.toDouble(), h.toDouble()),
      ui.Offset(w / 2, 0),
      ui.Offset(w / 2, h.toDouble()),
      ui.Offset(0, h / 2),
      ui.Offset(w.toDouble(), h / 2),
    ];
    final picked = <ui.Rect>{};
    for (final t in targets) {
      ui.Rect? best;
      var bd = double.infinity;
      for (final r in ring0) {
        final d = (r.center - t).distanceSquared;
        if (d < bd) {
          bd = d;
          best = r;
        }
      }
      if (best != null) picked.add(best);
    }
    return picked.toList();
  }

  /// רשת-האריחים החופפים, מקובצת ל**טבעות** לפי מרחק-האריח משפת-התמונה —
  /// החיצונית ראשונה (שם התוויות), פנימה.
  static List<List<ui.Rect>> _tileRings(
      int w, int h, int tileSrc, int overlap) {
    final step = math.max(tileSrc - overlap, tileSrc ~/ 2);
    final xs = <int>[for (var x0 = 0; x0 < w; x0 += step) x0];
    final ys = <int>[for (var y0 = 0; y0 < h; y0 += step) y0];
    final rings = <int, List<ui.Rect>>{};
    for (var r = 0; r < ys.length; r++) {
      for (var c = 0; c < xs.length; c++) {
        final tw = math.min(tileSrc, w - xs[c]);
        final th = math.min(tileSrc, h - ys[r]);
        // שאריות-שוליים זעירות — מדולגות (אלא אם זה האריח היחיד).
        if ((tw < 80 || th < 80) && (xs.length > 1 || ys.length > 1)) continue;
        final ring =
            [c, r, xs.length - 1 - c, ys.length - 1 - r].reduce(math.min);
        (rings[ring] ??= []).add(ui.Rect.fromLTWH(xs[c].toDouble(),
            ys[r].toDouble(), tw.toDouble(), th.toDouble()));
      }
    }
    final keys = rings.keys.toList()..sort();
    return [for (final k in keys) rings[k]!];
  }

  /// מרנדר אריח מוגדל ×[upscale] (מסובב לפי [rot] במעברים-האנכיים)
  /// ב-**Skia**, מריץ עליו את המנוע, וממפה את מרכזי-המילים חזרה
  /// לקואורדינטות-המקור.
  static Future<List<OcrWord>> _ocrTile(
    ui.Image im,
    ui.Rect r, {
    required _TileRot rot,
    required int psm,
    required int upscale,
    required int runId,
  }) async {
    final wUp = (r.width * upscale).roundToDouble();
    final hUp = (r.height * upscale).roundToDouble();
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    switch (rot) {
      case _TileRot.ccw:
        // ‏CCW-90 של התוכן: (x,y) → (y, wUp−x); ממדי-הפלט מתהפכים.
        canvas.translate(0, wUp);
        canvas.rotate(-math.pi / 2);
      case _TileRot.cw:
        // ‏CW-90 של התוכן: (x,y) → (hUp−y, x).
        canvas.translate(hUp, 0);
        canvas.rotate(math.pi / 2);
      case _TileRot.none:
        break;
    }
    canvas.drawImageRect(
      im,
      r,
      ui.Rect.fromLTWH(0, 0, wUp, hUp),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final pic = rec.endRecording();
    final swap = rot != _TileRot.none;
    final tile = await pic.toImage(
        (swap ? hUp : wUp).round(), (swap ? wUp : hUp).round());
    pic.dispose();
    final png = await tile.toByteData(format: ui.ImageByteFormat.png);
    tile.dispose();
    if (png == null) return const [];
    final tp = '${Directory.systemTemp.path}/_amocr_${pid}_${runId}_'
        '${rot.name}_${r.left.round()}_${r.top.round()}.png';
    await File(tp).writeAsBytes(
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes));
    final words = await _wordsOfFile(tp, psm: psm);
    // מיפוי חזרה לקואורדינטות-האריח: ‏ccw ‏(cx,cy)→(wUp−cy, cx);
    // ‏cw ‏(cx,cy)→(cy, hUp−cx). הגובה נשאר גובה-הקריאה שנמדד.
    return [
      for (final w in words)
        (
          text: w.text,
          cx: r.left +
              (switch (rot) {
                    _TileRot.none => w.cx,
                    _TileRot.ccw => wUp - w.cy,
                    _TileRot.cw => w.cy,
                  }) /
                  upscale,
          cy: r.top +
              (switch (rot) {
                    _TileRot.none => w.cy,
                    _TileRot.ccw => w.cx,
                    _TileRot.cw => hUp - w.cx,
                  }) /
                  upscale,
          h: w.h / upscale,
        ),
    ];
  }

  /// מילים + מרכזי-תיבות מקובץ-תמונה (בקואורדינטות-הקובץ): דסקטופ — TSV
  /// של tesseract.exe; מובייל — hOCR של הפלאגין הנייטיבי. ברירת-המחדל —
  /// מצב-ספרות (תוויות-רשת); ‏[lang]/[digitsOnly] פותחים טקסט-חופשי
  /// (מנוע שמות-המקומות: ‏heb+eng בלי whitelist).
  static Future<List<OcrWord>> _wordsOfFile(
    String imagePath, {
    required int psm,
    String lang = 'eng',
    bool digitsOnly = true,
  }) async {
    if (_mobile) {
      try {
        final hocr = await FlutterTesseractOcr.extractHocr(
          imagePath,
          language: lang,
          args: {
            'psm': '$psm',
            if (digitsOnly) 'tessedit_char_whitelist': '0123456789,',
          },
        );
        return _parseHocr(hocr);
      } catch (e) {
        debugPrint('[OCR] mobile extractHocr failed: $e');
        return const [];
      }
    }
    final t = await tesseractPath();
    if (t == null) return const [];
    final out = '$imagePath.tsv_out';
    try {
      // ⚠️ TSV דרך המשתנה tessedit_create_tsv=1 ולא דרך קונפיג-הקובץ 'tsv'
      // — ה-Tesseract המצורף לא כולל את tessdata/configs/tsv (הועתק רק
      // traineddata), אז הקונפיג 'tsv' לא נמצא והקובץ לא נוצר.
      final r = await Process.run(t, [
        imagePath,
        out,
        ..._tessdataArgs(),
        '-l',
        lang,
        '--psm',
        '$psm',
        if (digitsOnly) ...['-c', 'tessedit_char_whitelist=0123456789,'],
        '-c',
        'tessedit_create_tsv=1',
      ]);
      if (r.exitCode != 0) return const [];
      final res = <OcrWord>[];
      for (final ln in File('$out.tsv').readAsLinesSync().skip(1)) {
        final c = ln.split('\t');
        if (c.length < 12) continue;
        final text = c[11].trim();
        if (text.isEmpty) continue;
        final x = double.tryParse(c[6]), y = double.tryParse(c[7]);
        final w = double.tryParse(c[8]), h = double.tryParse(c[9]);
        if (x == null || y == null || w == null || h == null) continue;
        res.add((text: text, cx: x + w / 2, cy: y + h / 2, h: h));
      }
      return res;
    } catch (_) {
      return const [];
    }
  }

  /// פרסור hOCR: כל `ocrx_word` נושא `title="bbox x0 y0 x1 y1; ..."`.
  static List<OcrWord> _parseHocr(String hocr) {
    final out = <OcrWord>[];
    final re = RegExp(
      r'''<span[^>]*class=.ocrx_word[^>]*title=.bbox (\d+) (\d+) (\d+) (\d+)[^>]*>(.*?)</span>''',
      dotAll: true,
    );
    for (final m in re.allMatches(hocr)) {
      final text = m
          .group(5)!
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .replaceAll('&amp;', '&')
          .trim();
      if (text.isEmpty) continue;
      final x0 = int.parse(m.group(1)!), y0 = int.parse(m.group(2)!);
      final x1 = int.parse(m.group(3)!), y1 = int.parse(m.group(4)!);
      out.add((
        text: text,
        cx: (x0 + x1) / 2,
        cy: (y0 + y1) / 2,
        h: (y1 - y0).toDouble(),
      ));
    }
    return out;
  }

  /// איחוד כפילויות מאזורי-החפיפה: אותו טקסט בטווח ~20px = אותה תווית.
  static List<OcrWord> _dedupWords(List<OcrWord> words) {
    final out = <OcrWord>[];
    for (final w in words) {
      final dup = out.any((o) =>
          o.text == w.text &&
          (o.cx - w.cx).abs() < 20 &&
          (o.cy - w.cy).abs() < 20);
      if (!dup) out.add(w);
    }
    return out;
  }
}
