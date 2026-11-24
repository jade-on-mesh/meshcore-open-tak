// MeshCore Open TAK - live traffic on the map: every packet the companion
// radio hears (the RX log, push 0x88) drawn along the repeaters it came
// through, with the same colours, shapes and timings as CoreScope's live map
// (public/live.js). Parsing and path building live here; the drawing is
// LiveTrafficLayer (lib/widgets/live_traffic_layer.dart).

import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connector/meshcore_protocol.dart';
import '../connector/raw_packet.dart';
import '../helpers/path_hop_resolver.dart';
import '../models/contact.dart';

/// Whether live traffic shows on the map: the map's live-traffic button and
/// App Settings › Map display both flip this. Off until turned on. On this
/// phone only.
class LiveTrafficSettings extends ChangeNotifier {
  LiveTrafficSettings._();

  static final LiveTrafficSettings instance = LiveTrafficSettings._();

  static const String _prefsKey = 'map_live_traffic_v1';

  bool _enabled = false;

  bool get enabled => _enabled;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefsKey) ?? false;
    } catch (e) {
      debugPrint('Live traffic: could not load ($e)');
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
      debugPrint('Live traffic: could not save ($e)');
    }
  }

  Future<void> toggle() => setEnabled(!_enabled);

  @visibleForTesting
  void resetForTest() => _enabled = false;
}

/// CoreScope's names for the payload types (TYPE_COLORS keys).
String liveTrafficTypeName(int payloadType) => switch (payloadType) {
  payloadTypeREQ => 'REQ',
  payloadTypeRESPONSE => 'RESPONSE',
  payloadTypeTXTMSG => 'TXT_MSG',
  payloadTypeACK => 'ACK',
  payloadTypeADVERT => 'ADVERT',
  payloadTypeGRPTXT => 'GRP_TXT',
  payloadTypeGRPDATA => 'GRP_DATA',
  payloadTypeANONREQ => 'ANON_REQ',
  payloadTypePATH => 'PATH',
  payloadTypeTRACE => 'TRACE',
  payloadTypeMULTIPART => 'MULTIPART',
  payloadTypeCONTROL => 'CONTROL',
  payloadTypeRawCustom => 'RAW_CUSTOM',
  _ => 'UNKNOWN',
};

/// CoreScope's colour for each payload type (live.js TYPE_COLORS); grey for
/// anything else.
Color liveTrafficTypeColor(int payloadType) => switch (payloadType) {
  payloadTypeADVERT => const Color(0xFF22C55E),
  payloadTypeGRPTXT => const Color(0xFF3B82F6),
  payloadTypeTXTMSG => const Color(0xFFF59E0B),
  payloadTypeACK => const Color(0xFF6B7280),
  payloadTypeREQ => const Color(0xFFA855F7),
  payloadTypeRESPONSE => const Color(0xFF06B6D4),
  payloadTypeTRACE => const Color(0xFFEC4899),
  payloadTypePATH => const Color(0xFF14B8A6),
  payloadTypeANONREQ => const Color(0xFFF43F5E),
  payloadTypeGRPDATA => const Color(0xFF8B5CF6),
  payloadTypeMULTIPART => const Color(0xFF0D9488),
  payloadTypeCONTROL => const Color(0xFFB45309),
  payloadTypeRawCustom => const Color(0xFFC026D3),
  _ => const Color(0xFF6B7280),
};

/// The grey of ghost (inferred) hops and their lines (live.js #94a3b8).
const Color liveTrafficGhostColor = Color(0xFF94A3B8);

/// One packet from the companion's RX log.
class LiveTrafficPacket {
  final int routeType;
  final int payloadType;

  /// Bytes per path entry (1-3); TRACE paths hold SNRs instead.
  final int hashWidth;

  /// The raw path: repeater hashes for most packets, one SNR byte per
  /// repeater reached for a TRACE.
  final Uint8List pathBytes;
  final Uint8List payload;
  final double snr;
  final int rssi;

  const LiveTrafficPacket({
    required this.routeType,
    required this.payloadType,
    required this.hashWidth,
    required this.pathBytes,
    required this.payload,
    required this.snr,
    required this.rssi,
  });

  /// Flooded (route type 0 transport-flood or 1 flood): its path is the
  /// repeaters it came through, oldest first.
  bool get isFlood => routeType == 0 || routeType == 1;

  String get typeName => liveTrafficTypeName(payloadType);
  Color get color => liveTrafficTypeColor(payloadType);
}

