// MeshCore Open TAK - AR view: hold the phone up and see teammates, pins,
// watched reports, photos and voice messages as floating labels where they
// are, with their distance, and a chime as a teammate or report comes into
// the middle of the view (documentation/ar-view.md). Bloodhound's arrow, for
// everything at once.
//
// It is a compass overlay rather than ARCore/ARKit tracking: the camera
// picture (through the QR scanner's camera, so no new plugin), and where it
// points from gravity and the magnetic field (OrientationChannel.kt,
// MeshOrientation in AppDelegate.swift), corrected for magnetic declination.
// Labels go by bearing and distance from your GPS position; good to a few
// degrees, enough to say "Sam is behind that building, 400 m".

import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../vox/voice_service.dart';
import 'photo_mosaic.dart';
import 'team_map.dart' show markerKindColor, markerKindIcon;
import 'team_service.dart';
import 'team_wire.dart';
import 'watch_feed.dart';
import 'watch_sounds.dart';

/// Where the back camera points: [azimuth] degrees from true north (with
/// [declination] added), [pitch] degrees above the horizon. [g] is gravity as
/// Android gives it (pointing up), [m] the magnetic field, both in device
/// axes (x right, y up, z out of the screen). Null when they're unusable
/// (phone flat on its face, or a magnet nearby).
({double azimuth, double pitch})? arCameraPose(
  List<double> g,
  List<double> m, {
  double declination = 0,
}) {
  var ax = g[0], ay = g[1], az = g[2];
  final ex = m[0], ey = m[1], ez = m[2];
  // East = field x up; north = up x east (Android's getRotationMatrix).
  var hx = ey * az - ez * ay, hy = ez * ax - ex * az, hz = ex * ay - ey * ax;
  final nh = sqrt(hx * hx + hy * hy + hz * hz);
  final na = sqrt(ax * ax + ay * ay + az * az);
  if (nh < 0.1 || na < 0.1) return null;
  hx /= nh;
  hy /= nh;
  hz /= nh;
  ax /= na;
  ay /= na;
  az /= na;
  final mz = ax * hy - ay * hx;
  // The camera looks along -z.
  final east = -hz, north = -mz, up = -az;
  var azimuth = atan2(east, north) * 180 / pi + declination;
  azimuth = (azimuth % 360 + 360) % 360;
  final pitch = asin(up.clamp(-1.0, 1.0)) * 180 / pi;
  return (azimuth: azimuth, pitch: pitch);
}

/// [b] - [a] in degrees, between -180 and 180.
double arAngleDiff(double a, double b) => ((b - a + 540) % 360) - 180;

/// Something to show in the AR view.
class ArTarget {
  /// Stable across frames (`m:KEY`, `w:KEY`, `ph:SID`...), for the chime.
  final String id;
  final String label;
  final double lat, lon;
  final Color color;
  final IconData icon;
  final VoidCallback? onTap;

  /// A picture in the label (a photo's), when there is one.
  final ui.Image? image;

  /// A tap starts Bloodhound to it (else it opens or plays something).
  final bool hounds;

  /// Chimes as it comes into the middle of the view (teammates, reports).
  final bool chime;
  const ArTarget({
    required this.label,
    required this.lat,
    required this.lon,
    required this.color,
    required this.icon,
    this.id = '',
    this.onTap,
    this.image,
    this.hounds = true,
    this.chime = false,
  });
}

/// Within this many degrees of the middle of the view, a target "comes into
/// view" for the chime; it must leave past [arChimeRearmDeg] to chime again.
const double arChimeDeg = 6, arChimeRearmDeg = 14;

/// Which targets just came into the middle of the view. [offsets] are each
/// target's degrees off the middle; [inView] holds the ids already there (a
/// target leaves it past [arChimeRearmDeg]), and is updated. Returns the ids
/// that came within [arChimeDeg] since the last call.
List<String> arChimeStep(
  Map<String, double> offsets,
  Set<String> inView,
) {
  final arrived = <String>[];
  for (final e in offsets.entries) {
    final d = e.value.abs();
    if (d <= arChimeDeg && inView.add(e.key)) arrived.add(e.key);
    if (d > arChimeRearmDeg) inView.remove(e.key);
  }
  inView.removeWhere((id) => !offsets.containsKey(id));
  return arrived;
}

/// The orientation stream, smoothed.
class _Orientation {
  static const _events = EventChannel('meshcore_open/orientation');
  static const _ctl = MethodChannel('meshcore_open/orientation_ctl');

