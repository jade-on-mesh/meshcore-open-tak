import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/aeic_hd_log.dart';

void main() {
  setUp(() => AeicHdLog.instance.clear());

  test('lines come newest first, under the radio summary', () {
    final log = AeicHdLog.instance;
    log.radioSummary = () => 'self=abc main radio SF7';
    log.add('sending 9 chunks', image: AeicHdLog.imageTag(0x8c41, 7));
    log.add('chunk #0/8 accepted', image: AeicHdLog.imageTag(0x8c41, 7));
    final lines = log.text().split('\n');
    expect(lines.first, 'self=abc main radio SF7');
    expect(lines[1], endsWith('[8c41/7] chunk #0/8 accepted'));
    expect(lines[2], endsWith('[8c41/7] sending 9 chunks'));
    log.radioSummary = null;
  });

  test('keeps only the newest lines and tells listeners', () {
    final log = AeicHdLog.instance;
    var bumps = 0;
    void listener() => bumps++;
    log.version.addListener(listener);
    for (var i = 0; i < AeicHdLog.capacity + 10; i++) {
      log.add('line $i');
    }
    log.version.removeListener(listener);
    expect(log.entries.length, AeicHdLog.capacity);
    expect(log.entries.first.text, 'line 10');
    expect(bumps, AeicHdLog.capacity + 10);
  });

  test('an image is named by its sender prefix and id', () {
    expect(AeicHdLog.imageTag(0x0a, 3), '000a/3');
  });
}
