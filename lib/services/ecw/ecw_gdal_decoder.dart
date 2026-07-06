import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ─────────────────────────── FFI signatures ───────────────────────────
typedef _VersionNative = Pointer<Utf8> Function();
typedef _VersionDart = Pointer<Utf8> Function();
typedef _OpenNative = Pointer<Void> Function(Pointer<Utf8> path);
typedef _OpenDart = Pointer<Void> Function(Pointer<Utf8> path);
typedef _CloseNative = Void Function(Pointer<Void> h);
typedef _CloseDart = void Function(Pointer<Void> h);
typedef _IntFromHandleNative = Int32 Function(Pointer<Void> h);
typedef _IntFromHandleDart = int Function(Pointer<Void> h);
typedef _SrsNative = Pointer<Utf8> Function(Pointer<Void> h);
typedef _SrsDart = Pointer<Utf8> Function(Pointer<Void> h);

typedef _RenderNative = Int32 Function(
  Pointer<Void> h,
  Double minx,
  Double miny,
  Double maxx,
  Double maxy,
  Int32 size,
  Pointer<Pointer<Uint8>> outRgba,
);
typedef _RenderDart = int Function(
  Pointer<Void> h,
  double minx,
  double miny,
  double maxx,
  double maxy,
  int size,
  Pointer<Pointer<Uint8>> outRgba,
);

typedef _FreeNative = Void Function(Pointer<Uint8> p);
typedef _FreeDart = void Function(Pointer<Uint8> p);

/// פתיחת ספריית ה-ECW הנייטיב.
/// - Android: `libauto_maps_ecw.so` (GDAL+ECW prebuilt מ-jniLibs).
/// - iOS: ה-pod מקשר את ecw_wrapper.c + gdal_ecw.xcframework **סטטית** לתוך בינארי
///   האפליקציה, אז הסמלים נמצאים בתהליך עצמו → `DynamicLibrary.process()`.
/// - Windows/מחשב: משתמשים בנתיב Python/GDAL (EcwTileServer), לא בנתיב הזה.
DynamicLibrary _openEcwLibrary() {
  if (Platform.isAndroid) return DynamicLibrary.open('libauto_maps_ecw.so');
  if (Platform.isIOS) return DynamicLibrary.process();
  throw UnsupportedError(
      'ECW native decoder not built for ${Platform.operatingSystem}');
}

/// עטיפת FFI נמוכת-דרג סביב ה-wrapper הנייטיב. לא thread-safe — הכוונה היא
/// שמופע יחיד חי בתוך [EcwGdalService]'s isolate, וכל הקריאות מסודרות שם.
class EcwGdalNative {
  EcwGdalNative._(this._lib)
      : _version = _lib
            .lookupFunction<_VersionNative, _VersionDart>('ecw_gdal_version'),
        _open = _lib.lookupFunction<_OpenNative, _OpenDart>('ecw_open'),
        _close = _lib.lookupFunction<_CloseNative, _CloseDart>('ecw_close'),
        _width =
            _lib.lookupFunction<_IntFromHandleNative, _IntFromHandleDart>(
                'ecw_width'),
        _height =
            _lib.lookupFunction<_IntFromHandleNative, _IntFromHandleDart>(
                'ecw_height'),
        _srs = _lib.lookupFunction<_SrsNative, _SrsDart>('ecw_srs'),
        _render =
            _lib.lookupFunction<_RenderNative, _RenderDart>('ecw_render_tile'),
        _free = _lib.lookupFunction<_FreeNative, _FreeDart>('ecw_free');

  factory EcwGdalNative() => EcwGdalNative._(_openEcwLibrary());

  // ignore: unused_field
  final DynamicLibrary _lib;
  final _VersionDart _version;
  final _OpenDart _open;
  final _CloseDart _close;
  final _IntFromHandleDart _width;
  final _IntFromHandleDart _height;
  final _SrsDart _srs;
  final _RenderDart _render;
  final _FreeDart _free;

