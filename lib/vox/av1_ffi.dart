// MeshCore Open TAK - dart:ffi binding for libvox_av1.so (AV1 still images
// on libaom, see android/app/src/main/cpp/vox_av1.c). Android only.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _EncodeC =
    Int32 Function(
      Pointer<Uint8> rgb,
      Int32 w,
      Int32 h,
      Int32 q,
      Int32 speed,
      Int32 threads,
      Pointer<Uint8> out,
      Int32 outCap,
    );
typedef _EncodeD =
    int Function(
      Pointer<Uint8> rgb,
      int w,
      int h,
      int q,
      int speed,
      int threads,
      Pointer<Uint8> out,
      int outCap,
    );
typedef _DecodeC =
    Int32 Function(
      Pointer<Uint8> data,
      Int32 len,
      Pointer<Uint8> rgbOut,
      Int32 maxW,
      Int32 maxH,
      Pointer<Int32> wOut,
      Pointer<Int32> hOut,
    );
typedef _DecodeD =
    int Function(
      Pointer<Uint8> data,
      int len,
      Pointer<Uint8> rgbOut,
      int maxW,
      int maxH,
      Pointer<Int32> wOut,
      Pointer<Int32> hOut,
    );

/// An RGB888 picture.
class VoxRgbImage {
  final int width;
  final int height;
  final Uint8List rgb; // width * height * 3
  const VoxRgbImage(this.width, this.height, this.rgb);
}

class VoxAv1 {
  VoxAv1._(DynamicLibrary lib)
    : _encode = lib.lookupFunction<_EncodeC, _EncodeD>('vox_av1_encode'),
      _decode = lib.lookupFunction<_DecodeC, _DecodeD>('vox_av1_decode');

  final _EncodeD _encode;
  final _DecodeD _decode;

  static VoxAv1? _instance;
  static Object? _loadError;

  /// Null when the native library isn't in this build. Safe to call from any
  /// isolate (each isolate opens its own handle).
  static VoxAv1? get instanceOrNull {
    if (_instance != null || _loadError != null) return _instance;
    try {
      _instance = VoxAv1._(_open());
    } catch (e) {
      _loadError = e;
    }
    return _instance;
  }

  // Android: in the APK. macOS: the vox_av1 pod, in the process (a build
  // without libaom has a stub, and the lookup fails). Windows: vox_av1.dll
  // next to the exe; Linux: the bundle's lib/ (.github/workflows/build.yml).
  static DynamicLibrary _open() {
    if (Platform.isAndroid) return DynamicLibrary.open('libvox_av1.so');
    if (Platform.isMacOS || Platform.isIOS) return DynamicLibrary.process();
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final names = Platform.isWindows
        ? ['$exeDir\\vox_av1.dll', 'vox_av1.dll']
        : Platform.isLinux
        ? ['$exeDir/lib/libvox_av1.so', 'libvox_av1.so']
        : const <String>[];
    for (final n in names) {
      try {
        return DynamicLibrary.open(n);
      } catch (_) {}
    }
    throw UnsupportedError('Photo messages are not in this build');
  }

  static bool get isAvailable => instanceOrNull != null;
  static Object? get loadError => _loadError;

  /// Encodes [img] at quantizer [q] (0 best .. 63 smallest). Returns the AV1
  /// OBUs, or null on failure.
  Uint8List? encode(VoxRgbImage img, int q, {int speed = 6, int threads = 2}) {
    final n = img.rgb.length;
    final rgb = calloc<Uint8>(n);
    var cap = 16384;
    var out = calloc<Uint8>(cap);
    try {
      rgb.asTypedList(n).setAll(0, img.rgb);
      var r = _encode(rgb, img.width, img.height, q, speed, threads, out, cap);
      if (r < 0) {
        calloc.free(out);
        cap = -r;
        out = calloc<Uint8>(cap);
        r = _encode(rgb, img.width, img.height, q, speed, threads, out, cap);
      }
      if (r <= 0) return null;
      return Uint8List.fromList(out.asTypedList(r));
    } finally {
      calloc.free(rgb);
      calloc.free(out);
    }
  }

  /// Decodes OBUs from [encode]. Null if they don't decode.
  VoxRgbImage? decode(Uint8List obus, {int maxSide = 4096}) {
    final data = calloc<Uint8>(obus.length);
    final wOut = calloc<Int32>();
    final hOut = calloc<Int32>();
    Pointer<Uint8> rgb = nullptr;
    try {
      data.asTypedList(obus.length).setAll(0, obus);
      // First call with no buffer just reports the size.
      final probe = _decode(data, obus.length, nullptr, 0, 0, wOut, hOut);
      if (probe != -1) return null;
      final w = wOut.value, h = hOut.value;
      if (w < 1 || h < 1 || w > maxSide || h > maxSide) return null;
      rgb = calloc<Uint8>(w * h * 3);
      final r = _decode(data, obus.length, rgb, w, h, wOut, hOut);
      if (r != 1) return null;
      return VoxRgbImage(w, h, Uint8List.fromList(rgb.asTypedList(w * h * 3)));
    } finally {
      calloc.free(data);
      calloc.free(wOut);
      calloc.free(hOut);
      if (rgb != nullptr) calloc.free(rgb);
    }
  }
}
