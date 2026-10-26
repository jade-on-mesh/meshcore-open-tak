import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/model_auto_download.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Model {
  _Model(this.id, {this.ready = false, this.fails = false});
  final String id;
  bool ready;
  bool fails;
  int downloads = 0;

  AutoDownloadModel get spec => AutoDownloadModel(
    id: id,
    isReady: () async => ready,
    download: () async {
      downloads++;
      if (fails) throw StateError('no');
      ready = true;
    },
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<List<String>> done() async =>
      (await SharedPreferences.getInstance()).getStringList(
        ModelAutoDownloader.prefsKey,
      ) ??
      [];

  test(
    'on Wi-Fi: downloads what is missing, in order, and records it',
    () async {
      final order = <String>[];
      final a = _Model('a');
      final b = _Model('b', ready: true);
      final c = _Model('c');
      final d = ModelAutoDownloader(
        [
          for (final m in [a, b, c])
            AutoDownloadModel(
              id: m.id,
              isReady: m.spec.isReady,
              download: () {
                order.add(m.id);
                return m.spec.download();
              },
            ),
        ],
        onWifi: () async => true,
        wifiChanges: const Stream.empty(),
      );
      await d.runOnce();
      expect(order, ['a', 'c']);
      expect(await done(), ['a', 'b', 'c']);
    },
  );

  test('on mobile data: nothing downloads; joining Wi-Fi starts it', () async {
    var wifi = false;
    final changes = StreamController<bool>();
    final a = _Model('a');
    final d = ModelAutoDownloader(
      [a.spec],
      onWifi: () async => wifi,
      wifiChanges: changes.stream,
    );
    d.start();
    await d.runOnce();
    expect(a.downloads, 0);
    expect(await done(), isEmpty);

    wifi = true;
    changes.add(true);
    await pumpEventQueue();
    await d.runOnce();
    expect(a.downloads, 1);
    expect(await done(), ['a']);
    d.dispose();
    await changes.close();
  });

  test('a model already done is not fetched again, even if deleted', () async {
    SharedPreferences.setMockInitialValues({
      ModelAutoDownloader.prefsKey: ['a'],
    });
    final a = _Model('a');
    await ModelAutoDownloader(
      [a.spec],
      onWifi: () async => true,
      wifiChanges: const Stream.empty(),
    ).runOnce();
    expect(a.downloads, 0);
  });

  test(
    'a failed download is retried next time; the others still run',
    () async {
      final a = _Model('a', fails: true);
      final b = _Model('b');
      final d = ModelAutoDownloader(
        [a.spec, b.spec],
        onWifi: () async => true,
        wifiChanges: const Stream.empty(),
      );
      await d.runOnce();
      expect(await done(), ['b']);
      a.fails = false;
      await d.runOnce();
      expect(a.downloads, 2);
      expect(await done(), ['a', 'b']);
    },
  );

  test('Wi-Fi and Ethernet count; mobile data does not', () {
    expect(connectivityAllowsModelDownload([ConnectivityResult.wifi]), isTrue);
    expect(
      connectivityAllowsModelDownload([
        ConnectivityResult.ethernet,
        ConnectivityResult.vpn,
      ]),
      isTrue,
    );
    expect(
      connectivityAllowsModelDownload([ConnectivityResult.mobile]),
      isFalse,
    );
    expect(connectivityAllowsModelDownload([ConnectivityResult.none]), isFalse);
  });
}
