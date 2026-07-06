import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'win_job_object.dart';

/// עוטף את שרת ה-ECW (Python + GDAL) כתהליך-בן ומחזיר URL
/// תבניתי לטעינה ב-flutter_map.
///
/// מקביל בעקרון ל-[Jp2TileServer] בקבצי `services/jp2/`, אבל במקום HTTP
/// server שכתוב ב-Dart, פה אנחנו מריצים תהליך Python שכבר יודע לקרוא
/// קבצי ECW דרך הפלאגין של GDAL ב-OSGeo4W.
///
/// תלויות:
///  - `OSGeo4W.bat` במיקום ידוע (ברירת מחדל `C:\OSGeo4W\OSGeo4W.bat`)
///  - `ecw_tile_server.py` (חי בפלאגין `gps_l5/scripts/`)
///  - קובץ ECW מקור
///
/// פלטפורמה: Windows בלבד בשלב הזה. עבור Android/iOS תהיה מימוש native
/// נפרד דרך FFI ל-Hexagon SDK / לקוד שיחולץ מ-APK הצרפתי.
class EcwTileServer {
  EcwTileServer({
    required this.ecwPath,
    required this.scriptPath,
    this.osgeo4wBat = r'C:\OSGeo4W\OSGeo4W.bat',
    this.host = '127.0.0.1',
    this.preferredPort = 0,
    this.applyStretch = false,
  });

  final String ecwPath;
  final String scriptPath;
  final String osgeo4wBat;
  final String host;
  final int preferredPort;
  final bool applyStretch;

  Process? _proc;
  int? _port;

  int? get port => _port;
  String? get baseUrl => _port == null ? null : 'http://$host:$_port';
  String? get tileUrlTemplate =>
      _port == null ? null : 'http://$host:$_port/{z}/{x}/{y}.png';

  /// מפעיל את השרת ומחכה שהפורט יהיה ידוע. זורק חריג אם השרת לא עלה.
  Future<int> start({Duration timeout = const Duration(seconds: 30)}) async {
    if (_proc != null) return _port!;

    if (!Platform.isWindows) {
      throw UnsupportedError(
          'EcwTileServer Python sidecar — Windows only at this stage');
    }
    if (!File(ecwPath).existsSync()) {
      throw FileSystemException('ECW source not found', ecwPath);
    }
    if (!File(scriptPath).existsSync()) {
      throw FileSystemException('tile-server script not found', scriptPath);
    }
    if (!File(osgeo4wBat).existsSync()) {
      throw FileSystemException('OSGeo4W.bat not found', osgeo4wBat);
    }

    // workers=4 — ארבעה תהליכי-בן מקבילים. עם multithread=False + recreate
    // תקופתי כל 500 reads, ה-SDK נשאר בריא. כל worker ~1GB RAM.
    final args = <String>[
      'python',
      scriptPath,
      '--src', ecwPath,
      '--host', host,
      '--port', preferredPort.toString(),
      '--workers', '4',
      '--cache-size', '4096',
      if (!applyStretch) '--no-stretch',
    ];
    final proc = await Process.start(osgeo4wBat, args, runInShell: false);
    _proc = proc;

    // מצרף את התהליך ל-Win32 Job Object — מבטיח שכל ה-subprocess
    // (cmd.exe → python.exe → workers של multiprocessing) ייהרגו אוטומטית
    // כשהאפליקציה תיסגר, גם בקרסה / Task Manager / ניתוק חשמל.
    WindowsJobObject().attach(proc.pid);

    final portCompleter = Completer<int>();
    final portRegex = RegExp(r'http://[^:]+:(\d+)');
    final stderrBuf = StringBuffer();
    // stderr זורם ל-debugPrint בזמן אמת — חיוני כדי לתפוס traceback של
    // workers שנפלו (BrokenProcessPool וכו'). בנוסף נשמר ב-buffer לדיווח
    // שגיאת startup/exit.
    final tag = ecwPath.split(RegExp(r'[\\/]')).last;

    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (line) {
        if (line.isNotEmpty) debugPrint('[ecw:$tag] $line');
        if (!portCompleter.isCompleted) {
          final m = portRegex.firstMatch(line);
          if (m != null) {
            portCompleter.complete(int.parse(m.group(1)!));
          }
        }
      },
      onError: (e) {
        if (!portCompleter.isCompleted) portCompleter.completeError(e);
      },
    );
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      stderrBuf.writeln(line);
      if (line.isNotEmpty) debugPrint('[ecw:$tag:stderr] $line');
    });
    unawaited(proc.exitCode.then((code) {
      debugPrint('[ecw:$tag] process exited code=$code');
      if (!portCompleter.isCompleted) {
        portCompleter.completeError(
            EcwTileServerException('exited code=$code: $stderrBuf'));
      }
    }));

    final p = await portCompleter.future.timeout(timeout, onTimeout: () {
      proc.kill();
      throw EcwTileServerException(
          'startup timeout after ${timeout.inSeconds}s; stderr=$stderrBuf');
    });
    _port = p;
    return p;
  }

  Future<void> stop() async {
    final p = _proc;
    _proc = null;
    _port = null;
    if (p != null) {
      p.kill();
      await p.exitCode;
    }
  }
}

class EcwTileServerException implements Exception {
  final String message;
  EcwTileServerException(this.message);
  @override
  String toString() => 'EcwTileServerException: $message';
}
