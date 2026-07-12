# -*- coding: utf-8 -*-
# מפת-בוחן למנוע שמות-המקומות: בוחר תא-שטח אמיתי צפוף-שמות מהגזטיר,
# מצייר את השמות במיקומיהם היחסיים האמיתיים (היטל שווה-מרחקים), ופולט
# גם קובץ-אמת (JSON) לטסט. הרצה: python tool/make_names_test_map.py
import json
import math
import os
import re
from collections import defaultdict

from PIL import Image, ImageDraw, ImageFont

GAZ = os.path.join(os.path.dirname(__file__), "..", "assets", "gazetteer_il.txt")
TEMP = os.environ.get("TEMP", "/tmp")
HEB = re.compile("[֐-׿]")

entries = []
with open(GAZ, encoding="utf-8") as f:
    for line in f:
        c = line.rstrip("\n").split("\t")
        if len(c) < 5:
            continue
        # איתור-עמודות גמיש: זוג-מספרים ראשון בטווחי-ישראל = lat/lon.
        coord_at = -1
        for i in range(1, len(c) - 1):
            try:
                la, lo = float(c[i]), float(c[i + 1])
            except ValueError:
                continue
            if 29 <= la <= 34 and 33.5 <= lo <= 36.5:
                coord_at = i
                break
        if coord_at < 1:
            continue
        lat, lon = float(c[coord_at]), float(c[coord_at + 1])
        # השם-העברי הראשון מבין עמודות-השמות.
        name = None
        for col in c[:coord_at]:
            for cand in col.split(","):
                cand = cand.strip().strip('"')
                if HEB.search(cand) and len(cand) >= 4 \
                        and not re.search(r"\d", cand):
                    name = cand
                    break
            if name:
                break
        if name:
            entries.append((name, lat, lon))

# מעדיפים שמות-יחידאיים (מופע-אחד בגזטיר, ≥2 מילים) — כמו מפת-טיולים
# אמיתית (עין/חורבת/תל...), לא מוסדות גנריים שחוזרים בכל עיר.
name_count = defaultdict(int)
for name, _, _ in entries:
    name_count[name] += 1
rare = [(n, la, lo) for n, la, lo in entries
        if name_count[n] == 1 and " " in n]

# תא 0.03°x0.03° עם הכי הרבה שמות-יחידאיים
cells = defaultdict(list)
for name, lat, lon in rare:
    cells[(round(lat / 0.03), round(lon / 0.03))].append((name, lat, lon))
best_cell = max(cells.values(), key=lambda v: len({n for n, _, _ in v}))
# עד 12 שמות ייחודיים, מפוזרים
seen = set()
chosen = []
for name, lat, lon in best_cell:
    if name in seen:
        continue
    seen.add(name)
    chosen.append((name, lat, lon))
    if len(chosen) >= 12:
        break

lat0 = sum(lat for _, lat, _ in chosen) / len(chosen)
lon0 = sum(lon for _, _, lon in chosen) / len(chosen)
kx = 111320.0 * math.cos(math.radians(lat0))
ky = 110540.0
SCALE = 2.0  # מ' לפיקסל
W, H = 2600, 2000

def to_px(lat, lon):
    x = W / 2 + (lon - lon0) * kx / SCALE
    y = H / 2 - (lat - lat0) * ky / SCALE
    return x, y

im = Image.new("RGB", (W, H), (247, 245, 238))
d = ImageDraw.Draw(im)
font = ImageFont.truetype(r"C:\Windows\Fonts\arial.ttf", 36)
truth = []
for name, lat, lon in chosen:
    x, y = to_px(lat, lon)
    if not (150 < x < W - 350 and 100 < y < H - 100):
        continue
    # סימן-פריט + שם לצידו (כמו במפות אמיתיות; PIL מצייר עברית הפוך —
    # הופכים את סדר-התווים כדי שה-RTL ייראה נכון ויקרא נכון ב-OCR)
    d.ellipse([x - 6, y - 6, x + 6, y + 6], outline=(60, 60, 200), width=3)
    disp = name[::-1]
    d.text((x + 14, y - 20), disp, font=font, fill=(30, 30, 30))
    truth.append({"name": name, "lat": lat, "lon": lon, "px": x, "py": y})

# קווי-"שבילים" עדינים כרעש
import random
random.seed(3)
for _ in range(25):
    pts = [(random.randint(0, W), random.randint(0, H))]
    for _ in range(4):
        pts.append((pts[-1][0] + random.randint(-400, 400),
                    pts[-1][1] + random.randint(-300, 300)))
    d.line(pts, fill=(190, 150, 120), width=3)

out_png = os.path.join(TEMP, "מפת_בוחן_שמות.png")
out_json = os.path.join(TEMP, "מפת_בוחן_שמות.json")
im.save(out_png)
with open(out_json, "w", encoding="utf-8") as f:
    json.dump({"lat0": lat0, "lon0": lon0, "scale": SCALE,
               "names": truth}, f, ensure_ascii=False, indent=1)
print(out_png, f"{len(truth)} names around ({lat0:.4f},{lon0:.4f})")
