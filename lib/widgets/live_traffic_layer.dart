// MeshCore Open TAK - live traffic on the map (lib/services/live_traffic.dart):
// each packet the companion hears runs along its path hop by hop, the way
// CoreScope's live map draws it (public/live.js renderAnimations):
//
// - a hop: a soft contrail (6 px, 20 %) and a core line (2 px, 80 %) grow
//   from one point to the next in 660 ms behind a white dot ringed in the
//   packet type's colour; lines to and from ghost hops are grey, dashed 4/6,
//   1.5 px at 30 %;
// - MediaMesh (heard on radio2): hollow rings every 12 px instead of the
//   line, a fainter contrail, a glowing ring for the head and the hop's
//   number on the fading copy;
// - a finished hop stays as a line that fades by 0.1 every 52 ms (the last
//   five kept);
// - each point the packet passes pulses: an inner ring growing 58 px/s and
//   fading 1.15/s, and a highlight ring growing 20 px/s and fading 1.35/s;
// - an inferred (ghost) repeater shows a small grey dot for 3 s;
// - a TRACE runs to the first hop it hasn't reached; the rest is a faint
//   dashed line for 10 s. On MediaMesh, each repeater it reached ripples
//   three rings with the SNR it heard the trace at.

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
  /// Which packets show, and how strongly (the map's MediaMesh filter).
  final LiveTrafficFilter filter;

  const LiveTrafficLayer({super.key, this.filter = LiveTrafficFilter.all});

  /// At most this many packets run at once (live.js MAX_CONCURRENT_ANIMS);
  /// more are skipped.
  static const int maxConcurrent = 20;

  @override
  State<LiveTrafficLayer> createState() => _LiveTrafficLayerState();
}

/// MediaMesh ring geometry (live.js MEDIAMESH_*), in screen pixels.
const double _ringSpacing = 12;
const double _ringRadius = 3.5;
const double _ringWeight = 1.6;
const int _ringsPerHop = 40;
const int _ringsPerPath = 200;
const double _headRadius = 5;
const double _headGlow = 13;

/// Rings allowed per hop on a path of [hopCount] hops: 40, fewer on long
/// paths so the whole path stays within 200.
@visibleForTesting
int liveTrafficRingCap(int hopCount) =>
    math.max(1, math.min(_ringsPerHop, _ringsPerPath ~/ math.max(1, hopCount)));

/// Where the rings sit along a hop [lengthPx] long, as fractions 0..1: one
/// every 12 px, evenly spread, at most [cap].
@visibleForTesting
List<double> liveTrafficRingFractions(double lengthPx, int cap) {
  if (!(lengthPx > 0)) return const [];
  final n = math.max(1, math.min((lengthPx / _ringSpacing).floor(), cap));
  return [for (var i = 0; i < n; i++) (i + 0.5) / n];
}

/// Radio2 sonar (live.js SONAR), in ms.
const int _sonarRings = 3;
const double _sonarStagger = 220;
const double _sonarGrow = 1100;
const double _sonarR0 = 6;
const double _sonarR1 = 36;
const double _sonarLabelIn = 200;
const double _sonarLabelHold = 2200;
const double _sonarLabelOut = 600;
const double _sonarMs = _sonarLabelHold + _sonarLabelOut;

/// Ring [k] of a sonar [ms] after it began: radius and opacity, or null
/// while it isn't showing.
@visibleForTesting
({double r, double a})? liveTrafficSonarRing(double ms, int k) {
  final v = ms - k * _sonarStagger;
  if (v <= 0 || v > _sonarGrow) return null;
  final p = v / _sonarGrow;
  return (
    r: _sonarR0 + p * (_sonarR1 - _sonarR0),
    a: 0.95 * math.pow(1 - p, 1.4).toDouble(),
  );
}

