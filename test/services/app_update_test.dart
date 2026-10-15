import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/app_update_service.dart';

void main() {
  const urls = {
    'meshcore-open-tak.apk': 'https://example.invalid/a.apk',
    'meshcore-open-tak-windows-setup.exe': 'https://example.invalid/w.exe',
    'meshcore-open-tak-macos.dmg': 'https://example.invalid/m.dmg',
    'version.json': 'https://example.invalid/version.json',
  };

  final withAssets = {
    'version': '9.5.0-tak',
    'build': 1234,
    'sha256': 'a' * 64,
    'size': 98765432,
    'commit': 'abc1234',
    'signed': true,
    'changes': ['Channels: Share QR in the menu', 42],
    'assets': {
      'android': {
        'name': 'meshcore-open-tak.apk',
        'sha256': 'a' * 64,
        'size': 98765432,
      },
      'windows': {
        'name': 'meshcore-open-tak-windows-setup.exe',
        'sha256': 'b' * 64,
        'size': 40000000,
      },
      'macos': {
        'name': 'meshcore-open-tak-macos.dmg',
        'sha256': 'c' * 64,
        'size': 50000000,
      },
    },
  };

  test('version.json picks this platform\'s file', () {
    final android = AppUpdateInfo.fromVersionJson(
      withAssets,
      assetUrls: urls,
      platform: 'android',
    )!;
    expect(android.version, '9.5.0-tak');
    expect(android.build, 1234);
    expect(android.downloadUrl, 'https://example.invalid/a.apk');
    expect(android.sha256, 'a' * 64);
    expect(android.changes, ['Channels: Share QR in the menu']);
    expect(android.isNewerThan(1233), isTrue);
    expect(android.isNewerThan(1234), isFalse);

    final windows = AppUpdateInfo.fromVersionJson(
      withAssets,
      assetUrls: urls,
      platform: 'windows',
    )!;
    expect(windows.downloadUrl, 'https://example.invalid/w.exe');
    expect(windows.fileName, 'meshcore-open-tak-windows-setup.exe');
    expect(windows.sha256, 'b' * 64);
    expect(windows.size, 40000000);

    final linux = AppUpdateInfo.fromVersionJson(
      withAssets,
      assetUrls: urls,
      platform: 'linux',
    )!;
    expect(linux.build, 1234);
    expect(linux.downloadUrl, isNull);
    expect(linux.sha256, isNull);
  });

  test('version.json from before desktop builds', () {
    final info = AppUpdateInfo.fromVersionJson(
      {'version': '9.5.0-tak', 'build': 1300, 'sha256': 'd' * 64, 'signed': false},
      assetUrls: urls,
      platform: 'android',
    )!;
    expect(info.downloadUrl, 'https://example.invalid/a.apk');
    expect(info.sha256, 'd' * 64);
    expect(info.signedWithReleaseKey, isFalse);
    final mac = AppUpdateInfo.fromVersionJson(
      {'version': '9.5.0-tak', 'build': 1300, 'sha256': 'd' * 64},
      assetUrls: urls,
      platform: 'macos',
    )!;
    expect(mac.downloadUrl, isNull);
  });

  test('bad fields', () {
    expect(
      AppUpdateInfo.fromVersionJson('nope', assetUrls: urls, platform: 'android'),
      isNull,
    );
    expect(
      AppUpdateInfo.fromVersionJson(
        {'version': '1'},
        assetUrls: urls,
        platform: 'android',
      ),
      isNull,
    );
    final info = AppUpdateInfo.fromVersionJson(
      {'version': '9.5.0-tak', 'build': 1300, 'sha256': 'not-a-hash'},
      assetUrls: urls,
      platform: 'android',
    )!;
    expect(info.sha256, isNull);
  });

  test('older releases: the title', () {
    final info = AppUpdateInfo.fromTitle(
      'MeshCore Open TAK 9.5.0-tak (build 1187)',
      assetUrls: urls,
      platform: 'windows',
    )!;
    expect(info.version, '9.5.0-tak');
    expect(info.build, 1187);
    expect(info.downloadUrl, 'https://example.invalid/w.exe');
    expect(info.sha256, isNull);
    expect(
      AppUpdateInfo.fromTitle('Something else', assetUrls: urls, platform: 'android'),
      isNull,
    );
  });

  test('every platform has a release file name', () {
    expect(appUpdateAssetNames.keys, containsAll(['android', 'windows', 'macos', 'linux']));
  });
}
