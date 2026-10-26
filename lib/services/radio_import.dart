// MeshCore Open TAK - importing identity, channels and contacts from other
// MeshCore apps and firmware into the connected radio.
//
// Reads:
//   - a MeshCore backup JSON (meshcore-backup.json): the official MeshCore
//     app's export, Wadamesh TAK's (and Wadamesh's), Squatch Mesh's;
//   - MeshCore Open's contacts export (a JSON list with base64 keys);
//   - Squatch Mesh's SD-card files (/inw): MeshCore's companion files
//     identity/_main.id, contacts3 (152-byte records), channels2 (68-byte);
//   - MeshPunk's SD-card files (/meshpunk): identity, contacts.bin (143-byte
//     records) and channels (text: slot, name, secret hex);
//   - MeshCore One's app backup (.mc1backup): raw-deflated JSON with base64
//     keys. It holds contacts and channels but no private key (MeshCore One's
//     "node config" export is the MeshCore backup JSON above, with the key).
// The same formats Wadamesh TAK reads (src/helpers/ForeignImport.h there).
// Pure Dart, no I/O: the screen picks the files, the connector applies it.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

enum RadioImportSource {
  meshcoreBackup,
  meshcoreOpenContacts,
  squatchMesh,
  meshPunk,
  meshCoreOne,
}

class RadioImportChannel {
  RadioImportChannel(this.name, this.secret);
  final String name;

  /// 16 bytes.
  final Uint8List secret;
}

class RadioImportContact {
  RadioImportContact({
    required this.publicKey,
    required this.name,
    this.type = 1,
    this.flags = 0,
    this.latitude,
    this.longitude,
    this.lastAdvert = 0,
    this.lastModified = 0,
  });
  final Uint8List publicKey;
  final String name;
  final int type;
  final int flags;
  final double? latitude;
  final double? longitude;

  /// Seconds since the epoch (0 when unknown).
  final int lastAdvert;
  final int lastModified;
}

class RadioImport {
  RadioImport(this.source);
  final RadioImportSource source;
  String? name;

  /// 64 bytes.
  Uint8List? privateKey;

  /// By slot; null for an empty one.
  final List<RadioImportChannel?> channels = [];
  final List<RadioImportContact> contacts = [];

  int get channelCount => channels.whereType<RadioImportChannel>().length;
  bool get hasIdentity => privateKey != null;
  bool get isEmpty =>
      !hasIdentity && name == null && channelCount == 0 && contacts.isEmpty;
}

/// What an import put on the radio.
class RadioImportResult {
  bool identity = false;

  /// Why the identity wasn't taken (the radio refused the key), if it wasn't.
  String? identityError;
  int channels = 0;
  int contacts = 0;

  /// Contacts the radio refused (its contact list full, for one).
  int contactErrors = 0;
}

/// MeshCore's Public channel key.
final Uint8List radioImportPublicSecret = _hex(
  '8b3387e9c5cdea6ac9e5edbaa115cd72',
)!;

/// What [files] (name -> bytes, names without folders) hold, or null when
/// nothing here is a known export. One JSON file, or the files of a
/// firmware's folder (any of them).
RadioImport? parseRadioImport(Map<String, Uint8List> files) {
  final names = {for (final k in files.keys) _base(k): files[k]!};
  final mc1 = names.entries.where(
    (e) => e.key.toLowerCase().endsWith('.mc1backup'),
  );
  if (mc1.isNotEmpty) return _parseMeshCoreOne(mc1.first.value);
  final json = names.entries.where(
    (e) => e.key.toLowerCase().endsWith('.json'),
  );
  if (json.isNotEmpty) return _parseJson(json.first.value);
  if (names.containsKey('_main.id') ||
      names.containsKey('contacts3') ||
      names.containsKey('channels2')) {
    return _parseCompanion(
      names['_main.id'],
      names['contacts3'],
      names['channels2'],
    );
  }
  if (names.containsKey('identity') ||
      names.containsKey('contacts.bin') ||
      names.containsKey('channels')) {
    return _parseMeshPunk(
      names['identity'],
      names['contacts.bin'],
      names['channels'],
    );
  }
  return null;
}