/// The sonar label's opacity [ms] after the burst began.
@visibleForTesting
double liveTrafficSonarLabelAlpha(double ms) {
  if (ms <= 0) return 0;
  if (ms < _sonarLabelIn) return ms / _sonarLabelIn;
  if (ms < _sonarLabelHold) return 1;
  return math.max(0, 1 - (ms - _sonarLabelHold) / _sonarLabelOut);
}

/// The SNR as the sonar label writes it: "+4.5", "−3.0".
@visibleForTesting
String liveTrafficSnrText(double snr) =>
    '${snr >= 0 ? '+' : '−'}${snr.abs().toStringAsFixed(1)}';

class _HopAnim {
  final LatLng from;
  final LatLng to;
  final Color color;
  final bool dashed;
  final bool mediaMesh;
  final int ringCap;
  final int hopNo;

  /// Everything about this packet drawn at this much (1, or 0.15 for
  /// main-mesh traffic under the map's MediaMesh filter).
  final double alpha;
  final VoidCallback onComplete;
  double progress = 0;

  _HopAnim(
    this.from,
    this.to,
    this.color,
    this.onComplete, {
    required this.dashed,
    required this.mediaMesh,
    required this.ringCap,
    required this.hopNo,
    this.alpha = 1,
  });

  /// live.js: 0.8, or 0.3 for a ghost hop's line.
  double get baseOpacity => dashed ? 0.3 : 0.8;

  double get opacity => baseOpacity * alpha;
}

class _Fade {
  final _HopAnim hop;

  /// Fades as live.js does (−0.1 a step); drawn times [_HopAnim.alpha].
  double opacity;
  double sinceFade = 0;
  bool stepped = false;

  _Fade(this.hop) : opacity = hop.baseOpacity;
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
  final double alpha;

  /// live.js pulseNode's default marker size.
  static const double _baseSize = 14;

  _Pulse(this.position, this.color, [this.alpha = 1]);
}

/// A grey dot: an inferred hop (3 s), or a trace's unreached inferred hop
/// (10 s, ringed in the trace colour).
class _Dot {
  final LatLng position;
  final double radius;
  final double fillAlpha;
  final Color stroke;
  final double strokeAlpha;
  double timeLeft;

  _Dot(
    this.position, {
    required this.radius,
    required this.fillAlpha,
    required this.stroke,
    required this.strokeAlpha,
    required this.timeLeft,
  });
}

/// A trace's route past the hops it reached: faint dashes for 10 s.
class _Dash {
  final LatLng from;
  final LatLng to;
  final Color color;
  final double alpha;
  double timeLeft = 10000;

  _Dash(this.from, this.to, this.color, [this.alpha = 1]);
}

class _Sonar {
  final LatLng position;
  final String? label;
  double elapsed = 0;

  _Sonar(this.position, this.label);
}

