// MeshCore Open TAK - watch feeds: show chosen channels (e.g. #icewatch,
// #dronewatch) as a compact, filterable report feed on the Tactical screen.
//
// Messages in the condensed report format bots like IceBot post
//   🔴 CRITICAL / 10-03 11:30 / @Auburn E Main St / 3-🚗 5-🥾 / https://…
// are parsed into structured cards. Anything else is shown as plain text.
// Messages with coordinates (or a shared map marker) also go on the map.

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
  });

  bool get isStructured => statusWord != null || place != null || counts.isNotEmpty;
  bool get hasPosition => lat != null && lon != null;
  String get key => '${channel.index}:${message.messageId}';

  /// One-line headline for the card.
  String get headline {
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
final _markerRe = RegExp(r'm:(-?[0-9.]+),(-?[0-9.]+)\|');

WatchLevel _levelFromWord(String w) {
  final u = w.toUpperCase();
  for (final l in WatchLevel.values) {
    if (l.label.isNotEmpty && u.contains(l.label)) return l;
  }
  if (u.contains('URGENT') || u.contains('ALERT')) return WatchLevel.critical;
  return WatchLevel.none;
}

/// Parses one channel message into a feed item.
@visibleForTesting
WatchItem parseWatchMessage(Channel channel, ChannelMessage m) {
  var level = WatchLevel.none;
  String? status, when, place, url;
  final counts = <(int, String)>[];
  final other = <String>[];
  double? lat, lon;

  final mk = _markerRe.firstMatch(m.text);
  final co = mk ?? _coordRe.firstMatch(m.text);
  if (co != null) {
    final a = double.tryParse(co.group(1)!), b = double.tryParse(co.group(2)!);
    if (a != null && b != null && a.abs() <= 90 && b.abs() <= 180) {
      lat = a;
      lon = b;
    }
  }

  for (final raw in m.text.split('\n')) {
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
    other.add(line);
  }
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
  );
}

class WatchFeedService extends ChangeNotifier {
  WatchFeedService(this._connector) {
    _connector.addListener(_onConnector);
    unawaited(_load());
  }

  final MeshCoreConnector _connector;
  static const _kChannels = 'watch_channels_v1';
  static const _kSeen = 'watch_seen_v1';

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

  int get unseenCount =>
      items.where((i) => i.message.timestamp.isAfter(_seen)).length;

  bool isUnseen(WatchItem i) => i.message.timestamp.isAfter(_seen);

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
      for (var i = start; i < msgs.length; i++) {
        final m = msgs[i];
        if (m.text.trim().isEmpty) continue;
        out.add(parseWatchMessage(c, m));
      }
    }
    out.sort((a, b) => b.message.timestamp.compareTo(a.message.timestamp));
    _items = out;
    _dirty = false;
    return out;
  }

  @override
  void dispose() {
    _connector.removeListener(_onConnector);
    super.dispose();
  }
}
