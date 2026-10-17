// MeshCore Open TAK - watch feeds: show chosen channels (e.g. #icewatch,
// #dronewatch) as a compact, filterable report feed on the Tactical screen.
//
// Messages in the condensed report format bots like IceBot post
//   🔴 CRITICAL / 10-03 11:30 / @Auburn E Main St / 3-🚗 5-🥾 / https://…
// are parsed into structured cards. Anything else is shown as plain text.
// Messages with coordinates (or a shared map marker) also go on the map, for
// as long as the Watch tab's "On map" setting allows.
//
// Detector bots get some extra handling, e.g. a drone detector's
//   DRONE 1581F9DEV26590296G6G h251m 1m/s https://maps.google.com/?q=47.60378,-122.34052
//   Op https://maps.google.com/?q=47.60531,-122.34016
// is one drone (only its latest report stays on the map) with its operator's
// position, and a bot's bare link right after its report is folded into it.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connector/meshcore_connector.dart';
import '../models/channel.dart';
import '../models/channel_message.dart';
import 'team_wire.dart' show teamBearingDeg, teamDistanceMeters;
import 'watch_sounds.dart';

/// Status levels found in feed reports, most urgent first.
enum WatchLevel {
  critical('CRITICAL', 0xFFE53935),
  active('ACTIVE', 0xFFFDD835),
  observed('OBSERVED', 0xFF43A047),
  other('OTHER', 0xFF1E88E5),
  none('', 0xFF9E9E9E);

  const WatchLevel(this.label, this.argb);
  final String label;
  final int argb;
}

class WatchItem {
  final Channel channel;
  final ChannelMessage message;
  final WatchLevel level;
  final String? statusWord;
  final String? when; // as written in the report, e.g. "10-03 11:30"
  final String? place;
  final List<(int, String)> counts; // (3, '🚗')
  final String? url;
  final double? lat, lon;
  final List<String> otherLines;

  /// When it happened: the sender's time if their clock is plausible, else
  /// when this phone first saw it (some detectors send 1970).
  final DateTime time;

  /// A second position in the same message, e.g. a drone's operator ("Op").
  final double? lat2, lon2;
  final String? label2;

  /// Something reported again and again (a drone by serial): only the
  /// newest report of each goes on the map. "DRONE 1581F9…" etc.
  final String? trackId;

  /// Short facts after the id, e.g. "h251m 1m/s".
  final String? detail;

  /// Direction of travel the sender reported, in degrees, if any.
  final double? bearing;

  /// An earthquake report's magnitude ("Earthquake M3.9 …"), else null.
  final double? magnitude;

  const WatchItem({
    required this.channel,
    required this.message,
    this.level = WatchLevel.none,
    this.statusWord,
    this.when,
    this.place,
    this.counts = const [],
    this.url,
    this.lat,
    this.lon,
    this.otherLines = const [],
    required this.time,
    this.lat2,
    this.lon2,
    this.label2,
    this.trackId,
    this.detail,
    this.bearing,
    this.magnitude,
  });

  bool get hasSecondPosition => lat2 != null && lon2 != null;

  /// The short name the map puts before a report: "ICE" for an ICE watch
  /// channel (#icewatch, or anything IceBot posts), else the channel's name.
  String get mapTag => watchMapTag(channel.name, message.senderName);
  bool get isDrone => trackId?.startsWith('DRONE') ?? false;
  bool get isQuake => magnitude != null;

  /// What the map writes beside a report's dot: "QUAKE M3.9 Castle Rock",
  /// "ICE Portland NE …", "#channel place".
  String get mapLabel {
    if (isQuake) {
      final p = place ?? '';
      final of = p.toLowerCase().lastIndexOf(' of ');
      final town = (of >= 0 ? p.substring(of + 4) : p).split(',').first.trim();
      return 'QUAKE M${magnitude!.toStringAsFixed(1)} $town'.trim();
    }
    return '$mapTag ${place ?? statusWord ?? ''}'.trim();
  }

