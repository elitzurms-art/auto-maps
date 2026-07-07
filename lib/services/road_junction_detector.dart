import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// סוג האלמנט שאותר — קובע את התיאור שמוצג ל-Gemini ולמשתמש.
enum MapFeatureKind {
  /// מפגש 3+ דרכים.
  junction,

  /// קצה-דרך / מבוי סתום (ענף-שלד יחיד).
  deadEnd,

  /// כיכר — טבעת דרך סביב אי קטן ועגול, או דיסק-דרך מוצק קטן ועגול.
  roundabout,

  /// עיקול חד בדרך (שינוי-כיוון גדול בשלד).
  bend,
}

/// מועמד-עוגן שאותר אלגוריתמית: מיקום + סוג.
typedef MapFeature = ({Point<double> pos, MapFeatureKind kind});

/// תוצאת הגלאי: מאפיינים + נקודות-כביש + **קווי-כביש** (פוליגונים מהשלד),
/// הכל בפיקסלי-מקור. קווי-הכביש הם צורת הרשת כווקטורים — לרישום מבוסס-קווים.
class DetectResult {
  final List<MapFeature> features;
  final List<Point<double>> roadPoints;
  final List<List<Point<double>>> polylines;
  const DetectResult({
    required this.features,
    required this.roadPoints,
    this.polylines = const [],
  });

  static const empty =
      DetectResult(features: <MapFeature>[], roadPoints: <Point<double>>[]);
}

/// גלאי מאפייני-מפה קלאסי (עיבוד-תמונה, בלי מודל): מוצא צמתים, קצוות-דרך,
/// מבנים ועיקולים במפה משורטטת/סרוקה בדיוק-פיקסל ודטרמיניסטית.
///
/// הצנרת: בהירות → סף Otsu (משיחות כהות על רקע בהיר) → פתיחה מורפולוגית
/// (מוחקת טקסט וקווים דקים, משאירה דרכים עבות) → הסרת רכיבים קטנים →
/// דילול Zhang-Suen לשלד ברוחב פיקסל → פיקסלי-שלד עם 3+ שכנים = צמתים →
/// אשכול ומיון לפי משקל עם פיזור מרחבי.
///
/// בלי `dart:ui` בכוונה — רץ גם ב-VM טהור (בדיקות/כלי-עזר) וגם ב-Isolate.
class RoadJunctionDetector {
  /// מריץ את [detect] ב-Isolate על תמונה מפוענחת.
  ///
  /// ⚠️ המתודות האלה חייבות להישאר **סטטיות**: closure שנוצר בתוך מתודת
  /// State/מסך גורר את כל הקשר ה-widget ‏(WidgetsFlutterBinding וכו') שאינו
  /// בר-שליחה בין isolates — "object is unsendable". כאן בסביבה יש רק את
  /// הפרמטר.
  static Future<List<MapFeature>> detectInIsolate(img.Image image) {
    return Isolate.run(() => detect(image));
  }

  /// מריץ את [detectFull] ב-Isolate — מאפיינים + נקודות-כביש (למַתאם).
  static Future<DetectResult> detectFullInIsolate(img.Image image) {
    return Isolate.run(() => detectFull(image));
  }

  /// מריץ את [detect] ב-Isolate על קובץ — הפענוח הכבד קורה בתוך ה-Isolate.
  static Future<List<MapFeature>> detectFileInIsolate(String imagePath) {
    return Isolate.run(() {
      final decoded = img.decodeImage(File(imagePath).readAsBytesSync());
      return decoded == null ? const <MapFeature>[] : detect(decoded);
    });
  }

  /// תווית עברית קצרה לסוג-מאפיין (לפרומפט ולטולטיפ).
  static String kindLabel(MapFeatureKind kind) => switch (kind) {
        MapFeatureKind.junction => 'צומת',
        MapFeatureKind.deadEnd => 'קצה דרך',
        MapFeatureKind.roundabout => 'כיכר',
        MapFeatureKind.bend => 'עיקול',
      };

  /// מחזיר מועמדי-עוגן (צמתים, קצוות-דרך, מבנים, עיקולים) בקואורדינטות של
  /// [src], עם פיזור מרחבי. רשימה ריקה כשהתמונה לא נראית כמו שרטוט-קווים.
  ///
  /// [debugDir] — כשמוגדר, כותב לשם PNG של כל שלב-ביניים (מסכה, שלד...)
  /// + '00_info.txt' עם ערכי הכיול. לכיול הגלאי על מפות אמיתיות.
  /// **הערכת-סיבוב (deskew)** מהיסטוגרמת-כיווני-שיפוע — *לפני* זיהוי
  /// הצמתים. עובד על תמונה מסובבת (שיפועים חסינים לאי-חסינות-הצמתים של
  /// הגלאי): רשת-כבישים/מסגרת יוצרות שיפועים חזקים בשני כיוונים ניצבים;
  /// קיפול mod 90° מאחד אותם לשיא אחד = זווית-הרשת. מחזיר את הסטייה
  /// מיישור-צירים בטווח [-45,45]° (לתיקון: סובב את התמונה ב-‏minus התוצאה).
  /// ריצה ב-Isolate דרך [estimateSkewInIsolate].
  static Future<double> estimateSkewInIsolate(img.Image src) =>
      Isolate.run(() => estimateSkewDeg(src));