class _LiveTrafficLayerState extends State<LiveTrafficLayer>
    with SingleTickerProviderStateMixin {
  static const double _hopMs = 660;
  static const double _fadeStepMs = 52;
  static const int _maxFades = 5;
  static const int _maxSonars = 40;

  late final Ticker _ticker;
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  final LiveTrafficFrameReader _reader = LiveTrafficFrameReader();
  StreamSubscription<dynamic>? _frames;
  Duration _last = Duration.zero;
  int _running = 0;

  final List<_HopAnim> _hops = [];
  final List<_Fade> _fades = [];
  final List<_Pulse> _pulses = [];
  final List<_Dot> _dots = [];
  final List<_Dash> _dashes = [];
  final List<_Sonar> _sonars = [];

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    final connector = context.read<MeshCoreConnector>();
    _frames = connector.receivedFrames.listen((frame) {
      final packet = _reader.read(frame);
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

  /// live.js: a TRACE splits at its first unreached hop (animated up to it,
  /// dashed after); everything else runs its whole path.
  void _play(LiveTrafficRoute route) {
    final alpha = widget.filter.alphaFor(route);
    if (alpha <= 0) return;
    final hops = route.hops;
    final split = route.firstUnreached;
    final run = split == null ? hops : hops.sublist(0, split + 1);
    if (split != null) _dashedRest(hops.sublist(split), route.color, alpha);
    if (run.length == 1) {
      if (!run.first.ghost) {
        _pulses.add(_Pulse(run.first.position, route.color, alpha));
      }
    } else {
      _animate(run, route, alpha);
    }
    _wake();
  }

  /// live.js animatePath: at each point a pulse (a grey dot for a ghost),
  /// then the line to the next.
  void _animate(
    List<LiveTrafficHop> hops,
    LiveTrafficRoute route,
    double alpha,
  ) {
    if (_running >= LiveTrafficLayer.maxConcurrent) return;
    _running++;
    final ringCap = liveTrafficRingCap(hops.length - 1);
    final sonar = route.mediaMesh && route.isTrace;
    final sonarLabel = context.l10n.liveTraffic_sonarLabel;
    void next(int index) {
      if (!mounted) return;
      if (index >= hops.length) {
        _running = math.max(0, _running - 1);
        return;
      }
      final hp = hops[index];
      if (sonar && !hp.ghost && hp.reached) {
        if (_sonars.length >= _maxSonars) _sonars.removeAt(0);
        final snr = hp.snr;
        _sonars.add(
          _Sonar(
            hp.position,
            snr == null ? null : sonarLabel(liveTrafficSnrText(snr)),
          ),
        );
      }
      if (hp.ghost) {
        _dots.add(
          _Dot(
            hp.position,
            radius: 3,
            fillAlpha: 0.35 * alpha,
            stroke: liveTrafficGhostColor,
            strokeAlpha: 0.5 * alpha,
            timeLeft: 3000,
          ),
        );
      } else {
        _pulses.add(_Pulse(hp.position, route.color, alpha));
      }
      if (index < hops.length - 1) {
        final to = hops[index + 1];
        final dashed = to.dashedFrom(hp);
        _hops.add(
          _HopAnim(
            hp.position,
            to.position,
            dashed ? liveTrafficGhostColor : route.color,
            () => next(index + 1),
            dashed: dashed,
            mediaMesh: route.mediaMesh && !dashed,
            ringCap: ringCap,
            hopNo: index + 1,
            alpha: alpha,
          ),
        );
      } else {
        if (!hp.ghost) _pulses.add(_Pulse(hp.position, route.color, alpha));
        next(index + 1);
      }
    }

    next(0);
  }

  /// live.js drawDashedPath: a trace's unreached hops.
  void _dashedRest(List<LiveTrafficHop> hops, Color color, double alpha) {
    if (hops.length < 2) return;
    for (var i = 0; i < hops.length - 1; i++) {
      _dashes.add(_Dash(hops[i].position, hops[i + 1].position, color, alpha));
    }
    // Hops with no marker of their own (inferred) get a faint dot.
    for (var i = 1; i < hops.length; i++) {
      if (!hops[i].ghost) continue;
      final last = i == hops.length - 1;
      _dots.add(
        _Dot(
          hops[i].position,
          radius: last ? 4 : 3,
          fillAlpha: (last ? 0.25 : 0.2) * alpha,
          stroke: color,
          strokeAlpha: (last ? 0.35 : 0.3) * alpha,
          timeLeft: 10000,
        ),
      );
    }
  }

  void _tick(Duration elapsed) {
    // Each step's time is capped (live.js tickDt) so a stall doesn't jump.
    final dt = _last == Duration.zero
        ? 16.0
        : math.min(32.0, (elapsed - _last).inMicroseconds / 1000);
    _last = elapsed;
    final sec = dt / 1000;

    for (var i = _dots.length - 1; i >= 0; i--) {
      _dots[i].timeLeft -= dt;
      if (_dots[i].timeLeft <= 0) _dots.removeAt(i);
    }
    for (var i = _dashes.length - 1; i >= 0; i--) {
      _dashes[i].timeLeft -= dt;
      if (_dashes[i].timeLeft <= 0) _dashes.removeAt(i);
    }
    for (var i = _sonars.length - 1; i >= 0; i--) {
      _sonars[i].elapsed += dt;
      if (_sonars[i].elapsed > _sonarMs) _sonars.removeAt(i);
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
      _fades.add(_Fade(a));
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
        f.stepped = true;
        f.opacity -= 0.1 * steps;
        if (f.opacity <= 0) _fades.removeAt(i);
      }
    }

    if (_hops.isEmpty &&
        _fades.isEmpty &&
        _pulses.isEmpty &&
        _dots.isEmpty &&
        _dashes.isEmpty &&
        _sonars.isEmpty) {
      _ticker.stop();
    }
    _frame.value++;
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final theme = Theme.of(context);
    return IgnorePointer(
      child: SizedBox.expand(
        child: CustomPaint(
          painter: _LiveTrafficPainter(
            repaint: _frame,
            project: camera.latLngToScreenOffset,
            mediaMeshColor: liveTrafficMediaMeshColor(theme.brightness),
            surface: theme.colorScheme.surface,
            onSurface: theme.colorScheme.onSurface,
            hops: _hops,
            fades: _fades,
            pulses: _pulses,
            dots: _dots,
            dashes: _dashes,
            sonars: _sonars,
          ),
        ),
      ),
    );
  }
}

class _LiveTrafficPainter extends CustomPainter {
  final Offset Function(LatLng) project;
  final Color mediaMeshColor;
  final Color surface;
  final Color onSurface;
  final List<_HopAnim> hops;
  final List<_Fade> fades;
  final List<_Pulse> pulses;
  final List<_Dot> dots;
  final List<_Dash> dashes;
  final List<_Sonar> sonars;

  _LiveTrafficPainter({
    required Listenable repaint,
    required this.project,
    required this.mediaMeshColor,
    required this.surface,
    required this.onSurface,
    required this.hops,
    required this.fades,
    required this.pulses,
    required this.dots,
    required this.dashes,
    required this.sonars,
  }) : super(repaint: repaint);

  static Color _a(Color c, double alpha) =>
      c.withValues(alpha: alpha.clamp(0.0, 1.0));

  static Paint _stroke(Color color, double alpha, double width) => Paint()
    ..color = _a(color, alpha)
    ..style = PaintingStyle.stroke
    ..strokeWidth = width;

  void _line(
    Canvas canvas,
    Offset a,
    Offset b,
    Paint paint, {
    double dash = 0,
    double gap = 0,
  }) {
    if (dash <= 0) {
      canvas.drawLine(a, b, paint);
      return;
    }
    final d = b - a;
    final len = d.distance;
    if (len <= 0) return;
    final u = d / len;
    for (var s = 0.0; s < len; s += dash + gap) {
      canvas.drawLine(a + u * s, a + u * math.min(s + dash, len), paint);
    }
  }

  bool _offscreen(Offset a, Offset b, Size size) =>
      (a.dx < 0 && b.dx < 0) ||
      (a.dx > size.width && b.dx > size.width) ||
      (a.dy < 0 && b.dy < 0) ||
      (a.dy > size.height && b.dy > size.height);

  void _rings(
    Canvas canvas,
    Offset a,
    Offset b,
    int cap,
    double upTo,
    Paint p,
  ) {
    final d = b - a;
    for (final f in liveTrafficRingFractions(d.distance, cap)) {
      if (f > upTo) break;
      canvas.drawCircle(a + d * f, _ringRadius, p);
    }
  }

  void _hopBadge(Canvas canvas, Offset at, int n, double alpha) {
    canvas.drawCircle(at, 9, Paint()..color = _a(surface, alpha));
    canvas.drawCircle(at, 8.25, _stroke(mediaMeshColor, alpha, 1.5));
    final tp = TextPainter(
      text: TextSpan(
        text: '$n',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1,
          color: _a(onSurface, alpha),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);

    // A trace's unreached hops: faint dashes in its colour (6/8).
    for (final d in dashes) {
      final a = project(d.from), b = project(d.to);
      if (_offscreen(a, b, size)) continue;
      _line(canvas, a, b, _stroke(d.color, 0.25 * d.alpha, 2), dash: 6, gap: 8);
    }

    // Finished hops, fading (renderFades: contrail at 15 % of the line,
    // 12 % under MediaMesh rings, once fading starts).
    for (final f in fades) {
      final h = f.hop;
      // Drawn opacity: the fade times the packet's alpha.
      final fo = f.opacity * h.alpha;
      final a = project(h.from), b = project(h.to);
      if (_offscreen(a, b, size)) continue;
      final glow = f.stepped
          ? (h.mediaMesh ? 0.12 : 0.15)
          : (h.mediaMesh ? 0.15 : 0.2);
      _line(
        canvas,
        a,
        b,
        _stroke(h.color, fo * glow, 6)..strokeCap = StrokeCap.round,
      );
      if (h.mediaMesh) {
        _rings(
          canvas,
          a,
          b,
          h.ringCap,
          1,
          _stroke(mediaMeshColor, fo, _ringWeight),
        );
        if (h.hopNo > 0) {
          _hopBadge(canvas, (a + b) / 2, h.hopNo, math.min(1, f.opacity / 0.8) * h.alpha);
        }
      } else {
        _line(
          canvas,
          a,
          b,
          _stroke(h.color, fo, h.dashed ? 1.5 : 2)
            ..strokeCap = StrokeCap.round,
          dash: h.dashed ? 4 : 0,
          gap: 6,
        );
      }
    }

    for (final d in dots) {
      final p = project(d.position);
      canvas.drawCircle(
        p,
        d.radius,
        Paint()..color = _a(liveTrafficGhostColor, d.fillAlpha),
      );
      canvas.drawCircle(p, d.radius, _stroke(d.stroke, d.strokeAlpha, 1));
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
        _stroke(p.color, p.op * p.alpha, math.max(0.3, 3 - p.r * 0.04)),
      );
      if (p.hlOp > 0) {
        canvas.drawCircle(at, p.hlR, _stroke(p.color, p.hlOp * p.alpha, p.hlWeight));
      }
    }

    _paintSonars(canvas, size);

    for (final h in hops) {
      final a = project(h.from), b = project(h.to);
      if (_offscreen(a, b, size)) continue;
      final t = h.progress.clamp(0.0, 1.0);
      final head = Offset.lerp(a, b, t)!;
      _line(
        canvas,
        a,
        head,
        _stroke(h.color, h.opacity * (h.mediaMesh ? 0.15 : 0.2), 6)
          ..strokeCap = StrokeCap.round,
      );
      if (h.mediaMesh) {
        _rings(
          canvas,
          a,
          b,
          h.ringCap,
          t,
          _stroke(mediaMeshColor, h.opacity, _ringWeight),
        );
        // The head: a soft glow round a hollow ring.
        canvas.drawCircle(
          head,
          _headGlow,
          Paint()
            ..shader = RadialGradient(
              colors: [
                _a(mediaMeshColor, h.opacity * 0.55),
                _a(mediaMeshColor, 0),
              ],
            ).createShader(Rect.fromCircle(center: head, radius: _headGlow)),
        );
        canvas.drawCircle(
          head,
          _headRadius,
          _stroke(mediaMeshColor, h.opacity, 2),
        );
      } else {
        _line(
          canvas,
          a,
          head,
          _stroke(h.color, h.opacity, h.dashed ? 1.5 : 2),
          dash: h.dashed ? 4 : 0,
          gap: 6,
        );
        canvas.drawCircle(
          head,
          3.5,
          Paint()..color = _a(Colors.white, h.opacity),
        );
        canvas.drawCircle(head, 3.5, _stroke(h.color, h.opacity, 1.5));
      }
    }
  }

  /// live.js drawSonars: three rings, then the SNR in a pill.
  void _paintSonars(Canvas canvas, Size size) {
    for (final s in sonars) {
      final at = project(s.position);
      if (at.dx < -60 ||
          at.dy < -60 ||
          at.dx > size.width + 60 ||
          at.dy > size.height + 60) {
        continue;
      }
      for (var k = 0; k < _sonarRings; k++) {
        final ring = liveTrafficSonarRing(s.elapsed, k);
        if (ring == null) continue;
        canvas.drawCircle(
          at,
          ring.r,
          _stroke(mediaMeshColor, ring.a, 2.4 - k * 0.5),
        );
      }
      final label = s.label;
      final la = label == null ? 0.0 : liveTrafficSonarLabelAlpha(s.elapsed);
      if (label == null || la <= 0) continue;
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: _a(onSurface, la),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final box = RRect.fromRectAndRadius(
        Rect.fromLTWH(at.dx + 10, at.dy - 26, tp.width + 12, 18),
        const Radius.circular(9),
      );
      canvas.drawRRect(box, Paint()..color = _a(surface, la * 0.9));
      canvas.drawRRect(box, _stroke(mediaMeshColor, la, 1.2));
      tp.paint(
        canvas,
        Offset(box.left + 6, box.top + (box.height - tp.height) / 2),
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
            const SizedBox(height: 6),
            for (final (kind, label) in [
              (_SwatchKind.inferred, l10n.liveTraffic_legendGhost),
              (_SwatchKind.unreached, l10n.liveTraffic_legendUnreached),
              (_SwatchKind.rings, l10n.liveTraffic_legendRings),
              (_SwatchKind.sonar, l10n.liveTraffic_legendSonar),
            ])
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 22,
                      height: 14,
                      child: CustomPaint(
                        painter: _Swatch(
                          kind,
                          liveTrafficMediaMeshColor(
                            Theme.of(sheetContext).brightness,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(label, style: textStyle)),
                  ],
                ),
              ),
            const SizedBox(height: 14),
          ],
        ),
      );
    },
  );
}