  /// The map's label for a drone: "DRONE 1581F9DE h251m 1m/s 045° NE" (the
  /// first 8 letters and digits of its serial, then height, speed and
  /// direction of travel when known). [course] is used when the report has
  /// no direction of its own (e.g. worked out from its previous position).
  String droneLabel([double? course]) {
    final serial = (trackId ?? '').replaceFirst('DRONE ', '');
    final short = serial.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final b = bearing ?? course;
    return [
      'DRONE ${short.length > 8 ? short.substring(0, 8) : short}',
      ?detail,
      if (b != null) watchBearingLabel(b),
    ].join(' ');
  }

  /// Only a link (a bot posting its report's URL on its own).
  bool get isBareLink =>
      url != null &&
      !hasPosition &&
      statusWord == null &&
      place == null &&
      counts.isEmpty &&
      otherLines.isEmpty;

  WatchItem withUrl(String u) => WatchItem(
    channel: channel,
    message: message,
    level: level,
    statusWord: statusWord,
    when: when,
    place: place,
    counts: counts,
    url: u,
    lat: lat,
    lon: lon,
    otherLines: otherLines,
    time: time,
    lat2: lat2,
    lon2: lon2,
    label2: label2,
    trackId: trackId,
    detail: detail,
    bearing: bearing,
    magnitude: magnitude,
  );

  bool get isStructured =>
      statusWord != null || place != null || counts.isNotEmpty;
  bool get hasPosition => lat != null && lon != null;
  String get key => '${channel.index}:${message.messageId}';

  /// Everything the Watch search looks through, lower-cased.
  String get searchText => [
    statusWord,
    place,
    trackId,
    detail,
    label2,
    level == WatchLevel.none ? null : level.label,
    channel.name,
    message.senderName,
    message.text,
    ...otherLines,
  ].whereType<String>().join('\n').toLowerCase();

  /// The search box's words: every one must appear (any order, any case).
  bool matches(List<String> words) {
    if (words.isEmpty) return true;
    final text = searchText;
    return words.every(text.contains);
  }

  /// One-line headline for the card.
  String get headline {
    if (trackId != null) return trackId!;
    if (place != null) return place!;
    if (otherLines.isNotEmpty) return otherLines.first;
    return message.text.split('\n').first;
  }
}

final _dotLevels = <String, WatchLevel>{
  '🔴': WatchLevel.critical,
  '🟠': WatchLevel.active,
  '🟡': WatchLevel.active,
  '🟢': WatchLevel.observed,
  '🔵': WatchLevel.other,
  '🟣': WatchLevel.other,
  '⚪': WatchLevel.none,
};

final _whenRe = RegExp(r'^\d{1,2}[-/]\d{1,2}\s+\d{1,2}:\d{2}$');
final _countRe = RegExp(r'(\d+)\s*-\s*([^\s\d]+)');
final _urlRe = RegExp(r'https?://\S+');
final _coordRe = RegExp(r'(-?\d{1,2}\.\d{3,})\s*,\s*(-?\d{1,3}\.\d{3,})');
// Other ways bots write a position:
//   "46.22N 122.60W", "46.22° N, 122.60° W" (hemisphere after)
final _hemiRe = RegExp(
  r'(?<![\d.])(\d{1,2}(?:\.\d+)?)\s*°?\s*([NSns])(?![A-Za-z])[\s,;/]*'
  r'(\d{1,3}(?:\.\d+)?)\s*°?\s*([EWew])(?![A-Za-z])',
);
//   "N46.22 W122.60" (hemisphere before)
final _hemiPreRe = RegExp(
  r'(?<![A-Za-z])([NSns])\s*(\d{1,2}(?:\.\d+)?)°?[\s,;/]+'
  r'([EWew])\s*(\d{1,3}(?:\.\d+)?)°?(?![\d.])',
);
//   "lat 45.52 lon -122.68", "lat: 45.5, lng: -122.6", "latitude=… longitude=…"
final _latLonWordRe = RegExp(
  r'\blat(?:itude)?\s*[:=]?\s*(-?\d{1,2}(?:\.\d+)?)[^\d\n-]{1,12}?'
  r'\b(?:lon|lng|long|longitude)\s*[:=]?\s*(-?\d{1,3}(?:\.\d+)?)',
  caseSensitive: false,
);
//   "45.5625 -122.6108" (two plain decimals, 4+ places each)
final _spaceCoordRe = RegExp(
  r'(?<![\d.])(-?\d{1,2}\.\d{4,})\s+(-?\d{1,3}\.\d{4,})(?![\d.])',
);

