import 'package:flutter/material.dart';

import '../connector/meshcore_connector.dart';
import '../helpers/snack_bar_builder.dart';
import '../models/radio_settings.dart';
import '../services/media_mesh.dart';

/// MediaMesh Settings: send and receive photos and voice clips on a second
/// frequency of the connected radio (its `radio2` profile), under the normal
/// Radio Settings. See documentation/media-mesh.md.
class MediaMeshSettingsDialog extends StatefulWidget {
  final MeshCoreConnector connector;

  const MediaMeshSettingsDialog({super.key, required this.connector});

  @override
  State<MediaMeshSettingsDialog> createState() =>
      _MediaMeshSettingsDialogState();
}

class _MediaMeshSettingsDialogState extends State<MediaMeshSettingsDialog> {
  late final MediaMeshController _controller = MediaMeshController(
    widget.connector,
  );
  final _frequencyController = TextEditingController();
  MediaMeshState? _state;
  MediaMeshSettings _settings = MediaMeshSettings.defaults;
  String? _frequencyError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _frequencyController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final state = await _controller.load();
    if (!mounted) return;
    setState(() {
      _state = state;
      _settings = state.settings;
      _frequencyController.text = _settings.frequencyMHz.toStringAsFixed(3);
    });
  }

  void _validateFrequency(String text) {
    final freq = double.tryParse(text.trim());
    String? error;
    if (freq == null || freq < 150 || freq > 960) {
      error = 'Enter a frequency between 150 and 960 MHz';
    } else {
      _settings = _settings.copyWith(frequencyMHz: freq);
      if (_matchesMain()) error = 'Must differ from the main radio';
    }
    setState(() => _frequencyError = error);
  }

  bool _matchesMain() => sameChannelAsMain(
    _settings,
    mainFreqHz: widget.connector.currentFreqHz,
    mainBwHz: widget.connector.currentBwHz,
    mainSf: widget.connector.currentSf,
  );

  Future<void> _save() async {
    _validateFrequency(_frequencyController.text);
    if (_frequencyError != null) return;
    setState(() => _saving = true);
    try {
      await _controller.apply(_settings);
      if (!mounted) return;
      showDismissibleSnackBar(
        context,
        content: Text(
          _settings.enabled
              ? 'Photos and voice now use MediaMesh'
              : 'MediaMesh off',
        ),
      );
      Navigator.pop(context);
    } on MediaMeshException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showDismissibleSnackBar(context, content: Text(e.message));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return AlertDialog(
      title: const Text('MediaMesh Settings'),
      content: SingleChildScrollView(
        child: state == null
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : state.support == MediaMeshSupport.none
            ? Text(
                state.detail ??
                    'This radio\'s firmware has no MediaMesh (radio2). '
                        'Use Wadamesh, or MeshCore firmware with radio2 '
                        'and media routing.',
              )
            : _buildForm(context, state),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (state != null && state.support != MediaMeshSupport.none)
          FilledButton(
            onPressed: _saving || _frequencyError != null ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
      ],
    );
  }

  Widget _buildForm(BuildContext context, MediaMeshState state) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Photos & voice on MediaMesh'),
          subtitle: const Text(
            'Send and receive photos and voice clips on a second, faster '
            'frequency. Text stays on the main mesh.',
          ),
          value: _settings.enabled,
          onChanged: (on) =>
              setState(() => _settings = _settings.copyWith(enabled: on)),
        ),
        if (state.support == MediaMeshSupport.noMediaRouting) ...[
          const SizedBox(height: 8),
          Text(
            'This firmware has radio2 but cannot route media to it yet. '
            'Saving with MediaMesh on will fail until the radio is updated.',
            style: textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 16),
        TextField(
          controller: _frequencyController,
          onChanged: _validateFrequency,
          decoration: InputDecoration(
            labelText: 'MediaMesh frequency (MHz)',
            border: const OutlineInputBorder(),
            errorText: _frequencyError,
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<LoRaBandwidth>(
          initialValue: _settings.bandwidth,
          decoration: const InputDecoration(
            labelText: 'Bandwidth',
            border: OutlineInputBorder(),
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
          decoration: const InputDecoration(
            labelText: 'Spreading factor',
            border: OutlineInputBorder(),
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
          decoration: const InputDecoration(
            labelText: 'Coding rate',
            border: OutlineInputBorder(),
          ),
          items: LoRaCodingRate.values
              .map((cr) => DropdownMenuItem(value: cr, child: Text(cr.label)))
              .toList(),
          onChanged: (value) {
            if (value == null) return;
            setState(() => _settings = _settings.copyWith(codingRate: value));
          },
        ),
        const SizedBox(height: 16),
        Text(
          'Everyone sharing photos must use the same MediaMesh settings, and '
          'their radio needs MediaMesh on too. The radio switches between both '
          'frequencies, so heavy media traffic costs some main-mesh reception.',
          style: textTheme.bodySmall,
        ),
      ],
    );
  }
}
