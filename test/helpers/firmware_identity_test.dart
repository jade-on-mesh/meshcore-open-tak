import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/firmware_identity.dart';

void main() {
  test('named builds', () {
    final tak = FirmwareIdentity.fromVersionString('wadamesh-tak 42')!;
    expect(tak.name, 'Wadamesh TAK');
    expect(tak.version, '42');
    expect(tak.label, 'Wadamesh TAK 42');
    expect(
      FirmwareIdentity.fromVersionString('wadamesh v1.2.3')!.label,
      'Wadamesh v1.2.3',
    );
    expect(
      FirmwareIdentity.fromVersionString('Meshcomod v2')!.name,
      'Meshcomod',
    );
    expect(
      FirmwareIdentity.fromVersionString('some-fork 1.0')!.name,
      'Some Fork',
    );
  });

  test('version only', () {
    final dev = FirmwareIdentity.fromVersionString('v1.17.4-touch')!;
    expect(dev.name, 'Wadamesh');
    expect(dev.version, 'v1.17.4');
    final stock = FirmwareIdentity.fromVersionString(' v1.18.0 ')!;
    expect(stock.name, 'MeshCore');
    expect(stock.version, 'v1.18.0');
  });

  test('nothing reported', () {
    expect(FirmwareIdentity.fromVersionString(null), isNull);
    expect(FirmwareIdentity.fromVersionString('  '), isNull);
  });
}