//   45°31'30"N 122°40'30"W, 45° 31.5' N 122° 40.5' W, 45d31m30sN (DMS / DDM)
const _dmsOne =
    r'(\d{1,3}(?:\.\d+)?)\s*(?:°|d)\s*(?:(\d{1,2}(?:\.\d+)?)\s*(?:\x27|′|m)\s*'
    r'(?:(\d{1,2}(?:\.\d+)?)\s*(?:"|″|\x27\x27|s)\s*)?)?';
final _dmsRe = RegExp(
  '(?<![\\d.])$_dmsOne([NSns])(?![A-Za-z])[\\s,;/]*$_dmsOne([EWew])(?![A-Za-z])',
);
//   Maidenhead: CN85pm, CN85pm42 (any case); a 4-character square (CN85) only
//   after "grid" / "locator" / "loc".
final _maidenheadRe = RegExp(
  r'(?<![A-Za-z0-9_])([A-Ra-r]{2}\d{2})(?:([A-Xa-x]{2})(\d{2})?)?(?![A-Za-z0-9_])',
);
final _gridCueRe = RegExp(
  r'\b(?:grid|locator|loc)\s*[:=]?\s*$',
  caseSensitive: false,
);

/// The middle of a Maidenhead square: "CN85pm" -> 45.521, -122.708.
(double, double)? maidenheadCenter(String loc) {
  final s = loc.toUpperCase();
  if (s.length < 4 || s.length.isOdd || s.length > 8) return null;
  final a = s.codeUnitAt(0) - 65, b = s.codeUnitAt(1) - 65;
  if (a < 0 || a > 17 || b < 0 || b > 17) return null;
  var lon = a * 20.0 - 180 + int.parse(s[2]) * 2;
  var lat = b * 10.0 - 90 + int.parse(s[3]);
  var w = 2.0, h = 1.0;
  if (s.length >= 6) {
    final c = s.codeUnitAt(4) - 65, d = s.codeUnitAt(5) - 65;
    if (c < 0 || c > 23 || d < 0 || d > 23) return null;
    w = 2 / 24;
    h = 1 / 24;
    lon += c * w;
    lat += d * h;
    if (s.length == 8) {
      w /= 10;
      h /= 10;
      lon += int.parse(s[6]) * w;
      lat += int.parse(s[7]) * h;
    }
  }
  return (lat + h / 2, lon + w / 2);
}

/// Every position written in [text], in order, as (start, end, lat, lon):
/// the comma form first, then the others where they don't overlap it.
List<(int, int, double, double)> watchPositions(String text) {
  final out = <(int, int, double, double)>[];
  bool free(int s, int e) => !out.any((o) => s < o.$2 && e > o.$1);
  void add(int s, int e, double? la, double? lo) {
    if (la == null || lo == null || la.abs() > 90 || lo.abs() > 180) return;
    if (free(s, e)) out.add((s, e, la, lo));
  }

  for (final m in _coordRe.allMatches(text)) {
    add(m.start, m.end, double.tryParse(m[1]!), double.tryParse(m[2]!));
  }
  double? signed(String n, String h) {
    final v = double.tryParse(n);
    if (v == null) return null;
    return 'SWsw'.contains(h) ? -v : v;
  }

  double? dms(String? d, String? m, String? s, String h) {
    final deg = double.tryParse(d ?? '');
    if (deg == null) return null;
    final v =
        deg +
        (double.tryParse(m ?? '') ?? 0) / 60 +
        (double.tryParse(s ?? '') ?? 0) / 3600;
    return 'SWsw'.contains(h) ? -v : v;
  }

  for (final m in _dmsRe.allMatches(text)) {
    add(
      m.start,
      m.end,
      dms(m[1], m[2], m[3], m[4]!),
      dms(m[5], m[6], m[7], m[8]!),
    );
  }
  for (final m in _hemiRe.allMatches(text)) {
    add(m.start, m.end, signed(m[1]!, m[2]!), signed(m[3]!, m[4]!));
  }
  for (final m in _hemiPreRe.allMatches(text)) {
    add(m.start, m.end, signed(m[2]!, m[1]!), signed(m[4]!, m[3]!));
  }
  for (final m in _latLonWordRe.allMatches(text)) {
    add(m.start, m.end, double.tryParse(m[1]!), double.tryParse(m[2]!));
  }
  for (final m in _spaceCoordRe.allMatches(text)) {
    add(m.start, m.end, double.tryParse(m[1]!), double.tryParse(m[2]!));
  }
  for (final m in _maidenheadRe.allMatches(text)) {
    final full = m[0]!;
    if (full.length == 4 && !_gridCueRe.hasMatch(text.substring(0, m.start))) {
      continue;
    }
    final c = maidenheadCenter(full);
    if (c != null) add(m.start, m.end, c.$1, c.$2);
  }
  out.sort((a, b) => a.$1.compareTo(b.$1));
  return out;
}

