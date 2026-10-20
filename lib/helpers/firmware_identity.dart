/// The connected radio's firmware, as shown in Settings > About: a name and a
/// version, worked out from DEVICE_INFO's version string. Companion firmware
/// has no separate name field, so builds that carry one put it in front of the
/// version:
///
/// - `wadamesh-tak 42`   jade-on-mesh/wadamesh-tak releases
/// - `wadamesh v1.2.3`   Wadamesh releases
/// - `v1.17.4-touch`     Wadamesh development builds
/// - `v1.18.0`           MeshCore (stock, or a fork that doesn't name itself)
class FirmwareIdentity {
  final String name;
  final String version;

  const FirmwareIdentity(this.name, this.version);

  static const _names = {
    'wadamesh-tak': 'Wadamesh TAK',
    'wadamesh': 'Wadamesh',
    'meshcomod': 'Meshcomod',
    'meshcore': 'MeshCore',
  };

  /// Null when there is no version string.
  static FirmwareIdentity? fromVersionString(String? raw) {
    final s = raw?.trim() ?? '';
    if (s.isEmpty) return null;
    final named = RegExp(r'^([A-Za-z][\w.-]*)\s+(\S.*)$').firstMatch(s);
    if (named != null) {
      final word = named.group(1)!;
      return FirmwareIdentity(_prettyName(word), named.group(2)!.trim());
    }
    if (s.toLowerCase().endsWith('-touch')) {
      return FirmwareIdentity('Wadamesh', s.substring(0, s.length - 6));
    }
    return FirmwareIdentity('MeshCore', s);
  }

  static String _prettyName(String word) {
    final known = _names[word.toLowerCase()];
    if (known != null) return known;
    return word
        .split('-')
        .where((p) => p.isNotEmpty)
        .map((p) => p[0].toUpperCase() + p.substring(1))
        .join(' ');
  }

  /// "Wadamesh TAK 42", "MeshCore v1.18.0".
  String get label => '$name $version';
}
