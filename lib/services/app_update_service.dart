import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/prefs_manager.dart';
import '../utils/platform_info.dart';

/// One build on the GitHub "Latest build" release, from its `version.json`
/// (written by .github/workflows/build.yml) or, for older releases, from the
/// release title "MeshCore Open TAK 9.5.0-tak (build 1234)".
class AppUpdateInfo {
  final String version;
  final int build;
  final String apkUrl;
  final String? sha256;
  final int? size;
  final String? commit;
  final bool signedWithReleaseKey;
  final List<String> changes;

  const AppUpdateInfo({
    required this.version,
    required this.build,
    required this.apkUrl,
    this.sha256,
    this.size,
    this.commit,
    this.signedWithReleaseKey = true,
    this.changes = const [],
  });

  bool isNewerThan(int installedBuild) => build > installedBuild;

  /// From `version.json`; [apkUrl] is the release asset's download URL.
  static AppUpdateInfo? fromVersionJson(Object? json, {required String apkUrl}) {
    if (json is! Map) return null;
    final build = json['build'];
    final version = json['version'];
    if (build is! int || version is! String) return null;
    final sha = json['sha256'];
    final changes = json['changes'];
    return AppUpdateInfo(
      version: version,
      build: build,
      apkUrl: apkUrl,
      sha256: sha is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)
          ? sha
          : null,
      size: json['size'] is int ? json['size'] as int : null,
      commit: json['commit'] is String ? json['commit'] as String : null,
      signedWithReleaseKey: json['signed'] != false,
      changes: changes is List ? changes.whereType<String>().toList() : const [],
    );
  }

  /// From the release title, when the release has no `version.json` yet.
  static AppUpdateInfo? fromTitle(String title, {required String apkUrl}) {
    final m = RegExp(
      r'MeshCore Open TAK (\S+) \(build (\d+)\)',
    ).firstMatch(title);
    if (m == null) return null;
    return AppUpdateInfo(
      version: m.group(1)!,
      build: int.parse(m.group(2)!),
      apkUrl: apkUrl,
    );
  }
}

enum AppUpdateStatus {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  installing,
  error,
}

/// Checks the GitHub "Latest build" release for a newer APK, downloads it
/// and hands it to Android's installer (AppUpdateChannel.kt). Android only.
class AppUpdateService extends ChangeNotifier {
  AppUpdateService._();
  static final AppUpdateService instance = AppUpdateService._();

  static const _releaseUrl =
      'https://api.github.com/repos/jade-on-mesh/meshcore-open-tak/releases/tags/latest-build';
  static const _apkName = 'meshcore-open-tak.apk';
  static const _checkEvery = Duration(hours: 6);
  static const _channel = MethodChannel('meshcore_open/app_update');
  static const _prefLastCheck = 'app_update_last_check_ms';
  static const _prefDismissed = 'app_update_dismissed_build';
  static const _prefAuto = 'app_update_auto_check';

  /// CI builds are numbered 1000 and up; a lower number is a local build.
  static const firstCiBuild = 1000;

  AppUpdateStatus _status = AppUpdateStatus.idle;
  AppUpdateInfo? _latest;
  String _installedVersion = '';
  int _installedBuild = 0;
  double? _progress;
  String? _error;
  AppUpdateStatus _failedStep = AppUpdateStatus.idle;
  Timer? _timer;
  bool _started = false;

  bool get supported => PlatformInfo.isAndroid;
  AppUpdateStatus get status => _status;
  AppUpdateInfo? get latest => _latest;
  String get installedVersion => _installedVersion;
  int get installedBuild => _installedBuild;
  bool get isLocalBuild => _installedBuild < firstCiBuild;

  /// 0..1 while downloading, null when the size is unknown.
  double? get progress => _progress;

  /// The reason of the last failure, untranslated.
  String? get error => _error;

  /// What failed: [AppUpdateStatus.idle] for a check,
  /// [AppUpdateStatus.available] for a download or install.
  AppUpdateStatus get failedStep => _failedStep;

  /// A newer build than the one installed.
  bool get updateAvailable =>
      _latest != null && _latest!.isNewerThan(_installedBuild);

  /// Show the dot and the banner: an update the person has not set aside.
  bool get shouldNotify =>
      updateAvailable && !isLocalBuild && _latest!.build != _dismissedBuild;

  int get _dismissedBuild => _prefs?.getInt(_prefDismissed) ?? 0;

  bool get autoCheck => _prefs?.getBool(_prefAuto) ?? true;

  SharedPreferences? get _prefs {
    try {
      return PrefsManager.instance;
    } catch (_) {
      return null;
    }
  }

  /// Call once at startup: checks now if the last check is older than six
  /// hours, then every six hours while the app runs.
  Future<void> start() async {
    if (!supported || _started) return;
    _started = true;
    try {
      final info = await PackageInfo.fromPlatform();
      _installedVersion = info.version;
      _installedBuild = int.tryParse(info.buildNumber) ?? 0;
    } catch (_) {}
    notifyListeners();
    if (isLocalBuild) return; // a developer build: check only by hand
    _timer = Timer.periodic(_checkEvery, (_) {
      if (autoCheck) check();
    });
    final last = _prefs?.getInt(_prefLastCheck) ?? 0;
    final due =
        DateTime.now().millisecondsSinceEpoch - last >
        _checkEvery.inMilliseconds;
    if (autoCheck && due) unawaited(check());
  }

