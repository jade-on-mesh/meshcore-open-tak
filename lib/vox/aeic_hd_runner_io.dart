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
import 'dart:typed_data';

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
    return Directory('${support.path}/aeic_hd/${Uri.parse(baseUrl).pathSegments.where((s) => s.isNotEmpty).last}');
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
        throw HttpException(
          'model list: HTTP ${manifestResponse.statusCode}',
        );
      }
      final manifest =
          jsonDecode(utf8.decode(manifestResponse.bodyBytes))
              as Map<String, dynamic>;
      final files = [
        for (final f in (manifest['files'] as List).cast<Map<String, dynamic>>())
          _PackFile(
            // The program reads one flat directory (as mikecarper's
            // push_models.py lays it out), so keep just the file name.
            (f['path'] as String).split('/').last,
            f['asset'] as String,
            (f['size'] as num).toInt(),
            f['sha256'] as String,
          ),
      ];
      final total = files.fold<int>(0, (a, f) => a + f.size);
      onTotal(total);

      // Files already downloaded and checked on an earlier attempt.
      final verifiedFile = File('${dir.path}/.verified');
      final verified = <String>{
        if (await verifiedFile.exists())
          ...(await verifiedFile.readAsLines()).where((l) => l.isNotEmpty),
      };
      var done = 0;
      for (final f in files) {
        final target = File('${dir.path}/${f.name}');
        final key = '${f.name} ${f.sha256}';
        if (verified.contains(key) &&
            await target.exists() &&
            await target.length() == f.size) {
          done += f.size;
          onProgress(done / total);
          continue;
        }
        await _download(client, f, target, (got) {
          onProgress((done + got) / total);
        });
        done += f.size;
        verified.add(key);
        await verifiedFile.writeAsString('${verified.join('\n')}\n');
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
          } else if (response.statusCode != 200 &&
              response.statusCode != 206) {
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
      await _run([
        '--encode',
        '--model-dir',
        dir.path,
        '--input',
        input.path,
        '--bitstream-output',
        output.path,
        '--threads',
        '$_threads',
      ], 'ENCODE_COMPLETE', stages, onProgress);
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
      await _run([
        '--model-dir',
        dir.path,
        '--bitstream',
        input.path,
        '--output',
        output.path,
        '--threads',
        '$_threads',
      ], 'DECODE_COMPLETE', stages, onProgress);
      return await output.readAsBytes();
    } finally {
      await work.delete(recursive: true);
    }
  }

  void cancelJob() {
    _cancelJob = true;
    _process?.kill(ProcessSignal.sigkill);
  }

  static int get _threads => math.max(1, math.min(4, Platform.numberOfProcessors));

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
      if (cols.length > 1 && cols[0] == 'stage' && (only?.call(cols[1]) ?? true)) {
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