  StreamSubscription<dynamic>? _sub;
  List<double>? _g, _m;
  double _decl = 0;
  final ValueNotifier<({double azimuth, double pitch})?> pose = ValueNotifier(null);
  final ValueNotifier<String?> error = ValueNotifier(null);

  void start() {
    _sub = _events.receiveBroadcastStream().listen(
      (e) {
        if (e is! List || e.length < 7) return;
        final v = [for (final x in e) (x as num).toDouble()];
        const k = 0.15; // low-pass: steadier labels, a little lag
        List<double> mix(List<double>? old, List<double> now) => old == null
            ? now
            : [for (var i = 0; i < 3; i++) old[i] + k * (now[i] - old[i])];
        _g = mix(_g, v.sublist(0, 3));
        _m = mix(_m, v.sublist(3, 6));
        _decl = v[6];
        pose.value = arCameraPose(_g!, _m!, declination: _decl);
      },
      onError: (Object e) {
        error.value = e is PlatformException ? (e.message ?? e.code) : '$e';
      },
    );
  }

  Future<void> setLocation(double lat, double lon) async {
    try {
      await _ctl.invokeMethod<void>('setLocation', {'lat': lat, 'lon': lon});
    } catch (_) {}
  }

  void dispose() {
    unawaited(_sub?.cancel());
    pose.dispose();
    error.dispose();
  }
}

class ArViewScreen extends StatefulWidget {
  const ArViewScreen({super.key});

  @override
  State<ArViewScreen> createState() => _ArViewScreenState();
}

class _ArViewScreenState extends State<ArViewScreen> {
  final _orientation = _Orientation();
  MobileScannerController? _camera;
  bool _cameraFailed = false;
  bool _located = false;

  // Photos and voice messages with a place: collected every few seconds,
  // not every frame.
  List<MosaicPhoto> _photos = const [], _clips = const [];
  DateTime _mediaAt = DateTime.fromMillisecondsSinceEpoch(0);

  // The chime: on unless turned off (remembered), and who's in the middle.
  static const _kChime = 'ar_chime';
  bool _chimeOn = true;
  final Set<String> _inView = {};
  final WatchSoundPlayer _sound = WatchSoundPlayer();
  DateTime _lastChime = DateTime.fromMillisecondsSinceEpoch(0);

  // A portrait camera picture shown edge to edge: what it covers, roughly.
  static const double _hFov = 52, _vFov = 70;

  @override
  void initState() {
    super.initState();
    unawaited(
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
    );
    if (!kIsWeb) {
      _camera = MobileScannerController(
        facing: CameraFacing.back,
        detectionSpeed: DetectionSpeed.noDuplicates,
        formats: const [BarcodeFormat.aztec],
      );
    }
    _orientation.start();
    unawaited(() async {
      try {
        final p = await SharedPreferences.getInstance();
        final on = p.getBool(_kChime) ?? true;
        if (mounted && on != _chimeOn) setState(() => _chimeOn = on);
      } catch (_) {}
    }());
  }

