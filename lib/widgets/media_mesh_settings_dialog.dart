import 'dart:async';

import 'package:flutter/material.dart';

import '../connector/meshcore_connector.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../models/radio_settings.dart';
import '../screens/radio_console_screen.dart';
import '../services/media_lockdown.dart';
import '../services/media_mesh.dart';

/// MediaMesh Settings: the connected radio's second LoRa profile (`radio2`),
/// what goes on it, a temporary profile, and live figures. Under the normal
/// Radio Settings. See documentation/media-mesh.md.
class MediaMeshSettingsDialog extends StatefulWidget {
  final MeshCoreConnector connector;

  const MediaMeshSettingsDialog({super.key, required this.connector});

  @override
  State<MediaMeshSettingsDialog> createState() =>
      _MediaMeshSettingsDialogState();
}

class _MediaMeshSettingsDialogState extends State<MediaMeshSettingsDialog> {
  static const _refreshEvery = Duration(seconds: 3);

  late final MediaMeshController _controller = MediaMeshController(
    widget.connector,
  );
  final _frequencyController = TextEditingController();
  MediaMeshState? _state;
  MediaMeshSettings _settings = MediaMeshSettings.defaults;
  Radio2Status? _status;
  TempRadio2? _temp;
  bool _frequencyInvalid = false;
  bool _frequencyOnMain = false;
  String? _conflict; // a community mesh radio2 would sit on
  bool _saving = false;
  bool _busyTemp = false;
  bool _refreshing = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _frequencyController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final state = await _controller.load();
    if (!mounted) return;
    setState(() {
      _state = state;
      _settings = state.settings;
      _status = state.status;
      _temp = state.temp;
      _frequencyController.text = _settings.frequencyMHz.toStringAsFixed(3);
    });
    _validateFrequency(_frequencyController.text); // a saved one may conflict
    if (state.support != MediaMeshSupport.none) {
      _timer = Timer.periodic(_refreshEvery, (_) => _refresh());
    }
  }

  Future<void> _refresh() async {
    if (_refreshing || _saving || _busyTemp) return;
    _refreshing = true;
    try {
      final (status, temp) = await _controller.refreshStatus();
      if (!mounted) return;
      setState(() {
        _status = status ?? _status;
        _temp = temp;
      });
    } finally {
      _refreshing = false;
    }
  }

  void _validateFrequency(String text) {
    final freq = double.tryParse(text.trim());
    var invalid = false;
    var onMain = false;
    String? conflict;
    if (freq == null || freq < 150 || freq > 960) {
      invalid = true;
    } else {
      _settings = _settings.copyWith(frequencyMHz: freq);
      onMain = sameChannelAsMain(
        _settings,
        mainFreqHz: widget.connector.currentFreqHz,
        mainBwHz: widget.connector.currentBwHz,
        mainSf: widget.connector.currentSf,
      );
      conflict = conflictingCommunityMesh(_settings);
    }
    setState(() {
      _frequencyInvalid = invalid;
      _frequencyOnMain = onMain;
      _conflict = conflict;
    });
  }

  bool get _profileValid =>
      !_frequencyInvalid && !_frequencyOnMain && _conflict == null;

  bool get _devMain => MediaLockdown.devAllowMain.value;

  /// The preset these settings match (SF7, CR 4/5 at 250 or 125 kHz), if any.
  static Set<LoRaBandwidth> _presetOf(MediaMeshSettings s) {
    final standard =
        s.spreadingFactor == LoRaSpreadingFactor.sf7 &&
        s.codingRate == LoRaCodingRate.cr4_5;
    if (standard &&
        (s.bandwidth == LoRaBandwidth.bw250 ||
            s.bandwidth == LoRaBandwidth.bw125)) {
      return {s.bandwidth};
    }
    return {};
  }

  Future<void> _toggleDeveloperMain() async {
    final on = !_devMain;
    await MediaLockdown.set(on);
    if (!mounted) return;
    setState(() {});
    showDismissibleSnackBar(
      context,
      content: Text(
        on
            ? 'Developer: photos and voice may use the main mesh'
            : 'Photos and voice on MediaMesh (radio2) only',
      ),
    );
  }

  Future<void> _save() async {
    _validateFrequency(_frequencyController.text);
    if (!_profileValid) return;
    setState(() => _saving = true);
    try {
      await _controller.apply(_settings);
      if (!mounted) return;
      showDismissibleSnackBar(
        context,
        content: Text(
          _settings.enabled
              ? context.l10n.mediaMesh_saved
              : context.l10n.mediaMesh_turnedOff,
        ),
      );
      Navigator.pop(context);
    } on MediaMeshException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showDismissibleSnackBar(context, content: Text(e.message));
    }
  }

  Future<void> _temporary(int? minutes) async {
    if (minutes != null) {
      _validateFrequency(_frequencyController.text);
      if (!_profileValid) return;
    }
    setState(() => _busyTemp = true);
    try {
      if (minutes == null) {
        await _controller.stopTemporary();
      } else {
        await _controller.startTemporary(_settings, minutes);
      }
      if (!mounted) return;
      showDismissibleSnackBar(
        context,
        content: Text(
          minutes == null
              ? context.l10n.mediaMesh_tempStopped
              : context.l10n.mediaMesh_tempStarted,
        ),
      );
    } on MediaMeshException catch (e) {
      if (!mounted) return;
      showDismissibleSnackBar(context, content: Text(e.message));
    } finally {
      if (mounted) setState(() => _busyTemp = false);
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = _state;
    final usable = state != null && state.support != MediaMeshSupport.none;
    return AlertDialog(
      // Long-press: the developer switch that lets photos and voice use the
      // main mesh (MediaLockdown). Hidden until this is locked down fully.
      title: GestureDetector(
        onLongPress: _toggleDeveloperMain,
        child: Text(l10n.mediaMesh_title),
      ),
      content: SingleChildScrollView(
        child: state == null
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : !usable
            ? Text(
                state.detail != null
                    ? l10n.mediaMesh_cantRun
                    : l10n.mediaMesh_noFirmware,
              )
            : _buildForm(context, state),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(l10n.common_cancel),
        ),
        if (usable)
          FilledButton(
            onPressed: _saving || !_profileValid ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.common_save),
          ),
      ],
    );
  }

  Widget _section(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Text(title, style: Theme.of(context).textTheme.titleSmall),
  );

  Widget _buildForm(BuildContext context, MediaMeshState state) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final errorStyle = small?.copyWith(color: theme.colorScheme.error);
    final media = _settings.media;
    final mediaHelp = switch (media) {
      MediaChoice.photosAndVoice => l10n.mediaMesh_photosVoiceHelp,
      MediaChoice.everything => l10n.mediaMesh_everythingHelp,
      MediaChoice.custom => l10n.mediaMesh_customHelp,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.mediaMesh_mode, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          // Off or On (listen and send). Listen only is a console setting;
          // it selects neither, and On makes it send too.
          child: SegmentedButton<Radio2Mode>(
            showSelectedIcon: false,
            emptySelectionAllowed: true,
            segments: [
              ButtonSegment(
                value: Radio2Mode.off,
                label: Text(l10n.mediaMesh_modeOff),
              ),
              ButtonSegment(
                value: Radio2Mode.rxtx,
                label: Text(l10n.mediaMesh_modeOn),
              ),
            ],
            selected: {
              if (_settings.mode != Radio2Mode.rx) _settings.mode,
            },
            onSelectionChanged: (picked) {
              if (picked.isEmpty) return;
              setState(
                () => _settings = _settings.copyWith(mode: picked.first),
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _settings.mode == Radio2Mode.rx
              ? l10n.mediaMesh_listenOnlyNote
              : l10n.mediaMesh_modeOnHelp,
          style: small,
        ),
        if (state.support == MediaMeshSupport.noMediaRouting) ...[
          const SizedBox(height: 8),
          Text(l10n.mediaMesh_noMediaRouting, style: errorStyle),
        ],
        if (_settings.enabled) ...[
          _section(context, l10n.mediaMesh_sentOn),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<MediaChoice>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: MediaChoice.photosAndVoice,
                  label: Text(l10n.mediaMesh_photosVoice),
                ),
                // Everything (tx.media auto) sends photos and voice on the
                // main mesh too: developers only (MediaLockdown).
                if (_devMain || media == MediaChoice.everything)
                  ButtonSegment(
                    value: MediaChoice.everything,
                    label: Text(l10n.mediaMesh_everything),
                  ),
                if (state.settings.media == MediaChoice.custom)
                  ButtonSegment(
                    value: MediaChoice.custom,
                    label: Text(l10n.mediaMesh_custom),
                  ),
              ],
              selected: {media},
              onSelectionChanged: (picked) => setState(
                () => _settings = _settings.copyWith(media: picked.first),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(mediaHelp, style: small),
          if (_settings.shareWithMain != null &&
              media == MediaChoice.photosAndVoice &&
              _devMain)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.mediaMesh_shareMain),
              subtitle: Text(
                _settings.shareWithMain!
                    ? l10n.mediaMesh_shareMainOn
                    : l10n.mediaMesh_shareMainOff,
              ),
              value: _settings.shareWithMain!,
              onChanged: (v) => setState(
                () => _settings = _settings.copyWith(shareWithMain: v),
              ),
            ),
        ],
        const SizedBox(height: 20),
        TextField(
          controller: _frequencyController,
          onChanged: _validateFrequency,
          decoration: InputDecoration(
            labelText: l10n.mediaMesh_frequency,
            border: const OutlineInputBorder(),
            errorText: _frequencyInvalid
                ? l10n.mediaMesh_frequencyRange
                : _frequencyOnMain
                ? l10n.mediaMesh_frequencyMain
                : _conflict != null
                ? l10n.mediaMesh_conflictsWith(_conflict!)
                : null,
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        const SizedBox(height: 16),
        Text(l10n.mediaMesh_preset, style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<LoRaBandwidth>(
            showSelectedIcon: false,
            emptySelectionAllowed: true,
            segments: [
              ButtonSegment(
                value: LoRaBandwidth.bw250,
                label: Text(l10n.mediaMesh_presetFast),
              ),
              ButtonSegment(
                value: LoRaBandwidth.bw125,
                label: Text(l10n.mediaMesh_presetRange),
              ),
            ],
            selected: _presetOf(_settings),
            onSelectionChanged: (picked) {
              if (picked.isEmpty) return;
              setState(
                () => _settings = _settings.copyWith(
                  bandwidth: picked.first,
                  spreadingFactor: LoRaSpreadingFactor.sf7,
                  codingRate: LoRaCodingRate.cr4_5,
                ),
              );
              _validateFrequency(_frequencyController.text);
            },
          ),
        ),
        const SizedBox(height: 6),
        Text(l10n.mediaMesh_presetHelp, style: small),
        const SizedBox(height: 16),
        DropdownButtonFormField<LoRaBandwidth>(
          key: ValueKey('bw-${_settings.bandwidth.name}'),
          initialValue: _settings.bandwidth,
          decoration: InputDecoration(
            labelText: l10n.settings_bandwidth,
            border: const OutlineInputBorder(),
          ),
          items: LoRaBandwidth.values
              .map((bw) => DropdownMenuItem(value: bw, child: Text(bw.label)))
              .toList(),
          onChanged: (value) {
            if (value == null) return;
            setState(() => _settings = _settings.copyWith(bandwidth: value));
            _validateFrequency(_frequencyController.text);
          },
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<LoRaSpreadingFactor>(
          key: ValueKey('sf-${_settings.spreadingFactor.name}'),
          initialValue: _settings.spreadingFactor,
          decoration: InputDecoration(
            labelText: l10n.settings_spreadingFactor,
            border: const OutlineInputBorder(),
          ),
          items: LoRaSpreadingFactor.values
              .map((sf) => DropdownMenuItem(value: sf, child: Text(sf.label)))
              .toList(),
          onChanged: (value) {
            if (value == null) return;
            setState(
              () => _settings = _settings.copyWith(spreadingFactor: value),
            );
            _validateFrequency(_frequencyController.text);
          },
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<LoRaCodingRate>(
          key: ValueKey('cr-${_settings.codingRate.name}'),
          initialValue: _settings.codingRate,
          decoration: InputDecoration(
            labelText: l10n.settings_codingRate,
            border: const OutlineInputBorder(),
          ),
          items: LoRaCodingRate.values
              .map((cr) => DropdownMenuItem(value: cr, child: Text(cr.label)))
              .toList(),
          onChanged: (value) {
            if (value == null) return;
            setState(() => _settings = _settings.copyWith(codingRate: value));
          },
        ),
        const SizedBox(height: 12),
        Text(l10n.mediaMesh_footer, style: small),
        ..._buildStatus(context, small, errorStyle),
        _section(context, l10n.mediaMesh_temporary),
        Text(l10n.mediaMesh_temporaryHelp, style: small),
        const SizedBox(height: 8),
        if (_temp != null) ...[
          Text(
            l10n.mediaMesh_tempRunning(
              _temp!.frequencyMHz.toStringAsFixed(3),
              _temp!.minutesLeft,
            ),
          ),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (minutes, label) in [
              (15, l10n.mediaMesh_temp15),
              (60, l10n.mediaMesh_temp60),
              (120, l10n.mediaMesh_temp120),
            ])
              OutlinedButton(
                onPressed: _busyTemp || !_profileValid
                    ? null
                    : () => _temporary(minutes),
                child: Text(label),
              ),
            if (_temp != null)
              TextButton(
                onPressed: _busyTemp ? null : () => _temporary(null),
                child: Text(l10n.mediaMesh_tempStop),
              ),
          ],
        ),
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.terminal),
          title: Text(l10n.mediaMesh_openConsole),
          subtitle: Text(l10n.mediaMesh_openConsoleSubtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => RadioConsoleScreen(connector: widget.connector),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildStatus(
    BuildContext context,
    TextStyle? small,
    TextStyle? errorStyle,
  ) {
    final status = _status;
    if (status == null || status.mode == 'off') return const [];
    final l10n = context.l10n;
    return [
      _section(context, l10n.mediaMesh_status),
      Text(
        l10n.mediaMesh_packets(
          status.rx[0],
          status.rx[1],
          status.tx[0],
          status.tx[1],
        ),
        style: small,
      ),
      const SizedBox(height: 4),
      Text(
        status.switchMeasured && status.switchUs != null
            ? l10n.mediaMesh_switchTime(status.switchUs!)
            : l10n.mediaMesh_switchMeasuring,
        style: small,
      ),
      for (final warning in status.warnings) ...[
        const SizedBox(height: 4),
        Text(l10n.mediaMesh_warning(warning), style: errorStyle),
      ],
    ];
  }
}
