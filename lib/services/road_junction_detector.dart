import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// גלאי צמתים קלאסי (עיבוד-תמונה, בלי מודל): מוצא מפגשי-דרכים במפה
/// משורטטת/סרוקה בדיוק-פיקסל ודטרמיניסטית.
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
  static Future<List<Point<double>>> detectInIsolate(img.Image image) {
    return Isolate.run(() => detect(image));
  }

  /// מריץ את [detect] ב-Isolate על קובץ — הפענוח הכבד קורה בתוך ה-Isolate.
  static Future<List<Point<double>>> detectFileInIsolate(String imagePath) {
    return Isolate.run(() {
      final decoded = img.decodeImage(File(imagePath).readAsBytesSync());
      return decoded == null ? const <Point<double>>[] : detect(decoded);
    });
  }

  /// מחזיר מרכזי-צומת מועמדים בקואורדינטות של [src], ממוינים לפי חוזק
  /// עם פיזור מרחבי. רשימה ריקה כשהתמונה לא נראית כמו שרטוט-קווים.
  ///
  /// [debugDir] — כשמוגדר, כותב לשם PNG של כל שלב-ביניים (מסכה, שלד...)
  /// + '00_info.txt' עם ערכי הכיול. לכיול הגלאי על מפות אמיתיות.
  static List<Point<double>> detect(
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
    if (w < 60 || h < 60) return const [];

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
    final hist = List<int>.filled(256, 0);
    for (final v in lum) {
      hist[v]++;
    }
    var bgPeak = 255;
    for (var v = 129; v < 256; v++) {
      if (hist[v] > hist[bgPeak]) bgPeak = v;
    }
    final thrDark = min(max(_otsu(lum), bgPeak - 40), bgPeak - 12);
    final thrBright = min(bgPeak + 12, 250);
    final maskDark = Uint8List(w * h);
    final maskBright = Uint8List(w * h);
    final maskCorr = Uint8List(w * h);
    var nDark = 0, nBright = 0, nCorr = 0;
    for (var i = 0; i < lum.length; i++) {
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

    final darkClusters = (nDark < 200 || nDark > lum.length * 0.55)
        ? const <_Cluster>[]
        : _clustersFromMask(maskDark, w, h, debugDir, 'dark');
    final brightClusters = nBright < 200
        ? const <_Cluster>[]
        : _clustersFromMask(maskBright, w, h, debugDir, 'bright');
    // מסדרונות: בלי סגירה (הייתה מגשרת את קווי-הגבול הדקים של המגרשים
    // וממזגת אותם עם הכבישים), ורק הרכיב הגדול — תאי-המגרשים (גם הם
    // בצבע-רקע, מוקפים קו) הם רכיבים קטנים נפרדים.
    final corrClusters = nCorr < 200
        ? const <_Cluster>[]
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
    var clusters = darkClusters;
    if (brightClusters.length > clusters.length) clusters = brightClusters;
    if (corrClusters.length > clusters.length) clusters = corrClusters;
    clusters = List<_Cluster>.from(clusters);
    if (clusters.isEmpty) return const [];

    // 8) בחירה: לפי משקל, עם מרחק-מינימום ביניהם (פיזור); הקלה אם דליל.
    clusters.sort((a, b) => b.weight.compareTo(a.weight));
    final picked = <_Cluster>[];
    for (final minSep in [max(w, h) * 0.06, max(w, h) * 0.03]) {
      for (final c in clusters) {
        if (picked.length >= maxCandidates) break;
        if (picked.any(
          (p) => (p.cx - c.cx).abs() < minSep && (p.cy - c.cy).abs() < minSep,
        )) {
          continue;
        }
        if (picked.any((p) => identical(p, c))) continue;
        picked.add(c);
      }
      if (picked.length >= 4) break;
    }

    if (debugDir != null) {
      final vis = img.Image.from(work);
      for (final c in picked) {
        img.drawCircle(vis, x: c.cx.round(), y: c.cy.round(), radius: 12,
            color: img.ColorRgb8(255, 0, 200));
        img.drawCircle(vis, x: c.cx.round(), y: c.cy.round(), radius: 13,
            color: img.ColorRgb8(255, 0, 200));
      }
      File('$debugDir/06_candidates.png').writeAsBytesSync(img.encodePng(vis));
    }

    return [
      for (final c in picked) Point(c.cx * scale, c.cy * scale),
    ];
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

  /// הצנרת המשותפת לשתי הקוטביות: פתיחה → מחיקת גושים → סינון רכיבים →
  /// דילול → צמתי crossing-number → אשכולות. משנה את [mask] במקום.
  static List<_Cluster> _clustersFromMask(
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
    if (strokeW == 0) return const [];
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
    if (blobCore.any((v) => v == 1)) {
      final blobZone = _dilate(blobCore, w, h, blobRadius + 6);
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

    // פיקסלי-צומת לפי crossing-number: מספר מעברי 0→1 בסריקה מעגלית של
    // 8 השכנים. קו ישר (גם מדרגת-אלכסון) = 2 מעברים; צומת אמיתי = 3+.
    // ספירת-שכנים פשוטה מסמנת בטעות את כל מדרגות האלכסון כצמתים.
    const margin = 16;
    final nodePts = <int>[]; // אינדקסים שטוחים
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
        if (transitions >= 3) nodePts.add(row + x);
      }
    }
    if (nodePts.isEmpty) return const [];

    // אשכול נקודות-צומת סמוכות (עד 16px) → מרכז + משקל
    return _cluster(nodePts, w, 16);
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
    final total = lum.length;
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
          (comp.length > 3000 && solidity > maxSolidity)) {
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
