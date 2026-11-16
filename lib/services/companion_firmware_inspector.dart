import 'dart:typed_data';

enum Esp32FirmwareLayout { application, fullFlash }

/// Selects the phone-update format only when the reported board family is
/// unambiguous. Unknown boards keep both file types available for inspection.
class CompanionFirmwareInspector {
  /// MeshCore Open TAK: every board name MeshCore firmware reports (its
  /// `getManufacturerName()`, which the `board` command prints), lowercased
  /// with only letters and digits kept, and how a phone updates it: 'zip'
  /// (nRF52, Bluetooth DFU), 'bin' (ESP32, Wi-Fi OTA) or 'wired' (RP2040 and
  /// STM32: no phone update). Taken from each board's variant in the firmware
  /// source, so names that don't say their chip ("RAK WisMesh Tag",
  /// "Elecrow ThinkNode M2") are still known. The rules after it are the
  /// fallback for names this list doesn't have yet.
  static const Map<String, String> _firmwareBoards = {
    'elecrowthinknodem1': 'zip', // Elecrow ThinkNode-M1
    'elecrowthinknodem2': 'bin', // Elecrow ThinkNode M2
    'elecrowthinknodem3': 'zip', // Elecrow ThinkNode M3
    'elecrowthinknodem4': 'zip', // Elecrow ThinkNode M4
    'elecrowthinknodem5': 'bin', // Elecrow ThinkNode M5
    'elecrowthinknodem6': 'zip', // Elecrow ThinkNode M6
    'elecrowthinknodem7': 'bin', // Elecrow ThinkNode M7
    'elecrowthinknodem8': 'zip', // Elecrow ThinkNode-M8
    'elecrowthinknodem9': 'bin', // Elecrow ThinkNode M9
    'gat56230smeshkit': 'zip', // GAT562 30S Mesh Kit
    'gat562evbpro': 'zip', // GAT562 EVB Pro
    'gat562meshtrackerpro': 'zip', // GAT562 Mesh Tracker Pro
    'gat562meshwatch13': 'zip', // GAT562 Mesh Watch 13
    'heltecct62': 'bin', // Heltec CT62
    'heltece213': 'bin', // Heltec E213
    'heltece290': 'bin', // Heltec E290
    'heltecmeshpocket': 'zip', // Heltec MeshPocket
    'heltecmeshsolar': 'zip', // Heltec Mesh Solar
    'heltecrc32': 'bin', // Heltec RC32
    'heltect096': 'zip', // Heltec T096
    'heltect1': 'zip', // Heltec T1
    'heltect114': 'zip', // Heltec T114
    'heltect190': 'bin', // Heltec T190
    'heltectowerv2': 'zip', // Heltec Tower V2
    'heltecv2': 'bin', // Heltec V2
    'heltecv4r8': 'bin', // Heltec V4 R8
    'heltecwirelesspaper': 'bin', // Heltec Wireless Paper
    'keepteenlt1': 'zip', // Keepteen LT1
    'lilygot3s3sx126x': 'bin', // LilyGo T3 S3 SX126x
    'lilygotbeam1w': 'bin', // LilyGo T-Beam 1W
    'lilygotbeamsx126x': 'bin', // LilyGo T-Beam SX126x
    'lilygotdeck': 'bin', // LilyGo T-Deck
    'lilygotecho': 'zip', // LilyGo T-Echo
    'lilygotechocard': 'zip', // LilyGo T-Echo Card
    'lilygotecholite': 'zip', // LilyGo T-Echo Lite
    'lilygotethelite': 'bin', // LilyGO T-ETH Elite
    'lilygotimpulseplus': 'zip', // LilyGo T-Impulse-Plus
    'lilygotlorav2116': 'bin', // LILYGO T-LoRa V2.1-1.6
    'm5stackcardputeradv': 'bin', // M5Stack Cardputer-Adv
    'meshadventurer': 'bin', // Meshadventurer
    'meshnologyw12': 'bin', // Meshnology W12
    'meshtiny': 'zip', // Meshtiny
    'minewsemi': 'zip', // Minewsemi
    'mkes3': 'bin', // MKE S3
    'muziworksr1neo': 'zip', // muzi works R1 Neo
    'nanog2ultra': 'zip', // Nano G2 Ultra
    'picow': 'wired', // Pico W
    'rak11310': 'wired', // RAK 11310
    'rak3112': 'bin', // RAK 3112
    'rak3401': 'zip', // RAK 3401
    'rak3x72': 'wired', // RAK 3x72
    'rak4631': 'zip', // RAK 4631
    'rakwismeshtag': 'zip', // RAK WisMesh Tag
    'seeedsensecapindicatorlora': 'bin', // Seeed SenseCAP Indicator LoRa
    'seeedsensecapmeshtrackerx1': 'zip', // Seeed SenseCAP MeshTracker X1
    'seeedsensecapsolar': 'zip', // Seeed SenseCap Solar
    'seeedtrackert1000e': 'zip', // Seeed Tracker T1000-E
    'seeedwioe5devboard': 'wired', // Seeed Wio E5 Dev Board
    'seeedwioe5mini': 'wired', // Seeed Wio E5 mini
    'seeedwiotrackerl11w': 'zip', // Seeed Wio Tracker L1 1W
    'seeedwiotrackerl2pro': 'bin', // Seeed Wio Tracker L2 Pro
    'seeedwiowm1110': 'zip', // Seeed Wio WM1110
    'stationg2': 'bin', // Station G2
    'stationg3esp32': 'bin', // Station G3 ESP32
    'tenstarc3sx1262': 'bin', // Tenstar C3 SX1262
    'tinyrelay': 'wired', // Tiny Relay
    'unitc6l': 'bin', // Unit C6L
    'waveshareesp32s3lr1121': 'bin', // Waveshare ESP32-S3-LR1121
    'wavesharerp2040lora': 'wired', // Waveshare RP2040-LoRa
    'xiaorp2040': 'wired', // Xiao RP2040
    'xiaos3': 'bin', // Xiao S3
    'xiaos3wio': 'bin', // Xiao S3 WIO
  };

