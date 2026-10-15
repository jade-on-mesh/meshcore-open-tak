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
import 'package:url_launcher/url_launcher.dart';

import '../storage/prefs_manager.dart';
import '../utils/platform_info.dart';

/// The release file each platform updates from, as named by
/// .github/workflows/build.yml.
const Map<String, String> appUpdateAssetNames = {
  'android': 'meshcore-open-tak.apk',
  'windows': 'meshcore-open-tak-windows-setup.exe',
  'macos': 'meshcore-open-tak-macos.dmg',
  'linux': 'meshcore-open-tak-linux-x86_64.AppImage',
};

/// One build on the GitHub "Latest build" release, from its `version.json`
/// (written by .github/workflows/build.yml) or, for older releases, from the
/// release title "MeshCore Open TAK 9.5.0-tak (build 1234)".
class AppUpdateInfo {
  final String version;
  final int build;

  /// This platform's file on the release, or null when this build has none
  /// for it (for example a desktop build that failed).
  final String? downloadUrl;
  final String? fileName;
  final String? sha256;
  final int? size;
  final String? commit;
  final bool signedWithReleaseKey;
  final List<String> changes;

  const AppUpdateInfo({
    required this.version,
    required this.build,
    this.downloadUrl,
    this.fileName,
    this.sha256,
    this.size,
    this.commit,
    this.signedWithReleaseKey = true,
    this.changes = const [],
  });

  bool isNewerThan(int installedBuild) => build > installedBuild;

  static final _sha = RegExp(r'^[0-9a-f]{64}$');

  /// From `version.json`. [assetUrls] maps the release's file names to their
  /// download URLs; [platform] is a key of [appUpdateAssetNames].
  static AppUpdateInfo? fromVersionJson(
    Object? json, {
    required Map<String, String> assetUrls,
    required String platform,
  }) {
    if (json is! Map) return null;
    final build = json['build'];
    final version = json['version'];
    if (build is! int || version is! String) return null;
    String? name;
    Object? sha;
    Object? size;
    final assets = json['assets'];
    if (assets is Map && assets[platform] is Map) {
      final a = assets[platform] as Map;
      name = a['name'] is String ? a['name'] as String : null;
      sha = a['sha256'];
      size = a['size'];
    } else if (platform == 'android') {
      // version.json before desktop builds: the top level is the APK.
      name = appUpdateAssetNames['android'];
      sha = json['sha256'];
      size = json['size'];
    }
    final url = name == null ? null : assetUrls[name];
    final changes = json['changes'];
    return AppUpdateInfo(
      version: version,
      build: build,
      downloadUrl: url,
      fileName: url == null ? null : name,
      sha256: url != null && sha is String && _sha.hasMatch(sha) ? sha : null,
      size: url != null && size is int ? size : null,
      commit: json['commit'] is String ? json['commit'] as String : null,
      signedWithReleaseKey: json['signed'] != false,
      changes: changes is List ? changes.whereType<String>().toList() : const [],
    );
  }