/// The packet in an RX log frame (`[0x88][snr×4][rssi][raw packet]`), or
/// null for anything else or a malformed frame.
LiveTrafficPacket? parseLiveTrafficFrame(Uint8List frame) {
  if (frame.length < 5 || frame[0] != pushCodeLogRxData) return null;
  try {
    final view = ByteData.sublistView(frame);
    final snr = view.getInt8(1) / 4.0;
    final rssi = view.getInt8(2);
    var i = 3;
    final header = frame[i++];
    final routeType = header & 0x03;
    final payloadType = (header >> 2) & 0x0F;
    if (routeType == 0 || routeType == 3) i += 4; // transport codes
    if (i >= frame.length) return null;
    final pathLenRaw = frame[i++];
    final int hashWidth;
    final int pathLen;
    if (payloadType == payloadTypeTRACE) {
      // A TRACE's path is one SNR byte per repeater it reached.
      hashWidth = 1;
      pathLen = pathLenRaw & 0x3F;
    } else {
      hashWidth = decodePathHashWidth(pathLenRaw);
      pathLen = decodePathByteLen(pathLenRaw);
    }
    if (hashWidth > 3 || i + pathLen > frame.length) return null;
    final pathBytes = Uint8List.fromList(frame.sublist(i, i + pathLen));
    i += pathLen;
    return LiveTrafficPacket(
      routeType: routeType,
      payloadType: payloadType,
      hashWidth: hashWidth,
      pathBytes: pathBytes,
      payload: Uint8List.fromList(frame.sublist(i)),
      snr: snr,
      rssi: rssi,
    );
  } catch (_) {
    return null;
  }
}

/// An advert's sender: its public key and, when the advert carries one, its
/// location. Null when [payload] is too short to be an advert.
({Uint8List publicKey, LatLng? position})? liveTrafficAdvertSender(
  Uint8List payload,
) {
  const keySize = 32, appDataStart = 32 + 4 + 64;
  if (payload.length <= appDataStart) return null;
  final publicKey = Uint8List.fromList(payload.sublist(0, keySize));
  final flags = payload[appDataStart];
  LatLng? position;
  if (flags & 0x10 != 0 && payload.length >= appDataStart + 9) {
    final view = ByteData.sublistView(payload);
    final lat = view.getInt32(appDataStart + 1, Endian.little) / 1e6;
    final lon = view.getInt32(appDataStart + 5, Endian.little) / 1e6;
    if (_plausible(lat, lon)) position = LatLng(lat, lon);
  }
  return (publicKey: publicKey, position: position);
}

bool _plausible(double lat, double lon) =>
    lat.abs() <= 90 &&
    lon.abs() <= 180 &&
    (lat.abs() > 1e-6 || lon.abs() > 1e-6);

/// A TRACE's route: the repeater hashes it is to visit (from its payload,
/// after tag, auth code and flags), split by the hash size its flags give.
List<Uint8List> liveTrafficTraceRoute(Uint8List payload) {
  if (payload.length <= 9) return const [];
  final route = payload.sublist(9);
  final code = payload[8] & 0x03;
  final pow2 = 1 << code, linear = code + 1;
  // Firmware decodeTraceHashSize: whichever reading divides the route;
  // the older power-of-two reading when both or neither do.
  final size = (route.length % pow2 != 0 && route.length % linear == 0)
      ? linear
      : pow2;
  return [
    for (var j = 0; j + size <= route.length; j += size)
      Uint8List.fromList(route.sublist(j, j + size)),
  ];
}

/// One point a packet is drawn through.
class LiveTrafficHop {
  /// Who it is (a public key, or `hop-<hex>` for an unknown repeater): two
  /// hops in a row with the same key are one.
  final String key;
  final LatLng position;

  /// Inferred: an unknown repeater placed between the known ones around it,
  /// drawn grey and dashed (live.js "Inferred Hops").
  final bool ghost;

  /// False for a TRACE hop the trace hasn't reached yet: the line to it is
  /// dashed.
  final bool reached;

  const LiveTrafficHop(
    this.key,
    this.position, {
    this.ghost = false,
    this.reached = true,
  });

  /// Whether the line from [from] to this hop is drawn dashed and grey
  /// (live.js: ghost hops and a TRACE's unreached hops).
  bool dashedFrom(LiveTrafficHop from) => ghost || from.ghost || !reached;
}

/// How a packet is drawn: through [hops], in [color].
class LiveTrafficRoute {
  final String typeName;
  final Color color;
  final List<LiveTrafficHop> hops;

  const LiveTrafficRoute({
    required this.typeName,
    required this.color,
    required this.hops,
  });
}

