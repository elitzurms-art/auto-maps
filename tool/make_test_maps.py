# -*- coding: utf-8 -*-
# מחולל מפות-הבוחן הסינתטיות של test/grid_adaptive_test.dart — גיליונות
# 5000x3500 עם רשת-ITM ואמת-קרקע ידועה (E0/N0/STEP קבועים כאן ומשוכפלים
# בטסט). שלוש גרסאות שמכסות את מסלולי-המנוע:
#   A מפת_בוחן_גדולה   — תוויות-שוליים מלאות   → "גישוש בלבד"
#   B מפת_בוחן_פנימית  — מזרחים למעלה + צפונים פנימיים → "מכויל ×1"
#   C מפת_בוחן_הפוכה   — כמו A עם כיתוב-אנכי הפוך → נפילה-לאחור CW
# הרצה: python tool/make_test_maps.py   (כותב ל-%TEMP%)
import os
import random

from PIL import Image, ImageDraw, ImageFont

W, H = 5000, 3500
E0, N0 = 205000, 742400  # הפינה השמאלית-עליונה (עמק-זבולון, ITM)
STEP_M, STEP_PX, MARGIN = 200, 400, 300
TEMP = os.environ.get("TEMP", "/tmp")
FONT_BIG = ImageFont.truetype(r"C:\Windows\Fonts\arial.ttf", 40)
FONT_SMALL = ImageFont.truetype(r"C:\Windows\Fonts\arial.ttf", 26)


def build(name, margins_all, interior_norths, vertical_ccw):
    im = Image.new("RGB", (W, H), (245, 244, 238))
    d = ImageDraw.Draw(im)

    for i in range(0, (W - 2 * MARGIN) // STEP_PX + 1):
        x = MARGIN + i * STEP_PX
        d.line([(x, MARGIN), (x, H - MARGIN)], fill=(120, 160, 190), width=2)
    for j in range(0, (H - 2 * MARGIN) // STEP_PX + 1):
        y = MARGIN + j * STEP_PX
        d.line([(MARGIN, y), (W - MARGIN, y)], fill=(120, 160, 190), width=2)

    def vertical_text(x, y, text):
        tmp = Image.new("RGBA", (400, 60), (0, 0, 0, 0))
        ImageDraw.Draw(tmp).text((0, 0), text, font=FONT_BIG, fill=(30, 30, 30))
        # ‎-90 = הכיוון המקובל בגיליונות (מלמטה-למעלה); ‎90 = הפוך (גרסה C).
        rot = tmp.rotate(-90 if vertical_ccw else 90, expand=True)
        im.paste(rot, (int(x), int(y)), rot)

    # מזרחים — אנכיים בשוליים העליונים (ובתחתונים כשהשוליים מלאים)
    for i in range(0, (W - 2 * MARGIN) // STEP_PX + 1):
        x = MARGIN + i * STEP_PX
        label = f"{E0 + i * STEP_M:,}"
        vertical_text(x - 45, 40, label)
        if margins_all:
            vertical_text(x - 45, H - 260, label)

    if margins_all:
        # צפונים — אופקיים בשוליים שמאל/ימין
        for j in range(0, (H - 2 * MARGIN) // STEP_PX + 1):
            y = MARGIN + j * STEP_PX
            label = f"{N0 - j * STEP_M:,}"
            d.text((60, y - 22), label, font=FONT_BIG, fill=(30, 30, 30))
            d.text((W - 250, y - 22), label, font=FONT_BIG, fill=(30, 30, 30))
    keep_clear = []  # אזורי-הרחקה סביב תוויות פנימיות — שהרעש לא יטשטש אותן
    if interior_norths:
        # צפונים — ליד צמתים פנימיים (כמו מפות-סקר)
        for j in range(1, (H - 2 * MARGIN) // STEP_PX, 2):
            y = MARGIN + j * STEP_PX
            label = f"{N0 - j * STEP_M:,}"
            for i in (2, 6, 10):
                x = MARGIN + i * STEP_PX
                d.text((x + 15, y - 50), label, font=FONT_BIG, fill=(30, 30, 30))
                keep_clear.append((x + 15, y - 50))

    # רעש-"מגרשים" צפוף (בוחן את עמידות psm-11)
    random.seed(42)
    for _ in range(800):
        x = random.randint(MARGIN + 200, W - MARGIN - 300)
        y = random.randint(MARGIN + 200, H - MARGIN - 200)
        if any(abs(x - cx) < 350 and abs(y - cy) < 250 for cx, cy in keep_clear):
            continue
        poly = [(x, y),
                (x + random.randint(60, 200), y + random.randint(-20, 20)),
                (x + random.randint(40, 180), y + random.randint(60, 160)),
                (x + random.randint(-30, 30), y + random.randint(50, 140))]
        d.polygon(poly, outline=(200, 60, 60))
        d.text((x + 25, y + 25), str(random.randint(1, 450)), font=FONT_SMALL,
               fill=(40, 40, 40))

    out = os.path.join(TEMP, name)
    im.save(out)
    print(out, im.size)


build("מפת_בוחן_גדולה.png", margins_all=True, interior_norths=False,
      vertical_ccw=True)
build("מפת_בוחן_פנימית.png", margins_all=False, interior_norths=True,
      vertical_ccw=True)
build("מפת_בוחן_הפוכה.png", margins_all=True, interior_norths=False,
      vertical_ccw=False)
