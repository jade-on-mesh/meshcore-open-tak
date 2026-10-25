// MeshCore Open TAK - ggwave (data over sound, MIT) through FFI.
//
// third_party/ggwave, built as libggwave.so (Android, Linux bundle),
// libggwave.dll (next to the Windows exe) or a pod (iOS/macOS, in the
// process). Text up to 140 bytes becomes a few seconds of tones and back.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// ggwave's transmission protocols (ggwave_ProtocolId).
enum GgwaveProtocol {
  audibleNormal(0),
  audibleFast(1),
  audibleFastest(2),
  ultrasoundNormal(3),
  ultrasoundFast(4),
  ultrasoundFastest(5);

  const GgwaveProtocol(this.id);
  final int id;
  bool get ultrasound => id >= 3;
}

/// ggwave_Parameters.
final class _Params extends Struct {
  @Int32()
  external int payloadLength;
  @Float()
  external double sampleRateInp;
  @Float()
  external double sampleRateOut;
  @Float()
  external double sampleRate;
  @Int32()
  external int samplesPerFrame;
  @Float()
  external double soundMarkerThreshold;
  @Int32()
  external int sampleFormatInp;
  @Int32()
  external int sampleFormatOut;
  @Int32()
  external int operatingMode;
}

const int _formatI16 = 4; // GGWAVE_SAMPLE_FORMAT_I16
const int _modeRx = 1 << 1;
const int _modeTx = 1 << 2;

typedef _DefaultsC = _Params Function();
typedef _InitC = Int32 Function(_Params);
typedef _InitD = int Function(_Params);
typedef _FreeC = Void Function(Int32);
typedef _FreeD = void Function(int);
typedef _EncodeC =
    Int32 Function(
      Int32,
      Pointer<Uint8>,
      Int32,
      Int32,
      Int32,
      Pointer<Void>,
      Int32,
    );
typedef _EncodeD =
    int Function(int, Pointer<Uint8>, int, int, int, Pointer<Void>, int);
typedef _DecodeC =
    Int32 Function(Int32, Pointer<Void>, Int32, Pointer<Uint8>, Int32);
typedef _DecodeD = int Function(int, Pointer<Void>, int, Pointer<Uint8>, int);
typedef _LogC = Void Function(Pointer<Void>);
typedef _LogD = void Function(Pointer<Void>);

class Ggwave {
  Ggwave._(DynamicLibrary lib)
    : _defaults = lib.lookupFunction<_DefaultsC, _DefaultsC>(
        'ggwave_getDefaultParameters',
      ),
      _init = lib.lookupFunction<_InitC, _InitD>('ggwave_init'),
      _free = lib.lookupFunction<_FreeC, _FreeD>('ggwave_free'),
      _encode = lib.lookupFunction<_EncodeC, _EncodeD>('ggwave_encode'),
      _decode = lib.lookupFunction<_DecodeC, _DecodeD>('ggwave_ndecode') {
    // Quiet: ggwave logs every frame it decodes to stderr otherwise.
    lib.lookupFunction<_LogC, _LogD>('ggwave_setLogFile')(nullptr);
  }

  final _DefaultsC _defaults;
  final _InitD _init;
  final _FreeD _free;
  final _EncodeD _encode;
  final _DecodeD _decode;

  static Ggwave? _instance;
  static Object? _loadError;

  /// The library, or null where this build doesn't have it.
  static Ggwave? get instanceOrNull {
    if (_instance != null || _loadError != null) return _instance;
    try {
      _instance = Ggwave._(_open());
    } catch (e) {
      _loadError = e;
    }
    return _instance;
  }

  static bool get isAvailable => instanceOrNull != null;

  static DynamicLibrary _open() {
    if (Platform.isAndroid) return DynamicLibrary.open('libggwave.so');
    if (Platform.isIOS || Platform.isMacOS) return DynamicLibrary.process();
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    if (Platform.isWindows) {
      for (final n in ['$exeDir\\libggwave.dll', 'libggwave.dll']) {
        try {
          return DynamicLibrary.open(n);
        } catch (_) {}
      }
    }
    if (Platform.isLinux) {
      for (final n in ['$exeDir/lib/libggwave.so', 'libggwave.so']) {
        try {
          return DynamicLibrary.open(n);
        } catch (_) {}
      }
    }
    throw UnsupportedError('libggwave not found');
  }

  /// 48 kHz mono PCM for [payload] (at most 140 bytes), [volume] 1..100.
  Int16List encode(
    Uint8List payload, {
    GgwaveProtocol protocol = GgwaveProtocol.audibleFast,
    int volume = 50,
    int sampleRate = 48000,
  }) {
    if (payload.isEmpty || payload.length > 140) {
      throw ArgumentError('ggwave carries 1..140 bytes');
    }
    final p = _defaults()
      ..sampleRateOut = sampleRate.toDouble()
      ..sampleFormatOut = _formatI16
      ..operatingMode = _modeTx;
    final id = _init(p);
    if (id < 0) throw StateError('ggwave_init failed');
    final data = calloc<Uint8>(payload.length);
    try {
      data.asTypedList(payload.length).setAll(0, payload);
      final bytes = _encode(
        id,
        data,
        payload.length,
        protocol.id,
        volume,
        nullptr,
        1,
      );
      if (bytes <= 0) throw StateError('ggwave_encode failed');
      final out = calloc<Uint8>(bytes);
      try {
        final n = _encode(
          id,
          data,
          payload.length,
          protocol.id,
          volume,
          out.cast(),
          0,
        );
        if (n <= 0) throw StateError('ggwave_encode failed');
        return Int16List.fromList(out.cast<Int16>().asTypedList(n ~/ 2));
      } finally {
        calloc.free(out);
      }
    } finally {
      calloc.free(data);
      _free(id);
    }
  }

  /// A receiver for [sampleRate] mono 16-bit PCM.
  GgwaveReceiver receiver({int sampleRate = 48000}) {
    final p = _defaults()
      ..sampleRateInp = sampleRate.toDouble()
      ..sampleFormatInp = _formatI16
      ..operatingMode = _modeRx;
    final id = _init(p);
    if (id < 0) throw StateError('ggwave_init failed');
    return GgwaveReceiver._(this, id);
  }
}

/// Feeds captured audio to ggwave and yields what it hears. ggwave loses a
/// partial frame when it isn't resampling, so audio goes in in whole blocks
/// of 1024 samples (one frame at 48 kHz).
class GgwaveReceiver {
  GgwaveReceiver._(this._g, this._id);

  static const int _block = 1024;
  final Ggwave _g;
  final int _id;
  final Pointer<Int16> _buf = calloc<Int16>(_block);
  final Pointer<Uint8> _out = calloc<Uint8>(256);
  int _have = 0;
  bool _closed = false;

  /// Adds [pcm]; returns every payload decoded on the way.
  List<Uint8List> add(Int16List pcm) {
    final got = <Uint8List>[];
    if (_closed) return got;
    var i = 0;
    while (i < pcm.length) {
      final n = (pcm.length - i).clamp(0, _block - _have);
      _buf.asTypedList(_block).setRange(_have, _have + n, pcm, i);
      _have += n;
      i += n;
      if (_have == _block) {
        _have = 0;
        final r = _g._decode(_id, _buf.cast(), _block * 2, _out, 256);
        if (r > 0) got.add(Uint8List.fromList(_out.asTypedList(r)));
      }
    }
    return got;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _g._free(_id);
    calloc.free(_buf);
    calloc.free(_out);
  }
}
