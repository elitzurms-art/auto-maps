<div dir="rtl">

# Auto Maps — כלי ג'יאורפרנס

אפליקציית **Flutter** ייעודית (single-purpose) שממירה מפה משורטטת/תמונה לשכבה ג'יאורפרנסית שאפליקציית **LiveMaps** (`C:\LiveMaps`) צורכת. **Desktop-first (Windows)**, גם Android/iOS/macOS/Linux. GitHub: `elitzurms-art/auto-maps` (public). נגזר מפיצ'ר הג'יאורפרנס של `C:\navigate` (‏`world_file_parser_service.dart` הועתק as-is; `georeference_screen.dart` רוזז מ-`MapConfig`/`TopoLayerService`).

## הזרימה
ייבוא תמונה → נעיצת נקודות **פיקסל↔עולם** מול מפת-ייחוס → חישוב **affine** (least-squares) *או* **יישור TPS** למפות לא-ישרות (מתג במסך הנעיצה; `gdal_warp_service.dart` → `ecw_warp_tps` ב-wrapper) → ייצוא. **מצב אוטומטי:** כפתור ✨ במסך הנעיצה שולח את התמונה ל-**Gemini** (`gemini_anchor_service.dart`, מפתח API ב-shared_preferences) ומקבל הצעות עוגנים **נקודתיים** (צמתים/כיכרות/עיקולים/מבנים/נקודות-גובה/מעיינות — לא תוויות שם), ואז **שלב אימות**: לכל עוגן נשלף קטע OSM אמיתי (z16) והמודל מצביע על הנקודה בו — ההצבעה מומרת ל-lat/lon ב-web-mercator (לא זיכרון המודל). **אישור פר-נקודה** (סמנים סגולים; מסגרת ירוקה=אומת/אדומה=נכשל/לבנה=לא-אומת) בדיאלוג עם מיני-מפה (מפה/לוויין) ושילוב-שקוף של המפה החדשה (affine זמני + סליידר). package: `com.elitzur.auto_maps`.

**כלל UI:** בכל מסך — SafeArea + רווח תחתון ~1.5 ס"מ (≈56lp) שכפתורים לא ייחתכו ע"י ה-gesture bar במובייל.

## פורמט ההעברה ל-LiveMaps (קנוני — חייב להתאים לצרכן)
`livemaps_export_service.dart` כותב ל-`oflline_map` (או Drive מסונכרן):
- `<name>.png` — התמונה.
- `<name>.livemap.json`: מפתחות פינות **`nw/ne/se/sw`**, קואורדינטות **`[lat, lon]`** (lat קודם), + `imageWidth/Height`, `transform:"affine"`, `sourceCrs`. ⚠️ **אל תשנה לפורמט אחר** — הצרכן ב-LiveMaps (`layers/sources/GeoImageOverlay.kt` + `overlay/GeoImageDrape*`) קורא בדיוק את זה. TPS ב-phase 2 ישאיר את אותו חוזה (רסטר מיושר + פינות; `transform:"tps"`).

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
- `lib/services/gemini_anchor_service.dart` — **המצב האוטומטי**: מקטין ל-1600px, שולח ל-`gemini-2.5-flash` עם responseSchema, מקבל עוגנים (pixel+world+שם+ביטחון) וממפה חזרה למימדי המקור. ואז `_verifyAnchors`: קטע-סריקה עם צלב + קטע OSM (סטיצ'ינג אריחים, z16/640px) לכל עוגן בקריאה שנייה אחת → המודל מצביע בקטע-הייחוס → עידון קואורדינטות ב-web-mercator; `verified: true/false/null` (כשל רשת ⇒ null, לא מפיל). **לולאת השלמה:** סבב 1 מבקש עד 12; אם יש פחות מ-5 מאומתים — עד 2 סבבים נוספים עם רשימת מה-שהוצע-ונדחה ("חדשים בלבד, אזורים שטרם כוסו"), דדופ לפי מרחק פיקסלים (2%).
- `lib/screens/georeference_screen.dart` — מסך הנעיצה: מתג TPS, כפתור ✨ AI, סמני הצעות סגולים עם אישור/דחייה פר-נקודה בדיאלוג משולב: מיני-מפה (רקע מפת-ייחוס/לוויין), OverlayImage של המפה החדשה מ-affine זמני (3+ נקודות) + סליידר שקיפות. מחזיר `GeoreferenceOutcome` (result+transform+warpedImagePath). `home_screen.dart` — בחירת תמונה→נעיצה→ייצוא.

## TODO / phases עתידיים
- **הרצה-אמיתית** של iOS/macOS (דרך ה-CI). Android ✅ רץ על מכשיר (2026-07-06).
- **הקטנת בנדל ה-136MB** — build מותאם של GDAL (בלי arrow/poppler/hdf5...) אם צריך.

## קשור
- **צרכן ב-LiveMaps:** `layers/sources/GeoImageOverlay.kt`, `overlay/GeoImageDrape*`, `MapPaneController.setImageOverlays`, `map.html` maplibre image source.
- **navigate:** מקור ה-`world_file_parser_service` + ה-ECW native (‏`ecw_wrapper.c`, `build_gdal_xcframework.sh`). ה-backport של ECW-DLL ל-Windows ב-navigate: ענף `feat/windows-ecw-native-dll`.

</div>
