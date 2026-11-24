// MeshCore Open TAK - analyzer-style node markers: repeaters, companions,
// rooms and sensors drawn on the app map the way CoreScope draws them
// (public/roles.js makeRoleMarkerSVG, public/live.js addNodeMarker,
// style.css .mm-node): a shape and colour per role with a white outline,
// sized by zoom, and a fuchsia ring with a badge on MediaMesh repeaters.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connector/meshcore_protocol.dart';
import '../services/live_traffic.dart' show liveTrafficMediaMeshColor;

/// Whether the map draws nodes as the analyzer does (App Settings › Map
/// display, and the map's filter sheet). Off until turned on; on this phone
/// only.
class AnalyzerMarkerSettings extends ChangeNotifier {
  AnalyzerMarkerSettings._();

  static final AnalyzerMarkerSettings instance = AnalyzerMarkerSettings._();

  static const String _prefsKey = 'map_analyzer_markers_v1';

  bool _enabled = false;

  bool get enabled => _enabled;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefsKey) ?? false;
    } catch (e) {
      debugPrint('Analyzer markers: could not load ($e)');
    }
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (value == _enabled) return;
    _enabled = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, value);
    } catch (e) {
      debugPrint('Analyzer markers: could not save ($e)');
    }
  }

  @visibleForTesting
  void resetForTest() => _enabled = false;
}

/// CoreScope's node roles.
enum AnalyzerRole { repeater, companion, room, sensor, unknown }

/// The role a contact type draws as: chat nodes are companions.
AnalyzerRole analyzerRoleFor(int contactType) => switch (contactType) {
  advTypeRepeater => AnalyzerRole.repeater,
  advTypeChat => AnalyzerRole.companion,
  advTypeRoom => AnalyzerRole.room,
  advTypeSensor => AnalyzerRole.sensor,
  _ => AnalyzerRole.unknown,
};

/// The role colours of CascadiaMesh's analyzer (analyzer.cascadiamesh.org,
/// its theme's `nodeColors`); the same in light and dark themes, each with a
/// white outline.
Color analyzerRoleColor(AnalyzerRole role) => switch (role) {
  AnalyzerRole.repeater => const Color(0xFF0080C0),
  AnalyzerRole.companion => const Color(0xFF9F0000),
  AnalyzerRole.room => const Color(0xFF16A34A),
  AnalyzerRole.sensor => const Color(0xFFD97706),
  AnalyzerRole.unknown => const Color(0xFF6B7280),
};

/// The marker's size at [zoom] (live.js addNodeMarker): repeaters 18 px and
/// the rest 14 px at zoom 14, scaled by (zoom − 8) / 6 (at least 0.4), never
/// under 10, rounded up to an even number.
double analyzerMarkerSize(AnalyzerRole role, double zoom) {
  final scale = math.max(0.4, (zoom - 8) / 6);
  final base = role == AnalyzerRole.repeater ? 18 : 14;
  final n = math.max(10, (base * scale).round());
  return (n.isOdd ? n + 1 : n).toDouble();
}

/// How a MediaMesh repeater shows: a ring round the marker and a badge,
/// filled when it sends on radio2, hollow when it only listens.
enum AnalyzerMediaMesh { none, listens, sends }

/// One node, as the analyzer draws it, centred in whatever box it's given
/// (give it room for the MediaMesh ring: [size] + 12).
class AnalyzerNodeMarker extends StatelessWidget {
  final AnalyzerRole role;
  final double size;
  final AnalyzerMediaMesh mediaMesh;

  /// Not heard for a while: drawn at 35 % (live.js pruneStaleNodes).
  final bool stale;

  /// The node picked on the map: a ring in [selectedColor] round it.
  final bool selected;
  final Color? selectedColor;

  const AnalyzerNodeMarker({
    super.key,
    required this.role,
    required this.size,
    this.mediaMesh = AnalyzerMediaMesh.none,
    this.stale = false,
    this.selected = false,
    this.selectedColor,
  });

