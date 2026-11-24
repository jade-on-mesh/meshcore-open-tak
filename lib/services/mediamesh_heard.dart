// MeshCore Open TAK - nodes heard sending on MediaMesh (radio2), from the
// companion's RX log: a Keymind Cascade companion marks each packet it heard
// on radio2 (see LiveTrafficFrameReader). The same evidence CoreScope's
// ingestor takes as "heard" (cmd/ingestor/mediamesh.go mediaMeshSender):
//
// - a flood with a path: its last hop, the repeater our radio heard send it,
//   when that hash matches exactly one repeater or room;
// - an advert with an empty path (a zero-hop advert, or a flood heard
//   straight from its sender): the node that sent it.
//
// Other packets give nothing: their sender is encrypted, and a direct
// packet's path is the route still to go. The map's MediaMesh filter counts
// these nodes (companions too) as MediaMesh, like the analyzer.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../models/contact.dart';
import 'live_traffic.dart';

class MediaMeshHeard extends ChangeNotifier {
  MediaMeshHeard._();

  static final MediaMeshHeard instance = MediaMeshHeard._();

  static const String _prefsKey = 'mediamesh_heard_v1';

  /// Forgotten when not heard on radio2 for this long (as MediaMesh
  /// repeaters' reports).
  static const Duration keepFor = Duration(days: 30);

  /// A node heard again is re-stamped (and saved) at most this often.
  static const Duration _restamp = Duration(hours: 1);

  Map<String, DateTime> _heard = {};
  StreamSubscription<Uint8List>? _sub;
  final LiveTrafficFrameReader _reader = LiveTrafficFrameReader();

  /// Whether the node with [publicKeyHex] was heard sending on radio2 in the
  /// last [keepFor].
  bool heard(String publicKeyHex, {DateTime? now}) {
    final at = _heard[publicKeyHex.toLowerCase()];
    return at != null && (now ?? DateTime.now()).difference(at) <= keepFor;
  }

  int get count => _heard.keys.where(heard).length;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        final now = DateTime.now();
        _heard = {
          for (final e in json.entries)
            if (e.value is int)
              e.key: DateTime.fromMillisecondsSinceEpoch(e.value as int),
        }..removeWhere((_, at) => now.difference(at) > keepFor);
      }
    } catch (e) {
      debugPrint('MediaMesh heard: could not load ($e)');
    }
    notifyListeners();
  }

  /// Listens to [connector]'s frames for radio2 packets.
  void attach(MeshCoreConnector connector) {
    _sub?.cancel();
    _sub = connector.receivedFrames.listen((frame) {
      final packet = _reader.read(frame);
      if (packet == null || !packet.mediaMesh) return;
      final key = mediaMeshSenderKey(packet, connector.contacts);
      if (key != null) note(key);
    });
  }

  /// Records [publicKeyHex] as heard sending on radio2 at [at] (now).
  void note(String publicKeyHex, {DateTime? at}) {
    final key = publicKeyHex.toLowerCase();
    final now = at ?? DateTime.now();
    final had = _heard[key];
    final isNew = had == null || now.difference(had) > keepFor;
    if (!isNew && now.difference(had) < _restamp) return;
    _heard = {..._heard, key: now};
    if (isNew) notifyListeners();
    unawaited(_save());
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode({
          for (final e in _heard.entries) e.key: e.value.millisecondsSinceEpoch,
        }),
      );
    } catch (e) {
      debugPrint('MediaMesh heard: could not save ($e)');
    }
  }

  @visibleForTesting
  void resetForTest() {
    _sub?.cancel();
    _sub = null;
    _heard = {};
  }
}

/// The public key (hex) of the node that sent [packet], as far as the radio
/// can tell (see the top of this file), or null.
String? mediaMeshSenderKey(LiveTrafficPacket packet, List<Contact> contacts) {
  if (packet.payloadType == payloadTypeTRACE) return null;
  if (packet.pathBytes.isEmpty) {
    if (packet.payloadType != payloadTypeADVERT) return null;
    final sender = liveTrafficAdvertSender(packet.payload);
    if (sender == null) return null;
    return sender.publicKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
  if (!packet.isFlood) return null;
  final width = packet.hashWidth.clamp(1, 3);
  if (packet.pathBytes.length < width) return null;
  final last = packet.pathBytes.sublist(packet.pathBytes.length - width);
  Contact? match;
  for (final c in contacts) {
    if (c.type != advTypeRepeater && c.type != advTypeRoom) continue;
    if (c.publicKey.length < width) continue;
    var same = true;
    for (var i = 0; i < width; i++) {
      if (c.publicKey[i] != last[i]) {
        same = false;
        break;
      }
    }
    if (!same) continue;
    if (match != null) return null; // shared hash: not evidence
    match = c;
  }
  return match?.publicKeyHex.toLowerCase();
}
