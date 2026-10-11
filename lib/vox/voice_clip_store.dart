// MeshCore Open TAK - on-disk cache of complete Codec2 clips, keyed by
// session id, so voice bubbles keep playing after an app restart.
export 'voice_clip_store_stub.dart'
    if (dart.library.io) 'voice_clip_store_io.dart';