// "Earthquake M3.9 mw | 24 km ESE of Castle Rock, Washington | 11:09:28 UTC |
// depth 9 km | 46.22N 122.60W" (SeaBot and other quake feeds).
final _quakeRe = RegExp(
  r'\b(?:earthquake|quake)\b[^|\n]{0,20}?\bM\s?(\d(?:\.\d+)?)',
  caseSensitive: false,
);
final _depthRe = RegExp(r'depth\s*(\d+(?:\.\d+)?)\s*km', caseSensitive: false);
final _utcRe = RegExp(r'\b\d{1,2}:\d{2}(?::\d{2})?\s*UTC\b');
// "DRONE <serial>" anywhere in the message (after an emoji, a bot's prefix,
// on its own line...). The serial must hold a digit, so chat like "a drone
// overhead" is not taken for a detection.
final _droneRe = RegExp(
  r'\bDRONE\b[\s:#-]*((?=[A-Za-z0-9-]*\d)[A-Za-z0-9-]{6,})',
  caseSensitive: false,
);
final _factRe = RegExp(
  r'^(h-?\d+m|-?\d+(\.\d+)?m/s|\d+(\.\d+)?\s?km/h|alt\S*)$',
);
// A direction of travel: "123°", "hdg123", "brg:45", "dir 270", "heading 90".
final _bearingRe = RegExp(
  r'(?:\b(?:hdg|brg|dir|crs|cog|heading|bearing|course)[\s:=]*(\d{1,3}(?:\.\d+)?)°?)'
  r'|(?:(?<![\d.])(\d{1,3}(?:\.\d+)?)\s?°)',
  caseSensitive: false,
);

/// "ICE" for ICE watch reports (a channel named for it, or IceBot posting),
/// else the channel name as it is.
String watchMapTag(String channelName, String? sender) {
  final c = channelName.toLowerCase(), who = (sender ?? '').toLowerCase();
  if (c.contains('ice') || who.contains('icebot')) return 'ICE';
  return channelName;
}

/// "045° NE"
String watchBearingLabel(double b) {
  const names = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  final d = ((b % 360) + 360) % 360;
  return '${d.round().toString().padLeft(3, '0')}° ${names[((d + 22.5) ~/ 45) % 8]}';
}

/// Lines that are only a position ("📍 45.5625,-122.6108"), not text.
bool _onlyCoords(String line) {
  var rest = line;
  for (final p in watchPositions(line).reversed) {
    rest = rest.replaceRange(p.$1, p.$2, '');
  }
  rest = rest.replaceAll(RegExp(r'[\s📍,;:]'), '');
  return rest.isEmpty;
}

final _markerRe = RegExp(r'm:(-?[0-9.]+),(-?[0-9.]+)\|');

WatchLevel _levelFromWord(String w) {
  final u = w.toUpperCase();
  for (final l in WatchLevel.values) {
    if (l.label.isNotEmpty && u.contains(l.label)) return l;
  }
  if (u.contains('URGENT') || u.contains('ALERT')) return WatchLevel.critical;
  return WatchLevel.none;
}

