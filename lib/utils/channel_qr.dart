// Channel share links/QR codes: meshcore://channel/add?name=<name>&secret=<hex>
// (the same shape as contact cards, meshcore://contact/add?...). The secret
// is the channel's 16-byte PSK as 32 hex characters.

/// A channel read from a share link or QR code.
class ScannedChannel {
  final String name;

  /// 32 lowercase hex characters.
  final String secretHex;

  const ScannedChannel({required this.name, required this.secretHex});
}

final RegExp _hex32 = RegExp(r'^[0-9a-fA-F]{32}$');

/// The share link for a channel. [secretHex] may contain spaces or other
/// separators; returns null when it is not 16 bytes of hex.
String? channelShareLink(String name, String secretHex) {
  final secret = secretHex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (!_hex32.hasMatch(secret)) return null;
  return Uri(
    scheme: 'meshcore',
    host: 'channel',
    path: '/add',
    queryParameters: {'name': name.trim(), 'secret': secret.toLowerCase()},
  ).toString();
}

/// Returns null when [data] is not a MeshCore channel link.
ScannedChannel? parseChannelQr(String data) {
  final uri = Uri.tryParse(data.trim());
  if (uri == null || uri.scheme.toLowerCase() != 'meshcore') return null;
  final path = '${uri.host}${uri.path}'.toLowerCase().replaceAll(
    RegExp(r'^/+|/+$'),
    '',
  );
  if (path != 'channel/add') return null;
  final secret = (uri.queryParameters['secret'] ?? '').trim();
  if (!_hex32.hasMatch(secret)) return null;
  final name = (uri.queryParameters['name'] ?? '').trim();
  return ScannedChannel(name: name, secretHex: secret.toLowerCase());
}

bool isChannelQr(String data) => parseChannelQr(data) != null;
