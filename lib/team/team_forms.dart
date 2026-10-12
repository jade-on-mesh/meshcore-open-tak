// MeshCore Open TAK - forms: tactical pin editor and SALUTE report.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../vox/image_send_sheet.dart';
import '../vox/voice_record_sheet.dart';
import '../vox/voice_service.dart';
import '../vox/voice_wire.dart';
import 'team_map.dart';
import 'team_service.dart';
import 'team_wire.dart';

/// Photo or voice note picker for pins and reports. The clip is registered
/// with the voice service (kept ready to serve) and only its reference goes
/// on air with the pin; teammates fetch it when they open the pin.
class TeamAttachmentField extends StatelessWidget {
  final TeamAttachment? value;
  final ValueChanged<TeamAttachment?> onChanged;
  final String label;

  const TeamAttachmentField({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
  });

  TeamAttachment _fromEnvelope(VoxVoiceEnvelope env) => TeamAttachment(
    env.mode.wireId,
    env.sessionId,
    env.totalPackets,
    env.durationSeconds,
  );

  @override
  Widget build(BuildContext context) {
    final voice = context.watch<VoxVoiceService>();
    final v = value;
    if (v != null) {
      final env = teamAttachmentEnvelope(v);
      return Row(
        children: [
          Icon(env?.isImage == true ? Icons.photo : Icons.mic),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              env?.isImage == true
                  ? 'Photo attached (${v.packets} packets, sent on request)'
                  : 'Voice note attached (${v.extra}s, sent on request)',
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Remove attachment',
            onPressed: () => onChanged(null),
          ),
        ],
      );
    }
    return Wrap(
      spacing: 8,
      children: [
        if (voice.imagesAvailable)
          OutlinedButton.icon(
            icon: const Icon(Icons.add_a_photo_outlined),
            label: const Text('Photo'),
            onPressed: () => showVoxImagePicker(
              context,
              recipientLabel: label,
              sendLabel: 'Attach',
              onSend: (image) async {
                final env = voice.registerClip(voice.imageClip(image));
                onChanged(_fromEnvelope(env));
              },
            ),
          ),
        if (voice.isAvailable)
          OutlinedButton.icon(
            icon: const Icon(Icons.mic_none),
            label: const Text('Voice note'),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => VoxRecordSheet(
                recipientLabel: label,
                onSend: (clip) async {
                  final env = voice.registerClip(clip);
                  onChanged(_fromEnvelope(env));
                },
              ),
            ),
          ),
      ],
    );
  }
}

/// Title row for the team form sheets: title, optional subtitle and a close
/// button, so a sheet can always be left without sending anything.
class TeamSheetHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback onClose;
  const TeamSheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: t.titleMedium),
              if (subtitle != null) Text(subtitle!, style: t.bodySmall),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Close',
          onPressed: onClose,
        ),
      ],
    );
  }
}

/// Cancel + primary action, side by side.
class TeamSheetActions extends StatelessWidget {
  final VoidCallback onCancel;
  final VoidCallback? onSubmit;
  final String submitLabel;
  final IconData submitIcon;
  const TeamSheetActions({
    super.key,
    required this.onCancel,
    required this.onSubmit,
    required this.submitLabel,
    this.submitIcon = Icons.send,
  });

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: OutlinedButton(onPressed: onCancel, child: const Text('Cancel')),
      ),
      const SizedBox(width: 12),
      Expanded(
        flex: 2,
        child: FilledButton.icon(
          icon: Icon(submitIcon),
          label: Text(submitLabel),
          onPressed: onSubmit,
        ),
      ),
    ],
  );
}

/// Asks before throwing away a partly filled form.
Future<bool> confirmTeamDiscard(BuildContext context, String what) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('Discard $what?'),
      content: const Text('Nothing has been sent.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Keep editing'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Discard'),
        ),
      ],
    ),
  );
  return r == true;
}

// --------------------------------------------------------------- pin editor