/// Parses one channel message into a feed item. [time] is when it happened
/// (see [WatchItem.time]); it defaults to the message's own timestamp.
WatchItem parseWatchMessage(
  Channel channel,
  ChannelMessage m, {
  DateTime? time,
}) {
  var level = WatchLevel.none;
  String? status, when, place, url, trackId, detail, label2;
  double? bearing;
  final counts = <(int, String)>[];
  final other = <String>[];
  double? lat, lon, lat2, lon2;

  (double, double)? valid(String? a, String? b) {
    final x = double.tryParse(a ?? ''), y = double.tryParse(b ?? '');
    if (x == null || y == null || x.abs() > 90 || y.abs() > 180) return null;
    return (x, y);
  }

  final mk = _markerRe.firstMatch(m.text);
  if (mk != null) {
    final v = valid(mk.group(1), mk.group(2));
    if (v != null) (lat, lon) = (v.$1, v.$2);
  } else {
    // Every position in the message: the first is the report's; a second one
    // takes the word just before it as its label ("Op" for an operator).
    var prevEnd = 0;
    for (final co in watchPositions(m.text)) {
      final v = (co.$3, co.$4);
      if (lat == null) {
        (lat, lon) = (v.$1, v.$2);
      } else if (lat2 == null) {
        (lat2, lon2) = (v.$1, v.$2);
        final words = m.text
            .substring(prevEnd, co.$1)
            .split(RegExp(r'\s+'))
            .where(
              (w) => w.isNotEmpty && !w.contains('://') && !w.contains('='),
            )
            .toList();
        label2 = words.isEmpty ? null : words.last;
      }
      prevEnd = co.$2;
    }
  }

  final drone = _droneRe.firstMatch(m.text);
  if (drone != null) {
    trackId = 'DRONE ${drone.group(1)}';
    level = WatchLevel.active;
    status = 'DRONE';
    final facts = [
      for (final w in m.text.substring(drone.end).split(RegExp(r'\s+')))
        if (_factRe.hasMatch(w)) w,
    ];
    if (facts.isNotEmpty) detail = facts.join(' ');
    final b = _bearingRe.firstMatch(m.text.substring(drone.end));
    final v = double.tryParse(b?.group(1) ?? b?.group(2) ?? '');
    if (v != null && v <= 360) bearing = v;
  }

  // An earthquake: magnitude, where, how deep, when.
  final quake = drone == null ? _quakeRe.firstMatch(m.text) : null;
  double? magnitude;
  if (quake != null) {
    magnitude = double.tryParse(quake[1]!);
    if (magnitude != null) {
      level = magnitude >= 5
          ? WatchLevel.critical
          : magnitude >= 4
          ? WatchLevel.active
          : WatchLevel.other;
      status = 'QUAKE M${magnitude.toStringAsFixed(1)}';
      for (final seg in m.text.split(RegExp(r'[|\n]'))) {
        final s = seg.trim();
        if (place == null && s.toLowerCase().contains(' of ')) place = s;
      }
      final d = _depthRe.firstMatch(m.text);
      if (d != null) detail = 'depth ${d[1]} km';
      when = _utcRe.firstMatch(m.text)?.group(0);
    }
  }

  for (final raw
      in drone != null || magnitude != null
          ? const <String>[]
          : m.text.split('\n')) {
    var line = raw.trim();
    if (line.isEmpty) continue;
    final u = _urlRe.firstMatch(line);
    if (u != null) {
      url ??= u.group(0);
      line = line.replaceFirst(u.group(0)!, '').trim();
      if (line.isEmpty) continue;
    }
    // Leading status dot ("🔴 CRITICAL").
    String? dot;
    for (final d in _dotLevels.keys) {
      if (line.startsWith(d)) {
        dot = d;
        break;
      }
    }
    if (status == null && dot != null) {
      level = _dotLevels[dot]!;
      status = line.substring(dot.length).trim();
      final byWord = _levelFromWord(status);
      if (byWord != WatchLevel.none) level = byWord;
      continue;
    }
    if (when == null && _whenRe.hasMatch(line)) {
      when = line;
      continue;
    }
    final at = line.indexOf('@');
    if (place == null && at >= 0 && at <= 4) {
      place = line.substring(at + 1).trim();
      continue;
    }
    final cs = _countRe.allMatches(line).toList();
    if (cs.isNotEmpty &&
        cs.map((c) => c.group(0)!.length).fold<int>(0, (a, b) => a + b) >=
            line.replaceAll(' ', '').length * 0.6) {
      for (final c in cs) {
        counts.add((int.parse(c.group(1)!), c.group(2)!));
      }
      continue;
    }
    if (lat != null && _onlyCoords(line)) continue; // shown as the map point
    other.add(line);
  }
  if (drone != null) url = _urlRe.firstMatch(m.text)?.group(0);
  if (status == null) {
    final w = _levelFromWord(m.text.split('\n').first);
    if (w != WatchLevel.none) {
      level = w;
      status = w.label;
    }
  }
  return WatchItem(
    channel: channel,
    message: m,
    level: level,
    statusWord: status,
    when: when,
    place: place,
    counts: counts,
    url: url,
    lat: lat,
    lon: lon,
    otherLines: other,
    time: time ?? m.timestamp,
    lat2: lat2,
    lon2: lon2,
    label2: label2,
    trackId: trackId,
    detail: detail,
    bearing: bearing,
    magnitude: magnitude,
  );
}

