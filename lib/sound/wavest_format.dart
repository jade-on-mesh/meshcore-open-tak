// MeshCore Open TAK - messages in Wavest's format (github.com/bennjordan/Wavest),
// so this app and Wavest's web page can talk over ggwave:
//
//   U:<callsign>|<text>                 plain
//   E:<callsign>|AES:<base64>           AES-256-GCM: 12-byte IV, then ciphertext
//                                       and tag; key = SHA-256(passkey)
//   E:<callsign>|XOR:<base64>           Wavest's fallback, read only
//
// Anything else heard (a share link, say) is shown as it is. Wavest's key is
// an unsalted hash of the passkey: fine for keeping a chat between friends
// unreadable to bystanders, not a substitute for the mesh's own encryption.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';

/// ggwave's limit for one message.
const int wavestMaxBytes = 140;

class WavestMessage {
  final String sender;
  final String text;
  final bool encrypted;

  /// False when it was encrypted and no key here opened it.
  final bool readable;

  /// Not in Wavest's format at all (shown as it was heard).
  final bool raw;

  const WavestMessage({
    required this.sender,
    required this.text,
    this.encrypted = false,
    this.readable = true,
    this.raw = false,
  });
}

/// A callsign as Wavest sends it: no `|` or `:`.
String wavestCallsign(String s) => s.replaceAll(RegExp(r'[|:]'), '').trim();

final _aes = AesGcm.with256bits();

Future<SecretKey> _key(String passkey) async =>
    SecretKey(hash.sha256.convert(utf8.encode(passkey)).bytes);

/// The message to play; [passkey] encrypts it (null or empty: plain).
/// [iv] is for tests only.
Future<String> wavestBuild(
  String callsign,
  String text, {
  String? passkey,
  List<int>? iv,
}) async {
  final cs = wavestCallsign(callsign);
  if (passkey == null || passkey.isEmpty) return 'U:$cs|$text';
  final nonce = iv ?? List<int>.generate(12, (_) => Random.secure().nextInt(256));
  final box = await _aes.encrypt(
    utf8.encode(text),
    secretKey: await _key(passkey),
    nonce: nonce,
  );
  final all = Uint8List.fromList([...nonce, ...box.cipherText, ...box.mac.bytes]);
  return 'E:$cs|AES:${base64.encode(all)}';
}

/// Whether [text] from [callsign] fits one ggwave message.
Future<bool> wavestFits(String callsign, String text, {String? passkey}) async =>
    utf8.encode(await wavestBuild(callsign, text, passkey: passkey)).length <=
    wavestMaxBytes;

/// Reads what was heard. [passkey] opens encrypted messages.
Future<WavestMessage> wavestParse(String heard, {String? passkey}) async {
  final kind = heard.startsWith('U:')
      ? 'U'
      : heard.startsWith('E:')
      ? 'E'
      : null;
  final bar = heard.indexOf('|');
  if (kind == null || bar < 0) {
    return WavestMessage(sender: '', text: heard, raw: true);
  }
  final sender = heard.substring(2, bar);
  final body = heard.substring(bar + 1);
  if (kind == 'U') return WavestMessage(sender: sender, text: body);
  final opened = passkey == null || passkey.isEmpty
      ? null
      : await _open(body, passkey);
  return WavestMessage(
    sender: sender,
    text: opened ?? body,
    encrypted: true,
    readable: opened != null,
  );
}

Future<String?> _open(String body, String passkey) async {
  try {
    if (body.startsWith('XOR:')) {
      final t = utf8.decode(base64.decode(body.substring(4)), allowMalformed: true);
      return String.fromCharCodes([
        for (var i = 0; i < t.length; i++)
          t.codeUnitAt(i) ^ passkey.codeUnitAt(i % passkey.length),
      ]);
    }
    final all = base64.decode(body.startsWith('AES:') ? body.substring(4) : body);
    if (all.length <= 12 + 16) return null;
    final box = SecretBox(
      all.sublist(12, all.length - 16),
      nonce: all.sublist(0, 12),
      mac: Mac(all.sublist(all.length - 16)),
    );
    return utf8.decode(await _aes.decrypt(box, secretKey: await _key(passkey)));
  } catch (_) {
    return null;
  }
}
