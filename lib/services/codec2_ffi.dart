// Codec2 FFI binding.
//
// Originally part of MeshCore Open (MIT, removed upstream in baf92ef) and
// restored for MeshCore Open TAK, now parameterised by mode and with Linux
// support. Codec2 itself is LGPL-2.1 and is built as a separate shared
// library from third_party/codec2 (Android: libcodec2.so via CMake, iOS: the
// codec2 pod, Linux: the system libcodec2).

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

class Codec2Ffi {
  Codec2Ffi._(DynamicLibrary lib)
    : _create = lib.lookupFunction<_CreateC, _CreateD>('codec2_create'),
      _destroy = lib.lookupFunction<_DestroyC, _DestroyD>('codec2_destroy'),
      _encode = lib.lookupFunction<_EncodeC, _EncodeD>('codec2_encode'),
      _decode = lib.lookupFunction<_DecodeC, _DecodeD>('codec2_decode'),
      _samplesPerFrame = lib.lookupFunction<_IntOfC, _IntOfD>(
        'codec2_samples_per_frame',
      ),
      _bytesPerFrame = lib.lookupFunction<_IntOfC, _IntOfD>(
        'codec2_bytes_per_frame',
      );

  static Codec2Ffi? _instance;
  static Object? _loadError;

  /// Null when Codec2 cannot be loaded on this platform/build.
  static Codec2Ffi? get instanceOrNull {
    if (_instance != null || _loadError != null) return _instance;
    try {
      _instance = Codec2Ffi._(_openLibrary());
    } catch (e) {
      _loadError = e;
    }
    return _instance;
  }

  static bool get isAvailable => instanceOrNull != null;
  static Object? get loadError => _loadError;

  final _CreateD _create;
  final _DestroyD _destroy;
  final _EncodeD _encode;
  final _DecodeD _decode;
  final _IntOfD _samplesPerFrame;
  final _IntOfD _bytesPerFrame;

  /// [codec2Mode] is a CODEC2_MODE_* value from codec2.h.
  Codec2Session createSession(int codec2Mode) {
    final handle = _create(codec2Mode);
    if (handle == nullptr) {
      throw StateError('codec2_create($codec2Mode) returned null');
    }
    return Codec2Session._(this, handle);
  }

  static DynamicLibrary _openLibrary() {
    if (Platform.isAndroid) return DynamicLibrary.open('libcodec2.so');
    if (Platform.isIOS || Platform.isMacOS) return DynamicLibrary.process();
    if (Platform.isLinux) {
      for (final name in const [
        'libcodec2.so',
        'libcodec2.so.1.2',
        'libcodec2.so.1.1',
        'libcodec2.so.1.0',
      ]) {
        try {
          return DynamicLibrary.open(name);
        } catch (_) {}
      }
      throw UnsupportedError('libcodec2 not found (install codec2)');
    }
    throw UnsupportedError('Codec2 is not available on this platform');
  }
}

class Codec2Session {
  Codec2Session._(this._ffi, this._handle)
    : samplesPerFrame = _ffi._samplesPerFrame(_handle),
      bytesPerFrame = _ffi._bytesPerFrame(_handle);

  final Codec2Ffi _ffi;
  final Pointer<Void> _handle;
  final int samplesPerFrame;
  final int bytesPerFrame;
  bool _disposed = false;

  /// Encodes PCM16 mono 8 kHz audio. The tail is zero-padded to a frame.
  Uint8List encode(Int16List pcm) {
    final frames = (pcm.length + samplesPerFrame - 1) ~/ samplesPerFrame;
    final out = Uint8List(frames * bytesPerFrame);
    final pcmIn = calloc<Int16>(samplesPerFrame);
    final bitsOut = calloc<Uint8>(bytesPerFrame);
    try {
      final inView = pcmIn.asTypedList(samplesPerFrame);
      final outView = bitsOut.asTypedList(bytesPerFrame);
      for (var f = 0; f < frames; f++) {
        final start = f * samplesPerFrame;
        final end = (start + samplesPerFrame).clamp(0, pcm.length);
        inView.fillRange(0, samplesPerFrame, 0);
        inView.setRange(0, end - start, pcm, start);
        _ffi._encode(_handle, bitsOut, pcmIn);
        out.setRange(f * bytesPerFrame, (f + 1) * bytesPerFrame, outView);
      }
    } finally {
      calloc.free(pcmIn);
      calloc.free(bitsOut);
    }
    return out;
  }

  /// Decodes a Codec2 bitstream; a trailing partial frame is dropped.
  Int16List decode(Uint8List bits) {
    final frames = bits.length ~/ bytesPerFrame;
    final out = Int16List(frames * samplesPerFrame);
    final bitsIn = calloc<Uint8>(bytesPerFrame);
    final pcmOut = calloc<Int16>(samplesPerFrame);
    try {
      final inView = bitsIn.asTypedList(bytesPerFrame);
      final outView = pcmOut.asTypedList(samplesPerFrame);
      for (var f = 0; f < frames; f++) {
        inView.setRange(0, bytesPerFrame, bits, f * bytesPerFrame);
        _ffi._decode(_handle, pcmOut, bitsIn);
        out.setRange(f * samplesPerFrame, (f + 1) * samplesPerFrame, outView);
      }
    } finally {
      calloc.free(bitsIn);
      calloc.free(pcmOut);
    }
    return out;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _ffi._destroy(_handle);
  }
}

typedef _CreateC = Pointer<Void> Function(Int32 mode);
typedef _CreateD = Pointer<Void> Function(int mode);
typedef _DestroyC = Void Function(Pointer<Void>);
typedef _DestroyD = void Function(Pointer<Void>);
typedef _EncodeC = Void Function(Pointer<Void>, Pointer<Uint8>, Pointer<Int16>);
typedef _EncodeD = void Function(Pointer<Void>, Pointer<Uint8>, Pointer<Int16>);
typedef _DecodeC = Void Function(Pointer<Void>, Pointer<Int16>, Pointer<Uint8>);
typedef _DecodeD = void Function(Pointer<Void>, Pointer<Int16>, Pointer<Uint8>);
typedef _IntOfC = Int32 Function(Pointer<Void>);
typedef _IntOfD = int Function(Pointer<Void>);
