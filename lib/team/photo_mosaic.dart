// MeshCore Open TAK - the photo mosaic: photos received over MediaMesh shown
// as thumbnails on the map where they were taken, grouped when zoomed out; a
// tap opens them as a timeline (documentation/photo-mosaic.md). A map toggle
// (Tools > Photos), off until turned on.
//
// Where a photo was taken, best first:
//   1. a position in its caption ("📍47.60378,-122.34052", which this app adds
//      when "Tag my photos" is on, or any coordinates someone wrote);
//   2. the team pin or report it is attached to;
//   3. roughly: where its sender was then (a teammate's track, this phone's
//      own track, or the sender's advertised position). These are marked
//      "about here".

import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';
import '../vox/image_message_bubble.dart' show voxRgbToUiImage;
import '../vox/voice_service.dart';
import '../vox/voice_wire.dart';
import 'photo_mosaic_prefs.dart';
import 'team_service.dart';
import 'team_wire.dart';
import 'watch_feed.dart' show watchPositions;

/// A photo with a place.
class MosaicPhoto {
  final VoxVoiceEnvelope envelope;
  final double lat, lon;
  final DateTime time;
  final String from;
  final String where; // the channel or chat it came in
  final bool approximate;
  const MosaicPhoto({
    required this.envelope,
    required this.lat,
    required this.lon,
    required this.time,
    required this.from,
    required this.where,
    required this.approximate,
  });

  String get sid => envelope.sessionId;
  LatLng get point => LatLng(lat, lon);

  /// The caption without the position tag.
  String get caption =>
      envelope.caption.replaceAll(RegExp(r'\s*📍\S+'), '').trim();
}

/// Where the first position written in [caption] is, or null.
(double, double)? mosaicCaptionPosition(String caption) {
  final tag = RegExp(r'📍\s*(-?\d{1,2}\.\d+)\s*,\s*(-?\d{1,3}\.\d+)').firstMatch(caption);
  if (tag != null) {
    final la = double.tryParse(tag.group(1)!), lo = double.tryParse(tag.group(2)!);
    if (la != null && lo != null && la.abs() <= 90 && lo.abs() <= 180) {
      return (la, lo);
    }
  }
  final any = watchPositions(caption);
  if (any.isEmpty) return null;
  return (any.first.$3, any.first.$4);
}

/// The point of [track] nearest [t] in time, if within [within].
(double, double)? mosaicNearestInTime(
  List<(double, double, DateTime)> track,
  DateTime t, {
  Duration within = const Duration(minutes: 30),
}) {
  (double, double)? best;
  Duration? gap;
  for (final p in track) {
    final d = p.$3.difference(t).abs();
    if (d > within) continue;
    if (gap == null || d < gap) {
      gap = d;
      best = (p.$1, p.$2);
    }
  }
  return best;
}

