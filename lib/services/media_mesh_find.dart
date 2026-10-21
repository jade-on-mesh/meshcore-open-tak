// MeshCore Open TAK - "Find MediaMesh": the radio2 profile the MediaMesh
// nearby uses.
//
// First it asks, like Discover Repeaters: one zero-hop DISCOVER_REQ with the
// radio2 flag, and repeaters that support it (keymindCascade, proposed) answer
// with their radio2 profile (DiscoverRadio2). The profile most of them run is
// the pick ([mediaMeshProfilePick], shared with Wadamesh TAK's
// mediamesh::profilePick).
//
// When no repeater says, it falls back to listening: radio2 listens on each
// preset in turn (a listen-only, 2-minute tempradio2)
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

/// A radio2 profile repeaters reported, and how many run it.
class MediaMeshProfile {
  const MediaMeshProfile({
    required this.frequencyKHz,
    required this.bandwidth,
    required this.spreadingFactor,
    required this.codingRate,
    required this.repeaters,
    required this.bestSnr,
  });

  final int frequencyKHz;
  final LoRaBandwidth bandwidth;
  final LoRaSpreadingFactor spreadingFactor;
  final LoRaCodingRate codingRate;

  /// Repeaters reporting this profile.
  final int repeaters;

  /// The best SNR (dB) we heard one of them at.
  final double bestSnr;

  double get frequencyMHz => frequencyKHz / 1000.0;

  String get label =>
      '${frequencyMHz.toStringAsFixed(3)} MHz · ${bandwidth.label} · '
      '${spreadingFactor.label} · CR ${codingRate.label}';
}

T? _byValue<T>(List<T> values, int v, int Function(T) of) {
  for (final x in values) {
    if (of(x) == v) return x;
  }
  return null;
}

/// The profile most reporting repeaters run (radio2 on: rx or rxtx), the
/// stronger signal breaking a tie; null when none reports one. Profiles the
/// app can't set (an odd bandwidth, SF or CR) are left out. The same rule as
/// Wadamesh's mediamesh::profilePick.
MediaMeshProfile? mediaMeshProfilePick(
  Iterable<({DiscoverRadio2 radio2, double snr})> reports,
) {
  final groups = <String, MediaMeshProfile>{};
  for (final r in reports) {
    final p = r.radio2;
    if (!p.active) continue;
    final bw = _byValue(LoRaBandwidth.values, p.bandwidthHz, (b) => b.hz);
    final sf = _byValue(
      LoRaSpreadingFactor.values,
      p.spreadingFactor,
      (s) => s.value,
    );
    final cr = _byValue(LoRaCodingRate.values, p.codingRate, (c) => c.value);
    if (bw == null || sf == null || cr == null || p.frequencyKHz == 0) continue;
    final key = '${p.frequencyKHz}/${bw.hz}/${sf.value}/${cr.value}';
    final had = groups[key];
    groups[key] = MediaMeshProfile(
      frequencyKHz: p.frequencyKHz,
      bandwidth: bw,
      spreadingFactor: sf,
      codingRate: cr,
      repeaters: (had?.repeaters ?? 0) + 1,
      bestSnr: had == null || r.snr > had.bestSnr ? r.snr : had.bestSnr,
    );
  }
  MediaMeshProfile? best;
  for (final g in groups.values) {
    if (best == null ||
        g.repeaters > best.repeaters ||
        (g.repeaters == best.repeaters && g.bestSnr > best.bestSnr)) {
      best = g;
    }
  }
  return best;
}

/// How long the asking round collects answers (repeaters answer after a
/// random delay, widened four times).
const Duration mediaMeshAskListen = Duration(seconds: 12);

/// A repeater that answered the asking round.
class MediaMeshNearby {
  const MediaMeshNearby({required this.name, required this.response});

  final String name;
  final NodeDiscoverResponse response;

  /// Null: the repeater didn't say (stock or older firmware).
  DiscoverRadio2? get radio2 => response.radio2;
}

class MediaMeshFindResult {
  /// Every repeater that answered the asking round.
  final List<MediaMeshNearby> nearby;

  /// What the repeaters reported, or null when none did.
  final MediaMeshProfile? reported;

  /// Listening fallback: radio2 packets heard on each preset (250, 125 kHz);
  /// empty when the repeaters reported a profile.
  final List<int> heard;

  /// Repeaters that answered at all (on either radio).
  final int repeatersAnswered;

  final double frequencyMHz;

  const MediaMeshFindResult({
    this.nearby = const [],
    this.reported,
    required this.heard,
    required this.repeatersAnswered,
    required this.frequencyMHz,
  });

  /// Whether any repeater answered with its radio2 profile (on or off).
  bool get asked => nearby.any((n) => n.radio2 != null);

  /// The listening fallback's preset.
  LoRaBandwidth? get pick =>
      heard.length < 2 ? null : mediaMeshFindPick(heard[0], heard[1]);

  int get heardOnPick =>
      pick == null ? 0 : heard[pick == LoRaBandwidth.bw250 ? 0 : 1];
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

  /// Asks the repeaters in range for their radio2 profile.
  Future<List<MediaMeshNearby>> ask() async {
    final out = <MediaMeshNearby>[];
    await for (final r in connector.discoverNearbyNodes(
      typeMask: 1 << advTypeRepeater,
      timeout: mediaMeshAskListen,
      wantRadio2: true,
    )) {
      out.add(
        MediaMeshNearby(
          name: connector.contactForDiscoverResponse(r).name,
          response: r,
        ),
      );
    }
    out.sort((a, b) => b.response.snr.compareTo(a.response.snr));
    return out;
  }

  /// Runs the search: asks first, then (when no repeater reports a profile)
  /// listens at [frequencyMHz]. [onStep] gets -1 while asking, then the
  /// preset being listened on (0 or 1). Throws [MediaMeshException] when it
  /// can't run.
  Future<MediaMeshFindResult> run({
    required double frequencyMHz,
    void Function(int step)? onStep,
  }) async {
    if (!connector.isConnected) {
      throw MediaMeshException('Not connected to a radio');
    }
    if (!connector.supportsNodeDiscover) {
      throw MediaMeshException(
        "This radio's firmware can't ask repeaters to answer",
      );
    }
    onStep?.call(-1);
    final nearby = await ask();
    final reported = mediaMeshProfilePick(
      nearby
          .where((n) => n.radio2 != null)
          .map((n) => (radio2: n.radio2!, snr: n.response.snr)),
    );
    if (nearby.any((n) => n.radio2 != null)) {
      return MediaMeshFindResult(
        nearby: nearby,
        reported: reported,
        heard: const [],
        repeatersAnswered: nearby.length,
        frequencyMHz: reported?.frequencyMHz ?? frequencyMHz,
      );
    }
    final temp = await _cli('get tempradio2');
    if (temp != null && TempRadio2.tryParse(temp) != null) {
      throw MediaMeshException('Stop the temporary radio2 first');
    }
    final heard = [0, 0];
    final answered = <String>{for (final n in nearby) n.response.publicKeyHex};
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
      nearby: nearby,
      heard: heard,
      repeatersAnswered: answered.length,
      frequencyMHz: frequencyMHz,
    );
  }
}
