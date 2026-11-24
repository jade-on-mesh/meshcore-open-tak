import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/utils/main_navigation.dart';

void main() {
  test('repeaters, rooms and sensors are nodes; people are contacts', () {
    expect(isNodeContactType(advTypeRepeater), isTrue);
    expect(isNodeContactType(advTypeRoom), isTrue);
    expect(isNodeContactType(advTypeSensor), isTrue);
    expect(isNodeContactType(advTypeChat), isFalse);
    expect(isNodeContactType(0), isFalse); // unknown: a person
  });

  test('the tabs, left to right', () {
    expect(
      [
        MainTab.dms,
        MainTab.contacts,
        MainTab.nodes,
        MainTab.channels,
        MainTab.map,
        MainTab.tactical,
      ],
      [0, 1, 2, 3, 4, 5],
    );
  });
}
