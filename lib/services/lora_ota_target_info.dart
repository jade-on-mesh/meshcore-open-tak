import 'ble_mota_catalog.dart';

/// Read-only target identity used to reject incompatible packages before a
/// temporary-radio handoff or LoRa download begins.
class LoraOtaTargetInfo {
  const LoraOtaTargetInfo({
    required this.environment,
    required this.applicationTargetId,
    required this.bootloaderTargetId,
    required this.baseHashPrefix,
    required this.bootloaderStorageCaps,
    required this.receiverStorage,
    required this.trustedSignerFingerprints,
  });

  final String environment;
  final int applicationTargetId;

  /// The bootloader's target and storage profile, from `ota bootloader`. Null
  /// when this repeater's build can't update its bootloader over the air
  /// (ESP32, or an nRF52 build without it): it answers "Bootloader update
  /// unavailable: ..." or similar, and only application packages apply.
  final int? bootloaderTargetId;
  final String baseHashPrefix;
  final int? bootloaderStorageCaps;

  /// Where the repeater stages a download: external_sd, external_qspi or
  /// internal_flash; null when it doesn't say (ESP32).
  final String? receiverStorage;
  final Set<String> trustedSignerFingerprints;

  /// This repeater can take a bootloader package.
  bool get bootloaderUpdatable =>
      bootloaderTargetId != null && bootloaderStorageCaps != null;

  static LoraOtaTargetInfo parse({
    required String status,
    required String self,
    required String bootloader,
    required String keys,
  }) {
    String value(String text, RegExp pattern, String label) {
      final match = pattern.firstMatch(text);
      if (match == null) throw FormatException('Target did not report $label');
      return match.group(1)!;
    }

    final environment = value(
      status,
      RegExp(r'\benv:([A-Za-z0-9_]+)'),
      'its build profile',
    );
    final applicationId = int.parse(
      value(status, RegExp(r'\btarget:([0-9A-Fa-f]{8})'), 'application target'),
      radix: 16,
    );
    // Only builds that can update their bootloader over the air report it;
    // an application update doesn't need it.
    final blTarget = RegExp(
      r'\btarget=([0-9A-Fa-f]{8})',
    ).firstMatch(bootloader);
    final blCaps = RegExp(r'\bcaps=([0-9A-Fa-f]{2})').firstMatch(bootloader);
    final bootloaderId = blTarget == null
        ? null
        : int.parse(blTarget.group(1)!, radix: 16);
    final storageCaps = blCaps == null
        ? null
        : int.parse(blCaps.group(1)!, radix: 16);
    final baseHash = value(
      self,
      RegExp(r'\bbase_hash=([0-9A-Fa-f]{16})'),
      'its firmware hash',
    ).toUpperCase();
    final String? receiverStorage;
    if (storageCaps != null) {
      receiverStorage = switch (storageCaps) {
        0x09 => 'external_sd',
        0x0E => 'external_qspi',
        0x0A => 'internal_flash',
        _ => throw const FormatException('Unknown target bootloader storage'),
      };
    } else {
      // `ota status` names the staging store on nRF52 (`bl:SD`, `bl:QSPI`,
      // `bl:internal`); ESP32 doesn't say.
      final bl = RegExp(r'\bbl:(SD|QSPI|internal)\b').firstMatch(status);
      receiverStorage = switch (bl?.group(1)) {
        'SD' => 'external_sd',
        'QSPI' => 'external_qspi',
        'internal' => 'internal_flash',
        _ => null,
      };
    }
    final keySection = keys.contains(':') ? keys.split(':').last : '';
    final fingerprints = RegExp(r'[0-9A-Fa-f]{16}')
        .allMatches(keySection)
        .map((match) => match.group(0)!.toUpperCase())
        .toSet();
    return LoraOtaTargetInfo(
      environment: environment,
      applicationTargetId: applicationId,
      bootloaderTargetId: bootloaderId,
      baseHashPrefix: baseHash,
      bootloaderStorageCaps: storageCaps,
      receiverStorage: receiverStorage,
      trustedSignerFingerprints: fingerprints,
    );
  }

  void validatePackage(BleMotaFile file) {
    if (file.isBootloader && !bootloaderUpdatable) {
      throw StateError(
        "${file.name} is a bootloader update, and this repeater's firmware "
        "can't update its bootloader over the air",
      );
    }
    final expectedId = file.isBootloader
        ? bootloaderTargetId
        : applicationTargetId;
    if (file.targetId != expectedId) {
      throw StateError('${file.name} targets a different radio');
    }
    if (file.isBootloader) {
      if (file.bootloaderStorageCaps != bootloaderStorageCaps) {
        throw StateError(
          '${file.name} has the wrong bootloader storage profile',
        );
      }
    } else if (!file.isFull && file.baseHashPrefix != baseHashPrefix) {
      throw StateError(
        '${file.name} needs a different installed firmware base',
      );
    }
  }

  Set<String> missingSigners(Iterable<BleMotaFile> files) {
    return files
        .where((file) => file.isSigned && !file.isBootloader)
        .map((file) => file.signerPublicKeyHex)
        .where(
          (key) =>
              key.isNotEmpty &&
              !trustedSignerFingerprints.contains(key.substring(0, 16)),
        )
        .toSet();
  }
}