/// Where [packet] is drawn, or null when nothing on it has a place on the
/// map.
///
/// - Flooded packets: the repeaters in the path (nearest to [self] first
///   resolved), the advert's sender before them when it gave a location, and
///   the companion itself ([self]) last, as the one that heard it.
/// - Direct packets: their path is the hops still to go, so only a pulse at
///   the companion.
/// - TRACE: its route; lines to hops it has reached solid, the rest dashed.
///
/// Unknown repeaters between two known points are placed evenly between them
/// as ghosts; unknown ones outside known points are left out (as live.js).
LiveTrafficRoute? liveTrafficRoute(
  LiveTrafficPacket packet, {
  required List<Contact> contacts,
  LatLng? self,
}) {
  final raw = <_RawHop>[];

  if (packet.payloadType == payloadTypeTRACE) {
    final route = liveTrafficTraceRoute(packet.payload);
    final resolved = PathHopResolver.resolveHops(
      hops: route,
      contacts: contacts,
    );
    // One SNR byte per repeater that passed it on: those were reached.
    final reached = packet.pathBytes.length;
    for (var j = 0; j < route.length; j++) {
      raw.add(_RawHop.of(resolved[j], route[j], reached: j < reached));
    }
  } else {
    if (packet.isFlood && packet.pathBytes.isNotEmpty) {
      final resolved = PathHopResolver.resolve(
        pathBytes: packet.pathBytes,
        contacts: contacts,
        endpoint: self,
        resolveFromEnd: self != null,
        pathHashByteWidth: packet.hashWidth,
      );
      final width = packet.hashWidth.clamp(1, 3);
      for (var j = 0; j < resolved.length; j++) {
        final start = j * width;
        final end = (start + width).clamp(0, packet.pathBytes.length);
        raw.add(_RawHop.of(resolved[j], packet.pathBytes.sublist(start, end)));
      }
    }
    if (packet.payloadType == payloadTypeADVERT) {
      final sender = liveTrafficAdvertSender(packet.payload);
      if (sender != null && sender.position != null) {
        final key = _hex(sender.publicKey);
        if (!raw.any((h) => h.key == key)) {
          raw.insert(0, _RawHop(key, sender.position));
        }
      }
    }
    if (self != null) raw.add(_RawHop('self', self));
  }

  final hops = _placeGhosts(raw);
  if (hops.isEmpty) return null;
  return LiveTrafficRoute(
    typeName: packet.typeName,
    color: packet.color,
    hops: hops,
  );
}

class _RawHop {
  final String key;
  final LatLng? position;
  final bool reached;

  const _RawHop(this.key, this.position, {this.reached = true});

  factory _RawHop.of(Contact? contact, List<int> hash, {bool reached = true}) {
    if (contact != null && contact.hasLocation) {
      return _RawHop(
        contact.publicKeyHex,
        LatLng(contact.latitude!, contact.longitude!),
        reached: reached,
      );
    }
    return _RawHop(
      contact?.publicKeyHex ?? 'hop-${_hex(hash)}',
      null,
      reached: reached,
    );
  }
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// live.js resolveHopPositions: unknown hops between two known ones placed
/// evenly between them (ghosts); the rest dropped. With fewer than two known
/// points, just the known ones.
List<LiveTrafficHop> _placeGhosts(List<_RawHop> raw) {
  final known = raw.where((h) => h.position != null).length;
  if (known < 2) {
    return [
      for (final h in raw)
        if (h.position != null)
          LiveTrafficHop(h.key, h.position!, reached: h.reached),
    ];
  }
  final out = <LiveTrafficHop>[];
  for (var i = 0; i < raw.length; i++) {
    final h = raw[i];
    if (h.position != null) {
      out.add(LiveTrafficHop(h.key, h.position!, reached: h.reached));
      continue;
    }
    var gapStart = i, gapEnd = i;
    while (gapStart > 0 && raw[gapStart - 1].position == null) {
      gapStart--;
    }
    while (gapEnd < raw.length - 1 && raw[gapEnd + 1].position == null) {
      gapEnd++;
    }
    if (gapStart == 0 || gapEnd == raw.length - 1) continue;
    final before = raw[gapStart - 1].position!;
    final after = raw[gapEnd + 1].position!;
    final t = (i - gapStart + 1) / (gapEnd - gapStart + 2);
    out.add(
      LiveTrafficHop(
        h.key,
        LatLng(
          before.latitude + (after.latitude - before.latitude) * t,
          before.longitude + (after.longitude - before.longitude) * t,
        ),
        ghost: true,
        reached: h.reached,
      ),
    );
  }
  // The same node twice in a row (e.g. the sender also in the path) is one.
  final deduped = <LiveTrafficHop>[];
  for (final h in out) {
    if (deduped.isNotEmpty && deduped.last.key == h.key) continue;
    deduped.add(h);
  }
  return deduped;
}
