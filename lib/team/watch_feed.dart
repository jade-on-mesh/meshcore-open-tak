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
  });

  bool get hasSecondPosition => lat2 != null && lon2 != null;
  bool get isDrone => trackId?.startsWith('DRONE') ?? false;

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
  );

  bool get isStructured =>
      statusWord != null || place != null || counts.isNotEmpty;
  bool get hasPosition => lat != null && lon != null;
  String get key => '${channel.index}:${message.messageId}';

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
final _droneRe = RegExp(r'^\s*DRONE\s+([A-Za-z0-9-]{6,})', caseSensitive: false);
final _factRe = RegExp(r'^(h-?\d+m|-?\d+(\.\d+)?m/s|\d+(\.\d+)?\s?km/h|alt\S*)$');

/// Lines that are only a position ("📍 45.5625,-122.6108"), not text.
bool _onlyCoords(String line) {
  final rest = line.replaceAll(_coordRe, '').replaceAll(RegExp(r'[\s📍,;:]'), '');
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
WatchItem parseWatchMessage(Channel channel, ChannelMessage m, {DateTime? time}) {
  var level = WatchLevel.none;
  String? status, when, place, url, trackId, detail, label2;
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
    final all = _coordRe.allMatches(m.text).toList();
    var prevEnd = 0;
    for (final co in all) {
      final v = valid(co.group(1), co.group(2));
      if (v == null) continue;
      if (lat == null) {
        (lat, lon) = (v.$1, v.$2);
      } else if (lat2 == null) {
        (lat2, lon2) = (v.$1, v.$2);
        final words = m.text
            .substring(prevEnd, co.start)
            .split(RegExp(r'\s+'))
            .where((w) => w.isNotEmpty && !w.contains('://') && !w.contains('='))
            .toList();
        label2 = words.isEmpty ? null : words.last;
      }
      prevEnd = co.end;
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
  }

  for (final raw in drone != null ? const <String>[] : m.text.split('\n')) {
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
    if (lat != null && _onlyCoords(line)) continue;   // shown as the map point
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

  /// Watched reports to put on the map: with a position, within [mapTtl],
  /// and only the newest report of anything tracked (a drone by serial).
  List<WatchItem> get mapItems {
    final cutoff = _mapTtl == null ? null : DateTime.now().subtract(_mapTtl!);
    final seenTracks = <String>{};
    final out = <WatchItem>[];
    for (final i in items) {
      if (!i.hasPosition) continue;
      if (cutoff != null && i.time.isBefore(cutoff)) continue;
      final t = i.trackId;
      if (t != null && !seenTracks.add(t)) continue;
      out.add(i);
      if (out.length >= 300) break;
    }
    return out;
  }

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
    }
    _dirty = true;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_kChannels, _watched.toList());
    } catch (_) {}
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
    _connector.removeListener(_onConnector);
    super.dispose();
  }
}
