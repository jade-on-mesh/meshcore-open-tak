import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/app_settings.dart';

void main() {
  test('Linked images on Wi-Fi is off by default and survives a save', () {
    expect(AppSettings().linkedImagesOnWifi, isFalse);
    expect(AppSettings.fromJson({}).linkedImagesOnWifi, isFalse);
    final on = AppSettings().copyWith(linkedImagesOnWifi: true);
    expect(AppSettings.fromJson(on.toJson()).linkedImagesOnWifi, isTrue);
  });
}
