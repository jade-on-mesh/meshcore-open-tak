// MeshCore Open TAK - AI sketch HD's codec inside the iPhone app.
//
// iOS doesn't let an app start a program, so the codec program the other
// platforms run (aeic_hd_runner_io.dart) is linked into the iPhone app as a
// library (third_party/aeic_hd, built by tool/build_aeic_hd_ios.sh) and
// called here over FFI: aeic_hd_run(argc, argv, log) runs the program's main
// with its output in a log file, on a background isolate so the app stays
// responsive while it works for minutes.

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart' as pffi;

typedef _RunC =
    ffi.Int32 Function(
      ffi.Int32,
      ffi.Pointer<ffi.Pointer<pffi.Utf8>>,
      ffi.Pointer<pffi.Utf8>,
    );
typedef _RunDart =
    int Function(
      int,
      ffi.Pointer<ffi.Pointer<pffi.Utf8>>,
      ffi.Pointer<pffi.Utf8>,
    );

abstract final class AeicHdIos {
  /// This is the iPhone app and its build has the codec linked in.
  static final bool available = _probe();

  static bool _probe() {
    if (!Platform.isIOS) return false;
    try {
      return ffi.DynamicLibrary.process().providesSymbol('aeic_hd_run');
    } catch (_) {
      return false;
    }
  }

  /// The phone's RAM in bytes, or null when it can't be read.
  static int? totalMemory() {
    if (!available) return null;
    try {
      final f = ffi.DynamicLibrary.process()
          .lookupFunction<ffi.Uint64 Function(), int Function()>(
            'aeic_hd_total_memory',
          );
      final bytes = f();
      return bytes > 0 ? bytes : null;
    } catch (_) {
      return null;
    }
  }

  /// Keeps [path] (the model pack, which can be downloaded again) out of
  /// iCloud and device backups.
  static void excludeFromBackup(String path) {
    if (!Platform.isIOS) return;
    try {
      final f = ffi.DynamicLibrary.process()
          .lookupFunction<
            ffi.Int32 Function(ffi.Pointer<pffi.Utf8>),
            int Function(ffi.Pointer<pffi.Utf8>)
          >('aeic_hd_exclude_from_backup');
      final p = path.toNativeUtf8(allocator: pffi.calloc);
      try {
        f(p);
      } finally {
        pffi.calloc.free(p);
      }
    } catch (_) {}
  }

  /// Stops the running job at its next model stage.
  static void cancel() {
    if (!available) return;
    try {
      ffi.DynamicLibrary.process()
          .lookupFunction<ffi.Void Function(), void Function()>(
            'aeic_hd_cancel',
          )();
    } catch (_) {}
  }

  /// Runs the codec program with [args], its output written to [logPath].
  /// Returns its exit status (0 for success, 130 when cancelled).
  static Future<int> run(List<String> args, String logPath) =>
      Isolate.run(() => _runHere(args, logPath));

  static int _runHere(List<String> args, String logPath) {
    final run = ffi.DynamicLibrary.process().lookupFunction<_RunC, _RunDart>(
      'aeic_hd_run',
    );
    final all = ['aeic_decode', ...args];
    final argv = pffi.calloc<ffi.Pointer<pffi.Utf8>>(all.length + 1);
    final log = logPath.toNativeUtf8(allocator: pffi.calloc);
    try {
      for (var i = 0; i < all.length; i++) {
        argv[i] = all[i].toNativeUtf8(allocator: pffi.calloc);
      }
      return run(all.length, argv, log);
    } finally {
      for (var i = 0; i < all.length; i++) {
        if (argv[i] != ffi.nullptr) pffi.calloc.free(argv[i]);
      }
      pffi.calloc.free(argv);
      pffi.calloc.free(log);
    }
  }
}
