import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

/// The sound of a 2400 bps modem (V.22bis) for video arriving over the mesh:
/// the connect handshake when a video's first packet comes in, then a burst of
/// data for each packet after it. Off unless chosen (Settings > voice and
/// photos: "Modem sounds for incoming video").
///
/// The data bursts are the packets' own bytes, sent the way a V.22bis modem
/// would: scrambled (x^-14 + x^-17, as the standard's self-synchronising
/// scrambler), four bits a symbol as 16-QAM, 600 symbols a second on the
/// answering modem's 2400 Hz carrier, with the calling modem's idle carrier
/// (scrambled ones) at 1200 Hz beneath it, as on a real two-way line.
class VoxModemSound {
  VoxModemSound._();

  static const int sampleRate = 16000;
  static const int baud = 600;

  /// The longest burst one packet makes, so a burst is a burst and the gaps
  /// between packets stay audible: 0.45 s (the first 135 bytes).
  static const Duration maxBurst = Duration(milliseconds: 450);

  /// The connect sequence: the answer tone, then the unscrambled ones each way
  /// (the warble), then both together. About 3.4 s.
  static Int16List handshake() {
    final out = <double>[];
    _tone(out, 2100, 1.6, 0.32);
    _silence(out, 0.08);
    _qam(out, _fixedSymbols(360), 1200, 0.30);
    _qam(out, _fixedSymbols(360), 2400, 0.30);
    final both = <double>[];
    _qam(both, _fixedSymbols(300), 1200, 0.22);
    final other = <double>[];
    _qam(other, _fixedSymbols(300, phase: 1), 2400, 0.22);
    for (var i = 0; i < both.length && i < other.length; i++) {
      out.add(both[i] + other[i]);
    }
    return _finish(out);
  }

  /// One packet's data: [bytes] on the 2400 Hz carrier (at most [maxBurst]),
  /// the other side's idle carrier under it.
  static Int16List burst(Uint8List bytes) {
    final maxSymbols = maxBurst.inMilliseconds * baud ~/ 1000;
    final symbols = _dataSymbols(bytes, maxSymbols);
    if (symbols.isEmpty) return Int16List(0);
    final data = <double>[];
    _qam(data, symbols, 2400, 0.30);
    // The other side has nothing to send: scrambled ones.
    final ones = Uint8List.fromList(List.filled(symbols.length ~/ 2 + 1, 0xFF));
    final idle = <double>[];
    _qam(idle, _dataSymbols(ones, symbols.length), 1200, 0.16);
    final n = min(data.length, idle.length);
    return _finish([for (var i = 0; i < n; i++) data[i] + idle[i]]);
  }