  static String _boardKey(String board) =>
      board.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// The board is one MeshCore firmware names, on a chip a phone can't
  /// update (RP2040, STM32): it needs a wired installer.
  static bool isWiredOnlyBoard(String? board) =>
      board != null && _firmwareBoards[_boardKey(board)] == 'wired';

  static String? updateExtensionForBoard(String? board) {
    if (board == null) return null;
    final name = _boardKey(board);
    if (name.isEmpty || name.startsWith('unknown')) return null;
    final known = _firmwareBoards[name];
    if (known != null) return known == 'wired' ? null : known;

    if (name.contains('xiaos3') ||
        name.contains('xiaoesp32') ||
        name.contains('esp32') ||
        name.startsWith('heltecv') ||
        name.startsWith('heltecwireless') ||
        name.contains('stationg2') ||
        name.contains('eoras3') ||
        name.contains('tdeck') ||
        name.contains('tbeam') ||
        name.contains('tlora') ||
        name.contains('sensecapindicator')) {
      return 'bin';
    }
    if (name.contains('nrf52') ||
        name.contains('rak4631') ||
        name.contains('rak3401') ||
        name.contains('t114') ||
        name.contains('techo') ||
        name.contains('t1000') ||
        name.contains('thinknode') ||
        name.startsWith('xiao')) {
      return 'zip';
    }
    return null;
  }

  /// The ESP image header alone occurs in both app-only and full-flash files.
  /// A partition table or an embedded second image marks a full-flash file.
  /// Such a file needs a wired installer and must never enter Wi-Fi OTA.
  static Esp32FirmwareLayout inspectEsp32(Uint8List image) {
    if (image.length < 1024 || image.length > 0x1000000) {
      throw const FormatException(
        'ESP32 image size is outside the supported range.',
      );
    }
    final startsAtZero = _imageHeaderAt(image, 0);
    final startsAt1000 = _imageHeaderAt(image, 0x1000);
    if (!startsAtZero && !startsAt1000) {
      throw const FormatException(
        'This file has no ESP32 firmware image header.',
      );
    }
    if (_partitionTableAt(image, 0x7000) ||
        _partitionTableAt(image, 0x8000) ||
        _imageHeaderAt(image, 0x10000) ||
        _imageHeaderAt(image, 0x150000)) {
      return Esp32FirmwareLayout.fullFlash;
    }
    return Esp32FirmwareLayout.application;
  }

  static bool _imageHeaderAt(Uint8List image, int offset) =>
      offset + 24 <= image.length &&
      image[offset] == 0xE9 &&
      image[offset + 1] >= 1 &&
      image[offset + 1] <= 16 &&
      image[offset + 2] <= 3;

  static bool _partitionTableAt(Uint8List image, int offset) =>
      offset + 32 <= image.length &&
      image[offset] == 0xAA &&
      image[offset + 1] == 0x50;
}
