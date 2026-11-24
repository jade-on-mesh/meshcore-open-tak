// MeshCore Open TAK - live traffic on the map (lib/services/live_traffic.dart):
// each packet the companion hears runs along its path hop by hop, the way
// CoreScope's live map draws it (public/live.js renderAnimations):
//
// - a hop: a soft contrail (6 px, 20 %) and a core line (2 px, 80 %) grow
//   from one point to the next in 660 ms behind a white dot ringed in the
//   packet type's colour; ghost and unreached TRACE hops are grey, dashed
//   4/6, 1.5 px at 30 %;
// - a finished hop stays as a line that fades by 0.1 every 52 ms (the last
//   five kept);
// - each point the packet passes pulses: an inner ring growing 58 px/s and
//   fading 1.15/s, and a highlight ring growing 20 px/s and fading 1.35/s;
// - an inferred (ghost) repeater shows a small grey dot for 3 s.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../services/live_traffic.dart';
import 'mesh_ui.dart';

/// The live-traffic drawing over the map. Put it in FlutterMap's children
/// while [LiveTrafficSettings.enabled]: it listens to the companion only
/// while it is there.
class LiveTrafficLayer extends StatefulWidget {
  const LiveTrafficLayer({super.key});

  /// At most this many packets run at once (live.js MAX_CONCURRENT_ANIMS);
  /// more are skipped.
  static const int maxConcurrent = 20;

  @override
  State<LiveTrafficLayer> createState() => _LiveTrafficLayerState();
}

class _HopAnim {
  final LatLng from;
  final LatLng to;
  final Color color;
  final bool dashed;
  final VoidCallback onComplete;
  double progress = 0;

  _HopAnim(this.from, this.to, this.color, this.dashed, this.onComplete);

  double get opacity => dashed ? 0.3 : 0.8;
}

class _Fade {
  final LatLng from;
  final LatLng to;
  final Color color;
  final bool dashed;
  double opacity;
  double sinceFade = 0;

  _Fade(this.from, this.to, this.color, this.dashed, this.opacity);
}

class _Pulse {
  final LatLng position;
  final Color color;
  double r = 2;
  double op = 0.9;
  double hlR = _baseSize / 2 + 4;
  double hlOp = 0.95;
  double hlWeight = 3;
  double age = 0;

  /// live.js pulseNode's default marker size.
  static const double _baseSize = 14;

  _Pulse(this.position, this.color);
}

class _Ghost {
  final LatLng position;
  double timeLeft = 3000;

  _Ghost(this.position);
}

