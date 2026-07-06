import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

/// Win32 Job Object — מבטיח ש-subprocess (python.exe + multiprocessing workers)
/// ייהרגו אוטומטית כשתהליך האפליקציה נסגר. עובד גם בקרסה, גם ב-Task Manager
/// kill, וגם בכיבוי לא נקי — כי Windows סוגר את ה-handle ל-job ברגע שה-process
/// מת, וזה מפעיל kill-on-close.
///
/// מנגנון: `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` (0x2000) — כשה-handle האחרון
/// ל-job נסגר, המערכת הורגת את כל התהליכים ששויכו אליו, כולל ילדים שנוצרו
/// אחרי השיוך (כי השיוך נורש דרך עץ ה-process).
///
/// תמיכת nested jobs מאז Windows 8 — עובד גם כשהאפליקציה כבר מצורפת ל-job
/// חיצוני (למשל מ-`flutter run` / VS Code).
///
/// win32 5.15.0 לא מייצא את ה-struct `JOBOBJECT_EXTENDED_LIMIT_INFORMATION`
/// ולא את הקבועים הרלוונטיים, ולכן הם מוגדרים כאן ידנית.
class WindowsJobObject {
  static final WindowsJobObject _instance = WindowsJobObject._();
  factory WindowsJobObject() => _instance;
  WindowsJobObject._();

  // JOBOBJECTINFOCLASS.JobObjectExtendedLimitInformation
  static const int _jobObjectExtendedLimitInformation = 9;
  // JOBOBJECT_BASIC_LIMIT_INFORMATION.LimitFlags bit
  static const int _jobObjectLimitKillOnJobClose = 0x2000;

  int? _hJob;
  bool _initialized = false;

  void _ensureInit() {
    if (_initialized) return;
    _initialized = true;
    if (!Platform.isWindows) return;

    final job = CreateJobObject(nullptr, nullptr);
    if (job == 0) {
      debugPrint('WindowsJobObject: CreateJobObject failed');
      return;
    }

    final info = calloc<_JobObjectExtendedLimitInformation>();
    try {
      info.ref.BasicLimitInformation.LimitFlags =
          _jobObjectLimitKillOnJobClose;
      final ok = SetInformationJobObject(
        job,
        _jobObjectExtendedLimitInformation,
        info.cast(),
        sizeOf<_JobObjectExtendedLimitInformation>(),
      );
      if (ok == 0) {
        debugPrint('WindowsJobObject: SetInformationJobObject failed');
        CloseHandle(job);
        return;
      }
      _hJob = job;
      // לא סוגרים את ה-handle בכוונה — נשאר פתוח עד שהאפליקציה מתה,
      // ואז Windows סוגרת אותו אוטומטית ומפעילה את kill-on-close.
    } finally {
      calloc.free(info);
    }
  }

  /// משייך תהליך (לפי PID) ל-job. תהליכי ילדים שנוצרים מהתהליך הזה (כולל
  /// `multiprocessing.spawn` workers ב-Python) יורשים את השיוך אוטומטית.
  ///
  /// מחזיר `true` אם הצליח. מחזיר `false` ב-non-Windows, או אם יצירת ה-job
  /// נכשלה, או אם השיוך עצמו נכשל.
  bool attach(int pid) {
    _ensureInit();
    final job = _hJob;
    if (job == null) return false;

    final hProc = OpenProcess(
      PROCESS_TERMINATE | PROCESS_SET_QUOTA,
      FALSE,
      pid,
    );
    if (hProc == 0) {
      debugPrint('WindowsJobObject: OpenProcess($pid) failed');
      return false;
    }

    try {
      final ok = AssignProcessToJobObject(job, hProc);
      if (ok == 0) {
        debugPrint('WindowsJobObject: AssignProcessToJobObject($pid) failed');
        return false;
      }
      return true;
    } finally {
      CloseHandle(hProc);
    }
  }
}

// ═══ FFI struct definitions (לא מיוצאים ע"י win32 5.15.0) ═══

// ignore_for_file: non_constant_identifier_names, camel_case_types

final class _JobObjectBasicLimitInformation extends Struct {
  @Int64()
  external int PerProcessUserTimeLimit;
  @Int64()
  external int PerJobUserTimeLimit;
  @Uint32()
  external int LimitFlags;
  // Dart FFI מוסיף 4 בייטים padding כאן אוטומטית ב-x64 (יישור ל-IntPtr)
  @IntPtr()
  external int MinimumWorkingSetSize;
  @IntPtr()
  external int MaximumWorkingSetSize;
  @Uint32()
  external int ActiveProcessLimit;
  // Dart FFI מוסיף 4 בייטים padding כאן ב-x64
  @IntPtr()
  external int Affinity;
  @Uint32()
  external int PriorityClass;
  @Uint32()
  external int SchedulingClass;
}

final class _IoCounters extends Struct {
  @Uint64()
  external int ReadOperationCount;
  @Uint64()
  external int WriteOperationCount;
  @Uint64()
  external int OtherOperationCount;
  @Uint64()
  external int ReadTransferCount;
  @Uint64()
  external int WriteTransferCount;
  @Uint64()
  external int OtherTransferCount;
}

final class _JobObjectExtendedLimitInformation extends Struct {
  external _JobObjectBasicLimitInformation BasicLimitInformation;
  external _IoCounters IoInfo;
  @IntPtr()
  external int ProcessMemoryLimit;
  @IntPtr()
  external int JobMemoryLimit;
  @IntPtr()
  external int PeakProcessMemoryUsed;
  @IntPtr()
  external int PeakJobMemoryUsed;
}