  /// From the release title, when the release has no `version.json` yet.
  static AppUpdateInfo? fromTitle(
    String title, {
    required Map<String, String> assetUrls,
    required String platform,
  }) {
    final m = RegExp(
      r'MeshCore Open TAK (\S+) \(build (\d+)\)',
    ).firstMatch(title);
    if (m == null) return null;
    final name = appUpdateAssetNames[platform];
    final url = name == null ? null : assetUrls[name];
    return AppUpdateInfo(
      version: m.group(1)!,
      build: int.parse(m.group(2)!),
      downloadUrl: url,
      fileName: url == null ? null : name,
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

/// Checks the GitHub "Latest build" release for a newer build, downloads this
/// platform's file and installs it:
///
/// - Android: Android's package installer (AppUpdateChannel.kt) asks to confirm.
/// - Windows: the installer runs silently, closes this app, updates it and
///   starts it again.
/// - macOS: the disk image opens; drag the app to Applications.
/// - Linux AppImage: the AppImage replaces itself and restarts. Other Linux
///   installs (the .tar.gz) open the release page.
class AppUpdateService extends ChangeNotifier {
  AppUpdateService._();
  static final AppUpdateService instance = AppUpdateService._();

  static const releasePage =
      'https://github.com/jade-on-mesh/meshcore-open-tak/releases/tag/latest-build';
  static const _releaseApi =
      'https://api.github.com/repos/jade-on-mesh/meshcore-open-tak/releases/tags/latest-build';
  static const _checkEvery = Duration(hours: 6);
  static const _channel = MethodChannel('meshcore_open/app_update');
  static const _prefLastCheck = 'app_update_last_check_ms';
  static const _prefDismissed = 'app_update_dismissed_build';
  static const _prefAuto = 'app_update_auto_check';

  /// Set by CI (--dart-define); local builds leave them empty.
  static const _definedVersion = String.fromEnvironment('APP_VERSION');
  static const _definedBuild = int.fromEnvironment('APP_BUILD');

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

  /// The platform key in [appUpdateAssetNames], or null where updates are
  /// not offered (web, iOS).
  static String? get platform {
    if (PlatformInfo.isAndroid) return 'android';
    if (PlatformInfo.isWindows) return 'windows';
    if (PlatformInfo.isMacOS) return 'macos';
    if (PlatformInfo.isLinux) return 'linux';
    return null;
  }

  bool get supported => platform != null;
  AppUpdateStatus get status => _status;
  AppUpdateInfo? get latest => _latest;
  String get installedVersion => _installedVersion;
  int get installedBuild => _installedBuild;
  bool get isLocalBuild => _installedBuild < firstCiBuild;

  /// The running AppImage's path on Linux, or null.
  String? get _appImage {
    if (!PlatformInfo.isLinux) return null;
    final path = Platform.environment['APPIMAGE'];
    return path == null || path.isEmpty ? null : path;
  }

  /// Linux outside an AppImage (the .tar.gz): updates are downloaded by hand.
  bool get needsManualDownload => PlatformInfo.isLinux && _appImage == null;

  /// This build can download and install the update itself.
  bool get canSelfInstall =>
      !needsManualDownload && _latest?.downloadUrl != null;

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
    _installedVersion = _definedVersion;
    _installedBuild = _definedBuild;
    if (_installedBuild == 0) {
      try {
        final info = await PackageInfo.fromPlatform();
        _installedVersion = info.version;
        _installedBuild = int.tryParse(info.buildNumber) ?? 0;
      } catch (_) {}
    }
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
          Uri.parse(_releaseApi),
          headers: {'Accept': 'application/vnd.github+json'},
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw HttpException('GitHub answered ${res.statusCode}');
    }
    final release = jsonDecode(res.body);
    if (release is! Map) return null;
    final urls = <String, String>{};
    final assets = release['assets'];
    if (assets is List) {
      for (final a in assets) {
        if (a is! Map) continue;
        final name = a['name'];
        final url = a['browser_download_url'];
        if (name is String && url is String) urls[name] = url;
      }
    }
    final key = platform!;
    final versionUrl = urls['version.json'];
    if (versionUrl != null) {
      final v = await http
          .get(Uri.parse(versionUrl))
          .timeout(const Duration(seconds: 20));
      if (v.statusCode == 200) {
        final info = AppUpdateInfo.fromVersionJson(
          jsonDecode(v.body),
          assetUrls: urls,
          platform: key,
        );
        if (info != null) return info;
      }
    }
    final title = release['name'];
    return title is String
        ? AppUpdateInfo.fromTitle(title, assetUrls: urls, platform: key)
        : null;
  }

  /// Android: whether this app may open the installer ("Install unknown
  /// apps"), granted once in system settings. Always true elsewhere.
  Future<bool> canInstall() async {
    if (!PlatformInfo.isAndroid) return true;
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

  Future<void> openReleasePage() async {
    try {
      await launchUrl(
        Uri.parse(releasePage),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
  }

  /// Downloads this platform's file (checking its SHA-256 when published)
  /// and installs it.
  Future<void> downloadAndInstall() async {
    final latest = _latest;
    final url = latest?.downloadUrl;
    if (latest == null || url == null) return;
    if (_status == AppUpdateStatus.downloading) return;
    _progress = 0;
    _set(AppUpdateStatus.downloading);
    final client = http.Client();
    File? file;
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);
      file = File(
        '${dir.path}/${latest.fileName ?? appUpdateAssetNames[platform]}',
      );
      final res = await client
          .send(http.Request('GET', Uri.parse(url)))
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
      await _install(file);
      // The installer (or the disk image) is now open; if the person backs
      // out, the update is still available.
      _set(AppUpdateStatus.available);
    } catch (e) {
      try {
        if (file != null && file.existsSync()) file.deleteSync();
      } catch (_) {}
      _fail(
        AppUpdateStatus.available,
        '${e is PlatformException ? e.message : e}',
      );
    } finally {
      client.close();
    }
  }

  Future<void> _install(File file) async {
    if (PlatformInfo.isAndroid) {
      await _channel.invokeMethod<void>('install', {'path': file.path});
    } else if (PlatformInfo.isWindows) {
      // Inno Setup: /SILENT shows only a progress window; it closes this app
      // (CloseApplications), updates it and starts it again ([Run]).
      await Process.start(file.path, const [
        '/SILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
      ], mode: ProcessStartMode.detached);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(0);
    } else if (PlatformInfo.isMacOS) {
      final opened = await launchUrl(Uri.file(file.path));
      if (!opened) {
        final r = await Process.run('open', [file.path]);
        if (r.exitCode != 0) throw ProcessException('open', [file.path]);
      }
    } else if (PlatformInfo.isLinux) {
      final target = _appImage;
      if (target == null) throw const FileSystemException('not an AppImage');
      // Next to the running AppImage, then renamed over it: a rename is
      // atomic, and the running copy keeps working until it exits.
      final staged = File('$target.new');
      await file.copy(staged.path);
      final chmod = await Process.run('chmod', ['755', staged.path]);
      if (chmod.exitCode != 0) {
        throw FileSystemException('chmod failed', staged.path);
      }
      await staged.rename(target);
      await Process.start(target, const [], mode: ProcessStartMode.detached);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      exit(0);
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