  /// **הערכת-סיבוב ב-projection-profile** (חסין-aliasing, בניגוד לשיפועים):
  /// אוסף פיקסלי-מבנה כהים, מסובב אותם בזוויות 0–90°, ובכל זווית מודד עד
  /// כמה הם מתרכזים לשורות/עמודות חדות (Σcount² על שני הצירים). רשת-כבישים
  /// מיושרת-צירים = ריכוז מקסימלי. מחזיר סטייה ב-[-45,45]°.
  static double estimateSkewDeg(img.Image src) {
    const dim = 1000; // רזולוציה בינונית מספיקה לזווית
    var work = src;
    final maxSide = max(src.width, src.height);
    if (maxSide > dim) {
      work = src.width >= src.height
          ? img.copyResize(src, width: dim)
          : img.copyResize(src, height: dim);
    }
    final w = work.width, h = work.height;
    if (w < 40 || h < 40) return 0;
    final lum = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        lum[y * w + x] = img.getLuminance(work.getPixel(x, y)).round();
      }
    }
    final content = _contentMask(lum, w, h);
    // סף: פיקסלי-מבנה = כהים מהחציון (כבישים כהים/קווי-שפה/טקסט/מסגרת).
    final vals = <int>[];
    for (var i = 0; i < lum.length; i++) {
      if (content[i] == 1) vals.add(lum[i]);
    }
    if (vals.length < 500) return 0;
    vals.sort();
    final median = vals[vals.length ~/ 2];
    final thr = median - 30; // כהה משמעותית מהרקע
    // קואורדינטות פיקסלי-המבנה, ממורכזות (עד ~20000, דגימה).
    final xs = <double>[], ys = <double>[];
    final cx = w / 2, cy = h / 2;
    var step = 1;
    // הערכת מונה גס לקביעת דגימה
    for (var i = 0; i < lum.length; i += 7) {
      if (content[i] == 1 && lum[i] <= thr) step++;
    }
    step = (step / 20000).ceil().clamp(1, 50);
    var cnt = 0;
    for (var i = 0; i < lum.length; i++) {
      if (content[i] == 1 && lum[i] <= thr) {
        if (cnt++ % step != 0) continue;
        xs.add((i % w) - cx);
        ys.add((i ~/ w) - cy);
      }
    }
    if (xs.length < 200) return 0;

    double score(double deg) {
      final t = deg * pi / 180, c = cos(t), s = sin(t);
      const nb = 400;
      final rows = Float64List(nb), cols = Float64List(nb);
      final half = (max(w, h)).toDouble();
      for (var i = 0; i < xs.length; i++) {
        final xr = c * xs[i] - s * ys[i];
        final yr = s * xs[i] + c * ys[i];
        final rb = (((yr + half) / (2 * half)) * nb).floor().clamp(0, nb - 1);
        final cb = (((xr + half) / (2 * half)) * nb).floor().clamp(0, nb - 1);
        rows[rb] += 1;
        cols[cb] += 1;
      }
      var e = 0.0;
      for (var i = 0; i < nb; i++) {
        e += rows[i] * rows[i] + cols[i] * cols[i];
      }
      return e;
    }

    // סריקה גסה 0–89° (סימטריית-רשת 90°) ואז עידון ±1° בצעדי 0.25°.
    var bestDeg = 0.0, bestScore = -1.0;
    for (var d = 0; d < 90; d++) {
      final sc = score(d.toDouble());
      if (sc > bestScore) {
        bestScore = sc;
        bestDeg = d.toDouble();
      }
    }
    for (var dd = -10; dd <= 10; dd++) {
      final d = bestDeg + dd * 0.25;
      final sc = score(d);
      if (sc > bestScore) {
        bestScore = sc;
        bestDeg = d;
      }
    }
    var phi = bestDeg % 90;
    if (phi > 45) phi -= 90; // לטווח [-45,45]
    return phi;
  }

  /// כמו [detectFull] אבל מחזיר רק את המאפיינים (תאימות אחורה).
  static List<MapFeature> detect(
    img.Image src, {
    int maxCandidates = 24,
    String? debugDir,
  }) =>
      detectFull(src, maxCandidates: maxCandidates, debugDir: debugDir)
          .features;

  static DetectResult detectFull(
    img.Image src, {
    int maxCandidates = 24,
    String? debugDir,
  }) {
    // הקטנה לעבודה. 2200 ולא פחות: רחובות פנימיים במפות-יישוב הם ~25px
    // במקור — מתחת ל-2200 הם יורדים אל מתחת לסף הפתיחה ונמחקים.
    const workDim = 2200;
    var work = src;
    var scale = 1.0;
    final maxSide = max(src.width, src.height);
    if (maxSide > workDim) {
      scale = maxSide / workDim;
      work = src.width >= src.height
          ? img.copyResize(src, width: workDim)
          : img.copyResize(src, height: workDim);
    }
    final w = work.width, h = work.height;
    if (w < 60 || h < 60) return DetectResult.empty;

    // 1) בהירות
    final lum = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        lum[y * w + x] =
            img.getLuminance(work.getPixel(x, y)).round().clamp(0, 255);
      }
    }

    // 2) שני ספים — יש שתי משפחות של מפות:
    //    א. קווים כהים על רקע בהיר (שרטוט קלאסי) — סף "כהה מהרקע".
    //    ב. דרכים *בהירות* בתוך מילוי אפור (מפות שכונה מודרניות, "מפת
    //       נוב") — סף "בהיר מהרקע".
    //    מריצים את הצנרת על שתי הקוטביות ובוחרים את הענף שמניב יותר
    //    צמתים — הרשת האמיתית עשירה בצמתים, הקוטביות השגויה נותנת פירורים.
    // מסכת-תוכן — מחריגה רקע-חוץ אחיד (פינות-סיבוב/שוליים) מכל חישובי-הסף.
    final content = _contentMask(lum, w, h);
    final hist = List<int>.filled(256, 0);
    var contentCount = 0;
    for (var i = 0; i < lum.length; i++) {
      if (content[i] == 1) {
        hist[lum[i]]++;
        contentCount++;
      }
    }
    var bgPeak = 255;
    for (var v = 129; v < 256; v++) {
      if (hist[v] > hist[bgPeak]) bgPeak = v;
    }
    final thrDark =
        min(max(_otsuHist(hist, contentCount), bgPeak - 40), bgPeak - 12);
    final thrBright = min(bgPeak + 12, 250);
    final maskDark = Uint8List(w * h);
    final maskBright = Uint8List(w * h);
    final maskCorr = Uint8List(w * h);
    var nDark = 0, nBright = 0, nCorr = 0;
    for (var i = 0; i < lum.length; i++) {
      if (content[i] == 0) continue; // דילוג על רקע-חוץ
      // <= — בקונבנציית אוצו ערך-הסף עצמו שייך למחלקה הכהה.
      if (lum[i] <= thrDark) {
        maskDark[i] = 1;
        nDark++;
      }
      if (lum[i] >= thrBright) {
        maskBright[i] = 1;
        nBright++;
      }
      // "מסדרונות": פיקסלים בצבע-הרקע — למפות שבהן למשטח הכביש אין צבע
      // משלו והוא מוגדר רק ע"י קווי-שפה (הכביש = מסדרון-רקע בין המגרשים).
      if ((lum[i] - bgPeak).abs() <= 20) {
        maskCorr[i] = 1;
        nCorr++;
      }
    }
    if (debugDir != null) {
      File('$debugDir/00_info.txt').writeAsStringSync(
        'work=${w}x$h scale=$scale otsu=${_otsu(lum)} bgPeak=$bgPeak '
        'thrDark=$thrDark (${(100.0 * nDark / lum.length).toStringAsFixed(1)}%) '
        'thrBright=$thrBright (${(100.0 * nBright / lum.length).toStringAsFixed(1)}%) '
        'corr=${(100.0 * nCorr / lum.length).toStringAsFixed(1)}%\n',
      );
      _dbgSave(debugDir, '01_mask_dark.png', maskDark, w, h);
      _dbgSave(debugDir, '01_mask_bright.png', maskBright, w, h);
      _dbgSave(debugDir, '01_mask_corridor.png', maskCorr, w, h);
    }

    final darkRes = (nDark < 200 || nDark > lum.length * 0.55)
        ? _BranchResult.empty
        : _clustersFromMask(maskDark, w, h, debugDir, 'dark');
    final brightRes = nBright < 200
        ? _BranchResult.empty
        : _clustersFromMask(maskBright, w, h, debugDir, 'bright');
    // מסדרונות: בלי סגירה (הייתה מגשרת את קווי-הגבול הדקים של המגרשים
    // וממזגת אותם עם הכבישים), ורק הרכיב הגדול — תאי-המגרשים (גם הם
    // בצבע-רקע, מוקפים קו) הם רכיבים קטנים נפרדים.
    final corrRes = nCorr < 200
        ? _BranchResult.empty
        : _clustersFromMask(
            maskCorr,
            w,
            h,
            debugDir,
            'corridor',
            closeFirst: false,
            largestOnly: true,
          );

    // הרשת האמיתית עשירה בצמתים; הקוטביות/הגישה השגויה נותנת פירורים.
    // הבחירה לפי צמתים בלבד — הם המדד האמין לעושר-רשת.
    var res = darkRes;
    if (brightRes.junctions.length > res.junctions.length) res = brightRes;
    if (corrRes.junctions.length > res.junctions.length) res = corrRes;
    if (res.junctions.isEmpty && res.deadEnds.isEmpty) {
      return DetectResult.empty;
    }

    // בחירה: צמתים תחילה (לפי משקל, עם מרחק-מינימום לפיזור; הקלה אם
    // דליל), ואז מכסה קטנה מכל סוג נוסף — מגוון עוזר ל-Gemini לבחור.
    final picked = <(_Cluster, MapFeatureKind)>[];
    bool farEnough(_Cluster c, double sep) => picked.every(
          (p) => (p.$1.cx - c.cx).abs() >= sep || (p.$1.cy - c.cy).abs() >= sep,
        );
    void pickFrom(
      List<_Cluster> list,
      MapFeatureKind kind,
      int quota,
      double sep,
    ) {
      var taken = 0;
      for (final c in list) {
        if (taken >= quota || picked.length >= maxCandidates) return;
        if (!farEnough(c, sep)) continue;
        picked.add((c, kind));
        taken++;
      }
    }

    final junctions = List<_Cluster>.from(res.junctions)
      ..sort((a, b) => b.weight.compareTo(a.weight));
    final side = max(w, h).toDouble();
    // כיכרות ראשונות — מרכז הכיכר עדיף על צמתי-השפה שלה, ובדיקת-הפיזור
    // של הצמתים אחריהן תחסום את צמתי-השפה המיותרים.
    final roundabouts = List<_Cluster>.from(res.roundabouts)
      ..sort((a, b) => b.weight.compareTo(a.weight));
    pickFrom(roundabouts, MapFeatureKind.roundabout, 4, side * 0.04);
    pickFrom(junctions, MapFeatureKind.junction, 14, side * 0.06);
    if (picked.length < 4) {
      pickFrom(junctions, MapFeatureKind.junction, 14, side * 0.03);
    }
    final deadEnds = List<_Cluster>.from(res.deadEnds)
      ..sort((a, b) => b.weight.compareTo(a.weight));
    final bends = List<_Cluster>.from(res.bends)
      ..sort((a, b) => b.weight.compareTo(a.weight));
    pickFrom(deadEnds, MapFeatureKind.deadEnd, 4, side * 0.04);
    pickFrom(bends, MapFeatureKind.bend, 4, side * 0.04);

    if (debugDir != null) {
      final vis = img.Image.from(work);
      for (final (c, kind) in picked) {
        final color = switch (kind) {
          MapFeatureKind.junction => img.ColorRgb8(255, 0, 200),
          MapFeatureKind.deadEnd => img.ColorRgb8(255, 140, 0),
          MapFeatureKind.roundabout => img.ColorRgb8(0, 90, 255),
          MapFeatureKind.bend => img.ColorRgb8(0, 170, 0),
        };
        img.drawCircle(vis, x: c.cx.round(), y: c.cy.round(), radius: 12,
            color: color);
        img.drawCircle(vis, x: c.cx.round(), y: c.cy.round(), radius: 13,
            color: color);
      }
      File('$debugDir/06_candidates.png').writeAsBytesSync(img.encodePng(vis));
    }

    return DetectResult(
      features: [
        for (final (c, kind) in picked)
          (pos: Point(c.cx * scale, c.cy * scale), kind: kind),
      ],
      // נקודות-הכביש של הענף המנצח, בפיקסלי-מקור.
      roadPoints: [
        for (final p in res.roadPoints) Point(p.x * scale, p.y * scale),
      ],
      // קווי-הכביש (פוליגונים), בפיקסלי-מקור.
      polylines: [
        for (final line in res.polylines)
          [for (final p in line) Point(p.x * scale, p.y * scale)],
      ],
    );
  }

  /// שמירת מסכה בינארית כ-PNG לדיבוג (לבן = 1).
  static void _dbgSave(
    String? dir,
    String name,
    Uint8List m,
    int w,
    int h,
  ) {
    if (dir == null) return;
    final im = img.Image(width: w, height: h, numChannels: 1);
    for (var i = 0; i < m.length; i++) {
      if (m[i] == 1) im.setPixelRgb(i % w, i ~/ w, 255, 255, 255);
    }
    File('$dir/$name').writeAsBytesSync(img.encodePng(im));
  }

  /// הצנרת המשותפת לענפים: סגירה → פתיחה → מחיקת גושים → סינון רכיבים →
  /// דילול → מאפיינים (צמתים/קצוות/עיקולים מהשלד + מבנים מהסינון).
  /// משנה את [mask] במקום.
  static _BranchResult _clustersFromMask(
    Uint8List mask,
    int w,
    int h,
    String? debugDir,
    String tag, {
    bool closeFirst = true,
    bool largestOnly = false,
  }) {
    // כל הרדיוסים נגזרים מרוחב-המשיחה שנמדד מהמסכה עצמה — לא קבועים
    // שמכוונים למפה מסוימת. p75 (ולא חציון) כי טקסט צפוף יכול להיות
    // כמחצית מפיקסלי-הדיו והדרכים תמיד עבות ממנו.
    // הפתיחה חייבת לשמר את הדרך ה*דקה* ביותר (לא הממוצעת): שחיקת r מוחקת
    // כל קו צר מ-2r+1, אז r ≤ (רוחב-הדרך-הדקה − 1) / 2.
    final strokeW = _estimateStrokeWidth(mask, w, h);
    if (strokeW == 0) return _BranchResult.empty;
    final closeRadius = closeFirst ? (strokeW * 0.3).round().clamp(1, 3) : 0;
    // ‎×0.8 — מרווח-ביטחון: האומדן הוא p25, והדרך הדקה באמת יכולה להיות
    // ~20% צרה ממנו; עדיף שקצת טקסט ישרוד (הסינון בהמשך) מלמחוק רחוב.
    final openRadius = (((strokeW * 0.8).round() - 1) ~/ 2).clamp(1, 5);
    final blobRadius = max(12, strokeW * 2);
    final minSize = max(600, strokeW * strokeW * 10);

    // סגירה מורפולוגית תחילה: קו-אמצע לבן מקווקו של כביש חוצה את פס-הדיו
    // לשניים והפתיחה הייתה מוחקת אותם — הסגירה מאחה את הפס. בענף
    // המסדרונות אין סגירה (מגשרת את קווי-הגבול הדקים של המגרשים).
    var m = closeRadius > 0
        ? _erode(_dilate(mask, w, h, closeRadius), w, h, closeRadius)
        : mask;
    // פתיחה מורפולוגית: טקסט וקווים דקים נמחקים, דרכים שורדות ברוחבן.
    m = _dilate(_erode(m, w, h, openRadius), w, h, openRadius);
    _dbgSave(debugDir, '02_${tag}_opened.png', m, w, h);

    // מחיקת גושים מסיביים גם כשהם מחוברים לרשת (תיבת-מקרא שדרך "נכנסת"
    // אליה, מבנה צבוע, שולי-נייר): שחיקה עמוקה משאירה רק ליבות של אזורים
    // עבים מפי-2 מרוחב-דרך, וניפוח-חזרה עם שוליים מוחק את הגוש וסביבתו,
    // כולל צמתי-הסרק שעל גבולו.
    final blobCore = _erode(m, w, h, blobRadius);
    Uint8List? blobZone;
    // כיכר "מלאה" (דיסק-דרך מוצק): ליבת-גוש קטנה, עגולה וקרובה-לריבועית —
    // נרשמת כמועמדת-כיכר לפני שהגוש נמחק מהמסכה.
    final roundabouts =
        _roundBlobCores(blobCore, w, h, strokeW, blobRadius);
    if (blobCore.any((v) => v == 1)) {
      blobZone = _dilate(blobCore, w, h, blobRadius + 6);
      for (var i = 0; i < m.length; i++) {
        if (blobZone[i] == 1) m[i] = 0;
      }
    }
    _dbgSave(debugDir, '03_${tag}_deblobbed.png', m, w, h);

    // סינון רכיבים: קטנים (כתמים, סמלים) וגם גושים מלאים מבודדים שנותרו.
    _filterComponents(m, w, h, minSize: minSize, maxSolidity: 0.45);
    if (largestOnly) _keepLargestComponent(m, w, h);
    _dbgSave(debugDir, '04_${tag}_components.png', m, w, h);
    if (debugDir != null) {
      File('$debugDir/00_info.txt').writeAsStringSync(
        '$tag: strokeW=$strokeW close=$closeRadius open=$openRadius '
        'blob=$blobRadius minSize=$minSize\n',
        mode: FileMode.append,
      );
    }

    // דילול לשלד
    final skel = _thinZhangSuen(m, w, h);
    _dbgSave(debugDir, '05_${tag}_skeleton.png', skel, w, h);

    // מאפיינים לפי crossing-number: מספר מעברי 0→1 בסריקה מעגלית של
    // 8 השכנים. קו ישר (גם מדרגת-אלכסון) = 2 מעברים; צומת אמיתי = 3+;
    // קצה-דרך = 1. ספירת-שכנים פשוטה מסמנת בטעות מדרגות-אלכסון כצמתים.
    const margin = 16;
    // אזור-פסילה לקצוות: מחיקת-הגושים חותכת דרכים על גבול הגוש ומייצרת
    // קצוות-סרק — פוסלים קצה בקרבת אזור שנמחק.
    final deadEndExcl =
        blobZone == null ? null : _dilate(blobZone, w, h, 10);
    final junctionPts = <int>[];
    final deadEndPts = <int>[];
    for (var y = margin; y < h - margin; y++) {
      final row = y * w;
      for (var x = margin; x < w - margin; x++) {
        if (skel[row + x] == 0) continue;
        // p2..p9 בכיוון השעון החל מצפון
        final ring = [
          skel[row - w + x], skel[row - w + x + 1], skel[row + x + 1],
          skel[row + w + x + 1], skel[row + w + x], skel[row + w + x - 1],
          skel[row + x - 1], skel[row - w + x - 1],
        ];
        var transitions = 0;
        for (var k = 0; k < 8; k++) {
          if (ring[k] == 0 && ring[(k + 1) % 8] == 1) transitions++;
        }
        if (transitions >= 3) {
          junctionPts.add(row + x);
        } else if (transitions == 1 &&
            (deadEndExcl == null || deadEndExcl[row + x] == 0)) {
          deadEndPts.add(row + x);
        }
      }
    }

    // כיכר "טבעת": אי-רקע קטן ועגול שכלוא בתוך המסכה (מוקף דרך מכל עבר).
    roundabouts.addAll(_roundIslands(m, w, h, strokeW));

    // דגימת נקודות-כביש מהשלד (כל ~5px) — צורת הרשת עצמה, לא רק צמתים.
    // משמשת את המַתאם לשבירת אמביגואיית-הסיבוב (כבישים אינם סימטריים).
    final roadPts = <Point<double>>[];
    var skelCount = 0;
    for (var i = 0; i < skel.length; i++) {
      if (skel[i] == 1 && (skelCount++ % 5 == 0)) {
        roadPts.add(Point((i % w).toDouble(), (i ~/ w).toDouble()));
      }
    }

    // מעקב-שלד לפוליגונים (קווי-כביש): מכל צומת/קצה עוקבים שרשרת-שלד עד
    // הצומת/קצה הבא — כל מעקב = קו-כביש (רשימת נקודות). הכבישים כווקטורים
    // מבחינים בהרבה מנקודות מבודדות ושוברים את אמביגואיית-הסיבוב.
    final polylines = _traceSkeleton(skel, w, h);

    final junctions = _cluster(junctionPts, w, 16);
    final deadEnds = _cluster(deadEndPts, w, 16);
    final bends = _findBends(skel, w, h, junctionPts, strokeW);
    return _BranchResult(
        junctions, deadEnds, bends, roundabouts, roadPts, polylines);
  }

  /// מעקב-שלד לפוליגונים: בונה גרף-שלד (דרגת-שכנים), ומכל קודקוד (דרגה≠2)
  /// עוקב כל שרשרת-פיקסלים עד הקודקוד הבא. מחזיר קווים פשוטים (Douglas-
  /// Peucker) באורך ≥ 4×רוחב-משיחה, בפיקסלי-המסכה.
  static List<List<Point<double>>> _traceSkeleton(
    Uint8List skel,
    int w,
    int h,
  ) {
    int deg(int p) {
      final x = p % w, y = p ~/ w;
      var d = 0;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
          if (skel[ny * w + nx] == 1) d++;
        }
      }
      return d;
    }

    // קודקודים = פיקסלי-שלד עם דרגה ≠ 2 (צומת ≥3, קצה =1).
    final isNode = Uint8List(skel.length);
    final nodes = <int>[];
    for (var i = 0; i < skel.length; i++) {
      if (skel[i] == 1) {
        final d = deg(i);
        if (d != 2) {
          isNode[i] = 1;
          nodes.add(i);
        }
      }
    }

    // מעקב שרשראות; מסמנים קצוות-שרשרת שביקרנו כדי לא לחזור.
    final visitedEdge = <int>{}; // מפתח = p*len + q של הצעד הראשון
    final out = <List<Point<double>>>[];
    Point<double> pt(int p) => Point((p % w).toDouble(), (p ~/ w).toDouble());

    for (final start in nodes) {
      final sx = start % w, sy = start ~/ w;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = sx + dx, ny = sy + dy;
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
          final first = ny * w + nx;
          if (skel[first] == 0) continue;
          final ekey = start * skel.length + first;
          if (visitedEdge.contains(ekey)) continue;

          // עוקבים לאורך השרשרת עד קודקוד.
          final chain = <int>[start, first];
          var prev = start, cur = first;
          while (isNode[cur] == 0) {
            final cx = cur % w, cy = cur ~/ w;
            int next = -1;
            for (var ddy = -1; ddy <= 1 && next < 0; ddy++) {
              for (var ddx = -1; ddx <= 1; ddx++) {
                if (ddx == 0 && ddy == 0) continue;
                final ax = cx + ddx, ay = cy + ddy;
                if (ax < 0 || ay < 0 || ax >= w || ay >= h) continue;
                final q = ay * w + ax;
                if (q != prev && q != cur && skel[q] == 1) {
                  next = q;
                  break;
                }
              }
            }
            if (next < 0) break;
            chain.add(next);
            prev = cur;
            cur = next;
          }
          visitedEdge.add(ekey);
          visitedEdge.add(cur * skel.length + chain[chain.length - 2]);
          if (chain.length >= 4) {
            out.add(_simplify([for (final p in chain) pt(p)], 2.5));
          }
        }
      }
    }
    // תפירת-קווים דרך צמתים: כביש ממשיך ישר דרך הצטלבות. ממזג קטעים
    // ששיתפו נקודת-קצה וממשיכים בזווית קטנה → כבישים ארוכים מבחינים.
    return _mergeStrokes(out);
  }

  /// ממזג פוליגונים לקווים ארוכים ("strokes") לפי המשכיות-טובה: בכל
  /// נקודת-קצה משותפת, מחבר את שני הקטעים בעלי הזווית הישרה ביותר.
  static List<List<Point<double>>> _mergeStrokes(
    List<List<Point<double>>> lines,
  ) {
    // אינדקס קצוות: מפתח מעוגל (2px) → רשימת (אינדקס-קו, האם-קצה-התחלה).
    String key(Point<double> p) =>
        '${(p.x / 2).round()},${(p.y / 2).round()}';
    final ends = <String, List<(int, bool)>>{};
    for (var i = 0; i < lines.length; i++) {
      ends.putIfAbsent(key(lines[i].first), () => []).add((i, true));
      ends.putIfAbsent(key(lines[i].last), () => []).add((i, false));
    }

    // כיוון-יציאה מקצה (וקטור מנורמל אל תוך הקו).
    Point<double> dirAt(List<Point<double>> l, bool atStart) {
      final a = atStart ? l.first : l.last;
      final b = atStart ? l[1] : l[l.length - 2];
      final dx = b.x - a.x, dy = b.y - a.y;
      final n = sqrt(dx * dx + dy * dy);
      return n < 1e-9 ? const Point(0.0, 0.0) : Point(dx / n, dy / n);
    }

    final used = List<bool>.filled(lines.length, false);
    final out = <List<Point<double>>>[];
    for (var start = 0; start < lines.length; start++) {
      if (used[start]) continue;
      var stroke = List<Point<double>>.from(lines[start]);
      used[start] = true;
      // מרחיבים לשני הקצוות.
      for (final atEnd in [true, false]) {
        while (true) {
          final tip = atEnd ? stroke.last : stroke.first;
          // כיוון-הגעה לקצה (המשך ישר = כיוון הפוך לכיוון-היציאה).
          final incoming = atEnd
              ? Point(
                  stroke.last.x - stroke[stroke.length - 2].x,
                  stroke.last.y - stroke[stroke.length - 2].y,
                )
              : Point(stroke.first.x - stroke[1].x, stroke.first.y - stroke[1].y);
          final ni = sqrt(incoming.x * incoming.x + incoming.y * incoming.y);
          if (ni < 1e-9) break;
          final ix = incoming.x / ni, iy = incoming.y / ni;
          // מועמדי-המשך בקצה הזה.
          var bestJ = -1;
          var bestStartEnd = true;
          var bestDot = 0.5; // דורשים זווית < ~60° מהמשך-ישר
          for (final (j, isStart) in ends[key(tip)] ?? const <(int, bool)>[]) {
            if (used[j] || j == start) continue;
            final d = dirAt(lines[j], isStart); // מצביע לתוך הקו
            final dot = ix * d.x + iy * d.y; // המשך-ישר → ~1
            if (dot > bestDot) {
              bestDot = dot;
              bestJ = j;
              bestStartEnd = isStart;
            }
          }
          if (bestJ < 0) break;
          used[bestJ] = true;
          final seg = bestStartEnd
              ? lines[bestJ]
              : lines[bestJ].reversed.toList();
          if (atEnd) {
            stroke.addAll(seg.skip(1));
          } else {
            stroke = [...seg.reversed.skip(1).toList().reversed, ...stroke];
          }
        }
      }
      out.add(_simplify(stroke, 2.5));
    }
    return out;
  }

  /// Douglas-Peucker — פישוט פוליגון תוך שמירת צורתו.
  static List<Point<double>> _simplify(List<Point<double>> pts, double eps) {
    if (pts.length < 3) return pts;
    var maxD = 0.0, idx = 0;
    final a = pts.first, b = pts.last;
    final dx = b.x - a.x, dy = b.y - a.y;
    final len = sqrt(dx * dx + dy * dy);
    for (var i = 1; i < pts.length - 1; i++) {
      final d = len < 1e-9
          ? sqrt(pow(pts[i].x - a.x, 2) + pow(pts[i].y - a.y, 2))
          : ((pts[i].x - a.x) * dy - (pts[i].y - a.y) * dx).abs() / len;
      if (d > maxD) {
        maxD = d;
        idx = i;
      }
    }
    if (maxD <= eps) return [a, b];
    final left = _simplify(pts.sublist(0, idx + 1), eps);
    final right = _simplify(pts.sublist(idx), eps);
    return [...left.sublist(0, left.length - 1), ...right];
  }

  /// כיכרות מלאות: רכיבי ליבת-הגושים שהם קטנים ועגולים. עיגול ממלא ~π/4
  /// מה-bbox שלו; מלבן ממלא ~1.0 — כך מבחינים כיכר מתיבת-מקרא/מבנה.
  static List<_Cluster> _roundBlobCores(
    Uint8List core,
    int w,
    int h,
    int strokeW,
    int blobRadius,
  ) {
    final out = <_Cluster>[];
    final visited = Uint8List(w * h);
    final stack = <int>[];
    for (var start = 0; start < core.length; start++) {
      if (core[start] == 0 || visited[start] == 1) continue;
      var size = 0, sx = 0, sy = 0;
      var minX = w, maxX = 0, minY = h, maxY = 0;
      stack.add(start);
      visited[start] = 1;
      while (stack.isNotEmpty) {
        final p = stack.removeLast();
        final x = p % w, y = p ~/ w;
        size++;
        sx += x;
        sy += y;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            final nx = x + dx, ny = y + dy;
            if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
            final q = ny * w + nx;
            if (core[q] == 1 && visited[q] == 0) {
              visited[q] = 1;
              stack.add(q);
            }
          }
        }
      }
      // מהליבה חזרה לגודל-הגוש האמיתי (השחיקה הורידה blobRadius מכל צד).
      final bw = maxX - minX + 1 + 2 * blobRadius;
      final bh = maxY - minY + 1 + 2 * blobRadius;
      final diam = max(bw, bh);
      final aspect = max(bw, bh) / min(bw, bh);
      final coreFill =
          size / ((maxX - minX + 1) * (maxY - minY + 1)).toDouble();
      if (diam >= 2 * strokeW &&
          diam <= 12 * strokeW &&
          aspect <= 1.4 &&
          coreFill >= 0.5 &&
          coreFill <= 0.92) {
        out.add(_Cluster(sx / size, sy / size, size));
      }
    }
    return out;
  }

  /// כיכרות-טבעת: רכיבי-רקע (אפסים) כלואים שאינם נוגעים בשולי התמונה,
  /// בגודל-כיכר וצורה עגלגלה.
  static List<_Cluster> _roundIslands(
    Uint8List m,
    int w,
    int h,
    int strokeW,
  ) {
    final out = <_Cluster>[];
    final visited = Uint8List(w * h);
    final stack = <int>[];
    final minA = 2.25 * strokeW * strokeW; // (1.5·strokeW)²
    final maxA = 64.0 * strokeW * strokeW; // (8·strokeW)²
    for (var start = 0; start < m.length; start++) {
      if (m[start] == 1 || visited[start] == 1) continue;
      var size = 0, sx = 0, sy = 0;
      var minX = w, maxX = 0, minY = h, maxY = 0;
      var touchesBorder = false;
      stack.add(start);
      visited[start] = 1;
      while (stack.isNotEmpty) {
        final p = stack.removeLast();
        final x = p % w, y = p ~/ w;
        size++;
        sx += x;
        sy += y;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
        if (x == 0 || y == 0 || x == w - 1 || y == h - 1) {
          touchesBorder = true;
        }
        // 4-שכנות — שלא "נזלוג" באלכסון דרך פינת-דרך.
        for (final q in [p - 1, p + 1, p - w, p + w]) {
          if (q < 0 || q >= m.length) continue;
          if ((q == p - 1 && x == 0) || (q == p + 1 && x == w - 1)) continue;
          if (m[q] == 0 && visited[q] == 0) {
            visited[q] = 1;
            stack.add(q);
          }
        }
      }
      if (touchesBorder || size < minA || size > maxA) continue;
      final bw = maxX - minX + 1, bh = maxY - minY + 1;
      final aspect = max(bw, bh) / min(bw, bh);
      final fill = size / (bw * bh);
      if (aspect <= 1.7 && fill >= 0.55) {
        out.add(_Cluster(sx / size, sy / size, size));
      }
    }
    return out;
  }

  /// עיקולים חדים: לכל פיקסל-מסלול בשלד (2 מעברים) הולכים k צעדים לשני
  /// הכיוונים ומודדים את הזווית בין הזרועות — ישר ≈ 180°, עיקול חד < 135°.
  /// עיקול בקרבת צומת נפסל (זרועות הצומת יוצרות זוויות ממילא).
  static List<_Cluster> _findBends(
    Uint8List skel,
    int w,
    int h,
    List<int> junctionPts,
    int strokeW,
  ) {
    const kSteps = 9;
    const margin = 16;
    final minJuncDist = (strokeW * 2.5).round();
    final bendPts = <int>[];

    // מפת-קרבה לצמתים — בדיקה מהירה במקום מרחק לכל צומת.
    Uint8List? nearJunction;
    if (junctionPts.isNotEmpty) {
      nearJunction = Uint8List(w * h);
      for (final p in junctionPts) {
        nearJunction[p] = 1;
      }
      nearJunction = _dilate(nearJunction, w, h, minJuncDist);
    }

    // שני השכנים של פיקסל-מסלול; null אם אין בדיוק 2.
    (int, int)? pathNeighbors(int p) {
      final x = p % w, y = p ~/ w;
      int? a, b;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final q = (y + dy) * w + (x + dx);
          if (skel[q] == 0) continue;
          if (a == null) {
            a = q;
          } else if (b == null) {
            b = q;
          } else {
            return null;
          }
        }
      }
      return (a == null || b == null) ? null : (a, b);
    }

    // הליכה לאורך השלד מ-p דרך first, עד k צעדים; null אם המסלול נגמר.
    int? walk(int p, int first) {
      var prev = p, cur = first;
      for (var i = 1; i < kSteps; i++) {
        final n = pathNeighbors(cur);
        if (n == null) return null; // צומת/קצה — לא מודדים דרכו
        final next = n.$1 == prev ? n.$2 : n.$1;
        prev = cur;
        cur = next;
      }
      return cur;
    }

    for (var y = margin; y < h - margin; y++) {
      final row = y * w;
      for (var x = margin; x < w - margin; x++) {
        final p = row + x;
        if (skel[p] == 0) continue;
        if (nearJunction != null && nearJunction[p] == 1) continue;
        final n = pathNeighbors(p);
        if (n == null) continue;
        final a = walk(p, n.$1);
        final b = walk(p, n.$2);
        if (a == null || b == null) continue;
        final v1x = (a % w - x).toDouble(), v1y = (a ~/ w - y).toDouble();
        final v2x = (b % w - x).toDouble(), v2y = (b ~/ w - y).toDouble();
        final dot = v1x * v2x + v1y * v2y;
        final norm = sqrt(v1x * v1x + v1y * v1y) * sqrt(v2x * v2x + v2y * v2y);
        if (norm == 0) continue;
        final angleDeg = acos((dot / norm).clamp(-1.0, 1.0)) * 180 / pi;
        if (angleDeg < 135) bendPts.add(p);
      }
    }
    return _cluster(bendPts, w, 16);
  }

  /// אומד את רוחב-המשיחה האופייני של המסכה: דוגם רשת נקודות, מודד לכל
  /// נקודת-דיו את אורך-הריצה האופקי והאנכי דרכה ולוקח את הקצר (≈רוחב הקו),
  /// ומחזיר את האחוזון ה-75 — עמיד לטקסט (דק, עד כמחצית הדגימות) ולגושים
  /// (ריצות ענק, נחתכות ב-200). 0 כשאין מספיק דיו.
  static int _estimateStrokeWidth(Uint8List m, int w, int h) {
    const step = 13;
    const walkCap = 100; // אין טעם למדוד מעבר — רק קווים מעניינים אותנו
    // שוליים (6%) בחוץ — מסגרת-מפה היקפית היא פס עבה עם אלפי דגימות
    // שמושכות את האחוזון הרחק מרוחב-דרך אמיתי.
    final mx = (w * 0.06).round(), my = (h * 0.06).round();
    final samples = <int>[];
    for (var y = my; y < h - my; y += step) {
      final row = y * w;
      for (var x = mx; x < w - mx; x += step) {
        if (m[row + x] == 0) continue;
        var l = x;
        while (l > 0 && x - l < walkCap && m[row + l - 1] == 1) {
          l--;
        }
        var r = x;
        while (r < w - 1 && r - x < walkCap && m[row + r + 1] == 1) {
          r++;
        }
        var t = y;
        while (t > 0 && y - t < walkCap && m[(t - 1) * w + x] == 1) {
          t--;
        }
        var b = y;
        while (b < h - 1 && b - y < walkCap && m[(b + 1) * w + x] == 1) {
          b++;
        }
        final width = min(r - l + 1, b - t + 1);
        // ≥60 = פנים של גוש/תיבה, לא קו — מזהם את האומדן.
        if (width < 60) samples.add(width);
      }
    }
    if (samples.length < 20) return 0;
    samples.sort();
    // רוחב "הדרך הדקה": p25 של הדגימות שמעל סף-טקסט (6px) — טקסט תמיד דק
    // מדרכים, ודרכים ראשיות רחבות לא צריכות למשוך את האומדן מעלה. כשאין
    // מספיק דגימות עבות (מפת קווים-דקים) — p75 של הכל.
    final roadish = [
      for (final s in samples)
        if (s >= 6) s,
    ];
    if (roadish.length >= 20) return roadish[roadish.length ~/ 4];
    return samples[(samples.length * 3) ~/ 4];
  }

  // ═══ עזרי מורפולוגיה ═══

  static int _otsu(Uint8List lum) {
    final hist = List<int>.filled(256, 0);
    for (final v in lum) {
      hist[v]++;
    }
    return _otsuHist(hist, lum.length);
  }

  /// מסכת-תוכן: מחריגה את הרקע האחיד שמחוץ למפה (הפינות הלבנות שנוצרות
  /// בסיבוב, או שוליים בצילום) ע"י flood-fill מגבולות-התמונה על פיקסלים
  /// דומי-רקע. בלי זה, פינות-לבנות מזיזות את סף-Otsu ואת bgPeak ומדללות
  /// את הצמתים. מוחל רק כשהאזור-החיצוני משמעותי-אך-לא-הכל (2%–70%);
  /// אחרת (מפה שממלאת פריים) מוחזר "הכל תוכן".
  static Uint8List _contentMask(Uint8List lum, int w, int h) {
    final n = w * h;
    // ערך-רקע = חציון הבהירות על הגבול (הרקע-החיצוני נוגע בגבול).
    final border = <int>[];
    for (var x = 0; x < w; x += 2) {
      border.add(lum[x]);
      border.add(lum[(h - 1) * w + x]);
    }
    for (var y = 0; y < h; y += 2) {
      border.add(lum[y * w]);
      border.add(lum[y * w + w - 1]);
    }
    border.sort();
    final seed = border[border.length ~/ 2];
    const tol = 16;
    final outside = Uint8List(n);
    final q = <int>[];
    void push(int i) {
      if (outside[i] == 0 && (lum[i] - seed).abs() <= tol) {
        outside[i] = 1;
        q.add(i);
      }
    }
    for (var x = 0; x < w; x++) {
      push(x);
      push((h - 1) * w + x);
    }
    for (var y = 0; y < h; y++) {
      push(y * w);
      push(y * w + w - 1);
    }
    var head = 0;
    while (head < q.length) {
      final i = q[head++];
      final x = i % w, y = i ~/ w;
      if (x > 0) push(i - 1);
      if (x < w - 1) push(i + 1);
      if (y > 0) push(i - w);
      if (y < h - 1) push(i + w);
    }
    var outCount = 0;
    for (var i = 0; i < n; i++) {
      if (outside[i] == 1) outCount++;
    }
    final frac = outCount / n;
    final content = Uint8List(n);
    if (frac < 0.02 || frac > 0.7) {
      // אין שוליים ברורים (או שהכל אחיד) — לא ממסכים.
      for (var i = 0; i < n; i++) {
        content[i] = 1;
      }
    } else {
      for (var i = 0; i < n; i++) {
        content[i] = outside[i] == 0 ? 1 : 0;
      }
    }
    return content;
  }

  static int _otsuHist(List<int> hist, int total) {
    if (total == 0) return 128;
    var sum = 0.0;
    for (var i = 0; i < 256; i++) {
      sum += i * hist[i];
    }
    var sumB = 0.0, wB = 0, best = 0.0, thr = 128;
    for (var t = 0; t < 256; t++) {
      wB += hist[t];
      if (wB == 0) continue;
      final wF = total - wB;
      if (wF == 0) break;
      sumB += t * hist[t];
      final mB = sumB / wB;
      final mF = (sum - sumB) / wF;
      final between = wB * wF * (mB - mF) * (mB - mF);
      if (between > best) {
        best = between;
        thr = t;
      }
    }
    return thr;
  }

  /// שחיקה עם אלמנט ריבועי (2r+1)² — שני מעברים נפרדים (אופקי+אנכי).
  static Uint8List _erode(Uint8List m, int w, int h, int r) =>
      _minFilter(_minFilter(m, w, h, r, horizontal: true), w, h, r,
          horizontal: false);

  static Uint8List _dilate(Uint8List m, int w, int h, int r) =>
      _maxFilter(_maxFilter(m, w, h, r, horizontal: true), w, h, r,
          horizontal: false);

  static Uint8List _minFilter(
    Uint8List m,
    int w,
    int h,
    int r, {
    required bool horizontal,
  }) {
    final out = Uint8List(w * h);
    final len = horizontal ? w : h;
    final lines = horizontal ? h : w;
    for (var l = 0; l < lines; l++) {
      var run = 0; // כמה 1-ים רצופים בחלון
      // חלון נע: out=1 רק אם כל (2r+1) ערכים סביב הם 1.
      for (var i = 0; i < len + r; i++) {
        final vIn = i < len
            ? (horizontal ? m[l * w + i] : m[i * w + l])
            : 0;
        run = vIn == 1 ? run + 1 : 0;
        final j = i - r;
        if (j >= 0 && j < len && run >= 2 * r + 1) {
          if (horizontal) {
            out[l * w + j] = 1;
          } else {
            out[j * w + l] = 1;
          }
        }
      }
    }
    return out;
  }

  static Uint8List _maxFilter(
    Uint8List m,
    int w,
    int h,
    int r, {
    required bool horizontal,
  }) {
    final out = Uint8List(w * h);
    final len = horizontal ? w : h;
    final lines = horizontal ? h : w;
    for (var l = 0; l < lines; l++) {
      var lastOne = -1 << 20;
      for (var i = 0; i < len + r; i++) {
        if (i < len) {
          final vIn = horizontal ? m[l * w + i] : m[i * w + l];
          if (vIn == 1) lastOne = i;
        }
        final j = i - r;
        if (j >= 0 && j < len && lastOne >= j - r) {
          // יש 1 בטווח [j-r, j+r] (lastOne>=j-r ובהכרח <=i=j+r)
          if (horizontal) {
            out[l * w + j] = 1;
          } else {
            out[j * w + l] = 1;
          }
        }
      }
    }
    return out;
  }

  /// מסיר רכיבים קטנים מ-[minSize] וגם רכיבים "מוצקים" — כאלה שממלאים
  /// יותר מ-[maxSolidity] מה-bbox שלהם (תיבות מלאות, לא רשתות-קווים).
  static void _filterComponents(
    Uint8List m,
    int w,
    int h, {
    required int minSize,
    required double maxSolidity,
  }) {
    final visited = Uint8List(w * h);
    final stack = <int>[];
    final comp = <int>[];
    for (var start = 0; start < m.length; start++) {
      if (m[start] == 0 || visited[start] == 1) continue;
      comp.clear();
      stack.add(start);
      visited[start] = 1;
      var minX = w, maxX = 0, minY = h, maxY = 0;
      while (stack.isNotEmpty) {
        final p = stack.removeLast();
        comp.add(p);
        final x = p % w, y = p ~/ w;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            final nx = x + dx, ny = y + dy;
            if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
            final q = ny * w + nx;
            if (m[q] == 1 && visited[q] == 0) {
              visited[q] = 1;
              stack.add(q);
            }
          }
        }
      }
      final bboxArea = (maxX - minX + 1) * (maxY - minY + 1);
      final solidity = comp.length / bboxArea;
      if (comp.length < minSize ||
          (comp.length > minSize && solidity > maxSolidity)) {
        for (final p in comp) {
          m[p] = 0;
        }
      }
    }
  }

  /// משאיר רק את הרכיב המחובר הגדול ביותר (רשת-המסדרונות; תאי-מגרשים
  /// מבודדים נמחקים).
  static void _keepLargestComponent(Uint8List m, int w, int h) {
    final labels = Int32List(w * h);
    final sizes = <int>[0]; // label 0 = רקע
    final stack = <int>[];
    var next = 1;
    for (var start = 0; start < m.length; start++) {
      if (m[start] == 0 || labels[start] != 0) continue;
      final label = next++;
      sizes.add(0);
      stack.add(start);
      labels[start] = label;
      while (stack.isNotEmpty) {
        final p = stack.removeLast();
        sizes[label]++;
        final x = p % w, y = p ~/ w;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            final nx = x + dx, ny = y + dy;
            if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
            final q = ny * w + nx;
            if (m[q] == 1 && labels[q] == 0) {
              labels[q] = label;
              stack.add(q);
            }
          }
        }
      }
    }
    if (next <= 2) return; // רכיב אחד או כלום
    var best = 1;
    for (var l = 2; l < next; l++) {
      if (sizes[l] > sizes[best]) best = l;
    }
    for (var i = 0; i < m.length; i++) {
      if (m[i] == 1 && labels[i] != best) m[i] = 0;
    }
  }

  /// דילול Zhang-Suen — שלד ברוחב פיקסל ששומר טופולוגיה.
  static Uint8List _thinZhangSuen(Uint8List mask, int w, int h) {
    final m = Uint8List.fromList(mask);
    final toDelete = <int>[];
    bool changed = true;
    while (changed) {
      changed = false;
      for (var pass = 0; pass < 2; pass++) {
        toDelete.clear();
        for (var y = 1; y < h - 1; y++) {
          final row = y * w;
          for (var x = 1; x < w - 1; x++) {
            final p = row + x;
            if (m[p] == 0) continue;
            // שכנים p2..p9 בכיוון השעון החל מצפון
            final p2 = m[p - w],
                p3 = m[p - w + 1],
                p4 = m[p + 1],
                p5 = m[p + w + 1],
                p6 = m[p + w],
                p7 = m[p + w - 1],
                p8 = m[p - 1],
                p9 = m[p - w - 1];
            final b = p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9;
            if (b < 2 || b > 6) continue;
            var a = 0;
            if (p2 == 0 && p3 == 1) a++;
            if (p3 == 0 && p4 == 1) a++;
            if (p4 == 0 && p5 == 1) a++;
            if (p5 == 0 && p6 == 1) a++;
            if (p6 == 0 && p7 == 1) a++;
            if (p7 == 0 && p8 == 1) a++;
            if (p8 == 0 && p9 == 1) a++;
            if (p9 == 0 && p2 == 1) a++;
            if (a != 1) continue;
            if (pass == 0) {
              if (p2 * p4 * p6 != 0 || p4 * p6 * p8 != 0) continue;
            } else {
              if (p2 * p4 * p8 != 0 || p2 * p6 * p8 != 0) continue;
            }
            toDelete.add(p);
          }
        }
        if (toDelete.isNotEmpty) {
          changed = true;
          for (final p in toDelete) {
            m[p] = 0;
          }
        }
      }
    }
    return m;
  }

  static List<_Cluster> _cluster(List<int> pts, int w, int radius) {
    // אשכול חמדני על רשת תאים בגודל radius.
    final byCell = <int, List<int>>{};
    int cellOf(int p) => (p ~/ w ~/ radius) * 100000 + (p % w ~/ radius);
    for (final p in pts) {
      byCell.putIfAbsent(cellOf(p), () => []).add(p);
    }
    final seen = <int>{};
    final out = <_Cluster>[];
    for (final p in pts) {
      if (!seen.add(p)) continue;
      var sx = 0, sy = 0, n = 0;
      final queue = <int>[p];
      while (queue.isNotEmpty) {
        final q = queue.removeLast();
        final qx = q % w, qy = q ~/ w;
        sx += qx;
        sy += qy;
        n++;
        final cy = qy ~/ radius, cx = qx ~/ radius;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            final cell = (cy + dy) * 100000 + (cx + dx);
            for (final r in byCell[cell] ?? const <int>[]) {
              if (seen.contains(r)) continue;
              final rx = r % w, ry = r ~/ w;
              if ((rx - qx).abs() <= radius && (ry - qy).abs() <= radius) {
                seen.add(r);
                queue.add(r);
              }
            }
          }
        }
      }
      out.add(_Cluster(sx / n, sy / n, n));
    }
    return out;
  }
}

class _Cluster {
  final double cx, cy;
  final int weight;
  _Cluster(this.cx, this.cy, this.weight);
}

/// תוצאת ענף אחד של הצנרת — מאפיינים לפי סוג + נקודות-כביש + קווי-כביש.
class _BranchResult {
  final List<_Cluster> junctions, deadEnds, bends, roundabouts;
  final List<Point<double>> roadPoints;
  final List<List<Point<double>>> polylines;
  const _BranchResult(this.junctions, this.deadEnds, this.bends,
      this.roundabouts, this.roadPoints, this.polylines);

  static const empty = _BranchResult(<_Cluster>[], <_Cluster>[], <_Cluster>[],
      <_Cluster>[], <Point<double>>[], <List<Point<double>>>[]);
}