/// Every photo this app knows of with a place, newest first.
List<MosaicPhoto> collectMosaicPhotos(
  MeshCoreConnector connector,
  TeamService team,
) {
  final out = <String, MosaicPhoto>{};

  (double, double)? senderAt(String name, DateTime t, bool own) {
    if (own) return mosaicNearestInTime(team.myTrack, t);
    for (final m in team.members) {
      if (m.callsign != name &&
          m.position.nameHash != TeamService.nameHash(name)) {
        continue;
      }
      return mosaicNearestInTime(m.trail, t) ??
          (m.heard.difference(t).abs() < const Duration(minutes: 30)
              ? (m.position.lat, m.position.lon)
              : null);
    }
    for (final c in connector.contacts) {
      if (c.name == name && c.hasLocation && c.latitude != null) {
        return (c.latitude!, c.longitude!);
      }
    }
    return null;
  }

  void add(
    VoxVoiceEnvelope env,
    DateTime t,
    String from,
    String where,
    bool own, {
    Contact? contact,
  }) {
    if (!env.isImage || out.containsKey(env.sessionId)) return;
    var p = mosaicCaptionPosition(env.caption);
    var approx = false;
    if (p == null) {
      approx = true;
      p = senderAt(from, t, own);
      if (p == null &&
          contact != null &&
          contact.hasLocation &&
          contact.latitude != null) {
        p = (contact.latitude!, contact.longitude!);
      }
    }
    if (p == null) return;
    out[env.sessionId] = MosaicPhoto(
      envelope: env,
      lat: p.$1,
      lon: p.$2,
      time: t,
      from: from,
      where: where,
      approximate: approx,
    );
  }

  // Pins and reports first: their place is exact.
  VoxVoiceEnvelope? attached(TeamAttachment? a) {
    if (a == null) return null;
    final mode = VoxVoiceMode.fromWireId(a.modeWireId);
    if (mode == null || !mode.isImage) return null;
    return VoxVoiceEnvelope(
      sessionId: a.sessionId,
      mode: mode,
      totalPackets: max(1, a.packets),
      durationSeconds: a.extra,
    );
  }

  String who(String key4) =>
      key4 == team.selfKey4 ? team.callsign : team.memberByKey(key4)?.callsign ?? key4.toUpperCase();
  for (final m in team.markers) {
    final env = attached(m.attachment);
    if (env == null || out.containsKey(env.sessionId)) continue;
    out[env.sessionId] = MosaicPhoto(
      envelope: env.withCaption(m.label),
      lat: m.lat,
      lon: m.lon,
      time: m.time,
      from: who(m.authorKey4),
      where: m.label.isEmpty ? m.kind.label : m.label,
      approximate: false,
    );
  }
  for (final r in team.reports) {
    final env = attached(r.attachment);
    if (env == null || out.containsKey(env.sessionId)) continue;
    out[env.sessionId] = MosaicPhoto(
      envelope: env.withCaption(r.title),
      lat: r.lat,
      lon: r.lon,
      time: r.observed,
      from: who(r.authorKey4),
      where: r.title,
      approximate: false,
    );
  }
  final me = connector.selfName ?? '';
  for (final c in connector.channels) {
    for (final m in connector.getChannelMessages(c)) {
      final env = VoxVoiceEnvelope.tryParse(m.text);
      if (env == null || !env.isImage) continue;
      add(
        env,
        m.timestamp,
        m.isOutgoing ? me : m.senderName,
        c.name,
        m.isOutgoing,
      );
    }
  }
  for (final c in connector.contacts) {
    for (final m in connector.getMessages(c)) {
      final env = VoxVoiceEnvelope.tryParse(m.text);
      if (env == null || !env.isImage) continue;
      add(
        env,
        m.timestamp,
        m.isOutgoing ? me : c.name,
        c.name,
        m.isOutgoing,
        contact: m.isOutgoing ? null : c,
      );
    }
  }
  final list = out.values.toList()..sort((a, b) => b.time.compareTo(a.time));
  return list;
}

/// Photos within [px] of each other on screen go together; each group's
/// first photo is its newest.
List<List<MosaicPhoto>> clusterMosaic(
  List<MosaicPhoto> photos,
  Offset Function(LatLng) toScreen, {
  double px = 64,
}) {
  final groups = <(Offset, List<MosaicPhoto>)>[];
  for (final p in photos) {
    final o = toScreen(p.point);
    var placed = false;
    for (final g in groups) {
      if ((g.$1 - o).distance <= px) {
        g.$2.add(p);
        placed = true;
        break;
      }
    }
    if (!placed) groups.add((o, [p]));
  }
  return [for (final g in groups) g.$2];
}

// ------------------------------------------------------------- thumbnails

/// Decoded photos for the map, small and few.
class _Thumbs {
  _Thumbs._();
  static final _Thumbs instance = _Thumbs._();

  final Map<String, ui.Image?> _done = {};
  final Set<String> _loading = {};
  final ValueNotifier<int> version = ValueNotifier(0);

  ui.Image? get(VoxVoiceService voice, VoxVoiceEnvelope env) {
    final sid = env.sessionId;
    if (_done.containsKey(sid)) return _done[sid];
    if (_loading.length < 3 && _loading.add(sid)) {
      unawaited(() async {
        ui.Image? img;
        try {
          final rgb = await voice.imageFor(env);
          if (rgb != null) img = await voxRgbToUiImage(rgb);
        } catch (_) {}
        _loading.remove(sid);
        _done[sid] = img;
        while (_done.length > 80) {
          _done.remove(_done.keys.first);
        }
        version.value++;
      }());
    }
    return null;
  }

  /// Not decodable (not downloaded yet, or this build can't).
  bool missing(String sid) => _done.containsKey(sid) && _done[sid] == null;
}

// --------------------------------------------------------------- map layer

/// The photos on the map, when the toggle is on.
class PhotoMosaicLayer extends StatelessWidget {
  const PhotoMosaicLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: PhotoMosaicPrefs.show,
      builder: (context, on, _) {
        if (!on) return const SizedBox.shrink();
        return ValueListenableBuilder<int>(
          valueListenable: _Thumbs.instance.version,
          builder: (context, _, _) => const _MosaicMarkers(),
        );
      },
    );
  }
}

