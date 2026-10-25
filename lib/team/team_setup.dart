// MeshCore Open TAK - one-scan team setup: a link carrying what a newcomer
// needs to join a team, shown as a QR code or played by Sound link, and read
// the same way by Wadamesh TAK standalones (src/ui-touch/TeamSetup.h, golden
// strings in both tests).
//
//   meshcore://team/join?n=<team channel>&s=<32 hex>[&w=<watched>,...]
//                       [&m=<MHz x 1000>,<bandwidth Hz>,<sf>,<cr>]
//
//   w: a hashtag channel by name ("#icewatch"; its key comes from the name),
//      a private one as "name:<32 hex>". Names are percent-encoded (RFC 3986
//      unreserved characters kept), so ',' and ':' only ever separate.
//   m: the MediaMesh (radio2) profile, e.g. 911150,250000,7,5.
//
// Callsigns stay personal, and the team's roles arrive over the team channel
// once joined, so neither is in the link.
//
// Sound link carries 140 bytes a message: a longer link goes as parts,
//   MCT:<id, 4 hex>:<i>/<n>:<piece of the link>
// played one after another and put back together by the listener.

import 'dart:convert';

const String teamSetupPrefix = 'meshcore://team/join?';
const String teamSetupPartPrefix = 'MCT:';
const int teamSetupSoundBytes = 140;

/// A channel to watch: a hashtag channel (no secret) or a private one.
class TeamSetupChannel {
  final String name;

  /// 32 lowercase hex, null for a hashtag channel.
  final String? secretHex;
  const TeamSetupChannel(this.name, [this.secretHex]);

  bool get isHashtag => secretHex == null;

  @override
  bool operator ==(Object o) =>
      o is TeamSetupChannel && o.name == name && o.secretHex == secretHex;
  @override
  int get hashCode => Object.hash(name, secretHex);
}

/// A MediaMesh (radio2) profile.
class TeamSetupMediaMesh {
  final int frequencyKHz;
  final int bandwidthHz;
  final int sf;
  final int cr;
  const TeamSetupMediaMesh({
    required this.frequencyKHz,
    required this.bandwidthHz,
    required this.sf,
    required this.cr,
  });

  double get frequencyMHz => frequencyKHz / 1000;

  String get label =>
      '${frequencyMHz.toStringAsFixed(3)} MHz · '
      '${bandwidthHz % 1000 == 0 ? bandwidthHz ~/ 1000 : bandwidthHz / 1000} kHz · '
      'SF$sf · CR 4/$cr';
}

class TeamSetup {
  final String teamName;
  final String teamSecretHex;
  final List<TeamSetupChannel> watched;
  final TeamSetupMediaMesh? mediaMesh;

  const TeamSetup({
    required this.teamName,
    required this.teamSecretHex,
    this.watched = const [],
    this.mediaMesh,
  });

  static final _hex32 = RegExp(r'^[0-9a-f]{32}$');

  /// The link (the QR code's text).
  String toLink() {
    final b = StringBuffer(teamSetupPrefix)
      ..write('n=${_enc(teamName)}&s=$teamSecretHex');
    if (watched.isNotEmpty) {
      b.write('&w=');
      b.write(
        watched
            .map(
              (c) => c.secretHex == null
                  ? _enc(c.name)
                  : '${_enc(c.name)}:${c.secretHex}',
            )
            .join(','),
      );
    }
    final m = mediaMesh;
    if (m != null) {
      b.write('&m=${m.frequencyKHz},${m.bandwidthHz},${m.sf},${m.cr}');
    }
    return b.toString();
  }

  static bool isLink(String s) => s.trim().startsWith(teamSetupPrefix);