  @override
  Widget build(BuildContext context) {
    final mm = liveTrafficMediaMeshColor(Theme.of(context).brightness);
    return Opacity(
      opacity: stale && !selected ? 0.35 : 1,
      child: CustomPaint(
        painter: AnalyzerMarkerPainter(
          role: role,
          size: size,
          mediaMesh: mediaMesh,
          mediaMeshColor: mm,
          selectedColor: selected
              ? (selectedColor ?? Theme.of(context).colorScheme.primary)
              : null,
        ),
      ),
    );
  }
}

/// Paints [AnalyzerNodeMarker] centred in the canvas; also used for the
/// legend swatches.
class AnalyzerMarkerPainter extends CustomPainter {
  final AnalyzerRole role;
  final double size;
  final AnalyzerMediaMesh mediaMesh;
  final Color mediaMeshColor;
  final Color? selectedColor;

  AnalyzerMarkerPainter({
    required this.role,
    required this.size,
    this.mediaMesh = AnalyzerMediaMesh.none,
    required this.mediaMeshColor,
    this.selectedColor,
  });

  /// The role's outline (makeRoleMarkerSVG) in a [size] box at [o].
  static Path shape(AnalyzerRole role, double size, Offset o) {
    final c = size / 2;
    final path = Path();
    switch (role) {
      case AnalyzerRole.companion:
        path.addRect(Rect.fromLTWH(o.dx + 3, o.dy + 3, size - 6, size - 6));
      case AnalyzerRole.sensor:
        path
          ..moveTo(o.dx + c, o.dy + 2)
          ..lineTo(o.dx + size - 2, o.dy + size - 2)
          ..lineTo(o.dx + 2, o.dy + size - 2)
          ..close();
      case AnalyzerRole.room:
        final r = c - 1.5;
        for (var i = 0; i < 6; i++) {
          final a = (i * 60 - 90) * math.pi / 180;
          final p = Offset(
            o.dx + c + r * math.cos(a),
            o.dy + c + r * math.sin(a),
          );
          if (i == 0) {
            path.moveTo(p.dx, p.dy);
          } else {
            path.lineTo(p.dx, p.dy);
          }
        }
        path.close();
      case AnalyzerRole.repeater:
      case AnalyzerRole.unknown:
        path.addOval(Rect.fromCircle(center: o + Offset(c, c), radius: c - 2));
    }
    return path;
  }

  @override
  void paint(Canvas canvas, Size box) {
    final o = Offset((box.width - size) / 2, (box.height - size) / 2);
    final center = o + Offset(size / 2, size / 2);
    final outline = shape(role, size, o);

    final selected = selectedColor;
    if (selected != null) {
      canvas.drawCircle(
        center,
        size / 2 + (mediaMesh == AnalyzerMediaMesh.none ? 4 : 8),
        Paint()
          ..color = selected
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }

    canvas.drawPath(outline, Paint()..color = analyzerRoleColor(role));
    // --mc-marker-stroke: white, 2 px, centred on the edge.
    canvas.drawPath(
      outline,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.miter,
    );

    if (mediaMesh != AnalyzerMediaMesh.none) {
      // .mm-node::before: a 2 px ring 4 px outside the marker box.
      canvas.drawCircle(
        center,
        size / 2 + 3,
        Paint()
          ..color = mediaMeshColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      // .mm-node::after: a 7 px badge over the top-right corner.
      final badge = Offset(o.dx + size + 5 - 3.5, o.dy - 5 + 3.5);
      if (mediaMesh == AnalyzerMediaMesh.sends) {
        canvas.drawCircle(badge, 3.5, Paint()..color = mediaMeshColor);
      }
      canvas.drawCircle(
        badge,
        2.75,
        Paint()
          ..color = mediaMeshColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(AnalyzerMarkerPainter old) =>
      old.role != role ||
      old.size != size ||
      old.mediaMesh != mediaMesh ||
      old.mediaMeshColor != mediaMeshColor ||
      old.selectedColor != selectedColor;
}