class _MosaicMarkers extends StatelessWidget {
  const _MosaicMarkers();

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    final team = context.watch<TeamService>();
    final voice = context.read<VoxVoiceService>();
    final camera = MapCamera.of(context);
    final thumbs = _Thumbs.instance;
    final bounds = camera.visibleBounds;
    final photos = [
      for (final p in collectMosaicPhotos(connector, team))
        if (bounds.contains(p.point) && !thumbs.missing(p.sid)) p,
    ].take(120).toList();
    final groups = clusterMosaic(
      photos,
      (p) => camera.latLngToScreenOffset(p),
    );
    return MarkerLayer(
      markers: [
        for (final g in groups)
          Marker(
            point: g.first.point,
            width: 64,
            height: 64,
            child: GestureDetector(
              onTap: () => showMosaicTimeline(context, g),
              child: _Tile(
                image: thumbs.get(voice, g.first.envelope),
                count: g.length,
                approximate: g.every((p) => p.approximate),
              ),
            ),
          ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  final ui.Image? image;
  final int count;
  final bool approximate;
  const _Tile({
    required this.image,
    required this.count,
    required this.approximate,
  });

  @override
  Widget build(BuildContext context) {
    final img = image;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: approximate ? Colors.white54 : Colors.white,
              width: 2,
            ),
            boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black45)],
          ),
          clipBehavior: Clip.antiAlias,
          child: img == null
              ? const Icon(Icons.photo_camera, color: Colors.white70)
              : Opacity(
                  opacity: approximate ? 0.8 : 1,
                  child: RawImage(image: img, fit: BoxFit.cover),
                ),
        ),
        if (count > 1)
          Positioned(
            right: -6,
            top: -6,
            child: CircleAvatar(
              radius: 11,
              backgroundColor: Theme.of(context).colorScheme.primary,
              child: Text(
                count > 99 ? '99+' : '$count',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onPrimary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ----------------------------------------------------------------- timeline

String _when(BuildContext context, DateTime t) {
  final l = MaterialLocalizations.of(context);
  final now = DateTime.now();
  final time = l.formatTimeOfDay(TimeOfDay.fromDateTime(t));
  if (now.difference(t).inHours < 20 && now.day == t.day) return time;
  return '${l.formatShortMonthDay(t)} $time';
}

/// [photos] in time order (newest first); a tap opens one full size.
Future<void> showMosaicTimeline(BuildContext context, List<MosaicPhoto> photos) {
  final voice = context.read<VoxVoiceService>();
  final sorted = [...photos]..sort((a, b) => b.time.compareTo(a.time));
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              context.l10n.mosaic_timelineTitle(sorted.length),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: _Thumbs.instance.version,
              builder: (context, _, _) => ListView.builder(
                controller: scroll,
                itemCount: sorted.length,
                itemBuilder: (context, i) {
                  final p = sorted[i];
                  final img = _Thumbs.instance.get(voice, p.envelope);
                  return InkWell(
                    onTap: img == null ? null : () => _openFull(context, p, img),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 96,
                            height: 72,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: img == null
                                  ? const ColoredBox(
                                      color: Colors.black26,
                                      child: Icon(Icons.photo_camera),
                                    )
                                  : RawImage(image: img, fit: BoxFit.cover),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${p.from} · ${_when(context, p.time)}',
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                                Text(
                                  p.where,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                if (p.caption.isNotEmpty) Text(p.caption),
                                if (p.approximate)
                                  Text(
                                    context.l10n.mosaic_approx,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(fontStyle: FontStyle.italic),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

void _openFull(BuildContext context, MosaicPhoto p, ui.Image img) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text('${p.from} · ${_when(context, p.time)}'),
        ),
        body: Center(
          child: InteractiveViewer(
            maxScale: 6,
            child: RawImage(image: img, fit: BoxFit.contain),
          ),
        ),
      ),
    ),
  );
}

// ----------------------------------------------------------------- settings

/// Tools > Photos: the map toggle, tagging, and every placed photo.
Future<void> showPhotoMosaicSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        final l = context.l10n;
        final photos = collectMosaicPhotos(
          context.read<MeshCoreConnector>(),
          context.read<TeamService>(),
        );
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: PhotoMosaicPrefs.show,
                builder: (_, on, _) => SwitchListTile(
                  secondary: const Icon(Icons.photo_library_outlined),
                  title: Text(l.mosaic_show),
                  subtitle: Text(l.mosaic_showHelp(photos.length)),
                  value: on,
                  onChanged: (v) => unawaited(PhotoMosaicPrefs.setShow(v)),
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: PhotoMosaicPrefs.tagOwn,
                builder: (_, on, _) => SwitchListTile(
                  secondary: const Icon(Icons.add_location_alt_outlined),
                  title: Text(l.mosaic_tag),
                  subtitle: Text(l.mosaic_tagHelp),
                  value: on,
                  onChanged: (v) => unawaited(PhotoMosaicPrefs.setTagOwn(v)),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.view_timeline_outlined),
                title: Text(l.mosaic_all),
                enabled: photos.isNotEmpty,
                onTap: () {
                  Navigator.pop(context);
                  unawaited(showMosaicTimeline(context, photos));
                },
              ),
            ],
          ),
        );
      },
    );
