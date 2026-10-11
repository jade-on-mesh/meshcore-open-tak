// MeshCore Open TAK - Codec2 entry point (native via FFI, unavailable on web).
export 'voice_codec_stub.dart' if (dart.library.ffi) 'voice_codec_ffi.dart';
