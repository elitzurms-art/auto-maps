import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;

import '../services/geo_export_service.dart';
import '../services/input_image_service.dart';
import '../services/livemaps_export_service.dart';
import '../services/world_file_parser_service.dart';
import 'georeference_screen.dart';

/// מסך הבית — בחירת תמונה, נעיצה ידנית, ואז ייצוא ל-LiveMaps.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _imagePath;
  GeoreferenceOutcome? _outcome;
  final _exportService = LiveMapsExportService();
  final _picker = ImagePicker();

  /// צילום-מצלמה נתמך רק במובייל (Android/iOS). ב-desktop אין מצלמת-מובייל
  /// טיפוסית, לכן מסתירים את הכפתור ומשתמשים ב"בחר תמונה" בלבד.
  bool get _cameraSupported => Platform.isAndroid || Platform.isIOS;

  Future<void> _captureImage() async {
    try {
      final XFile? shot = await _picker.pickImage(source: ImageSource.camera);
      final path = shot?.path;
      if (path == null) return;
      setState(() {
        _imagePath = path;
        _outcome = null;
      });
      await _openGeoreference(path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('שגיאת צילום: $e')));
    }
  }

  Future<void> _pickImage() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: InputImageService.pickerExtensions,
      dialogTitle: 'בחר מפה לג\'יאורפרנס (תמונה / PDF)',
    );
    final path = res?.files.single.path;
    if (path == null) return;
    await _loadInput(path);
  }

  /// נרמול הקלט (רינדור PDF / המרת TIFF) ופתיחת מסך הנעיצה.
  /// TIFF עם ג'יאורפרנס מובנה (GeoTIFF) מזוהה אוטומטית ומדלג על הנעיצה.
  Future<void> _loadInput(String path) async {
    try {
      final ext = p.extension(path).toLowerCase();
      if (ext == '.tif' || ext == '.tiff') {
        final geo = await _tryParseGeoTiff(path);
        if (geo != null) {
          setState(() {
            _imagePath = geo.pngPath;
            _outcome = GeoreferenceOutcome(
              result: geo.result,
              transform: 'affine',
            );
          });
          if (!mounted) return;
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  'זוהה GeoTIFF עם ג\'יאורפרנס מובנה '
                  '(${geo.result.detectedCrs}) — מוכן לייצוא.',
                ),
                duration: const Duration(seconds: 6),
              ),
            );
          return;
        }
      }

      var pdfPage = 1;
      if (InputImageService.isPdf(path)) {
        final pages = await InputImageService.pdfPageCount(path);
        if (pages > 1) {
          if (!mounted) return;
          final sel = await _askPdfPage(pages);
          if (sel == null) return;
          pdfPage = sel;
        }
        if (mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              const SnackBar(content: Text('מרנדר את עמוד ה-PDF...')),
            );
        }
      }
      final display = await InputImageService.normalize(
        path,
        pdfPage: pdfPage,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      setState(() {
        _imagePath = display;
        _outcome = null;
      });
      await _openGeoreference(display);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('טעינת הקובץ נכשלה: $e')));
    }
  }

  /// מנסה לפרסר TIFF כ-GeoTIFF; null כשאין תגי-ג'יאורפרנס (TIFF רגיל).
  Future<({WorldFileResult result, String pngPath})?> _tryParseGeoTiff(
    String path,
  ) async {
    try {
      return await WorldFileParserService().parseGeoTiff(tiffPath: path);
    } catch (_) {
      return null;
    }
  }

  /// בחירת עמוד ב-PDF מרובה-עמודים.
  Future<int?> _askPdfPage(int pages) async {
    final ctrl = TextEditingController(text: '1');
    final sel = await showDialog<int>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('ל-PDF יש $pages עמודים'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'איזה עמוד לרנדר? (1-$pages)',
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (v) =>
                Navigator.pop(ctx, int.tryParse(v.trim())?.clamp(1, pages)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('ביטול'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(
                ctx,
                int.tryParse(ctrl.text.trim())?.clamp(1, pages) ?? 1,
              ),
              child: const Text('רנדר'),
            ),
          ],
        ),
      ),
    );
    return sel;
  }

  /// חץ-החזרה במסך-הסיום — מזהיר שהתוצאה תנוקה ומחזיר למצב-ההתחלה
  /// (בחירת תמונה / צילום).
  Future<void> _startOver() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('לחזור להתחלה?'),
          content: const Text(
            'החזרה מנקה את התוצאה הנוכחית וחוזרת למסך בחירת-התמונה. '
            'אם עוד לא ייצאת — העבודה תאבד.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('ביטול'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('חזור להתחלה'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _imagePath = null;
      _outcome = null;
    });
  }

  Future<void> _openGeoreference(String path) async {
    final outcome = await Navigator.push<GeoreferenceOutcome>(
      context,
      MaterialPageRoute(builder: (_) => GeoreferenceScreen(imagePath: path)),
    );
    if (outcome != null) {
      setState(() => _outcome = outcome);
    }
  }

  Future<void> _export() async {
    final path = _imagePath;
    final outcome = _outcome;
    if (path == null || outcome == null) return;

    // מסירים סיומת "-עמודN" שנוספת בקובץ-הביניים של רינדור PDF — מיותרת בשם.
    final defaultName = p
        .basenameWithoutExtension(path)
        .replaceAll(RegExp(r'-עמוד\d+$'), '');
    final params = await showDialog<_ExportParams>(
      context: context,
      builder: (_) => _ExportDialog(defaultName: defaultName),
    );
    if (params == null) return;

    try {
      // ב-TPS מייצאים את הרסטר המיושר שנוצר, לא את המקור.
      final srcImage = outcome.warpedImagePath ?? path;
      final corners = outcome.result.cornersWgs84 ??
          _cornersFromBbox(outcome.result);
      final base = _sanitize(params.name);
      final pngPath = p.join(params.targetDir, '$base.png');
      final written = <String>[];

      // LiveMaps כותב גם את ה-PNG; אחרת מוודאים PNG לפורמטים שנשענים עליו.
      if (params.formats.contains(ExportFormat.liveMaps)) {
        final out = await _exportService.export(
          sourceImagePath: srcImage,
          result: outcome.result,
          name: params.name,
          targetDir: params.targetDir,
          transform: outcome.transform,
        );
        written.add(p.basename(out.jsonPath));
      } else {
        await GeoExportService.ensurePng(srcImage, pngPath);
      }
      final needsPng = params.formats.any((f) => f != ExportFormat.liveMaps);
      if (needsPng) written.add('$base.png');

      if (params.formats.contains(ExportFormat.worldFile)) {
        final files = await GeoExportService.writeWorldFile(
          pngPath: pngPath,
          corners: corners,
          imageWidth: outcome.result.imageWidth,
          imageHeight: outcome.result.imageHeight,
        );
        written.addAll(files.map(p.basename));
      }
      if (params.formats.contains(ExportFormat.kmz)) {
        final kmz = await GeoExportService.writeKmz(
          pngPath: pngPath,
          corners: corners,
          name: params.name,
          kmzPath: p.join(params.targetDir, '$base.kmz'),
        );
        written.add(p.basename(kmz));
      }
      if (params.formats.contains(ExportFormat.geoTiff)) {
        final tif = await GeoExportService.writeGeoTiff(
          pngPath: pngPath,
          corners: corners,
          imageWidth: outcome.result.imageWidth,
          imageHeight: outcome.result.imageHeight,
          tifPath: p.join(params.targetDir, '$base.tif'),
        );
        written.add(p.basename(tif));
      }
      String? mbtilesOut;
      if (params.formats.contains(ExportFormat.mbtiles)) {
        mbtilesOut = await GeoExportService.writeMbtiles(
          pngPath: pngPath,
          corners: corners,
          imageWidth: outcome.result.imageWidth,
          imageHeight: outcome.result.imageHeight,
          name: params.name,
          mbtilesPath: p.join(params.targetDir, '$base.mbtiles'),
        );
        written.add(p.basename(mbtilesOut));
      }
      if (params.formats.contains(ExportFormat.pmtiles)) {
        final pm = await GeoExportService.writePmtiles(
          pngPath: pngPath,
          corners: corners,
          imageWidth: outcome.result.imageWidth,
          imageHeight: outcome.result.imageHeight,
          name: params.name,
          pmtilesPath: p.join(params.targetDir, '$base.pmtiles'),
          existingMbtilesPath: mbtilesOut,
        );
        written.add(p.basename(pm));
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text('יוצא בהצלחה ל-${params.targetDir}:\n'
                '${written.join(', ')}'),
            duration: const Duration(seconds: 6),
          ),
        );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('שגיאת ייצוא: $e')));
    }
  }

  List<LatLng> _cornersFromBbox(WorldFileResult r) => [
        LatLng(r.northEast.latitude, r.southWest.longitude), // NW
        r.northEast, // NE
        LatLng(r.southWest.latitude, r.northEast.longitude), // SE
        r.southWest, // SW
      ];

  String _sanitize(String name) {
    final cleaned = name.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return cleaned.isEmpty ? 'layer' : cleaned;
  }

  @override
  Widget build(BuildContext context) {
    final hasImage = _imagePath != null;
    final hasResult = _outcome != null;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Auto Maps — כלי ג\'יאורפרנס'),
          // חץ-חזרה במסך-הסיום: מזהיר ומחזיר למצב-ההתחלה (בחירת תמונה).
          leading: hasResult
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'חזור להתחלה',
                  onPressed: _startOver,
                )
              : null,
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SafeArea(
              // רווח תחתון ~1.5 ס"מ בכל המסכים — שלא ייחתך ע"י ה-gesture bar.
              minimum: const EdgeInsets.only(bottom: 56),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      hasResult ? Icons.check_circle_outline : Icons.map,
                      size: 72,
                      color: hasResult ? Colors.green : Colors.blueGrey,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      hasResult
                          ? 'השכבה מוכנה — ייצא לקובץ, או חזור אחורה '
                              'כדי להתחיל מפה חדשה.'
                          : 'ייבא תמונת מפה, נעץ נקודות פיקסל↔עולם מול '
                              'OpenStreetMap, וייצא שכבה ג\'יאורפרנסית '
                              'לאפליקציית LiveMaps.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                    // מסך-ההתחלה: בחירה/צילום. במסך-הסיום אין אותם —
                    // מתחילים-מחדש רק דרך חץ-החזרה (עם אזהרה).
                    if (!hasResult) ...[
                      ElevatedButton.icon(
                        onPressed: _pickImage,
                        icon: const Icon(Icons.image_search),
                        label: const Text('בחר תמונה'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                      ),
                      if (_cameraSupported) ...[
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _captureImage,
                          icon: const Icon(Icons.photo_camera),
                          label: const Text('צלם מפה'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                        ),
                      ],
                    ],
                    if (hasImage) ...[
                      const SizedBox(height: 24),
                      _InfoCard(
                        imagePath: _imagePath!,
                        result: _outcome?.result,
                        transform: _outcome?.transform,
                      ),
                    ],
                    if (hasImage && !hasResult) ...[
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: () => _openGeoreference(_imagePath!),
                        icon: const Icon(Icons.edit_location_alt),
                        label: const Text('המשך לנעיצת נקודות'),
                      ),
                    ],
                    if (hasResult) ...[
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: _export,
                        icon: const Icon(Icons.save_alt),
                        label: const Text('ייצא לקובץ'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String imagePath;
  final WorldFileResult? result;
  final String? transform;

  const _InfoCard({required this.imagePath, this.result, this.transform});

  @override
  Widget build(BuildContext context) {
    final r = result;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.insert_drive_file, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    p.basename(imagePath),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (r != null) ...[
              const Divider(),
              Text('מימדים: ${r.imageWidth} × ${r.imageHeight} px'),
              if (r.nw != null)
                Text('NW: ${_fmt(r.nw!.latitude)}, ${_fmt(r.nw!.longitude)}'),
              if (r.se != null)
                Text('SE: ${_fmt(r.se!.latitude)}, ${_fmt(r.se!.longitude)}'),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 16),
                  const SizedBox(width: 4),
                  Text(
                    transform == 'tps'
                        ? 'מוכן לייצוא (יושר ב-TPS)'
                        : 'מוכן לייצוא',
                    style: const TextStyle(color: Colors.green),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _fmt(double v) => v.toStringAsFixed(6);
}

class _ExportParams {
  final String name;
  final String targetDir;
  final Set<ExportFormat> formats;
  const _ExportParams(this.name, this.targetDir, this.formats);
}

class _ExportDialog extends StatefulWidget {
  final String defaultName;
  const _ExportDialog({required this.defaultName});

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  late final TextEditingController _nameCtrl = TextEditingController(
    text: widget.defaultName,
  );
  String? _targetDir;
  final Set<ExportFormat> _formats = {ExportFormat.liveMaps};

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDir() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'בחר תיקיית יעד',
    );
    if (dir != null) setState(() => _targetDir = dir);
  }

  Widget _fmtTile(ExportFormat f, String title, String subtitle,
      {bool enabled = true}) {
    return CheckboxListTile(
      value: _formats.contains(f),
      onChanged: enabled
          ? (v) => setState(() {
                if (v == true) {
                  _formats.add(f);
                } else {
                  _formats.remove(f);
                }
              })
          : null,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      dense: true,
      title: Text(title),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final base = _nameCtrl.text.trim().isEmpty ? 'layer' : _nameCtrl.text.trim();
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text('ייצוא שכבה'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _nameCtrl,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'שם השכבה',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _pickDir,
                icon: const Icon(Icons.folder_open),
                label: Text(_targetDir ?? 'בחר תיקיית יעד'),
              ),
              const SizedBox(height: 8),
              const Align(
                alignment: Alignment.centerRight,
                child: Text('פורמטים:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              _fmtTile(ExportFormat.liveMaps, 'LiveMaps',
                  '$base.png + $base.livemap.json'),
              _fmtTile(ExportFormat.worldFile, 'World file (GIS)',
                  '$base.pgw + $base.prj (QGIS/ArcGIS)'),
              _fmtTile(ExportFormat.kmz, 'KMZ (Google Earth)', '$base.kmz'),
              _fmtTile(
                ExportFormat.geoTiff,
                'GeoTIFF${GeoExportService.geoTiffSupported ? '' : ' (לא נתמך בפלטפורמה)'}',
                '$base.tif — מיושר-צפון',
                enabled: GeoExportService.geoTiffSupported,
              ),
              _fmtTile(
                ExportFormat.mbtiles,
                'MBTiles${GeoExportService.mbtilesSupported ? '' : ' (לא נתמך בפלטפורמה)'}',
                '$base.mbtiles — פירמידת-אריחים (QGIS/שרתי-מפות)',
                enabled: GeoExportService.mbtilesSupported,
              ),
              _fmtTile(
                ExportFormat.pmtiles,
                'PMTiles${GeoExportService.pmtilesSupported ? '' : ' (לא נתמך בפלטפורמה)'}',
                '$base.pmtiles — אריחים בקובץ יחיד (CDN/MapLibre, בלי שרת)',
                enabled: GeoExportService.pmtilesSupported,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ביטול'),
          ),
          ElevatedButton(
            onPressed: (_targetDir != null &&
                    _nameCtrl.text.trim().isNotEmpty &&
                    _formats.isNotEmpty)
                ? () => Navigator.pop(
                      context,
                      _ExportParams(
                          _nameCtrl.text.trim(), _targetDir!, _formats),
                    )
                : null,
            child: const Text('ייצא'),
          ),
        ],
      ),
    );
  }
}