enum _SwatchKind { inferred, unreached, rings, sonar }

/// The legend's path styles, drawn as on the map.
class _Swatch extends CustomPainter {
  final _SwatchKind kind;
  final Color mediaMesh;

  _Swatch(this.kind, this.mediaMesh);

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    Paint stroke(Color c, double w) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = w;
    switch (kind) {
      case _SwatchKind.inferred:
        final p = stroke(liveTrafficGhostColor, 1.5);
        canvas.drawLine(Offset(0, y), Offset(4, y), p);
        canvas.drawLine(Offset(18, y), Offset(size.width, y), p);
        canvas.drawCircle(
          Offset(size.width / 2, y),
          3,
          Paint()..color = liveTrafficGhostColor,
        );
      case _SwatchKind.unreached:
        final p = stroke(liveTrafficTypeColor(payloadTypeTRACE), 2);
        canvas.drawLine(Offset(0, y), Offset(6, y), p);
        canvas.drawLine(Offset(14, y), Offset(size.width, y), p);
      case _SwatchKind.rings:
        final p = stroke(mediaMesh, 1.6);
        for (final x in [3.5, 11.0, 18.5]) {
          canvas.drawCircle(Offset(x, y), 3.5, p);
        }
      case _SwatchKind.sonar:
        final c = Offset(size.width / 2, y);
        canvas.drawCircle(c, 2, stroke(mediaMesh, 1.6));
        canvas.drawCircle(
          c,
          4.5,
          stroke(mediaMesh.withValues(alpha: 0.6), 1.3),
        );
        canvas.drawCircle(c, 7, stroke(mediaMesh.withValues(alpha: 0.3), 1));
    }
  }

  @override
  bool shouldRepaint(_Swatch old) =>
      old.kind != kind || old.mediaMesh != mediaMesh;
}
