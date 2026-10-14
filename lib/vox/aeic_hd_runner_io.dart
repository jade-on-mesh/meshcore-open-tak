// MeshCore Open TAK - AEIC HD: model pack download and the codec program.
//
// The program is mikecarper/AEIC's `aeic_decode` (it also encodes), shipped
// in the APK as libaeic_codec_exec.so (tool/build_aeic_hd_android.sh). Each
// job runs it once: it loads, runs and frees one model stage at a time, each
// stage in a child process of its own, and prints a line per stage, which is
// where the progress figure comes from.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data' show Endian;

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class AeicHdDownloadCancelled implements Exception {
  const AeicHdDownloadCancelled();
  @override
  String toString() => 'Download cancelled.';
}

class AeicHdJobCancelled implements Exception {
  const AeicHdJobCancelled();
  @override
  String toString() => 'Cancelled.';
}

class _PackFile {
  final String name;
  final String asset;
  final int size;
  final String sha256;
  const _PackFile(this.name, this.asset, this.size, this.sha256);
}

class AeicHdRunner {
  static const _channel = MethodChannel('meshcore_open_tak/aeic_hd');
  static const _square = 512;

  final String baseUrl;
  AeicHdRunner(this.baseUrl);

  bool get supported => Platform.isAndroid;

  bool _cancelDownload = false;
  Process? _process;
  bool _cancelJob = false;

  Future<Directory> _packDir() async {
    final support = await getApplicationSupportDirectory();
    return Directory(
      '${support.path}/aeic_hd/${Uri.parse(baseUrl).pathSegments.where((s) => s.isNotEmpty).last}',
    );
  }

  Future<File> get _completeMarker async =>
      File('${(await _packDir()).path}/.complete');

  Future<int?> totalMemory() async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('memory');
      return (m?['total'] as num?)?.toInt();
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<bool> installed() async => (await _completeMarker).exists();

  Future<String> _program() async {
    final dir = await _channel.invokeMethod<String>('nativeLibraryDir');
    final path = '$dir/libaeic_codec_exec.so';
    if (dir == null || !File(path).existsSync()) {
      throw StateError(
        'This build of the app doesn\'t include the AI sketch HD codec.',
      );
    }
    return path;
  }

  // ---------------------------------------------------------------------------
  // Download
  // ---------------------------------------------------------------------------

  Future<void> install({
    required void Function(int bytes) onTotal,
    required void Function(double progress) onProgress,
  }) async {
    _cancelDownload = false;
    final dir = await _packDir();
    await dir.create(recursive: true);
    final client = http.Client();
    try {
      final manifestResponse = await client.get(
        Uri.parse('${baseUrl}manifest.json'),
      );
      if (manifestResponse.statusCode != 200) {
        throw HttpException('model list: HTTP ${manifestResponse.statusCode}');
      }
      final manifest =
          jsonDecode(utf8.decode(manifestResponse.bodyBytes))
              as Map<String, dynamic>;
      // Format 2: the files come bundled in tar archives (GitHub release
      // uploads are slow per file; see aeic-ncnn-publish.yml).
      final archives = [
        for (final a
            in (manifest['archives'] as List).cast<Map<String, dynamic>>())
          _PackFile(
            a['asset'] as String,
            a['asset'] as String,
            (a['size'] as num).toInt(),
            a['sha256'] as String,
          ),
      ];
      final wantFiles = {
        for (final f
            in (manifest['files'] as List).cast<Map<String, dynamic>>())
          // The program reads one flat directory (as mikecarper's
          // push_models.py lays it out), so just the file name.
          (f['path'] as String).split('/').last: (f['size'] as num).toInt(),
      };
      final total = archives.fold<int>(0, (a, f) => a + f.size);
      onTotal(total);

      // Archives already downloaded, checked and unpacked on an earlier try.
      final verifiedFile = File('${dir.path}/.verified');
      final verified = <String>{
        if (await verifiedFile.exists())
          ...(await verifiedFile.readAsLines()).where((l) => l.isNotEmpty),
      };
      var done = 0;
      for (final a in archives) {
        final key = '${a.name} ${a.sha256}';
        if (!verified.contains(key)) {
          final tar = File('${dir.path}/${a.name}');
          await _download(client, a, tar, (got) {
            onProgress((done + got) / total);
          });
          await _untar(tar, dir);
          await tar.delete();
          verified.add(key);
          await verifiedFile.writeAsString('${verified.join('\n')}\n');
        }
        done += a.size;
        onProgress(done / total);
      }
      for (final e in wantFiles.entries) {
        final f = File('${dir.path}/${e.key}');
        if (!await f.exists() || await f.length() != e.value) {
          await verifiedFile.delete();
          throw StateError('model file ${e.key} is missing; download again');
        }
      }
      await (await _completeMarker).writeAsString(
        manifest['checkpoint_sha256'] as String? ?? 'ok',
      );
    } finally {
      client.close();
    }
  }