String _base(String path) {
  final i = path.lastIndexOf(RegExp(r'[/\\]'));
  return i < 0 ? path : path.substring(i + 1);
}

RadioImport? _parseJson(Uint8List bytes) {
  Object? doc;
  try {
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('﻿')) text = text.substring(1);
    doc = jsonDecode(text);
  } catch (_) {
    return null;
  }
  if (doc is List) return _parseOpenContacts(doc);
  if (doc is! Map) return null;
  if (!doc.containsKey('contacts') &&
      !doc.containsKey('channels') &&
      !doc.containsKey('private_key')) {
    return null;
  }
  final out = RadioImport(RadioImportSource.meshcoreBackup);
  final name = doc['name'];
  if (name is String && name.isNotEmpty) out.name = name;
  final prv = doc['private_key'];
  if (prv is String) {
    final k = _hex(prv);
    if (k != null && k.length == 64) out.privateKey = k;
  }
  final chans = doc['channels'];
  if (chans is List) {
    for (final c in chans) {
      final n = c is Map ? c['name'] : null;
      final s = c is Map ? c['secret'] : null;
      final key = s is String ? _hex(s) : null;
      out.channels.add(
        n is String && n.isNotEmpty && key != null && key.length >= 16
            ? RadioImportChannel(n, Uint8List.fromList(key.sublist(0, 16)))
            : null,
      );
    }
    _trimTrailingNulls(out.channels);
  }
  final contacts = doc['contacts'];
  if (contacts is List) {
    for (final c in contacts) {
      if (c is! Map) continue;
      final pk = c['public_key'];
      final key = pk is String ? _hex(pk) : null;
      if (key == null || key.length != 32) continue;
      final custom = c['custom_name'];
      final n = custom is String && custom.isNotEmpty ? custom : c['name'];
      out.contacts.add(
        RadioImportContact(
          publicKey: key,
          name: n is String ? n : '',
          type: _int(c['type'], 1),
          flags: _int(c['flags'], 0),
          latitude: _double(c['latitude']),
          longitude: _double(c['longitude']),
          lastAdvert: _int(c['last_advert'], 0),
          lastModified: _int(c['last_modified'], 0),
        ),
      );
    }
  }
  return out;
}

/// MeshCore One's .mc1backup: Apple's zlib (raw DEFLATE) around sorted-keys
/// JSON. A backup can hold several radios; the one with the most contacts is
/// taken.
RadioImport? _parseMeshCoreOne(Uint8List bytes) {
  Object? doc;
  try {
    // Raw DEFLATE; skip a zlib header if a tool added one.
    final zlib =
        bytes.length > 2 &&
        bytes[0] & 0x0F == 8 &&
        (bytes[0] << 8 | bytes[1]) % 31 == 0;
    final raw = Inflate(zlib ? bytes.sublist(2) : bytes).getBytes();
    doc = jsonDecode(utf8.decode(raw, allowMalformed: true));
  } catch (_) {
    return null;
  }
  if (doc is! Map) return null;
  final contacts = doc['contacts'] is List ? doc['contacts'] as List : const [];
  final channels = doc['channels'] is List ? doc['channels'] as List : const [];
  final devices = doc['devices'] is List ? doc['devices'] as List : const [];
  final perRadio = <Object?, int>{};
  for (final c in contacts) {
    if (c is Map) perRadio[c['radioID']] = (perRadio[c['radioID']] ?? 0) + 1;
  }
  for (final c in channels) {
    if (c is Map) perRadio.putIfAbsent(c['radioID'], () => 0);
  }
  if (perRadio.isEmpty) return null;
  final radio = perRadio.entries
      .reduce((a, b) => b.value > a.value ? b : a)
      .key;

  final out = RadioImport(RadioImportSource.meshCoreOne);
  for (final d in devices) {
    if (d is Map && d['radioID'] == radio) {
      final n = d['nodeName'];
      if (n is String && n.isNotEmpty) out.name = n;
    }
  }
  final bySlot = <int, RadioImportChannel>{};
  for (final c in channels) {
    if (c is! Map || c['radioID'] != radio) continue;
    final slot = _int(c['index'], -1);
    final n = c['name'];
    final key = _b64(c['secret']);
    if (slot < 0 || slot >= 64 || n is! String || n.isEmpty) continue;
    if (key == null || key.length < 16) continue;
    bySlot[slot] = RadioImportChannel(n, Uint8List.fromList(key.sublist(0, 16)));
  }
  if (bySlot.isNotEmpty) {
    final last = bySlot.keys.reduce((a, b) => a > b ? a : b);
    for (var i = 0; i <= last; i++) {
      out.channels.add(bySlot[i]);
    }
  }
  for (final c in contacts) {
    if (c is! Map || c['radioID'] != radio) continue;
    final key = _b64(c['publicKey']);
    if (key == null || key.length != 32) continue;
    final nick = c['nickname'];
    final n = nick is String && nick.isNotEmpty ? nick : c['name'];
    out.contacts.add(
      RadioImportContact(
        publicKey: key,
        name: n is String ? n : '',
        type: _int(c['typeRawValue'], 1),
        flags: _int(c['flags'], 0),
        latitude: _double(c['latitude']),
        longitude: _double(c['longitude']),
        lastAdvert: _int(c['lastAdvertTimestamp'], 0),
        lastModified: _int(c['lastModified'], 0),
      ),
    );
  }
  return out.isEmpty ? null : out;
}