  String get gdalVersion => _version().toDartString();

  Pointer<Void> open(String path) {
    final p = path.toNativeUtf8();
    try {
      return _open(p);
    } finally {
      malloc.free(p);
    }
  }

  void close(Pointer<Void> h) => _close(h);
  int width(Pointer<Void> h) => _width(h);
  int height(Pointer<Void> h) => _height(h);
  String srs(Pointer<Void> h) => _srs(h).toDartString();

  /// מרנדר אריח בודד ל-RGBA8888 (size×size×4). מחזיר null על כישלון.
  Uint8List? renderTile(
    Pointer<Void> h,
    double minx,
    double miny,
    double maxx,
    double maxy,
    int size,
  ) {
    final outPtr = malloc<Pointer<Uint8>>();
    outPtr.value = nullptr;
    try {
      final rc = _render(h, minx, miny, maxx, maxy, size, outPtr);
      if (rc != 0) return null;
      final rgbaPtr = outPtr.value;
      if (rgbaPtr == nullptr) return null;
      try {
        final size4 = size * size * 4;
        return Uint8List.fromList(rgbaPtr.asTypedList(size4));
      } finally {
        _free(rgbaPtr);
      }
    } finally {
      malloc.free(outPtr);
    }
  }
}

// ───────────────────── isolate protocol messages ─────────────────────
class _OpenMsg {
  final String path;
  final SendPort reply;
  _OpenMsg(this.path, this.reply);
}

class _TileMsg {
  final int id;
  final double minx, miny, maxx, maxy;
  final int size;
  _TileMsg(this.id, this.minx, this.miny, this.maxx, this.maxy, this.size);
}

class _TileResult {
  final int id;
  final Uint8List? rgba;
  _TileResult(this.id, this.rgba);
}

class _OpenResult {
  final bool ok;
  final int width;
  final int height;
  final String srs;
  final String gdalVersion;
  final String? error;
  _OpenResult(this.ok, this.width, this.height, this.srs, this.gdalVersion,
      this.error);
}

/// שירות ECW מבוסס GDAL — מנהל pool של isolates שמחזיקים dataset פתוח ומרנדרים
/// אריחים על דרישה (warp ל-Web Mercator).
///
/// ⚠️ **`poolSize` חייב להישאר 1.** ה-ECW SDK (NCSEcw) **אינו thread-safe** —
/// ב-Dart isolates הם threads באותו process נייטיב וחולקים את ה-global state של
/// ה-SDK, אז ריבוי workers שמרנדרים warp במקביל גורם ל-segfault (אותה תופעה
/// שתועדה ב-Python: `gdal.Warp(multithread=True)` על ECW = segfault).
/// ה-Python sidecar עוקף זאת עם `multiprocessing` (תהליכים נפרדים, state נפרד),
/// אבל ל-Dart אין מקבילה זולה. לכן הרינדור serial (worker יחיד).
/// (התשתית נשארת pool כדי לאפשר עתיד מבוסס-process; אל תעלה את הברירת-מחדל.)
///
/// המחיר: אזור חדש (~16 אריחים × ~130ms) ≈ ~2ש'. הגלילה עצמה חלקה
/// (flutter_map מציג cache), והשיפור לחוויה חוזרת הוא דרך disk cache.
class EcwGdalService {
  EcwGdalService({this.poolSize = 1});

  final int poolSize;
  final List<Isolate> _isolates = [];
  final List<SendPort> _workers = [];
  final List<ReceivePort> _recvPorts = [];
  final _ready = Completer<bool>();
  int _rr = 0; // round-robin index

  int _nextId = 1;
  final _pending = <int, Completer<Uint8List?>>{};

  int width = 0;
  int height = 0;
  String srs = '';
  String gdalVersion = '';
  bool _opening = false;
  bool get isReady => _ready.isCompleted && _workers.isNotEmpty;