  /// One file, resuming a partial `.part`, then checked against its SHA-256.
  Future<void> _download(
    http.Client client,
    _PackFile f,
    File target,
    void Function(int got) onBytes,
  ) async {
    final part = File('${target.path}.part');
    for (var attempt = 1; ; attempt++) {
      if (_cancelDownload) throw const AeicHdDownloadCancelled();
      var have = await part.exists() ? await part.length() : 0;
      if (have > f.size) {
        await part.delete();
        have = 0;
      }
      try {
        if (have < f.size) {
          final request = http.Request('GET', Uri.parse('$baseUrl${f.asset}'));
          if (have > 0) request.headers['Range'] = 'bytes=$have-';
          final response = await client.send(request);
          if (response.statusCode == 200 && have > 0) {
            have = 0; // server ignored the range: start over
          } else if (response.statusCode != 200 && response.statusCode != 206) {
            throw HttpException('${f.name}: HTTP ${response.statusCode}');
          }
          final sink = part.openWrite(
            mode: have > 0 ? FileMode.append : FileMode.write,
          );
          var got = have;
          try {
            await for (final chunk in response.stream) {
              if (_cancelDownload) throw const AeicHdDownloadCancelled();
              sink.add(chunk);
              got += chunk.length;
              onBytes(got);
            }
          } finally {
            await sink.close();
          }
        }
        final digest = await sha256.bind(part.openRead()).first;
        if (digest.toString() != f.sha256) {
          await part.delete();
          throw HttpException('${f.name}: download was corrupted');
        }
        await part.rename(target.path);
        return;
      } on AeicHdDownloadCancelled {
        rethrow;
      } catch (_) {
        if (attempt >= 4) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 * attempt));
      }
    }
  }

  void cancelDownload() => _cancelDownload = true;

  /// Unpacks a plain ustar archive (what Python's tarfile writes with
  /// USTAR_FORMAT) into [dir], flat: file names only, never a path.
  static Future<void> _untar(File tar, Directory dir) async {
    final raf = await tar.open();
    try {
      final length = await raf.length();
      var pos = 0;
      while (pos + 512 <= length) {
        await raf.setPosition(pos);
        final header = await raf.read(512);
        if (header.every((b) => b == 0)) break;
        String field(int from, int len) {
          var end = from;
          while (end < from + len && header[end] != 0) {
            end++;
          }
          return ascii.decode(header.sublist(from, end), allowInvalid: true);
        }

        final name = field(0, 100).split('/').last;
        final size = int.parse(field(124, 12).trim().isEmpty
            ? '0'
            : field(124, 12).trim(), radix: 8);
        final type = header[156];
        pos += 512;
        final regular = type == 0 || type == 0x30; // '0' or NUL
        if (regular && name.isNotEmpty && !name.startsWith('.')) {
          final out = await File('${dir.path}/$name').open(mode: FileMode.write);
          try {
            var left = size;
            await raf.setPosition(pos);
            while (left > 0) {
              final chunk = await raf.read(math.min(left, 1 << 20));
              if (chunk.isEmpty) throw const FormatException('truncated tar');
              await out.writeFrom(chunk);
              left -= chunk.length;
            }
          } finally {
            await out.close();
          }
        }
        pos += (size + 511) ~/ 512 * 512;
      }
    } finally {
      await raf.close();
    }
  }

  Future<void> remove() async {
    final dir = await _packDir();
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  // ---------------------------------------------------------------------------
  // Encode / decode
  // ---------------------------------------------------------------------------

  Future<Uint8List> encode(
    Uint8List rgb512,
    void Function(double) onProgress,
  ) async {
    if (rgb512.length != _square * _square * 3) {
      throw ArgumentError('expected a ${_square}x$_square RGB image');
    }
    final dir = await _packDir();
    final work = await _workDir();
    try {
      final input = File('${work.path}/input.ppm');
      final header = ascii.encode('P6\n$_square $_square\n255\n');
      await input.writeAsBytes([...header, ...rgb512], flush: true);
      final output = File('${work.path}/out.aeic');
      final stages =
          await _stageCount(dir, 'encoder.tsv') +
          await _stageCount(dir, 'codec.tsv', only: _contextStage);
      await _run(
        [
          '--encode',
          '--model-dir',
          dir.path,
          '--input',
          input.path,
          '--bitstream-output',
          output.path,
          '--threads',
          '$_threads',
        ],
        'ENCODE_COMPLETE',
        stages,
        onProgress,
      );
      final stream = await output.readAsBytes();
      return _stripHeader(stream);
    } finally {
      await work.delete(recursive: true);
    }
  }

  Future<Uint8List> decode(
    Uint8List payload,
    void Function(double) onProgress,
  ) async {
    final dir = await _packDir();
    final work = await _workDir();
    try {
      final input = File('${work.path}/in.aeic');
      final header = ByteData(12)
        ..setUint32(0, _square)
        ..setUint32(4, _square)
        ..setUint32(8, payload.length);
      await input.writeAsBytes([
        ...header.buffer.asUint8List(),
        ...payload,
      ], flush: true);
      final output = File('${work.path}/out.png');
      final stages =
          await _stageCount(dir, 'codec.tsv') +
          await _stageCount(dir, 'renderer.tsv');
      await _run(
        [
          '--model-dir',
          dir.path,
          '--bitstream',
          input.path,
          '--output',
          output.path,
          '--threads',
          '$_threads',
        ],
        'DECODE_COMPLETE',
        stages,
        onProgress,
      );
      return await output.readAsBytes();
    } finally {
      await work.delete(recursive: true);
    }
  }

  /// Checks this phone against the reference codec, with the sample photo
  /// the model pack was exported with: encoding it must give exactly the
  /// reference's bytes (anything else and this phone's photos could decode
  /// wrongly elsewhere), and decoding the reference stream must give the
  /// reference picture to within rounding.
  Future<String> selfTest(void Function(double) onProgress) async {
    final dir = await _packDir();
    final sample = File('${dir.path}/sample.aeic');
    final input = File('${dir.path}/input.ppm');
    final reference = File('${dir.path}/reference_rgb.f32');
    if (!await sample.exists() || !await input.exists()) {
      throw StateError('The model pack has no test sample.');
    }
    final work = await _workDir();
    try {
      final encoded = File('${work.path}/test.aeic');
      final encodeStages =
          await _stageCount(dir, 'encoder.tsv') +
          await _stageCount(dir, 'codec.tsv', only: _contextStage);
      await _run(
        [
          '--encode',
          '--model-dir',
          dir.path,
          '--input',
          input.path,
          '--bitstream-output',
          encoded.path,
          '--threads',
          '$_threads',
        ],
        'ENCODE_COMPLETE',
        encodeStages,
        (p) => onProgress(p * 0.1),
      );
      final want = await sample.readAsBytes();
      final got = await encoded.readAsBytes();
      var same = want.length == got.length;
      for (var i = 0; same && i < want.length; i++) {
        same = want[i] == got[i];
      }
      if (!same) {
        return 'FAILED: this phone encodes the test photo differently from '
            'the reference codec (${got.length} vs ${want.length} bytes). '
            'Don\'t send AI sketch HD photos from it.';
      }
      final decoded = File('${work.path}/test.ppm');
      final decodeStages =
          await _stageCount(dir, 'codec.tsv') +
          await _stageCount(dir, 'renderer.tsv');
      final watch = Stopwatch()..start();
      await _run(
        [
          '--model-dir',
          dir.path,
          '--bitstream',
          sample.path,
          '--output',
          decoded.path,
          '--threads',
          '$_threads',
        ],
        'DECODE_COMPLETE',
        decodeStages,
        (p) => onProgress(0.1 + p * 0.9),
      );
      final seconds = watch.elapsed.inSeconds;
      var quality = '';
      if (await reference.exists()) {
        final psnr = _psnr(
          await decoded.readAsBytes(),
          await reference.readAsBytes(),
        );
        if (psnr != null) {
          quality =
              ' The decoded picture is ${psnr.toStringAsFixed(1)} dB '
              'from the reference${psnr < 35 ? ', which is too far off: '
                        'something is wrong' : ''}.';
          if (psnr < 35) return 'FAILED:$quality';
        }
      }
      return 'Passed: encoding matches the reference exactly, and a photo '
          'took ${seconds ~/ 60} min ${seconds % 60} s to draw.$quality';
    } finally {
      await work.delete(recursive: true);
    }
  }

  /// PSNR of a 512x512 binary PPM against the exporter's float reference
  /// (`[1, 3, 512, 512]` little-endian float32 in [-1, 1]).
  static double? _psnr(Uint8List ppm, Uint8List f32) {
    const n = _square * _square;
    if (f32.length != n * 3 * 4 || ppm.length < n * 3) return null;
    final rgb = Uint8List.sublistView(ppm, ppm.length - n * 3);
    final ref = ByteData.sublistView(f32);
    var se = 0.0;
    for (var c = 0; c < 3; c++) {
      for (var i = 0; i < n; i++) {
        final v = (ref.getFloat32((c * n + i) * 4, Endian.little) + 1) * 127.5;
        final r = v.clamp(0, 255).roundToDouble();
        final d = rgb[i * 3 + c] - r;
        se += d * d;
      }
    }
    final mse = se / (n * 3);
    if (mse == 0) return 99;
    return 10 * math.log(255 * 255 / mse) / math.ln10;
  }

  void cancelJob() {
    _cancelJob = true;
    _process?.kill(ProcessSignal.sigkill);
  }

  static int get _threads =>
      math.max(1, math.min(4, Platform.numberOfProcessors));

  static bool _contextStage(String name) =>
      name == 'h_s' || name.startsWith('ctx');

  /// The reference codec's file is `height, width, length` (big-endian
  /// uint32 each) then the stream; on air only the stream is sent.
  static Uint8List _stripHeader(Uint8List file) {
    if (file.length < 12) throw const FormatException('empty AEIC stream');
    final h = ByteData.sublistView(file);
    final height = h.getUint32(0), width = h.getUint32(4), len = h.getUint32(8);
    if (height != _square || width != _square || len != file.length - 12) {
      throw FormatException(
        'unexpected AEIC stream header $height x $width, $len bytes',
      );
    }
    return Uint8List.sublistView(file, 12);
  }

  Future<Directory> _workDir() async {
    final tmp = await getTemporaryDirectory();
    return Directory('${tmp.path}/aeic_hd').createTemp('job');
  }

  static Future<int> _stageCount(
    Directory dir,
    String tsv, {
    bool Function(String name)? only,
  }) async {
    final f = File('${dir.path}/$tsv');
    if (!await f.exists()) return 0;
    var n = 0;
    for (final line in await f.readAsLines()) {
      final cols = line.split('\t');
      if (cols.length > 1 &&
          cols[0] == 'stage' &&
          (only?.call(cols[1]) ?? true)) {
        n++;
      }
    }
    return n;
  }

  Future<void> _run(
    List<String> args,
    String success,
    int stages,
    void Function(double) onProgress,
  ) async {
    _cancelJob = false;
    final program = await _program();
    final process = await Process.start(program, args);
    _process = process;
    var ended = 0;
    var ok = false;
    final tail = <String>[];
    void keep(String line) {
      tail.add(line);
      if (tail.length > 12) tail.removeAt(0);
    }

    final outDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.startsWith('STAGE_END')) {
            ended++;
            if (stages > 0) onProgress(math.min(0.97, ended / stages));
          } else if (line.startsWith(success)) {
            ok = true;
          }
          keep(line);
        })
        .asFuture<void>();
    final errDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(keep)
        .asFuture<void>();
    final code = await process.exitCode;
    await Future.wait([outDone, errDone]).catchError((_) => <void>[]);
    _process = null;
    if (_cancelJob) throw const AeicHdJobCancelled();
    if (code != 0 || !ok) {
      throw StateError(
        'AI sketch HD codec failed (exit $code): ${tail.join(' | ')}',
      );
    }
    onProgress(1);
  }
}
