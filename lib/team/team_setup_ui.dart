// MeshCore Open TAK - sharing and joining a team in one scan (team_setup.dart):
// the share sheet (QR code, and Sound link for standalones without a camera),
// the join screen (scan, or listen), and the sheet that sets it all up.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../models/channel.dart';
import '../models/radio_settings.dart';
import '../services/media_mesh.dart';
import '../sound/sound_link.dart';
import '../widgets/qr_code_display.dart';
import '../widgets/qr_scanner_widget.dart';
import 'team_service.dart';
import 'team_setup.dart';
import 'watch_feed.dart';

// ---------------------------------------------------------------- sharing

/// This team's setup: the team channel, the watched channels, and radio2's
/// profile when MediaMesh is on. Null without a team channel.
Future<TeamSetup?> currentTeamSetup(BuildContext context) async {
  final team = context.read<TeamService>();
  final connector = context.read<MeshCoreConnector>();
  WatchFeedService? watch;
  try {
    watch = context.read<WatchFeedService>();
  } on ProviderNotFoundException {
    watch = null;
  }
  final ch = team.teamChannel;
  if (ch == null) return null;
  final watched = <TeamSetupChannel>[];
  for (final name in watch?.watchedNames ?? const <String>{}) {
    for (final c in connector.channels) {
      if (c.name != name || c.isPublicChannel || c.index == ch.index) continue;
      watched.add(
        c.isHashtagChannel
            ? TeamSetupChannel(c.name)
            : TeamSetupChannel(c.name, c.pskHex),
      );
      break;
    }
  }
  TeamSetupMediaMesh? mm;
  try {
    final st = await MediaMeshController(
      connector,
    ).load().timeout(const Duration(seconds: 8));
    final s = st.settings;
    if (st.support != MediaMeshSupport.none && s.enabled) {
      mm = TeamSetupMediaMesh(
        frequencyKHz: (s.frequencyMHz * 1000).round(),
        bandwidthHz: s.bandwidth.hz,
        sf: s.spreadingFactor.value,
        cr: s.codingRate.value,
      );
    }
  } catch (_) {}
  return TeamSetup(
    teamName: ch.name,
    teamSecretHex: ch.pskHex.toLowerCase(),
    watched: watched,
    mediaMesh: mm,
  );
}

Future<void> showTeamSetupShare(BuildContext context) async {
  final l10n = context.l10n;
  final setup = await currentTeamSetup(context);
  if (!context.mounted) return;
  if (setup == null) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.teamSetup_noTeam)));
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ShareSheet(setup: setup),
  );
}

class _ShareSheet extends StatefulWidget {
  final TeamSetup setup;
  const _ShareSheet({required this.setup});
  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  int? _playing; // part being played (1-based)

