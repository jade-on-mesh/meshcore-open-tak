import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/team/team_screen.dart';

void main() {
  test('snippet: the words in context', () {
    final text =
        'ICE WATCH\nVehicles seen near the corner of Alberta and 15th, two '
        'unmarked vans parked facing north';
    expect(watchSnippet(text, ['vans']), startsWith('…'));
    expect(watchSnippet(text, ['vans']), contains('unmarked vans'));
    expect(watchSnippet(text, ['ice']), startsWith('ICE WATCH Vehicles'));
    expect(watchSnippet(text, ['nowhere']), isNull);
  });

  test('marking: every word, any case', () {
    const mark = Colors.yellow;
    final span = watchMarked('Drone over Alberta Park', [
      'alberta',
      'dr',
    ], mark);
    final parts = [
      for (final c in span.children!.cast<TextSpan>())
        (c.text, c.style?.backgroundColor == mark),
    ];
    expect(parts, [
      ('Dr', true),
      ('one over ', false),
      ('Alberta', true),
      (' Park', false),
    ]);
    expect(watchMarked('plain', const [], mark).text, 'plain');
  });
}
