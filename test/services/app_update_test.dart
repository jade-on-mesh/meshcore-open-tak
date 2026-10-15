import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/app_update_service.dart';

void main() {
  const apk = 'https://example.invalid/meshcore-open-tak.apk';

  test('version.json from CI', () {
    final info = AppUpdateInfo.fromVersionJson({
      'version': '9.5.0-tak',
      'build': 1234,
      'sha256': 'a' * 64,
      'size': 98765432,
      'commit': 'abc1234',
      'signed': true,
      'changes': ['Channels: Share QR in the menu', 42],
    }, apkUrl: apk)!;
    expect(info.version, '9.5.0-tak');
    expect(info.build, 1234);
    expect(info.sha256, 'a' * 64);
    expect(info.size, 98765432);
    expect(info.signedWithReleaseKey, isTrue);
    expect(info.changes, ['Channels: Share QR in the menu']);
    expect(info.isNewerThan(1233), isTrue);
    expect(info.isNewerThan(1234), isFalse);
  });

  test('bad or missing fields', () {
    expect(AppUpdateInfo.fromVersionJson('nope', apkUrl: apk), isNull);
    expect(
      AppUpdateInfo.fromVersionJson({'version': '1'}, apkUrl: apk),
      isNull,
    );
    final info = AppUpdateInfo.fromVersionJson({
      'version': '9.5.0-tak',
      'build': 1300,
      'sha256': 'not-a-hash',
      'signed': false,
    }, apkUrl: apk)!;
    expect(info.sha256, isNull);
    expect(info.signedWithReleaseKey, isFalse);
  });

  test('older releases: the title', () {
    final info = AppUpdateInfo.fromTitle(
      'MeshCore Open TAK 9.5.0-tak (build 1187)',
      apkUrl: apk,
    )!;
    expect(info.version, '9.5.0-tak');
    expect(info.build, 1187);
    expect(info.sha256, isNull);
    expect(AppUpdateInfo.fromTitle('Something else', apkUrl: apk), isNull);
  });
}