Uint8List? _b64(Object? v) {
  if (v is! String) return null;
  try {
    return base64Decode(v);
  } catch (_) {
    return null;
  }
}

RadioImport? _parseOpenContacts(List<dynamic> list) {
  final out = RadioImport(RadioImportSource.meshcoreOpenContacts);
  for (final c in list) {
    if (c is! Map) continue;
    final pk = c['publicKey'];
    Uint8List? key;
    try {
      key = pk is String ? base64Decode(pk) : null;
    } catch (_) {
      key = null;
    }
    if (key == null || key.length != 32) continue;
    final seen = _int(c['lastSeen'], 0) ~/ 1000;
    final n = c['name'];
    out.contacts.add(
      RadioImportContact(
        publicKey: key,
        name: n is String ? n : '',
        type: _int(c['type'], 1),
        flags: _int(c['flags'], 0),
        latitude: _double(c['latitude']),
        longitude: _double(c['longitude']),
        lastAdvert: seen,
        lastModified: seen,
      ),
    );
  }
  return out.contacts.isEmpty ? null : out;
}

RadioImport _parseCompanion(
  Uint8List? id,
  Uint8List? contacts3,
  Uint8List? channels2,
) {
  final out = RadioImport(RadioImportSource.squatchMesh);
  _identity(out, id, withName: true);
  if (channels2 != null) {
    for (var i = 0; i + 68 <= channels2.length; i += 68) {
      final name = _cstr(channels2, i + 4, 32);
      out.channels.add(
        name.isEmpty
            ? null
            : RadioImportChannel(
                name,
                Uint8List.fromList(channels2.sublist(i + 36, i + 52)),
              ),
      );
    }
    _trimTrailingNulls(out.channels);
  }
  if (contacts3 != null) {
    final b = ByteData.sublistView(contacts3);
    for (var i = 0; i + 152 <= contacts3.length; i += 152) {
      final c = _contact(
        contacts3,
        b,
        i,
        nameAt: i + 32,
        type: contacts3[i + 64],
        flags: contacts3[i + 65],
        lastAdvertAt: i + 72,
        lastModAt: i + 140,
        latAt: i + 144,
        lonAt: i + 148,
      );
      if (c != null) out.contacts.add(c);
    }
  }
  return out;
}

