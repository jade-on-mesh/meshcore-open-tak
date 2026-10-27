import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/app_settings.dart';

void main() {
  test('Linked images on Wi-Fi is on by default and survives a save', () {
    expect(AppSettings().linkedImagesOnWifi, isTrue);
    expect(AppSettings.fromJson({}).linkedImagesOnWifi, isTrue);
    // The old key's saved default (off) no longer applies.
    expect(
      AppSettings.fromJson({'linked_images_on_wifi': false}).linkedImagesOnWifi,
      isTrue,
    );
    final off = AppSettings().copyWith(linkedImagesOnWifi: false);
    expect(AppSettings.fromJson(off.toJson()).linkedImagesOnWifi, isFalse);
  });
}
