// MeshCore Open TAK - "Find MediaMesh": which preset the MediaMesh nearby
// uses, 250 kHz fast or 125 kHz range.
//
// radio2 listens on each preset in turn (a listen-only, 2-minute tempradio2)
// while a repeater discovery request goes out on the main mesh. MediaMesh
// repeaters (keymindCascade, `tx.reply both`) answer on both of their radios,
// so their radio2 answer is only heard when radio2 listens on the preset they
// run: the rise in the radio's radio2 receive count shows which. The saved
// radio2 comes back at the end (`tempradio2 off`). Shared with Wadamesh TAK
// (mediamesh::findPick in src/helpers/MediaMeshCore.h).

import 'dart:async';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../models/radio_settings.dart';
import 'media_mesh.dart';

/// The two presets, in the order they are tried.
const List<LoRaBandwidth> mediaMeshFindPresets = [
  LoRaBandwidth.bw250,
  LoRaBandwidth.bw125,
];

/// After the retune, before asking.
const Duration mediaMeshFindSettle = Duration(milliseconds: 1500);

/// Repeaters answer after a random delay (widened four times).
const Duration mediaMeshFindListen = Duration(seconds: 9);

/// The preset that heard more (a tie goes to the fast one), or null when
/// neither heard anything. The same rule as Wadamesh's mediamesh::findPick.
LoRaBandwidth? mediaMeshFindPick(int heardFast, int heardRange) {
  if (heardFast <= 0 && heardRange <= 0) return null;
  return heardRange > heardFast ? LoRaBandwidth.bw125 : LoRaBandwidth.bw250;
}

class MediaMeshFindResult {
  /// radio2 packets heard on each preset: 250 kHz, 125 kHz.
  final List<int> heard;

  /// Repeaters that answered at all (on either radio).
  final int repeatersAnswered;

  final double frequencyMHz;

  const MediaMeshFindResult({
    required this.heard,
    required this.repeatersAnswered,
    required this.frequencyMHz,
  });

  LoRaBandwidth? get pick => mediaMeshFindPick(heard[0], heard[1]);

  int get heardOnPick => pick == null ? 0 : heard[pick == LoRaBandwidth.bw250 ? 0 : 1];
}

class MediaMeshFinder {
  MediaMeshFinder(this.connector, this.controller);

  final MeshCoreConnector connector;
  final MediaMeshController controller;

  Future<String?> _cli(String command) async {
    try {
      return await connector.runLocalCliCommand(command);
    } catch (_) {
      return null;
    }
  }

  Future<int?> _radio2Rx() async {
    final r = await _cli('get radio2.status');
    final s = r == null ? null : Radio2Status.tryParse(r);
    if (s == null || s.rx.length < 2) return null;
    return s.rx[1];
  }

  /// Runs the search at [frequencyMHz]. [onStep] gets the preset being
  /// listened on (0 or 1). Throws [MediaMeshException] when it can't run.
  Future<MediaMeshFindResult> run({
    required double frequencyMHz,
    void Function(int preset)? onStep,
  }) async {
    if (!connector.isConnected) {
      throw MediaMeshException('Not connected to a radio');
    }
    if (!connector.supportsNodeDiscover) {
      throw MediaMeshException(
        "This radio's firmware can't ask repeaters to answer",
      );
    }
    final temp = await _cli('get tempradio2');
    if (temp != null && TempRadio2.tryParse(temp) != null) {
      throw MediaMeshException('Stop the temporary radio2 first');
    }
    final heard = [0, 0];
    final answered = <String>{};
    try {
      for (var i = 0; i < mediaMeshFindPresets.length; i++) {
        onStep?.call(i);
        final s = MediaMeshSettings.defaults.copyWith(
          frequencyMHz: frequencyMHz,
          bandwidth: mediaMeshFindPresets[i],
          spreadingFactor: LoRaSpreadingFactor.sf7,
          codingRate: LoRaCodingRate.cr4_5,
        );
        final ok = await _cli(
          buildTempRadio2Command(s, 2, mode: Radio2Mode.rx),
        );
        if (ok == null || !isCliOk(ok)) {
          throw MediaMeshException(
            ok == null
                ? 'The radio has no temporary radio2'
                : 'The radio refused the ${mediaMeshFindPresets[i].label} preset',
          );
        }
        await Future<void>.delayed(mediaMeshFindSettle);
        final before = await _radio2Rx();
        await for (final r in connector.discoverNearbyNodes(
          typeMask: 1 << advTypeRepeater,
          timeout: mediaMeshFindListen,
        )) {
          answered.add(r.publicKeyHex);
        }
        final after = await _radio2Rx();
        if (before != null && after != null && after >= before) {
          heard[i] = after - before;
        }
      }
    } finally {
      await _cli('set tempradio2 off'); // the saved radio2 again
    }
    return MediaMeshFindResult(
      heard: heard,
      repeatersAnswered: answered.length,
      frequencyMHz: frequencyMHz,
    );
  }
}