RadioImport _parseMeshPunk(
  Uint8List? id,
  Uint8List? contacts,
  Uint8List? channels,
) {
  final out = RadioImport(RadioImportSource.meshPunk);
  _identity(out, id, withName: false);
  final bySlot = <int, RadioImportChannel>{};
  var publicDeleted = false;
  if (channels != null) {
    for (final line
        in utf8
            .decode(channels, allowMalformed: true)
            .split(RegExp(r'[\r\n]+'))) {
      if (line == 'pubdel') {
        publicDeleted = true;
        continue;
      }
      final f = line.split('\t');
      if (f.length < 3) continue;
      final slot = int.tryParse(f[0]);
      final key = _hex(f[2]);
      if (slot == null ||
          slot < 1 ||
          slot >= 40 ||
          f[1].isEmpty ||
          key == null ||
          key.length < 16) {
        continue;
      }
      bySlot[slot] = RadioImportChannel(
        f[1],
        Uint8List.fromList(key.sublist(0, 16)),
      );
    }
  }
  if (!publicDeleted) {
    bySlot[0] = RadioImportChannel('Public', radioImportPublicSecret);
  }
  if (bySlot.isNotEmpty) {
    final last = bySlot.keys.reduce((a, b) => a > b ? a : b);
    for (var i = 0; i <= last; i++) {
      out.channels.add(bySlot[i]);
    }
  }
  if (contacts != null) {
    final b = ByteData.sublistView(contacts);
    for (var i = 0; i + 143 <= contacts.length; i += 143) {
      final c = _contact(
        contacts,
        b,
        i,
        nameAt: i + 32,
        type: contacts[i + 64],
        flags: contacts[i + 65],
        lastAdvertAt: i + 131,
        lastModAt: null,
        latAt: i + 135,
        lonAt: i + 139,
      );
      if (c != null) out.contacts.add(c);
    }
  }
  return out;
}

void _identity(RadioImport out, Uint8List? id, {required bool withName}) {
  if (id == null || id.length < 96) return;
  final prv = id.sublist(32, 96);
  if (prv.every((b) => b == 0)) return;
  out.privateKey = Uint8List.fromList(prv);
  if (withName && id.length >= 128) {
    final n = _cstr(id, 96, 32);
    if (n.isNotEmpty) out.name = n;
  }
}

RadioImportContact? _contact(
  Uint8List r,
  ByteData b,
  int at, {
  required int nameAt,
  required int type,
  required int flags,
  required int lastAdvertAt,
  required int? lastModAt,
  required int latAt,
  required int lonAt,
}) {
  final key = Uint8List.fromList(r.sublist(at, at + 32));
  final name = _cstr(r, nameAt, 32);
  if (type == 0 || name.isEmpty || key.every((x) => x == 0)) return null;
  final lat = b.getInt32(latAt, Endian.little);
  final lon = b.getInt32(lonAt, Endian.little);
  final has = lat != 0 || lon != 0;
  return RadioImportContact(
    publicKey: key,
    name: name,
    type: type,
    flags: flags,
    latitude: has ? lat / 1e6 : null,
    longitude: has ? lon / 1e6 : null,
    lastAdvert: b.getUint32(lastAdvertAt, Endian.little),
    lastModified: lastModAt == null ? 0 : b.getUint32(lastModAt, Endian.little),
  );
}

String _cstr(Uint8List b, int at, int cap) {
  var n = 0;
  while (n < cap && at + n < b.length && b[at + n] != 0) {
    n++;
  }
  return utf8.decode(b.sublist(at, at + n), allowMalformed: true);
}

void _trimTrailingNulls(List<Object?> l) {
  while (l.isNotEmpty && l.last == null) {
    l.removeLast();
  }
}

Uint8List? _hex(String s) {
  final t = s.trim();
  if (t.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(t)) return null;
  final out = Uint8List(t.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(t.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}

int _int(Object? v, int fallback) => v is num
    ? v.toInt()
    : v is String
    ? int.tryParse(v) ?? fallback
    : fallback;

double? _double(Object? v) {
  final d = v is num
      ? v.toDouble()
      : v is String
      ? double.tryParse(v)
      : null;
  return d == null || d == 0 ? null : d;
}