  Future<void> _play() async {
    final parts = widget.setup.soundParts();
    try {
      for (var i = 0; i < parts.length; i++) {
        if (!mounted) return;
        setState(() => _playing = i + 1);
        await SoundLink.instance.play(parts[i]);
        if (i < parts.length - 1) {
          await Future<void>.delayed(const Duration(milliseconds: 700));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.sound_playFailed('$e'))),
        );
      }
    } finally {
      if (mounted) setState(() => _playing = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final s = widget.setup;
    final parts = s.soundParts().length;
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.teamSetup_shareTitle, style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            QrCodeDisplay(data: s.toLink(), size: 240),
            const SizedBox(height: 8),
            _Summary(setup: s),
            const SizedBox(height: 12),
            if (SoundLink.instance.available) ...[
              OutlinedButton.icon(
                onPressed: _playing != null ? null : _play,
                icon: _playing != null
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.graphic_eq),
                label: Text(
                  _playing != null
                      ? l10n.teamSetup_playingPart(_playing!, parts)
                      : l10n.sound_playByShare,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                l10n.teamSetup_soundHelp(parts),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
            ],
            Text(
              l10n.teamSetup_shareWarning,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.tertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  final TeamSetup setup;
  const _Summary({required this.setup});
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final lines = [
      l10n.teamSetup_teamChannel(setup.teamName),
      if (setup.watched.isNotEmpty)
        l10n.teamSetup_watch(setup.watched.map((c) => c.name).join(', ')),
      if (setup.mediaMesh != null)
        l10n.teamSetup_mediaMesh(setup.mediaMesh!.label),
    ];
    return Text(
      lines.join('\n'),
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodyMedium,
    );
  }
}

// ---------------------------------------------------------------- joining

/// Scan a team QR code (or listen for one played by sound), then set it up.
Future<void> showTeamSetupJoin(BuildContext context) async {
  final setup = await Navigator.of(
    context,
  ).push<TeamSetup>(MaterialPageRoute(builder: (_) => const _JoinScreen()));
  if (setup == null || !context.mounted) return;
  await showTeamSetupConfirm(context, setup);
}

class _JoinScreen extends StatelessWidget {
  const _JoinScreen();
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.teamSetup_joinTitle),
        actions: [
          if (SoundLink.instance.available)
            IconButton(
              tooltip: l10n.sound_listen,
              icon: const Icon(Icons.hearing),
              onPressed: () async {
                final s = await showModalBottomSheet<TeamSetup>(
                  context: context,
                  showDragHandle: true,
                  builder: (_) => const _ListenSheet(),
                );
                if (s != null && context.mounted) Navigator.of(context).pop(s);
              },
            ),
        ],
      ),
      body: QrScannerWidget(
        validator: TeamSetup.isLink,
        onScanned: (data) {
          final s = TeamSetup.parse(data);
          if (s != null) Navigator.of(context).pop(s);
        },
        onValidationFailed: (_) => ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.teamSetup_notATeam))),
        instructions: l10n.teamSetup_scanHelp,
      ),
    );
  }
}

class _ListenSheet extends StatefulWidget {
  const _ListenSheet();
  @override
  State<_ListenSheet> createState() => _ListenSheetState();
}

class _ListenSheetState extends State<_ListenSheet> {
  final _assembler = TeamSetupAssembler();
  StreamSubscription<String>? _sub;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final s = await SoundLink.instance.listen();
      _sub = s.listen((heard) {
        if (!mounted || !TeamSetupAssembler.isPart(heard)) return;
        final setup = _assembler.accept(heard);
        if (setup != null) {
          Navigator.of(context).pop(setup);
        } else {
          setState(() {});
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(SoundLink.instance.stopListening());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final p = _assembler.progress;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hearing, size: 48, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text(l10n.sound_listening, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              _error ??
                  (p == null
                      ? l10n.teamSetup_listenHelp
                      : l10n.teamSetup_heardParts(p.$1, p.$2)),
              textAlign: TextAlign.center,
              style: _error == null
                  ? theme.textTheme.bodySmall
                  : TextStyle(color: theme.colorScheme.error),
            ),
            if (_error == null) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: p == null ? null : p.$1 / p.$2),
            ],
          ],
        ),
      ),
    );
  }
}

/// What joining will do, each part on its own switch, then does it.
Future<void> showTeamSetupConfirm(BuildContext context, TeamSetup s) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ConfirmSheet(setup: s),
    );

class _ConfirmSheet extends StatefulWidget {
  final TeamSetup setup;
  const _ConfirmSheet({required this.setup});
  @override
  State<_ConfirmSheet> createState() => _ConfirmSheetState();
}

class _ConfirmSheetState extends State<_ConfirmSheet> {
  bool _team = true, _watch = true, _media = true, _busy = false;
  String? _status;

