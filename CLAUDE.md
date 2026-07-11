<div dir="rtl">

# Auto Maps — כלי ג'יאורפרנס

אפליקציית **Flutter** ייעודית (single-purpose) שממירה מפה משורטטת/תמונה לשכבה ג'יאורפרנסית שאפליקציית **LiveMaps** (`C:\LiveMaps`) צורכת. **Desktop-first (Windows)**, גם Android/iOS/macOS/Linux. GitHub: `elitzurms-art/auto-maps` (public). נגזר מפיצ'ר הג'יאורפרנס של `C:\navigate` (‏`world_file_parser_service.dart` הועתק as-is; `georeference_screen.dart` רוזז מ-`MapConfig`/`TopoLayerService`).

## הזרימה
ייבוא מפה — תמונה (PNG/JPG/WebP/BMP/GIF), **PDF** (רינדור עמוד ל-PNG ‏~4500px דרך pdfx/pdfium, בורר-עמוד כשיש כמה), **HEIC** (קודק המנוע במובייל/מק; ב-Windows ‏WIC דרך `auto_maps_wic.dll` — ‏`wic_convert.cpp`, דורש HEIF Image Extensions של MS) או **TIFF** (המרה ב-Isolate; **GeoTIFF עם תגי-ג'יאורפרנס מזוהה אוטומטית ב-home_screen ומדלג על הנעיצה** — `parseGeoTiff` הקיים) — הכל דרך `input_image_service.dart` → נעיצת נקודות **פיקסל↔עולם** מול מפת-ייחוס → חישוב **affine** (least-squares) *או* **יישור TPS** למפות לא-ישרות (מתג במסך הנעיצה; `gdal_warp_service.dart` → `ecw_warp_tps` ב-wrapper) → ייצוא. **מצב אוטומטי (הזרימה היחידה — אין כפתורי ✨/⊞; ידני = נעיצה רגילה):** בטעינת התמונה במסך-הנעיצה רצים **שני מנועים ברקע במקביל** (בר "מריץ התאמות אוטומטיות…" עם חיווי-שלב פר-מנוע; ‏timeout קשיח: רשת **5 דק'**, כבישים **~50ש'**): **(1) רשת-קואורדינטות** — OCR (Tesseract, `grid_coord_service.dart`+`ocr_service.dart`) קורא תוויות-קואורדינטה מודפסות (ITM/UTM, זיהוי-CRS אוטומטי) למפות-סקר/קדסטרליות; **(2) כבישים קלאסי** (בלי AI, **ליישובים בלבד** — שטח-פתוח/צבאי שייך לגריד) — `gemini_anchor_service.suggestAnchors`: גלאי-צמתים (`road_junction_detector.dart`) → **geocode מבוסס-מועמדים** (Nominatim; n-גרמים יורדים משם-הקובץ — שם-מלא→זוגות→מילים-בודדות, `settlementOnly` קודם — תופס שם-מקום בכל מיקום ומתעלם ממילות-תיאור כמו "מסובבת"; ‏bbox צמוד ליישוב, ריפוד 15%) → Overpass (`overpass_service.dart`, מרוץ-שרתים) → **רישום RANSAC מאוחד לכל-הזוויות** (`_classicalMatch`+`anchor_matcher.dart`): איסוף-OSM פעם אחת, ואז כל אסטרטגיות-הכיוון בניקוד-איכות משותף — ישיר (סביב מצפן/צפון-מדויק/±20°) **וגם** deskew (יישור-לפי-תוכן, 4 רבעים, **כל זווית** 35°/70°); הטוב-לפי-`inliers*10-roadFit` מנצח חוצה-אסטרטגיות. כששני המנועים סיימו → **מסך-בחירה (hub)**: רשת/כבישים (מה שנמצא) + **"עבודה ידנית" (תמיד, אחרון)**; אם כבישים לא מצא — שדה-תיקון "שם היישוב" (`_areaController`/`_rerunRoad`) להרצה-חוזרת עם שם אחר. **כפתור-החזור מיירט ל-hub** (PopScope) ומ-hub יוצא; אפשר לעבור בין האפשרויות ולחזור לידני בכל עת. אפשרות-הכבישים פותחת מסך **אישור פר-נקודה** (`AdjustVerifyScreen`; מסגרת ירוקה=אומת/אדומה=נכשל/לבנה=לא-אומת) עם מיני-מפה (מפה/לוויין) ושילוב-שקוף (affine זמני + סליידר); **"אשר וייצא" שם מייצא ישירות** (מתג-TPS בסרגל-התחתון, `AdjustVerifyResult`; ביטול/חזור→hub) — **בלי** תצוגה-מקדימה כפולה (השילוב-השקוף הוא-הוא התצוגה). מסך-הסיום ב-home: בלי בחר/צלם — חץ-חזרה באפבר (אזהרה→איפוס להתחלה) + ייצוא בלבד. ⚠️ **מסלול-ה-AI (Gemini) הוסר לגמרי** — הכל CV מקומי; `gemini_anchor_service.dart` הוא שם-מורשת (בלי מפתח-API/רשת-מודל). package: `com.elitzur.auto_maps`.

**כלל UI:** בכל מסך — SafeArea + רווח תחתון ~1.5 ס"מ (≈56lp) שכפתורים לא ייחתכו ע"י ה-gesture bar במובייל.

## פורמט ההעברה ל-LiveMaps (קנוני — חייב להתאים לצרכן)
`livemaps_export_service.dart` כותב ל-`oflline_map` (או Drive מסונכרן):
- `<name>.png` — התמונה.
- `<name>.livemap.json`: מפתחות פינות **`nw/ne/se/sw`**, קואורדינטות **`[lat, lon]`** (lat קודם), + `imageWidth/Height`, `transform:"affine"`, `sourceCrs`. ⚠️ **אל תשנה לפורמט אחר** — הצרכן ב-LiveMaps (`layers/sources/GeoImageOverlay.kt` + `overlay/GeoImageDrape*`) קורא בדיוק את זה. TPS ב-phase 2 ישאיר את אותו חוזה (רסטר מיושר + פינות; `transform:"tps"`).

**פורמטים נוספים** (דיאלוג-הייצוא, `geo_export_service.dart`): world-file+‎.prj, KMZ, GeoTIFF, **MBTiles**, **PMTiles**. ‏GeoTIFF/MBTiles דרך GDAL המצורף (`ecw_write_geotiff`/`ecw_write_mbtiles` ב-wrapper; MBTiles = warp ל-EPSG:3857 + אריחי-PNG + overviews — זום-מקס' אוטומטי לפי רזולוציית-הקרקע, זום-מין' עד שהמפה ~אריח). ‏PMTiles = המרת MBTiles ב-Dart טהור (`pmtiles_writer_service.dart` — ל-GDAL אין דרייבר-רסטר PMTiles; spec v3: הילברט-tile_id + ספריית-varint + gzip; ‏MBTiles-ביניים זמני אם לא יוצא גם הוא). אומת ב-`tool/mbtiles_probe.dart`/`tool/pmtiles_probe.dart` + ספריית-הייחוס npm‏ pmtiles.

## מפת-ייחוס (בורר מקורות — `reference_map_controller.dart`)
`ReferenceMapSource` (מחזור-חיים `activate`/`deactivate`/`isReady`). הבורר מופיע כש-`availableSources().length > 1` (כיום תמיד — OSM+לוויין). מקורות:
- **OSM online** (ברירת מחדל) + **לוויין Esri online** (`SatelliteOnlineSource`, ‏World Imagery, סדר `{z}/{y}/{x}`).
- **MBTiles / ECW מתיקייה** — `loadFolder()` סורק תיקייה (`reference_maps` ליד ה-exe/cwd) וכל `.mbtiles`/`.ecw` = מקור נפרד. `.ecw` רק כש-`NativeEcwService.isSupportedPlatform`.
- **הוספה ידנית** — `addSource()` / `addEcwFile()`.

## ECW נייטיבי (בלי OSGeo4W בזמן ריצה)
FFI ל-GDAL דרך `ecw_wrapper.c` המשותף (מ-navigate). `ecw_gdal_decoder.dart._openEcwLibrary()`:
- **Android** → `libauto_maps_ecw.so` (‏`android/app/src/main/cpp/CMakeLists.txt` דרך `externalNativeBuild`, מקושר ל-`libgdal.so`/`libproj.so` המצורפים ב-`jniLibs/arm64-v8a/`).
- **Windows** → `auto_maps_ecw.dll` (‏`windows/ecw_native/CMakeLists.txt` מקמפל את `ecw_wrapper.c`, מקשר דרך `gdal_i.lib` שנוצר מטבלת ה-exports של `gdal313.dll` — **בלי gdal-dev**; מצרף ~136MB GDAL runtime + plugin ECW + `proj.db` ליד ה-exe ומעגן `GDAL_DRIVER_PATH`/`GDAL_DATA`/`PROJ_DATA` בעצמו).
- **iOS** → `DynamicLibrary.process()` (linkage סטטי דרך `gdal_ecw.xcframework`).
- **⚠️ תלות build ל-Windows:** `C:\OSGeo4W` (עם דרייבר ECW) חייב להיות מותקן **בזמן הבנייה** כדי לגזור ממנו את ה-runtime DLLs (הם מועתקים ב-POST_BUILD, **לא** committed). ‏`gdal_i.def`/`gdal_i.lib` כן committed.
- **⚠️ רישוי:** `NCSEcw.dll` = ECW/JP2 SDK של Hexagon — קריאה חופשית, אבל **הפצה-מחדש דורשת רישיון Hexagon**. GDAL/PROJ עצמם MIT.

## בנייה
- `flutter build windows --debug` — עובד (VS C++ toolchain). מייצר `auto_maps.exe` + כל בנדל ה-ECW לידו.
- **Android** — `flutter build apk` (דורש Android SDK). ⚠️ מאומת-קומפילציה (‏`libauto_maps_ecw.so` נבנה כ-arm64 ELF תקין), טרם רץ ב-APK מלא/מכשיר.
- **iOS/macOS** — דורשים **Mac**. אוטומטי דרך `.github/workflows/build-apple.yml` (macOS runner): מריץ `ios_native/build_gdal_xcframework.sh` (בונה `gdal_ecw.xcframework` מ-PROJ/GDAL/libecw) → `pod install` → `flutter build ios/macos`. שלב ה-GDAL הוא `continue-on-error` (אם ייכשל, בונה בלי ECW).
- **Linux** — פלטפורמה מופעלת, ECW טרם מחווט.

## קבצים
- `lib/services/world_file_parser_service.dart` — **ליבת ה-affine** + CRS (ITM/UTM36N/Old-Israel/WGS84 דרך proj4dart) + פרסור world-file/GeoTIFF/KMZ. הורחב ל-4 פינות אמיתיות (`cornersWgs84`, סדר NW/NE/SE/SW — לא bbox).
- `lib/services/reference_map_controller.dart` — הבורר + מקורות + סריקת תיקייה.
- `lib/services/ecw/` — `native_ecw_service.dart` (facade), `ecw_gdal_decoder.dart` (FFI), `ecw_gdal_tile_provider.dart`.
- `lib/services/livemaps_export_service.dart` — הייצוא (פרמטר `transform`: affine/tps).
- `lib/services/gdal_warp_service.dart` — **יישור TPS** (FFI ל-`ecw_warp_tps` ב-wrapper; רץ ב-Isolate.run). ה-C: translate מצרף GCPs ל-MEM (+expand rgba לפלטה) → GDALWarp ‎-tps ל-WGS84 → CreateCopy PNG. הפלט: PNG מיושר-צפון + geotransform. ⚠️ סימבולים חדשים ב-`gdal_i.def` מחייבים ריצת `lib /def:gdal_i.def /machine:x64 /out:gdal_i.lib`.
- `lib/services/gemini_anchor_service.dart` — **מנוע-הכבישים הקלאסי** (שם-מורשת; **בלי Gemini/AI/רשת-מודל**). `suggestAnchors`: גלאי-צמתים (`RoadJunctionDetector`, `road_junction_detector.dart` — Otsu→פתיחה מורפולוגית→Zhang-Suen→crossing-number≥3→אשכולות; בלי dart:ui) על התמונה **ועל גרסת-deskew** (`_deskewDetectSync`: `estimateSkewDeg`→יישור→re-detect→4 רבעים; זול למפה ישרה skew<2°→null) → `_classicalMatch`: geocode Nominatim (bbox צמוד, ריפוד 15%) → Overpass **פעם אחת** → **רישום מאוחד לכל-הזוויות** (ישיר סביב מצפן/צפון + deskew כל-זווית) עם ניקוד `scoreOf=inliers*10-roadFit`, הטוב מנצח חוצה-אסטרטגיות (מונע נעילה על זווית-שגויה). `detectCompass` — קריאת חץ-צפון קלאסית (מחזקת את המסלול-הישיר). ⚠️ bbox רחב בולע יישוב שכן→התאמות-שווא. ⚠️ Isolate.run רק עם מתודה סטטית (closure של State קורס).
- `lib/screens/georeference_screen.dart` — מסך הנעיצה, **זרימה אוטומטית-בלבד**: `initState` מריץ שני מנועי-רקע (`_autoDetectGrid(silent)` רשת + `_autoClassicalMatch` כבישים, כל אחד תמיד מסמן `_autoGridDone`/`_autoRoadDone` — גם בלי OCR/רמז); `_maybeOfferAuto` פותח את מסך-הבחירה (`_buildChooserView`, מתג `_showChooser`) כששניהם סיימו. **PopScope** מיירט חזור→hub. `_applyGridTicks`/`_openAdjustVerify`/`_chooseManual` + `_captureManualBeforeAuto`/`_restoreManualPoints`/`_pointsAreAuto` (שמירת עבודה-ידנית). מתג TPS. חיווי-שלב `_gridStage`/`_roadStage` בבר. מחזיר `GeoreferenceOutcome`. `home_screen.dart` — בחירת תמונה→נעיצה→ייצוא.

## TODO / phases עתידיים
- **הרצה-אמיתית** של iOS/macOS (דרך ה-CI). Android ✅ רץ על מכשיר (2026-07-06).
- **הקטנת בנדל ה-136MB** — build מותאם של GDAL (בלי arrow/poppler/hdf5...) אם צריך.

## קשור
- **צרכן ב-LiveMaps:** `layers/sources/GeoImageOverlay.kt`, `overlay/GeoImageDrape*`, `MapPaneController.setImageOverlays`, `map.html` maplibre image source.
- **navigate:** מקור ה-`world_file_parser_service` + ה-ECW native (‏`ecw_wrapper.c`, `build_gdal_xcframework.sh`). ה-backport של ECW-DLL ל-Windows ב-navigate: ענף `feat/windows-ecw-native-dll`.

</div>