  static TeamSetup? parse(String text) {
    final t = text.trim();
    if (!t.startsWith(teamSetupPrefix)) return null;
    final fields = <String, String>{};
    for (final kv in t.substring(teamSetupPrefix.length).split('&')) {
      final i = kv.indexOf('=');
      if (i > 0) fields[kv.substring(0, i)] = kv.substring(i + 1);
    }
    final name = _dec(fields['n'] ?? '').trim();
    final secret = (fields['s'] ?? '').toLowerCase();
    if (name.isEmpty || !_hex32.hasMatch(secret)) return null;
    final watched = <TeamSetupChannel>[];
    final w = fields['w'] ?? '';
    if (w.isNotEmpty) {
      for (final item in w.split(',')) {
        final c = item.indexOf(':');
        if (c < 0) {
          final n = _dec(item).trim();
          if (n.startsWith('#') && n.length > 1)
            watched.add(TeamSetupChannel(n));
        } else {
          final n = _dec(item.substring(0, c)).trim();
          final k = item.substring(c + 1).toLowerCase();
          if (n.isNotEmpty && _hex32.hasMatch(k)) {
            watched.add(TeamSetupChannel(n, k));
          }
        }
      }
    }
    TeamSetupMediaMesh? mm;
    final m = (fields['m'] ?? '').split(',');
    if (m.length == 4) {
      final f = int.tryParse(m[0]), bw = int.tryParse(m[1]);
      final sf = int.tryParse(m[2]), cr = int.tryParse(m[3]);
      if (f != null &&
          bw != null &&
          sf != null &&
          cr != null &&
          f >= 137000 &&
          f <= 1020000 &&
          bw > 0 &&
          sf >= 5 &&
          sf <= 12 &&
          cr >= 5 &&
          cr <= 8) {
        mm = TeamSetupMediaMesh(
          frequencyKHz: f,
          bandwidthHz: bw,
          sf: sf,
          cr: cr,
        );
      }
    }
    return TeamSetup(
      teamName: name,
      teamSecretHex: secret,
      watched: watched,
      mediaMesh: mm,
    );
  }

  /// What to play by Sound link: the link itself when it fits one message,
  /// else MCT: parts.
  List<String> soundParts() {
    final link = toLink();
    if (utf8.encode(link).length <= teamSetupSoundBytes) return [link];
    final id = (_fnv32(utf8.encode(link)) & 0xFFFF)
        .toRadixString(16)
        .padLeft(4, '0');
    // "MCT:abcd:NN/NN:" is at most 15 bytes; the link is ASCII.
    const room = teamSetupSoundBytes - 15;
    final n = (link.length + room - 1) ~/ room;
    return [
      for (var i = 0; i < n; i++)
        '$teamSetupPartPrefix$id:${i + 1}/$n:'
            '${link.substring(i * room, ((i + 1) * room).clamp(0, link.length))}',
    ];
  }
}

/// Collects heard Sound link messages until a team setup is whole.
class TeamSetupAssembler {
  final Map<String, Map<int, String>> _parts = {};
  final Map<String, int> _counts = {};

  static final _part = RegExp(r'^MCT:([0-9a-f]{4}):(\d{1,2})/(\d{1,2}):(.*)$');

  /// True when [heard] is (part of) a team setup.
  static bool isPart(String heard) =>
      TeamSetup.isLink(heard) || _part.hasMatch(heard.trim());

  /// (got, of) for the setup being heard, for a progress line.
  (int, int)? get progress {
    if (_parts.isEmpty) return null;
    final k = _parts.keys.last;
    return (_parts[k]!.length, _counts[k]!);
  }

  /// The setup once [heard] completes it.
  TeamSetup? accept(String heard) {
    final t = heard.trim();
    if (TeamSetup.isLink(t)) return TeamSetup.parse(t);
    final m = _part.firstMatch(t);
    if (m == null) return null;
    final id = m.group(1)!;
    final i = int.parse(m.group(2)!), n = int.parse(m.group(3)!);
    if (n < 1 || i < 1 || i > n) return null;
    final parts = _parts.putIfAbsent(id, () => {});
    _counts[id] = n;
    parts[i] = m.group(4)!;
    if (parts.length < n) return null;
    final link = [for (var k = 1; k <= n; k++) parts[k] ?? ''].join();
    _parts.remove(id);
    _counts.remove(id);
    return TeamSetup.parse(link);
  }
}

// Percent-encoding with RFC 3986 unreserved characters kept (as the firmware).
String _enc(String s) {
  final out = StringBuffer();
  for (final b in utf8.encode(s)) {
    final c = String.fromCharCode(b);
    if ((b >= 0x30 && b <= 0x39) ||
        (b >= 0x41 && b <= 0x5A) ||
        (b >= 0x61 && b <= 0x7A) ||
        c == '-' ||
        c == '_' ||
        c == '.' ||
        c == '~') {
      out.write(c);
    } else {
      out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

String _dec(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}

int _fnv32(List<int> bytes) {
  var h = 0x811c9dc5;
  for (final b in bytes) {
    h ^= b;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}