  Future<void> _join() async {
    final l10n = context.l10n;
    final connector = context.read<MeshCoreConnector>();
    final team = context.read<TeamService>();
    WatchFeedService? watch;
    try {
      watch = context.read<WatchFeedService>();
    } on ProviderNotFoundException {
      watch = null;
    }
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    setState(() => _busy = true);
    final problems = <String>[];
    try {
      if (!connector.isConnected) throw StateError(l10n.teamSetup_notConnected);
      final s = widget.setup;
      if (_team) {
        setState(() => _status = l10n.teamSetup_teamChannel(s.teamName));
        final ch = await _ensureChannel(connector, s.teamName, s.teamSecretHex);
        if (ch == null) {
          problems.add(l10n.teamSetup_noSlot(s.teamName));
        } else {
          await team.configure(enabled: true, channel: ch);
        }
      }
      if (_watch && watch != null) {
        for (final w in s.watched) {
          setState(() => _status = l10n.teamSetup_watch(w.name));
          final ch = await _ensureChannel(
            connector,
            w.name,
            w.secretHex ??
                Channel.derivePskFromHashtag(
                  w.name,
                ).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
          );
          if (ch == null) {
            problems.add(l10n.teamSetup_noSlot(w.name));
          } else {
            await watch.setWatched(ch, true);
          }
        }
      }
      final m = s.mediaMesh;
      if (_media && m != null) {
        setState(() => _status = l10n.teamSetup_mediaMesh(m.label));
        try {
          final c = MediaMeshController(connector);
          final st = await c.load();
          if (st.support == MediaMeshSupport.none) {
            problems.add(l10n.teamSetup_noMediaMesh);
          } else {
            await c.apply(
              st.settings.copyWith(
                mode: Radio2Mode.rxtx,
                media: MediaChoice.photosAndVoice,
                frequencyMHz: m.frequencyMHz,
                bandwidth: LoRaBandwidth.values.firstWhere(
                  (b) => b.hz == m.bandwidthHz,
                  orElse: () => st.settings.bandwidth,
                ),
                spreadingFactor: LoRaSpreadingFactor.values.firstWhere(
                  (x) => x.value == m.sf,
                  orElse: () => st.settings.spreadingFactor,
                ),
                codingRate: LoRaCodingRate.values.firstWhere(
                  (x) => x.value == m.cr,
                  orElse: () => st.settings.codingRate,
                ),
              ),
            );
          }
        } catch (e) {
          problems.add('MediaMesh: $e');
        }
      }
      nav.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            problems.isEmpty
                ? l10n.teamSetup_joined(s.teamName)
                : problems.join('\n'),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '$e';
        });
      }
    }
  }

  /// The channel with this secret, added in a free slot if the radio hasn't
  /// it. Null when every slot is in use.
  Future<Channel?> _ensureChannel(
    MeshCoreConnector connector,
    String name,
    String secretHex,
  ) async {
    final key = secretHex.toLowerCase();
    for (final c in connector.channels) {
      if (c.pskHex.toLowerCase() == key) return c;
    }
    final used = {
      ...connector.channels.map((c) => c.index),
      ...connector.unconfirmedChannelSlots,
    };
    int? slot;
    for (var i = 0; i < connector.maxChannels; i++) {
      if (!used.contains(i)) {
        slot = i;
        break;
      }
    }
    if (slot == null) return null;
    final psk = Uint8List.fromList([
      for (var i = 0; i < 32; i += 2)
        int.parse(key.substring(i, i + 2), radix: 16),
    ]);
    await connector.setChannel(slot, name, psk);
    for (var t = 0; t < 30; t++) {
      for (final c in connector.channels) {
        if (c.index == slot && c.pskHex.toLowerCase() == key) return c;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final s = widget.setup;
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.teamSetup_joinTitle,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _team,
              onChanged: _busy ? null : (v) => setState(() => _team = v!),
              title: Text(l10n.teamSetup_teamChannel(s.teamName)),
              subtitle: Text(l10n.teamSetup_teamChannelHelp),
            ),
            if (s.watched.isNotEmpty)
              CheckboxListTile(
                value: _watch,
                onChanged: _busy ? null : (v) => setState(() => _watch = v!),
                title: Text(
                  l10n.teamSetup_watch(s.watched.map((c) => c.name).join(', ')),
                ),
                subtitle: Text(l10n.teamSetup_watchHelp),
              ),
            if (s.mediaMesh != null)
              CheckboxListTile(
                value: _media,
                onChanged: _busy ? null : (v) => setState(() => _media = v!),
                title: Text(l10n.teamSetup_mediaMesh(s.mediaMesh!.label)),
                subtitle: Text(l10n.teamSetup_mediaMeshHelp),
              ),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  _status!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _busy || !(_team || _watch || _media) ? null : _join,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.teamSetup_join),
            ),
          ],
        ),
      ),
    );
  }
}