Future<void> showTeamPinEditor(
  BuildContext context, {
  required double lat,
  required double lon,
  TeamMarker? existing,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => _PinEditor(lat: lat, lon: lon, existing: existing),
);

class _PinEditor extends StatefulWidget {
  final double lat, lon;
  final TeamMarker? existing;
  const _PinEditor({required this.lat, required this.lon, this.existing});
  @override
  State<_PinEditor> createState() => _PinEditorState();
}

class _PinEditorState extends State<_PinEditor> {
  late MarkerKind _kind = widget.existing?.kind ?? MarkerKind.point;
  late final _label = TextEditingController(text: widget.existing?.label ?? '');
  late final _note = TextEditingController(text: widget.existing?.note ?? '');
  late TeamAttachment? _attachment = widget.existing?.attachment;
  bool _sending = false;

  @override
  void dispose() {
    _label.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final team = context.read<TeamService>();
    if (!team.active) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(team.inactiveReason ?? 'Team not ready')),
      );
      return;
    }
    setState(() => _sending = true);
    await team.putMarker(
      existing: widget.existing,
      kind: _kind,
      lat: widget.lat,
      lon: widget.lon,
      label: _label.text,
      note: _note.text,
      attachment: _attachment,
      clearAttachment: _attachment == null,
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: 12 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TeamSheetHeader(
                title: widget.existing == null
                    ? 'Drop tactical pin'
                    : 'Edit pin',
                subtitle: context.read<TeamService>().formatCoord(
                  widget.lat,
                  widget.lon,
                ),
                onClose: () => Navigator.pop(context),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final k in MarkerKind.values)
                    ChoiceChip(
                      avatar: Icon(
                        markerKindIcon(k),
                        size: 18,
                        color: markerKindColor(k),
                      ),
                      label: Text(k.label),
                      selected: _kind == k,
                      onSelected: (_) => setState(() => _kind = k),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _label,
                maxLength: teamMaxLabelBytes,
                decoration: const InputDecoration(labelText: 'Label'),
              ),
              TextField(
                controller: _note,
                maxLength: teamMaxNoteBytes,
                decoration: const InputDecoration(labelText: 'Note'),
              ),
              TeamAttachmentField(
                value: _attachment,
                label: 'pin',
                onChanged: (a) => setState(() => _attachment = a),
              ),
              const SizedBox(height: 12),
              TeamSheetActions(
                onCancel: () => Navigator.pop(context),
                submitLabel: widget.existing == null
                    ? 'Share with team'
                    : 'Update',
                onSubmit: _sending ? null : _save,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------- SALUTE

Future<void> showSaluteForm(
  BuildContext context, {
  required double lat,
  required double lon,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => _SaluteForm(lat: lat, lon: lon),
);

class _SaluteForm extends StatefulWidget {
  final double lat, lon;
  const _SaluteForm({required this.lat, required this.lon});
  @override
  State<_SaluteForm> createState() => _SaluteFormState();
}

class _SaluteFormState extends State<_SaluteForm> {
  TeamUrgency _urgency = TeamUrgency.observed;
  TeamAffiliation _aff = TeamAffiliation.unknown;
  int _vehicles = 0, _people = 0;
  final _place = TextEditingController();
  final _size = TextEditingController();
  final _activity = TextEditingController();
  final _unit = TextEditingController();
  final _equipment = TextEditingController();
  DateTime _time = DateTime.now();
  TeamAttachment? _attachment;
  bool _alsoText = false;
  bool _sending = false;

  @override
  void dispose() {
    for (final c in [_place, _size, _activity, _unit, _equipment]) {
      c.dispose();
    }
    super.dispose();
  }

  TeamReport get _preview => TeamReport(
    authorKey4: '00000000',
    reportId: 0,
    lat: widget.lat,
    lon: widget.lon,
    observed: _time,
    urgency: _urgency,
    affiliation: _aff,
    vehicles: _vehicles,
    people: _people,
    place: _place.text.trim(),
    size: _size.text.trim(),
    activity: _activity.text.trim(),
    unit: _unit.text.trim(),
    equipment: _equipment.text.trim(),
  );

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_time),
    );
    if (t == null) return;
    setState(() {
      _time = DateTime(_time.year, _time.month, _time.day, t.hour, t.minute);
    });
  }

  Future<void> _send() async {
    final team = context.read<TeamService>();
    if (!team.active) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(team.inactiveReason ?? 'Team not ready')),
      );
      return;
    }
    setState(() => _sending = true);
    final p = _preview;
    await team.fileReport(
      lat: p.lat,
      lon: p.lon,
      observed: p.observed,
      urgency: p.urgency,
      affiliation: p.affiliation,
      vehicles: p.vehicles,
      people: p.people,
      place: p.place,
      size: p.size,
      activity: p.activity,
      unit: p.unit,
      equipment: p.equipment,
      attachment: _attachment,
      alsoAsText: _alsoText,
    );
    if (mounted) Navigator.pop(context);
  }

  bool get _dirty =>
      _vehicles > 0 ||
      _people > 0 ||
      _attachment != null ||
      [
        _place,
        _size,
        _activity,
        _unit,
        _equipment,
      ].any((c) => c.text.trim().isNotEmpty);

  Future<void> _close() async {
    if (_dirty && !await confirmTeamDiscard(context, 'this report')) return;
    if (mounted) Navigator.pop(context);
  }

  Widget _counter(
    String label,
    String emoji,
    int value,
    ValueChanged<int> set,
  ) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('$emoji $label'),
      IconButton(
        icon: const Icon(Icons.remove_circle_outline),
        onPressed: value > 0 ? () => set(value - 1) : null,
      ),
      Text('$value', style: Theme.of(context).textTheme.titleMedium),
      IconButton(
        icon: const Icon(Icons.add_circle_outline),
        onPressed: value < 250 ? () => set(value + 1) : null,
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return PopScope(
      canPop: !_dirty || _sending,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 12,
            bottom: 12 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TeamSheetHeader(title: 'SALUTE report', onClose: _close),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final u in TeamUrgency.values.reversed)
                      ChoiceChip(
                        label: Text('${u.dot} ${u.label}'),
                        selected: _urgency == u,
                        onSelected: (_) => setState(() => _urgency = u),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                SegmentedButton<TeamAffiliation>(
                  segments: [
                    for (final a in TeamAffiliation.values)
                      ButtonSegment(value: a, label: Text(a.label)),
                  ],
                  selected: {_aff},
                  onSelectionChanged: (s) => setState(() => _aff = s.first),
                ),
                const Divider(),
                Text('S · Size', style: t.labelLarge),
                Wrap(
                  children: [
                    _counter(
                      'Vehicles',
                      '🚗',
                      _vehicles,
                      (v) => setState(() => _vehicles = v),
                    ),
                    _counter(
                      'Personnel',
                      '🥾',
                      _people,
                      (v) => setState(() => _people = v),
                    ),
                  ],
                ),
                TextField(
                  controller: _size,
                  maxLength: teamMaxSaluteSizeBytes,
                  decoration: const InputDecoration(
                    labelText: 'Other size note (optional)',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                TextField(
                  controller: _activity,
                  maxLength: teamMaxSaluteActivityBytes,
                  decoration: const InputDecoration(labelText: 'A · Activity'),
                  onChanged: (_) => setState(() {}),
                ),
                TextField(
                  controller: _place,
                  maxLength: teamMaxSalutePlaceBytes,
                  decoration: InputDecoration(
                    labelText: 'L · Location name (e.g. Auburn E Main St)',
                    helperText:
                        'Map point ${context.read<TeamService>().formatCoord(widget.lat, widget.lon)}',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                TextField(
                  controller: _unit,
                  maxLength: teamMaxSaluteUnitBytes,
                  decoration: const InputDecoration(
                    labelText: 'U · Unit / uniform',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule),
                  title: Text('T · Time observed: ${_preview.timeLabel}'),
                  trailing: TextButton(
                    onPressed: _pickTime,
                    child: const Text('Change'),
                  ),
                ),
                TextField(
                  controller: _equipment,
                  maxLength: teamMaxSaluteEquipmentBytes,
                  decoration: const InputDecoration(labelText: 'E · Equipment'),
                  onChanged: (_) => setState(() {}),
                ),
                TeamAttachmentField(
                  value: _attachment,
                  label: 'SALUTE report',
                  onChanged: (a) => setState(() => _attachment = a),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Also post as text'),
                  subtitle: const Text(
                    'For teammates on other MeshCore apps. Costs one more '
                    'channel message.',
                  ),
                  value: _alsoText,
                  onChanged: (v) => setState(() => _alsoText = v),
                ),
                const SizedBox(height: 6),
                Text('Preview', style: t.labelLarge),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: TeamReportCard(report: _preview),
                  ),
                ),
                const SizedBox(height: 8),
                TeamSheetActions(
                  onCancel: _close,
                  submitLabel: 'Send report',
                  onSubmit: _sending ? null : _send,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
