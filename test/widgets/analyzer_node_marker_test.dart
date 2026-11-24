import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/widgets/analyzer_node_marker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('contact types map to the analyzer roles and colours', () {
    expect(analyzerRoleFor(advTypeRepeater), AnalyzerRole.repeater);
    expect(analyzerRoleFor(advTypeChat), AnalyzerRole.companion);
    expect(analyzerRoleFor(advTypeRoom), AnalyzerRole.room);
    expect(analyzerRoleFor(advTypeSensor), AnalyzerRole.sensor);
    expect(analyzerRoleFor(9), AnalyzerRole.unknown);
    expect(analyzerRoleColor(AnalyzerRole.repeater), const Color(0xFFD55E00));
    expect(analyzerRoleColor(AnalyzerRole.companion), const Color(0xFF56B4E9));
    expect(analyzerRoleColor(AnalyzerRole.room), const Color(0xFF009E73));
    expect(analyzerRoleColor(AnalyzerRole.sensor), const Color(0xFFF0E442));
  });

  test('sizes follow live.js: 18/14 at zoom 14, even, at least 10', () {
    expect(analyzerMarkerSize(AnalyzerRole.repeater, 14), 18);
    expect(analyzerMarkerSize(AnalyzerRole.companion, 14), 14);
    expect(analyzerMarkerSize(AnalyzerRole.repeater, 17), 28); // 27 → 28
    expect(analyzerMarkerSize(AnalyzerRole.companion, 5), 10);
    expect(analyzerMarkerSize(AnalyzerRole.repeater, 10), 10); // 6 → 10
  });

  test('the shapes: circle, square, hexagon, triangle', () {
    Rect bounds(AnalyzerRole r) =>
        AnalyzerMarkerPainter.shape(r, 20, Offset.zero).getBounds();
    expect(bounds(AnalyzerRole.repeater), const Rect.fromLTWH(2, 2, 16, 16));
    expect(bounds(AnalyzerRole.companion), const Rect.fromLTWH(3, 3, 14, 14));
    expect(bounds(AnalyzerRole.sensor), const Rect.fromLTRB(2, 2, 18, 18));
    final hex = bounds(AnalyzerRole.room);
    expect(hex.top, closeTo(1.5, 1e-9));
    expect(hex.bottom, closeTo(18.5, 1e-9));
  });

  testWidgets('every role paints, with and without MediaMesh', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            for (final role in AnalyzerRole.values)
              for (final mm in AnalyzerMediaMesh.values)
                SizedBox(
                  width: 40,
                  height: 40,
                  child: AnalyzerNodeMarker(
                    role: role,
                    size: 18,
                    mediaMesh: mm,
                    stale: role == AnalyzerRole.sensor,
                    selected: role == AnalyzerRole.room,
                  ),
                ),
          ],
        ),
      ),
    );
    expect(t.takeException(), isNull);
    expect(find.byType(AnalyzerNodeMarker), findsNWidgets(15));
  });

  test('the setting survives a reload', () async {
    SharedPreferences.setMockInitialValues({});
    final s = AnalyzerMarkerSettings.instance..resetForTest();
    await s.load();
    expect(s.enabled, isFalse);
    await s.setEnabled(true);
    s.resetForTest();
    await s.load();
    expect(s.enabled, isTrue);
  });
}