  Future<void> _setChime(bool on) async {
    setState(() => _chimeOn = on);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kChime, on);
    } catch (_) {}
  }

  /// A teammate or report just came into the middle of the view.
  void _chimeFor(List<String> arrived) {
    if (!_chimeOn || arrived.isEmpty) return;
    final now = DateTime.now();
    if (now.difference(_lastChime) < const Duration(milliseconds: 700)) return;
    _lastChime = now;
    unawaited(HapticFeedback.selectionClick());
    unawaited(_sound.play(WatchSound.ping));
  }

  @override
  void dispose() {
    unawaited(SystemChrome.setPreferredOrientations(const []));
    unawaited(_camera?.dispose());
    _orientation.dispose();
    _sound.dispose();
    super.dispose();
  }

  List<ArTarget> _targets(BuildContext context, TeamService team) {
    final watch = context.read<WatchFeedService>();
    final out = <ArTarget>[];
    final hound = team.bloodhound;
    if (hound != null) {
      out.add(
        ArTarget(
          id: 'h',
          chime: true,
          label: hound.label,
          lat: hound.lat,
          lon: hound.lon,
          color: const Color(0xFFFF6D00),
          icon: Icons.track_changes,
        ),
      );
    }
    for (final m in team.members) {
      out.add(
        ArTarget(
          id: 'm:${m.key4}',
          chime: true,
          label: m.callsign,
          lat: m.position.lat,
          lon: m.position.lon,
          color: Color(m.position.color.argb),
          icon: Icons.person,
          onTap: () => team.houndMember(m.key4),
        ),
      );
    }
    for (final p in team.markers) {
      final label = p.label.isEmpty ? p.kind.label : p.label;
      out.add(
        ArTarget(
          id: 'p:${p.lat},${p.lon}',
          label: label,
          lat: p.lat,
          lon: p.lon,
          color: markerKindColor(p.kind),
          icon: markerKindIcon(p.kind),
          onTap: () => team.houndPoint(p.lat, p.lon, label),
        ),
      );
    }
    for (final w in watch.mapItems) {
      if (!w.hasPosition) continue;
      out.add(
        ArTarget(
          id: 'w:${w.key}',
          chime: true,
          label: w.headline,
          lat: w.lat!,
          lon: w.lon!,
          color: Color(w.level.argb),
          icon: Icons.visibility_outlined,
          onTap: () => team.houndPoint(w.lat!, w.lon!, w.headline),
        ),
      );
    }
    _refreshMedia(context, team);
    final voice = context.read<VoxVoiceService>();
    for (final p in _photos) {
      final from = p.approximate ? '${p.from} (≈)' : p.from;
      out.add(
        ArTarget(
          id: 'ph:${p.sid}',
          label: p.caption.isEmpty ? from : '$from: ${p.caption}',
          lat: p.lat,
          lon: p.lon,
          color: const Color(0xFF26C6DA),
          icon: Icons.photo_outlined,
          image: mosaicThumb(voice, p.envelope),
          hounds: false,
          onTap: () => _openPhoto(context, p),
        ),
      );
    }
    for (final c in _clips) {
      final from = c.approximate ? '${c.from} (≈)' : c.from;
      final secs = c.envelope.durationSeconds;
      out.add(
        ArTarget(
          id: 'v:${c.sid}',
          label: c.envelope.isTalk ? '$from: Talk ${secs}s' : '$from: ${secs}s',
          lat: c.lat,
          lon: c.lon,
          color: const Color(0xFFAB47BC),
          icon: c.envelope.isTalk ? Icons.campaign_outlined : Icons.mic_none,
          hounds: false,
          onTap: () => _playClip(context, c),
        ),
      );
    }
    return out;
  }

  void _refreshMedia(BuildContext context, TeamService team) {
    final now = DateTime.now();
    if (now.difference(_mediaAt) < const Duration(seconds: 5)) return;
    _mediaAt = now;
    final connector = context.read<MeshCoreConnector>();
    // The newest few: enough to find your way, few enough to read.
    _photos = collectMosaicPhotos(connector, team).take(20).toList();
    _clips = collectMosaicPhotos(
      connector,
      team,
      voice: true,
    ).take(20).toList();
  }

  Future<void> _openPhoto(BuildContext context, MosaicPhoto p) async {
    final voice = context.read<VoxVoiceService>();
    if (voice.stateFor(p.envelope).status == VoxClipStatus.complete) {
      await showMosaicTimeline(context, [p]);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.l10n.ar_downloading(p.from)),
        duration: const Duration(seconds: 2),
      ),
    );
    await voice.requestAndPlay(
      p.envelope,
      sender: p.contact,
      channelIndex: p.channelIndex,
    );
  }

  Future<void> _playClip(BuildContext context, MosaicPhoto c) async {
    final voice = context.read<VoxVoiceService>();
    if (voice.stateFor(c.envelope).status == VoxClipStatus.complete) {
      await voice.play(c.envelope);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.l10n.ar_downloading(c.from)),
        duration: const Duration(seconds: 2),
      ),
    );
    await voice.requestAndPlay(
      c.envelope,
      sender: c.contact,
      channelIndex: c.channelIndex,
    );
  }

  String _distance(double m) => m < 1000
      ? '${m.round()} m'
      : '${(m / 1000).toStringAsFixed(m < 10000 ? 1 : 0)} km';

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final team = context.watch<TeamService>();
    final fix = team.fix;
    if (fix != null && !_located) {
      _located = true;
      unawaited(_orientation.setLocation(fix.lat, fix.lon));
    }
    final cam = _camera;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        title: Text(l.ar_title),
        actions: [
          IconButton(
            icon: Icon(_chimeOn ? Icons.volume_up : Icons.volume_off),
            tooltip: l.ar_chime,
            onPressed: () => _setChime(!_chimeOn),
          ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (cam != null && !_cameraFailed)
            MobileScanner(
              controller: cam,
              fit: BoxFit.cover,
              errorBuilder: (context, error) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && !_cameraFailed) {
                    setState(() => _cameraFailed = true);
                  }
                });
                return const ColoredBox(color: Colors.black);
              },
            ),
          ValueListenableBuilder(
            valueListenable: _orientation.pose,
            builder: (context, pose, _) => LayoutBuilder(
              builder: (context, box) => _overlay(
                context,
                box.biggest,
                pose,
                fix == null ? null : (fix.lat, fix.lon),
                _targets(context, team),
              ),
            ),
          ),
          ValueListenableBuilder(
            valueListenable: _orientation.error,
            builder: (context, err, _) => err == null
                ? const SizedBox.shrink()
                : _banner(context, l.ar_noCompass(err)),
          ),
          if (fix == null) _banner(context, l.ar_noPosition),
        ],
      ),
    );
  }

  Widget _banner(BuildContext context, String text) => Align(
    alignment: Alignment.bottomCenter,
    child: SafeArea(
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text, style: const TextStyle(color: Colors.white)),
      ),
    ),
  );

  Widget _overlay(
    BuildContext context,
    Size size,
    ({double azimuth, double pitch})? pose,
    (double, double)? me,
    List<ArTarget> targets,
  ) {
    if (pose == null || me == null) return const SizedBox.shrink();
    final horizon = size.height / 2 + pose.pitch / (_vFov / 2) * size.height / 2;
    final placed = <Rect>[];
    final labels = <Widget>[];
    final left = <(ArTarget, double)>[], right = <(ArTarget, double)>[];
    // Nearest first: they get the spot nearest the horizon.
    final withDist = [
      for (final t in targets)
        (
          t,
          teamDistanceMeters(me.$1, me.$2, t.lat, t.lon),
          teamBearingDeg(me.$1, me.$2, t.lat, t.lon),
        ),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    // The chime: teammates and reports coming into the middle of the view.
    final offsets = <String, double>{
      for (final (t, _, bearing) in withDist)
        if (t.chime && t.id.isNotEmpty)
          t.id: arAngleDiff(pose.azimuth, bearing),
    };
    final arrived = arChimeStep(offsets, _inView);
    if (arrived.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _chimeFor(arrived));
    }
    for (final (t, dist, bearing) in withDist) {
      final d = arAngleDiff(pose.azimuth, bearing);
      if (d.abs() > _hFov / 2 + 4) {
        (d < 0 ? left : right).add((t, dist));
        continue;
      }
      final x = size.width / 2 + d / (_hFov / 2) * size.width / 2;
      // A photo's label carries its picture: wider and taller.
      final w = t.image != null ? 190.0 : 150.0;
      final h = t.image != null ? 64.0 : 44.0;
      var r = Rect.fromLTWH(x - w / 2, horizon - h - 8, w, h);
      while (placed.any((p) => p.overlaps(r)) && r.top > 60) {
        r = r.translate(0, -(h + 4));
      }
      placed.add(r);
      labels.add(
        Positioned.fromRect(
          rect: r,
          child: _ArLabel(
            target: t,
            distance: _distance(dist),
            onTap: t.onTap == null
                ? null
                : !t.hounds
                ? t.onTap
                : () {
                    t.onTap!();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(context.l10n.ar_hounding(t.label)),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  },
          ),
        ),
      );
    }
    String cardinal(double a) =>
        const ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'][((a + 22.5) % 360) ~/ 45];
    Widget side(List<(ArTarget, double)> list, bool isLeft) => Positioned(
      left: isLeft ? 8 : null,
      right: isLeft ? null : 8,
      top: size.height * 0.35,
      child: Column(
        crossAxisAlignment: isLeft
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.end,
        children: [
          for (final (t, dist) in list.take(3))
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                isLeft
                    ? '◀ ${t.label} ${_distance(dist)}'
                    : '${t.label} ${_distance(dist)} ▶',
                style: TextStyle(color: t.color, fontSize: 12),
              ),
            ),
        ],
      ),
    );
    return Stack(
      children: [
        // The horizon, faint.
        Positioned(
          left: 0,
          right: 0,
          top: horizon,
          child: Container(height: 1, color: Colors.white24),
        ),
        ...labels,
        side(left, true),
        side(right, false),
        // Heading at the top.
        Positioned(
          top: MediaQuery.of(context).padding.top + kToolbarHeight + 8,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                '${pose.azimuth.round()}° ${cardinal(pose.azimuth)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ArLabel extends StatelessWidget {
  final ArTarget target;
  final String distance;
  final VoidCallback? onTap;
  const _ArLabel({required this.target, required this.distance, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: target.color, width: 2),
        ),
        child: Row(
          children: [
            if (target.image != null)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 52,
                    height: 52,
                    child: RawImage(
                      image: target.image,
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                ),
              )
            else ...[
              Icon(target.icon, color: target.color, size: 18),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    target.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    distance,
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