class _LiveTrafficLayerState extends State<LiveTrafficLayer>
    with SingleTickerProviderStateMixin {
  static const double _hopMs = 660;
  static const double _fadeStepMs = 52;
  static const int _maxFades = 5;

  late final Ticker _ticker;
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  StreamSubscription<dynamic>? _frames;
  Duration _last = Duration.zero;
  int _running = 0;

  final List<_HopAnim> _hops = [];
  final List<_Fade> _fades = [];
  final List<_Pulse> _pulses = [];
  final List<_Ghost> _ghosts = [];

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    final connector = context.read<MeshCoreConnector>();
    _frames = connector.receivedFrames.listen((frame) {
      final packet = parseLiveTrafficFrame(frame);
      if (packet == null || !mounted) return;
      final lat = connector.selfLatitude, lon = connector.selfLongitude;
      final self = lat != null && lon != null && (lat != 0 || lon != 0)
          ? LatLng(lat, lon)
          : null;
      final route = liveTrafficRoute(
        packet,
        contacts: connector.contacts,
        self: self,
      );
      if (route != null) _play(route);
    });
  }

  @override
  void dispose() {
    _frames?.cancel();
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  void _wake() {
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  /// live.js animatePath: pulse at each point, then run the line to the next.
  void _play(LiveTrafficRoute route) {
    final hops = route.hops;
    if (hops.length == 1) {
      _pulse(hops.first, route.color);
      _wake();
      return;
    }
    if (_running >= LiveTrafficLayer.maxConcurrent) return;
    _running++;
    void next(int index) {
      if (!mounted) return;
      if (index >= hops.length) {
        _running = math.max(0, _running - 1);
        return;
      }
      final hp = hops[index];
      _pulse(hp, route.color);
      if (index < hops.length - 1) {
        final to = hops[index + 1];
        final dashed = to.dashedFrom(hp);
        _hops.add(
          _HopAnim(
            hp.position,
            to.position,
            dashed ? liveTrafficGhostColor : route.color,
            dashed,
            () => next(index + 1),
          ),
        );
      } else {
        next(index + 1);
      }
    }

    next(0);
    _wake();
  }

  void _pulse(LiveTrafficHop hop, Color color) {
    if (hop.ghost) {
      _ghosts.add(_Ghost(hop.position));
    } else {
      _pulses.add(_Pulse(hop.position, color));
    }
  }

  void _tick(Duration elapsed) {
    // Each step's time is capped (live.js tickDt) so a stall doesn't jump.
    final dt = _last == Duration.zero
        ? 16.0
        : math.min(32.0, (elapsed - _last).inMicroseconds / 1000);
    _last = elapsed;
    final sec = dt / 1000;

    for (var i = _ghosts.length - 1; i >= 0; i--) {
      _ghosts[i].timeLeft -= dt;
      if (_ghosts[i].timeLeft <= 0) _ghosts.removeAt(i);
    }

    for (var i = _pulses.length - 1; i >= 0; i--) {
      final p = _pulses[i];
      p.r += 58 * sec;
      p.op -= 1.15 * sec;
      p.hlR += 20 * sec;
      p.hlOp -= 1.35 * sec;
      p.hlWeight = p.hlOp > 0.4 ? 3 : 2;
      p.age += dt;
      if (p.op <= 0 || p.age > 30000) _pulses.removeAt(i);
    }

    final done = <_HopAnim>[];
    for (var i = _hops.length - 1; i >= 0; i--) {
      final a = _hops[i];
      a.progress += dt / _hopMs;
      if (a.progress >= 1) {
        _hops.removeAt(i);
        done.add(a);
      }
    }
    for (final a in done.reversed) {
      _fades.add(_Fade(a.from, a.to, a.color, a.dashed, a.opacity));
      while (_fades.length > _maxFades) {
        _fades.removeAt(0);
      }
      a.onComplete();
    }

    for (var i = _fades.length - 1; i >= 0; i--) {
      final f = _fades[i];
      f.sinceFade += dt;
      if (f.sinceFade >= _fadeStepMs) {
        final steps = math.min((f.sinceFade / _fadeStepMs).floor(), 4);
        f.sinceFade = 0;
        f.opacity -= 0.1 * steps;
        if (f.opacity <= 0) _fades.removeAt(i);
      }
    }

    if (_hops.isEmpty &&
        _fades.isEmpty &&
        _pulses.isEmpty &&
        _ghosts.isEmpty) {
      _ticker.stop();
    }
    _frame.value++;
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    return IgnorePointer(
      child: SizedBox.expand(
        child: CustomPaint(
          painter: _LiveTrafficPainter(
            repaint: _frame,
            project: camera.latLngToScreenOffset,
            hops: _hops,
            fades: _fades,
            pulses: _pulses,
            ghosts: _ghosts,
          ),
        ),
      ),
    );
  }
}

class _LiveTrafficPainter extends CustomPainter {
  final Offset Function(LatLng) project;
  final List<_HopAnim> hops;
  final List<_Fade> fades;
  final List<_Pulse> pulses;
  final List<_Ghost> ghosts;

  _LiveTrafficPainter({
    required Listenable repaint,
    required this.project,
    required this.hops,
    required this.fades,
    required this.pulses,
    required this.ghosts,
  }) : super(repaint: repaint);

  static Color _a(Color c, double alpha) =>
      c.withValues(alpha: alpha.clamp(0.0, 1.0));

  void _line(
    Canvas canvas,
    Offset a,
    Offset b,
    Color color,
    double width,
    double alpha, {
    bool dashed = false,
    bool round = false,
  }) {
    final paint = Paint()
      ..color = _a(color, alpha)
      ..strokeWidth = width
      ..style = PaintingStyle.stroke
      ..strokeCap = round ? StrokeCap.round : StrokeCap.butt;
    if (!dashed) {
      canvas.drawLine(a, b, paint);
      return;
    }
    // [4, 6] dashes, as live.js setLineDash([4, 6]).
    final d = b - a;
    final len = d.distance;
    if (len <= 0) return;
    final u = d / len;
    for (var s = 0.0; s < len; s += 10) {
      canvas.drawLine(a + u * s, a + u * math.min(s + 4, len), paint);
    }
  }

  bool _offscreen(Offset a, Offset b, Size size) =>
      (a.dx < 0 && b.dx < 0) ||
      (a.dx > size.width && b.dx > size.width) ||
      (a.dy < 0 && b.dy < 0) ||
      (a.dy > size.height && b.dy > size.height);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);

    // Finished hops, fading (contrail at 15 % of the line, as renderFades).
    for (final f in fades) {
      final a = project(f.from), b = project(f.to);
      if (_offscreen(a, b, size)) continue;
      _line(canvas, a, b, f.color, 6, f.opacity * 0.15, round: true);
      _line(
        canvas,
        a,
        b,
        f.color,
        f.dashed ? 1.5 : 2,
        f.opacity,
        dashed: f.dashed,
        round: true,
      );
    }

    for (final g in ghosts) {
      final p = project(g.position);
      canvas.drawCircle(p, 3, Paint()..color = _a(liveTrafficGhostColor, 0.35));
      canvas.drawCircle(
        p,
        3,
        Paint()
          ..color = _a(liveTrafficGhostColor, 0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }

    for (final p in pulses) {
      final at = project(p.position);
      if (at.dx < -p.hlR ||
          at.dy < -p.hlR ||
          at.dx > size.width + p.hlR ||
          at.dy > size.height + p.hlR) {
        continue;
      }
      canvas.drawCircle(
        at,
        p.r,
        Paint()
          ..color = _a(p.color, p.op)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.3, 3 - p.r * 0.04),
      );
      if (p.hlOp > 0) {
        canvas.drawCircle(
          at,
          p.hlR,
          Paint()
            ..color = _a(p.color, p.hlOp)
            ..style = PaintingStyle.stroke
            ..strokeWidth = p.hlWeight,
        );
      }
    }

    for (final h in hops) {
      final a = project(h.from), b = project(h.to);
      if (_offscreen(a, b, size)) continue;
      final t = h.progress.clamp(0.0, 1.0);
      final head = Offset.lerp(a, b, t)!;
      _line(canvas, a, head, h.color, 6, h.opacity * 0.2, round: true);
      _line(
        canvas,
        a,
        head,
        h.color,
        h.dashed ? 1.5 : 2,
        h.opacity,
        dashed: h.dashed,
      );
      canvas.drawCircle(head, 3.5, Paint()..color = _a(Colors.white, h.opacity));
      canvas.drawCircle(
        head,
        3.5,
        Paint()
          ..color = _a(h.color, h.opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_LiveTrafficPainter old) => true;
}

/// The map's live-traffic switch (above the filter button): filled while
/// live traffic shows.
class LiveTrafficButton extends StatelessWidget {
  const LiveTrafficButton({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final live = LiveTrafficSettings.instance;
    return ListenableBuilder(
      listenable: live,
      builder: (context, _) {
        final on = live.enabled;
        return FloatingActionButton(
          heroTag: 'map_live_traffic',
          tooltip: on ? l10n.liveTraffic_hide : l10n.liveTraffic_show,
          backgroundColor: on ? scheme.primary : scheme.surfaceContainerHigh,
          foregroundColor: on ? scheme.onPrimary : scheme.onSurface,
          onPressed: () {
            live.toggle();
            if (!on) {
              showDismissibleSnackBar(
                context,
                content: Text(l10n.liveTraffic_onHint),
                action: SnackBarAction(
                  label: l10n.liveTraffic_colours,
                  onPressed: () => showLiveTrafficLegend(context),
                ),
              );
            }
          },
          child: Icon(on ? Icons.podcasts : Icons.podcasts_outlined),
        );
      },
    );
  }
}

/// What each live-traffic colour means (CoreScope's legend).
Future<void> showLiveTrafficLegend(BuildContext context) {
  return showMeshSheet<void>(
    context,
    builder: (sheetContext) {
      final l10n = sheetContext.l10n;
      final scheme = Theme.of(sheetContext).colorScheme;
      final types = <(int, String)>[
        (payloadTypeADVERT, l10n.liveTraffic_typeAdvert),
        (payloadTypeGRPTXT, l10n.liveTraffic_typeChannel),
        (payloadTypeTXTMSG, l10n.liveTraffic_typeDirect),
        (payloadTypeACK, l10n.liveTraffic_typeAck),
        (payloadTypeREQ, l10n.liveTraffic_typeRequest),
        (payloadTypeRESPONSE, l10n.liveTraffic_typeResponse),
        (payloadTypeTRACE, l10n.liveTraffic_typeTrace),
        (payloadTypePATH, l10n.liveTraffic_typePath),
        (payloadTypeANONREQ, l10n.liveTraffic_typeAnonRequest),
        (payloadTypeGRPDATA, l10n.liveTraffic_typeGroupData),
        (payloadTypeMULTIPART, l10n.liveTraffic_typeMultipart),
        (payloadTypeCONTROL, l10n.liveTraffic_typeControl),
        (payloadTypeRawCustom, l10n.liveTraffic_typeRawCustom),
      ];
      final textStyle = TextStyle(fontSize: 15, color: scheme.onSurface);
      return SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BottomSheetHeader(title: l10n.liveTraffic_legendTitle),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                l10n.liveTraffic_legendHint,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            for (final (type, label) in types)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: liveTrafficTypeColor(type),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(label, style: textStyle)),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CustomPaint(painter: _DashSwatch()),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(l10n.liveTraffic_legendGhost, style: textStyle),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _DashSwatch extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = liveTrafficGhostColor
      ..strokeWidth = 2;
    final y = size.height / 2;
    canvas.drawLine(Offset(0, y), Offset(5, y), paint);
    canvas.drawLine(Offset(9, y), Offset(size.width, y), paint);
  }

  @override
  bool shouldRepaint(_DashSwatch old) => false;
}