  /// פותח את ה-pool על קובץ ECW. מחזיר true אם לפחות worker אחד נפתח.
  Future<bool> open(String ecwPath) async {
    if (_opening) return _ready.future;
    _opening = true;

    final oks = await Future.wait(
        [for (var i = 0; i < poolSize; i++) _spawnWorker(ecwPath, i)]);
    final anyOk = oks.any((e) => e);
    if (!_ready.isCompleted) _ready.complete(anyOk);
    return anyOk;
  }

  Future<bool> _spawnWorker(String ecwPath, int idx) async {
    final recv = ReceivePort();
    _recvPorts.add(recv);
    final iso = await Isolate.spawn(_isolateEntry, recv.sendPort,
        debugName: 'ecw_gdal_$idx');
    _isolates.add(iso);

    final openReply = ReceivePort();
    final ready = Completer<bool>();
    recv.listen((msg) {
      if (msg is SendPort) {
        _workers.add(msg);
        msg.send(_OpenMsg(ecwPath, openReply.sendPort));
      } else if (msg is _TileResult) {
        _pending.remove(msg.id)?.complete(msg.rgba);
      }
    });
    unawaited(openReply.first.then((res) {
      if (res is _OpenResult && res.ok) {
        width = res.width;
        height = res.height;
        srs = res.srs;
        gdalVersion = res.gdalVersion;
        if (!ready.isCompleted) ready.complete(true);
      } else {
        if (!ready.isCompleted) ready.complete(false);
      }
      openReply.close();
    }));
    return ready.future;
  }

  /// מרנדר אריח. bbox ב-EPSG:3857 (Web Mercator meters). מחזיר RGBA או null.
  /// בוחר worker ב-round-robin כדי לפזר את עומס ה-warp.
  Future<Uint8List?> renderTile(
    double minx,
    double miny,
    double maxx,
    double maxy, {
    int size = 256,
  }) async {
    if (_workers.isEmpty) {
      final ok = await _ready.future;
      if (!ok || _workers.isEmpty) return null;
    }
    final id = _nextId++;
    final completer = Completer<Uint8List?>();
    _pending[id] = completer;
    final worker = _workers[_rr++ % _workers.length];
    worker.send(_TileMsg(id, minx, miny, maxx, maxy, size));
    return completer.future;
  }

  void dispose() {
    for (final w in _workers) {
      w.send('close');
    }
    for (final iso in _isolates) {
      iso.kill(priority: Isolate.beforeNextEvent);
    }
    _isolates.clear();
    _workers.clear();
    for (final r in _recvPorts) {
      r.close();
    }
    _recvPorts.clear();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _pending.clear();
  }

  // ─────────────────── isolate entry point ───────────────────
  static void _isolateEntry(SendPort toMain) {
    final port = ReceivePort();
    toMain.send(port.sendPort);

    EcwGdalNative? native;
    Pointer<Void> handle = nullptr;

    port.listen((msg) {
      if (msg is _OpenMsg) {
        try {
          native = EcwGdalNative();
          handle = native!.open(msg.path);
          if (handle == nullptr) {
            msg.reply.send(_OpenResult(false, 0, 0, '', '', 'GDALOpen failed'));
            return;
          }
          msg.reply.send(_OpenResult(
            true,
            native!.width(handle),
            native!.height(handle),
            native!.srs(handle),
            native!.gdalVersion,
            null,
          ));
        } catch (e) {
          msg.reply.send(_OpenResult(false, 0, 0, '', '', e.toString()));
        }
      } else if (msg is _TileMsg) {
        Uint8List? rgba;
        if (native != null && handle != nullptr) {
          rgba = native!.renderTile(
              handle, msg.minx, msg.miny, msg.maxx, msg.maxy, msg.size);
        }
        toMain.send(_TileResult(msg.id, rgba));
      } else if (msg == 'close') {
        if (native != null && handle != nullptr) native!.close(handle);
        handle = nullptr;
        port.close();
      }
    });
  }
}
