import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

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
      allowedExtensions: ['png', 'jpg', 'jpeg', 'bmp', 'gif', 'webp'],
      dialogTitle: 'בחר תמונת מפה לג\'יאורפרנס',
    );
    final path = res?.files.single.path;
    if (path == null) return;
    setState(() {
      _imagePath = path;
      _outcome = null;
    });
    await _openGeoreference(path);
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

    final defaultName = p.basenameWithoutExtension(path);
    final params = await showDialog<_ExportParams>(
      context: context,
      builder: (_) => _ExportDialog(defaultName: defaultName),
    );
    if (params == null) return;

    try {
      // ב-TPS מייצאים את הרסטר המיושר שנוצר, לא את המקור.
      final out = await _exportService.export(
        sourceImagePath: outcome.warpedImagePath ?? path,
        result: outcome.result,
        name: params.name,
        targetDir: params.targetDir,
        transform: outcome.transform,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text('יוצא בהצלחה:\n${out.jsonPath}'),
            duration: const Duration(seconds: 5),
          ),
        );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('שגיאת ייצוא: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasImage = _imagePath != null;
    final hasResult = _outcome != null;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('Auto Maps — כלי ג\'יאורפרנס')),
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
                    const Icon(Icons.map, size: 72, color: Colors.blueGrey),
                    const SizedBox(height: 16),
                    const Text(
                      'ייבא תמונת מפה, נעץ נקודות פיקסל↔עולם מול OpenStreetMap, '
                      'וייצא שכבה ג\'יאורפרנסית לאפליקציית LiveMaps.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
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
                    if (hasImage) ...[
                      const SizedBox(height: 24),
                      _InfoCard(
                        imagePath: _imagePath!,
                        result: _outcome?.result,
                        transform: _outcome?.transform,
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: () => _openGeoreference(_imagePath!),
                        icon: const Icon(Icons.edit_location_alt),
                        label: Text(
                          hasResult ? 'ערוך נעיצה מחדש' : 'המשך לנעיצת נקודות',
                        ),
                      ),
                    ],
                    if (hasResult) ...[
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        onPressed: _export,
                        icon: const Icon(Icons.save_alt),
                        label: const Text('ייצא ל-LiveMaps'),
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
  const _ExportParams(this.name, this.targetDir);
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

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDir() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'בחר תיקיית יעד (oflline_map)',
    );
    if (dir != null) setState(() => _targetDir = dir);
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text('ייצוא ל-LiveMaps'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameCtrl,
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
            if (_targetDir != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${_nameCtrl.text}.png + ${_nameCtrl.text}.livemap.json',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ביטול'),
          ),
          ElevatedButton(
            onPressed: (_targetDir != null && _nameCtrl.text.trim().isNotEmpty)
                ? () => Navigator.pop(
                    context,
                    _ExportParams(_nameCtrl.text.trim(), _targetDir!),
                  )
                : null,
            child: const Text('ייצא'),
          ),
        ],
      ),
    );
  }
}