/// How long watched reports stay on the map; null = always.
const List<Duration?> watchMapTtlChoices = [
  Duration(minutes: 15),
  Duration(minutes: 30),
  Duration(hours: 1),
  Duration(hours: 2),
  Duration(hours: 6),
  Duration(hours: 12),
  Duration(hours: 24),
  Duration(days: 3),
  null,
];

String watchTtlLabel(Duration? d) {
  if (d == null) return 'Always';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  if (d.inHours < 48) return '${d.inHours} h';
  return '${d.inDays} days';
}

class WatchFeedService extends ChangeNotifier {
  WatchFeedService(this._connector) {
    _connector.addListener(_onConnector);
    unawaited(_load());
    // Reports leave the map as they pass [mapTtl], without a new message.
    _expiry = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_mapTtl != null) notifyListeners();
    });
  }

  late final Timer _expiry;

  final MeshCoreConnector _connector;
  static const _kChannels = 'watch_channels_v1';
  static const _kSeen = 'watch_seen_v1';
  static const _kMapTtl = 'watch_map_ttl_min_v1';
  static const _kFirstSeen = 'watch_first_seen_v1';
  static const _kSounds = 'watch_sounds_v1';

  Duration? _mapTtl = const Duration(hours: 6);

  /// How long a watched report stays on the map after it happened (null:
  /// always). The feed itself keeps everything.
  Duration? get mapTtl => _mapTtl;

  Future<void> setMapTtl(Duration? d) async {
    _mapTtl = d;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_kMapTtl, d?.inMinutes ?? 0);
    } catch (_) {}
  }

  // When this phone first saw each message, for senders whose clock is off.
  final Map<String, int> _firstSeen = {};
  bool _firstSeenDirty = false;

  DateTime _timeOf(String key, DateTime sent) {
    final now = DateTime.now();
    if (sent.year >= 2020 && sent.isBefore(now.add(const Duration(hours: 1)))) {
      return sent;
    }
    final ms = _firstSeen.putIfAbsent(key, () {
      _firstSeenDirty = true;
      return now.millisecondsSinceEpoch;
    });
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> _saveFirstSeen() async {
    if (!_firstSeenDirty) return;
    _firstSeenDirty = false;
    while (_firstSeen.length > 2000) {
      _firstSeen.remove(_firstSeen.keys.first);
    }
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_kFirstSeen, [
        for (final e in _firstSeen.entries) '${e.key}=${e.value}',
      ]);
    } catch (_) {}
  }

  // The report the Watch search (or a card's map button) asked the map to
  // show: drawn with a pulsing ring, and kept on the map even if it is older
  // than [mapTtl] or a newer report of the same drone exists.
  String? _mapFocus;
  Timer? _mapFocusTimer;

  String? get mapFocusKey => _mapFocus;

  /// Light up [item] on the map for a minute.
  void focusOnMap(WatchItem item) {
    _mapFocusTimer?.cancel();
    _mapFocus = item.key;
    _mapFocusTimer = Timer(const Duration(minutes: 1), () {
      _mapFocus = null;
      notifyListeners();
    });
    notifyListeners();
  }

  /// Watched reports to put on the map: with a position, within [mapTtl],
  /// and only the newest report of anything tracked (a drone by serial),
  /// plus the one [focusOnMap] lit up.
  List<WatchItem> get mapItems {
    final cutoff = _mapTtl == null ? null : DateTime.now().subtract(_mapTtl!);
    final latest = <String, WatchItem>{};
    final out = <WatchItem>[];
    _courses.clear();
    for (final i in items) {
      if (!i.hasPosition) continue;
      final focused = i.key == _mapFocus;
      final t = i.trackId;
      if (t != null) {
        final newer = latest[t];
        if (newer != null) {
          // An older report of something already on the map: its direction
          // of travel since then, if it moved enough to tell.
          if (!_courses.containsKey(t) &&
              teamDistanceMeters(i.lat!, i.lon!, newer.lat!, newer.lon!) >=
                  15) {
            _courses[t] = teamBearingDeg(
              i.lat!,
              i.lon!,
              newer.lat!,
              newer.lon!,
            );
          }
          if (!focused) continue;
        }
      }
      if (!focused && cutoff != null && i.time.isBefore(cutoff)) continue;
      if (t != null) latest.putIfAbsent(t, () => i);
      if (out.length < 300 || focused) out.add(i);
    }
    return out;
  }

  // Direction of travel worked out from each tracked thing's last two reports.
  final Map<String, double> _courses = {};

  /// Where a tracked report (a drone) is heading, from its last two
  /// positions; null if unknown. Valid after [mapItems].
  double? courseOf(WatchItem i) =>
      i.trackId == null ? null : _courses[i.trackId!];

  /// Watched channels by name (names survive index changes).
  final Set<String> _watched = {};
  DateTime _seen = DateTime.fromMillisecondsSinceEpoch(0);

  Set<String> get watchedNames => Set.unmodifiable(_watched);

  List<Channel> get watchedChannels => [
    for (final c in _connector.channels)
      if (_watched.contains(c.name)) c,
  ];

  List<Channel> get allChannels => [
    for (final c in _connector.channels)
      if (c.name.isNotEmpty) c,
  ];

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _watched.addAll(p.getStringList(_kChannels) ?? const []);
      final s = p.getInt(_kSeen);
      if (s != null) _seen = DateTime.fromMillisecondsSinceEpoch(s);
      for (final e in p.getStringList(_kSounds) ?? const <String>[]) {
        final i = e.lastIndexOf('=');
        if (i > 0) {
          _sounds[e.substring(0, i)] = WatchSound.fromName(e.substring(i + 1));
        }
      }
      final ttl = p.getInt(_kMapTtl);
      if (ttl != null) _mapTtl = ttl == 0 ? null : Duration(minutes: ttl);
      for (final e in p.getStringList(_kFirstSeen) ?? const <String>[]) {
        final i = e.lastIndexOf('=');
        final v = i < 0 ? null : int.tryParse(e.substring(i + 1));
        if (v != null) _firstSeen[e.substring(0, i)] = v;
      }
    } catch (_) {}
    _dirty = true;
    notifyListeners();
  }

  Future<void> setWatched(Channel c, bool watch) async {
    if (watch) {
      _watched.add(c.name);
    } else {
      _watched.remove(c.name);
      _primed.remove(c.name); // its history stays silent if watched again
    }
    _dirty = true;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_kChannels, _watched.toList());
    } catch (_) {}
  }

  // ------------------------------------------------------- alert sounds

  /// Each watched channel's alert sound, by channel name (off if unset).
  final Map<String, WatchSound> _sounds = {};
  final WatchSoundPlayer _player = WatchSoundPlayer();

  WatchSound soundFor(String channel) => _sounds[channel] ?? WatchSound.off;

  Future<void> setSound(String channel, WatchSound s) async {
    if (s == WatchSound.off) {
      _sounds.remove(channel);
    } else {
      _sounds[channel] = s;
    }
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_kSounds, [
        for (final e in _sounds.entries) '${e.key}=${e.value.name}',
      ]);
    } catch (_) {}
  }

  /// Plays [s] now, e.g. to try it in the picker.
  Future<void> preview(WatchSound s) => _player.play(s);

  // Reports already accounted for, so each new one sounds once.
  final Set<String> _known = {};
  // Channels whose existing reports have been taken in silently.
  final Set<String> _primed = {};
  final Map<String, DateTime> _lastSound = {}; // by channel
  final Map<String, DateTime> _trackHeard = {}; // by trackId (a drone)

  /// A watched report with a position just reached the map: play its
  /// channel's sound. Not for history: a channel's reports when it is first
  /// seen (app start, a newly watched channel, another radio), a burst of
  /// stored messages, or reports more than 30 minutes old. A drone sounds
  /// when it first appears, not for every update while it keeps reporting.
  /// One sound per channel per 8 s at most.
  void _announceNew() {
    final now = DateTime.now();
    final cutoff = _mapTtl == null ? null : now.subtract(_mapTtl!);
    final fresh = <String, List<WatchItem>>{};
    for (final i in items) {
      if (_known.add(i.key)) {
        (fresh[i.channel.name] ??= []).add(i);
      }
    }
    WatchSound? sound;
    for (final e in fresh.entries) {
      final silent = _primed.add(e.key) || e.value.length > 5;
      for (final i in e.value) {
        if (!i.hasPosition) continue;
        final t = i.trackId;
        if (t != null) {
          final last = _trackHeard[t];
          _trackHeard[t] = now;
          if (last != null && now.difference(last).inMinutes < 10) continue;
        }
        if (silent) continue;
        if (cutoff != null && i.time.isBefore(cutoff)) continue;
        if (now.difference(i.time).inMinutes > 30) continue;
        final s = soundFor(e.key);
        if (s == WatchSound.off) continue;
        final last = _lastSound[e.key];
        if (last != null && now.difference(last).inSeconds < 8) continue;
        _lastSound[e.key] = now;
        sound ??= s;
      }
    }
    if (_known.length > 5000) {
      _known
        ..clear()
        ..addAll(items.map((i) => i.key));
    }
    if (sound != null) unawaited(_player.play(sound));
  }

  /// Marks everything up to now as seen (clears the unread badge).
  Future<void> markSeen() async {
    _seen = DateTime.now();
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_kSeen, _seen.millisecondsSinceEpoch);
    } catch (_) {}
  }

  int get unseenCount => items.where((i) => i.time.isAfter(_seen)).length;

  bool isUnseen(WatchItem i) => i.time.isAfter(_seen);

  // Parsing is cached and redone only when the watched messages change.
  bool _dirty = true;
  int _signature = 0;
  List<WatchItem> _items = const [];

  void _onConnector() {
    final sig = Object.hashAll([
      for (final c in watchedChannels) ...[
        c.index,
        _connector.getChannelMessages(c).length,
      ],
    ]);
    if (sig != _signature) {
      _signature = sig;
      _dirty = true;
      _announceNew();
      notifyListeners();
    }
  }

  /// Newest first, at most 200 per channel.
  List<WatchItem> get items {
    if (!_dirty) return _items;
    final out = <WatchItem>[];
    for (final c in watchedChannels) {
      final msgs = _connector.getChannelMessages(c);
      final start = msgs.length > 200 ? msgs.length - 200 : 0;
      final chan = <WatchItem>[];
      for (var i = start; i < msgs.length; i++) {
        final m = msgs[i];
        if (m.text.trim().isEmpty) continue;
        final key = '${c.index}:${m.messageId}';
        final it = parseWatchMessage(c, m, time: _timeOf(key, m.timestamp));
        // A bot's bare link right after its own report belongs to that report.
        if (it.isBareLink && chan.isNotEmpty) {
          final prev = chan.last;
          if (prev.url == null &&
              prev.message.senderName == m.senderName &&
              it.time.difference(prev.time).inMinutes.abs() <= 5) {
            chan[chan.length - 1] = prev.withUrl(it.url!);
            continue;
          }
        }
        chan.add(it);
      }
      out.addAll(chan);
    }
    out.sort((a, b) => b.time.compareTo(a.time));
    unawaited(_saveFirstSeen());
    _items = out;
    _dirty = false;
    return out;
  }

  @override
  void dispose() {
    _expiry.cancel();
    _mapFocusTimer?.cancel();
    _player.dispose();
    _connector.removeListener(_onConnector);
    super.dispose();
  }
}
