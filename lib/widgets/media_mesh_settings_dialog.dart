import 'dart:async';

import 'package:flutter/material.dart';

import '../connector/meshcore_connector.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../models/radio_settings.dart';
import '../screens/radio_console_screen.dart';
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
    }
    setState(() {
      _frequencyInvalid = invalid;
      _frequencyOnMain = onMain;
    });
  }

  bool get _profileValid => !_frequencyInvalid && !_frequencyOnMain;

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
      title: Text(l10n.mediaMesh_title),
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
          child: SegmentedButton<Radio2Mode>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: Radio2Mode.off,
                label: Text(l10n.mediaMesh_modeOff),
              ),
              ButtonSegment(
                value: Radio2Mode.rx,
                label: Text(l10n.mediaMesh_modeListen),
              ),
              ButtonSegment(
                value: Radio2Mode.rxtx,
                label: Text(l10n.mediaMesh_modeListenSend),
              ),
            ],
            selected: {_settings.mode},
            onSelectionChanged: (picked) => setState(
              () => _settings = _settings.copyWith(mode: picked.first),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(l10n.mediaMesh_modeHelp, style: small),
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
                : null,
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<LoRaBandwidth>(
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