  Future<void> setAutoCheck(bool on) async {
    await _prefs?.setBool(_prefAuto, on);
    notifyListeners();
  }

  /// Hides the dot and banner for the current update until a newer one.
  Future<void> dismiss() async {
    final latest = _latest;
    if (latest == null) return;
    await _prefs?.setInt(_prefDismissed, latest.build);
    notifyListeners();
  }

  Future<void> check() async {
    if (!supported) return;
    if (_status == AppUpdateStatus.checking ||
        _status == AppUpdateStatus.downloading) {
      return;
    }
    _set(AppUpdateStatus.checking);
    try {
      final latest = await _fetchLatest();
      await _prefs?.setInt(
        _prefLastCheck,
        DateTime.now().millisecondsSinceEpoch,
      );
      _latest = latest;
      _set(
        latest != null && latest.isNewerThan(_installedBuild)
            ? AppUpdateStatus.available
            : AppUpdateStatus.upToDate,
      );
    } catch (e) {
      _fail(AppUpdateStatus.idle, '$e');
    }
  }

  Future<AppUpdateInfo?> _fetchLatest() async {
    final res = await http
        .get(
          Uri.parse(_releaseUrl),
          headers: {'Accept': 'application/vnd.github+json'},
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw HttpException('GitHub answered ${res.statusCode}');
    }
    final release = jsonDecode(res.body);
    if (release is! Map) return null;
    final assets = release['assets'];
    String? apkUrl;
    String? versionUrl;
    if (assets is List) {
      for (final a in assets) {
        if (a is! Map) continue;
        final url = a['browser_download_url'];
        if (url is! String) continue;
        if (a['name'] == _apkName) apkUrl = url;
        if (a['name'] == 'version.json') versionUrl = url;
      }
    }
    if (apkUrl == null) return null;
    if (versionUrl != null) {
      final v = await http
          .get(Uri.parse(versionUrl))
          .timeout(const Duration(seconds: 20));
      if (v.statusCode == 200) {
        final info = AppUpdateInfo.fromVersionJson(
          jsonDecode(v.body),
          apkUrl: apkUrl,
        );
        if (info != null) return info;
      }
    }
    final title = release['name'];
    return title is String
        ? AppUpdateInfo.fromTitle(title, apkUrl: apkUrl)
        : null;
  }

  /// Whether Android lets this app open the installer ("Install unknown
  /// apps"). The person grants it once in system settings.
  Future<bool> canInstall() async {
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openInstallPermission() async {
    try {
      await _channel.invokeMethod<void>('openInstallPermission');
    } catch (_) {}
  }

  /// Downloads the APK (checking its SHA-256 when published) and opens
  /// Android's installer, which asks the person to confirm.
  Future<void> downloadAndInstall() async {
    final latest = _latest;
    if (latest == null || _status == AppUpdateStatus.downloading) return;
    _progress = 0;
    _set(AppUpdateStatus.downloading);
    final client = http.Client();
    File? file;
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);
      file = File('${dir.path}/$_apkName');
      final res = await client
          .send(http.Request('GET', Uri.parse(latest.apkUrl)))
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        throw HttpException('download answered ${res.statusCode}');
      }
      final total = res.contentLength ?? latest.size;
      final digest = AccumulatorSink<Digest>();
      final hasher = sha256.startChunkedConversion(digest);
      final sink = file.openWrite();
      var received = 0;
      var lastNotify = DateTime.now();
      try {
        await for (final chunk in res.stream.timeout(
          const Duration(seconds: 60),
        )) {
          sink.add(chunk);
          hasher.add(chunk);
          received += chunk.length;
          if (total != null && total > 0) _progress = received / total;
          final now = DateTime.now();
          if (now.difference(lastNotify).inMilliseconds > 200) {
            lastNotify = now;
            notifyListeners();
          }
        }
      } finally {
        await sink.close();
      }
      hasher.close();
      final sha = digest.events.single.toString();
      if (latest.sha256 != null && sha != latest.sha256) {
        throw const FormatException(
          'the download is damaged (checksum mismatch)',
        );
      }
      _progress = 1;
      _set(AppUpdateStatus.installing);
      await _channel.invokeMethod<void>('install', {'path': file.path});
      // Android's installer is now on screen; if the person backs out the
      // update is still available.
      _set(AppUpdateStatus.available);
    } catch (e) {
      try {
        if (file != null && file.existsSync()) file.deleteSync();
      } catch (_) {}
      _fail(AppUpdateStatus.available, '${e is PlatformException ? e.message : e}');
    } finally {
      client.close();
    }
  }

  void _set(AppUpdateStatus s) {
    _status = s;
    if (s != AppUpdateStatus.error) _error = null;
    notifyListeners();
  }

  void _fail(AppUpdateStatus step, String message) {
    _failedStep = step;
    _error = message;
    _status = AppUpdateStatus.error;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