  /// [samples] as a 16-bit mono WAV file.
  static Uint8List wav(Int16List samples) {
    final data = ByteData(44 + samples.length * 2);
    void str(int at, String s) {
      for (var i = 0; i < s.length; i++) {
        data.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    data.setUint32(4, 36 + samples.length * 2, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, sampleRate, Endian.little);
    data.setUint32(28, sampleRate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    str(36, 'data');
    data.setUint32(40, samples.length * 2, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      data.setInt16(44 + i * 2, samples[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }

  static Duration durationOf(Int16List samples) =>
      Duration(microseconds: samples.length * 1000000 ~/ sampleRate);

  // ---- signal pieces ---------------------------------------------------------

  static const List<double> _levels = [-3, -1, 1, 3];

  /// Four bits a symbol, after V.22bis's scrambler (1 + x^-14 + x^-17), so any
  /// data sounds like a modem's hiss and not a pattern. (I, Q) pairs.
  static List<(double, double)> _dataSymbols(Uint8List bytes, int maxSymbols) {
    final out = <(double, double)>[];
    // The last 17 scrambled bits. Not zero: by the time data flows the
    // scrambler has been running through the handshake (and from all zeros it
    // would turn zeros into zeros: a steady tone).
    var reg = 0x1B5A3;
    var nibble = 0, nb = 0;
    for (final byte in bytes) {
      for (var b = 0; b < 8; b++) {
        final bit = (byte >> b) & 1;
        final s = bit ^ ((reg >> 13) & 1) ^ ((reg >> 16) & 1);
        reg = ((reg << 1) | s) & 0x1FFFF;
        nibble |= s << nb;
        if (++nb == 4) {
          out.add((_levels[nibble & 3], _levels[nibble >> 2]));
          if (out.length >= maxSymbols) return out;
          nibble = 0;
          nb = 0;
        }
      }
    }
    return out;
  }

  /// Unscrambled ones: the same point over and over, turning a quarter each
  /// symbol (V.22bis's differential quadrant), which gives the handshake's
  /// steady warble.
  static List<(double, double)> _fixedSymbols(int n, {int phase = 0}) {
    const corners = [(3.0, 3.0), (-3.0, 3.0), (-3.0, -3.0), (3.0, -3.0)];
    return [for (var i = 0; i < n; i++) corners[(i + phase) % 4]];
  }

  /// [symbols] at [baud] on carrier [fc], each eased into the next (a raised
  /// cosine), appended to [out].
  static void _qam(
    List<double> out,
    List<(double, double)> symbols,
    double fc,
    double amp,
  ) {
    if (symbols.isEmpty) return;
    final total = (symbols.length * sampleRate / baud).round();
    final start = out.length;
    for (var n = 0; n < total; n++) {
      final pos = n * baud / sampleRate; // in symbols
      final k = pos.floor().clamp(0, symbols.length - 1);
      final next = min(k + 1, symbols.length - 1);
      final frac = pos - pos.floor();
      // Hold most of the symbol, ease over its last third.
      final t = frac < 2 / 3 ? 0.0 : (1 - cos(pi * (frac - 2 / 3) * 3)) / 2;
      final i = symbols[k].$1 * (1 - t) + symbols[next].$1 * t;
      final q = symbols[k].$2 * (1 - t) + symbols[next].$2 * t;
      final w = 2 * pi * fc * n / sampleRate;
      out.add(amp * (i * cos(w) - q * sin(w)) / 4.25);
    }
    _fade(out, start, out.length);
  }

  static void _tone(List<double> out, double f, double secs, double amp) {
    final start = out.length;
    final n = (secs * sampleRate).round();
    for (var i = 0; i < n; i++) {
      out.add(amp * sin(2 * pi * f * i / sampleRate));
    }
    _fade(out, start, out.length);
  }

  static void _silence(List<double> out, double secs) {
    for (var i = 0, n = (secs * sampleRate).round(); i < n; i++) {
      out.add(0);
    }
  }

  /// A few ms in and out, so nothing clicks.
  static void _fade(List<double> out, int from, int to) {
    final n = min(sampleRate * 6 ~/ 1000, (to - from) ~/ 2);
    for (var i = 0; i < n; i++) {
      final g = i / n;
      out[from + i] *= g;
      out[to - 1 - i] *= g;
    }
  }

  /// To 16-bit samples, with a phone line's faint hiss.
  static Int16List _finish(List<double> x) {
    final rng = Random(2400);
    return Int16List.fromList([
      for (final v in x)
        ((v + (rng.nextDouble() - 0.5) * 0.008).clamp(-1.0, 1.0) * 32767)
            .round(),
    ]);
  }
}

/// Plays [VoxModemSound] as video packets arrive: the handshake on a video's
/// first packet, then a burst a packet, one after another. Never lags behind
/// the radio: a burst that would start more than [maxBacklog] late is
/// dropped.
class VoxModemPlayer {
  /// Plays one WAV (it isn't awaited to the end: the player times it).
  final Future<void> Function(Uint8List wav) play;
  final Duration maxBacklog;

  /// Runs a callback after a while (a Timer; tests pass their own clock).
  final Timer Function(Duration, void Function()) after;

  VoxModemPlayer({
    required this.play,
    this.maxBacklog = const Duration(seconds: 2),
    this.after = Timer.new,
  });

  final Set<String> _greeted = {};
  final List<Int16List> _queue = [];
  Duration _queued = Duration.zero;
  bool _busy = false;
  Timer? _timer;

  /// Videos that had their handshake (the latest few).
  int get greetedCount => _greeted.length;

  /// A new packet of video [sid] with [data] arrived.
  void onVideoPacket(String sid, Uint8List data) {
    if (_greeted.add(sid)) {
      if (_greeted.length > 32) _greeted.remove(_greeted.first);
      _enqueue(VoxModemSound.handshake(), always: true);
    }
    _enqueue(VoxModemSound.burst(data));
    _pump();
  }

  void _enqueue(Int16List s, {bool always = false}) {
    if (s.isEmpty) return;
    if (!always && _queued > maxBacklog) return;
    _queue.add(s);
    _queued += VoxModemSound.durationOf(s);
  }

  void _pump() {
    if (_busy || _queue.isEmpty) return;
    // Everything waiting, as one sound: no gap between a handshake and the
    // burst after it.
    final total = _queue.fold<int>(0, (n, s) => n + s.length);
    final all = Int16List(total);
    var at = 0;
    for (final s in _queue) {
      all.setAll(at, s);
      at += s.length;
    }
    _queue.clear();
    _queued = Duration.zero;
    _busy = true;
    unawaited(play(VoxModemSound.wav(all)).catchError((_) {}));
    _timer = after(VoxModemSound.durationOf(all), () {
      _busy = false;
      _pump();
    });
  }

  /// Stops waiting sounds (the toggle went off).
  void clear() {
    _queue.clear();
    _queued = Duration.zero;
    _timer?.cancel();
    _busy = false;
  }
}
