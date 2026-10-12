// MeshCore Open TAK - CASEVAC / MEDEVAC 9-line form, card and sheet.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'team_forms.dart';
import 'team_service.dart';
import 'team_wire.dart';

const Color casevacRed = Color(0xFFD32F2F);

Color casevacColor(TeamCasevac c) {
  if (c.urgent + c.urgentSurgical > 0) return casevacRed;
  if (c.priority > 0) return const Color(0xFFF9A825);
  return const Color(0xFF43A047);
}

// ------------------------------------------------------------------- form

Future<void> showCasevacForm(
  BuildContext context, {
  required double lat,
  required double lon,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => _CasevacForm(lat: lat, lon: lon),
);

class _CasevacForm extends StatefulWidget {
  final double lat, lon;
  const _CasevacForm({required this.lat, required this.lon});
  @override
  State<_CasevacForm> createState() => _CasevacFormState();
}

class _CasevacFormState extends State<_CasevacForm> {
  final _place = TextEditingController();
  final _freq = TextEditingController();
  final _callsign = TextEditingController();
  final _markDetail = TextEditingController();
  final _remarks = TextEditingController();

  // Line 3.
  int _urgent = 0, _urgentSurgical = 0, _priority = 0, _routine = 0;
  int _convenience = 0;
  // Line 4.
  final Set<CasevacEquipment> _equipment = {};
  // Line 5.
  int _litter = 0, _ambulatory = 0;
  // Line 6.
  CasevacSecurity _security = CasevacSecurity.noEnemy;
  // Line 7.
  CasevacMarking _marking = CasevacMarking.none;
  // Line 8.
  int _usMil = 0, _usCiv = 0, _nonUsMil = 0, _nonUsCiv = 0, _epw = 0;
  int _child = 0;
  // Line 9.
  final Set<CasevacTerrain> _terrain = {};
  CasevacNbc _nbc = CasevacNbc.none;

  bool _alsoText = false;
  bool _sending = false;

  @override
  void dispose() {
    for (final c in [_place, _freq, _callsign, _markDetail, _remarks]) {
      c.dispose();
    }
    super.dispose();
  }

  TeamCasevac get _draft => TeamCasevac(
    authorKey4: '00000000',
    requestId: 0,
    lat: widget.lat,
    lon: widget.lon,
    time: DateTime.now(),
    frequency: _freq.text.trim(),
    callsign: _callsign.text.trim(),
    urgent: _urgent,
    urgentSurgical: _urgentSurgical,
    priority: _priority,
    routine: _routine,
    convenience: _convenience,
    equipment: _equipment,
    litter: _litter,
    ambulatory: _ambulatory,
    security: _security,
    marking: _marking,
    markingDetail: _markDetail.text.trim(),
    usMilitary: _usMil,
    usCivilian: _usCiv,
    nonUsMilitary: _nonUsMil,
    nonUsCivilian: _nonUsCiv,
    epw: _epw,
    child: _child,
    terrain: _terrain,
    nbc: _nbc,
    place: _place.text.trim(),
    remarks: _remarks.text.trim(),
  );

  bool get _dirty =>
      _draft.totalPatients > 0 ||
      _litter + _ambulatory > 0 ||
      [
        _place,
        _freq,
        _callsign,
        _markDetail,
        _remarks,
      ].any((c) => c.text.trim().isNotEmpty);

  Future<void> _close() async {
    if (_dirty && !await confirmTeamDiscard(context, 'this request')) return;
    if (mounted) Navigator.pop(context);
  }

  Future<void> _send() async {
    final team = context.read<TeamService>();
    if (!team.active) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(team.inactiveReason ?? 'Team not ready')),
      );
      return;
    }
    if (_draft.totalPatients == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Line 3: how many patients, and how urgent?'),
        ),
      );
      return;
    }
    setState(() => _sending = true);
    await team.requestCasevac(_draft, alsoAsText: _alsoText);
    if (mounted) Navigator.pop(context);
  }

  Widget _line(String n, String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 11,
              backgroundColor: casevacRed,
              child: Text(
                n,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
            Text(title, style: Theme.of(context).textTheme.labelLarge),
          ],
        ),
        const SizedBox(height: 6),
        ...children,
      ],
    ),
  );

  Widget _counter(String label, int value, ValueChanged<int> set) => SizedBox(
    width: 168,
    child: Row(
      children: [
        Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: value > 0 ? () => setState(() => set(value - 1)) : null,
        ),
        SizedBox(
          width: 22,
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add_circle_outline),
          onPressed: value < 99 ? () => setState(() => set(value + 1)) : null,
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final d = _draft;
    return PopScope(
      canPop: !_dirty || _sending,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: 12 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TeamSheetHeader(
                title: '🚑 CASEVAC 9-line',
                subtitle: 'Sent to your team and TAK as a MEDEVAC request',
                onClose: _close,
              ),
              _line('1', 'Pickup location', [
                Text(
                  '${widget.lat.toStringAsFixed(5)}, '
                  '${widget.lon.toStringAsFixed(5)}',
                ),
                TextField(
                  controller: _place,
                  maxLength: teamMaxCasevacPlaceBytes,
                  decoration: const InputDecoration(
                    labelText: 'Place name (optional)',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ]),
              _line('2', 'Frequency and callsign', [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _freq,
                        maxLength: teamMaxCasevacFreqBytes,
                        decoration: const InputDecoration(
                          labelText: 'Frequency',
                          hintText: 'e.g. 146.520',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _callsign,
                        maxLength: teamMaxCasevacCallsignBytes,
                        decoration: InputDecoration(
                          labelText: 'Callsign',
                          hintText: context.read<TeamService>().callsign,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
              ]),
              _line('3', 'Patients by precedence', [
                Wrap(
                  children: [
                    _counter('A Urgent', _urgent, (v) => _urgent = v),
                    _counter(
                      'B Urgent surg.',
                      _urgentSurgical,
                      (v) => _urgentSurgical = v,
                    ),
                    _counter('C Priority', _priority, (v) => _priority = v),
                    _counter('D Routine', _routine, (v) => _routine = v),
                    _counter(
                      'E Convenience',
                      _convenience,
                      (v) => _convenience = v,
                    ),
                  ],
                ),
              ]),
              _line('4', 'Special equipment', [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final e in CasevacEquipment.values)
                      FilterChip(
                        label: Text(e.label),
                        selected: e == CasevacEquipment.none
                            ? _equipment.isEmpty
                            : _equipment.contains(e),
                        onSelected: (on) => setState(() {
                          if (e == CasevacEquipment.none) {
                            _equipment.clear();
                          } else if (on) {
                            _equipment.add(e);
                          } else {
                            _equipment.remove(e);
                          }
                        }),
                      ),
                  ],
                ),
              ]),
              _line('5', 'Patients by type', [
                Wrap(
                  children: [
                    _counter('Litter', _litter, (v) => _litter = v),
                    _counter('Ambulatory', _ambulatory, (v) => _ambulatory = v),
                  ],
                ),
              ]),
              _line('6', 'Security at pickup site', [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final s in CasevacSecurity.values)
                      ChoiceChip(
                        label: Text('${s.letter} · ${s.label}'),
                        selected: _security == s,
                        onSelected: (_) => setState(() => _security = s),
                      ),
                  ],
                ),
              ]),
              _line('7', 'Pickup zone marking', [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final m in CasevacMarking.values)
                      ChoiceChip(
                        label: Text(m.label),
                        selected: _marking == m,
                        onSelected: (_) => setState(() => _marking = m),
                      ),
                  ],
                ),
                if (_marking != CasevacMarking.none)
                  TextField(
                    controller: _markDetail,
                    maxLength: teamMaxCasevacMarkingBytes,
                    decoration: const InputDecoration(
                      labelText: 'Colour / detail',
                      hintText: 'e.g. red smoke',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
              ]),
              _line('8', 'Patient nationality / status', [
                Wrap(
                  children: [
                    _counter('A US military', _usMil, (v) => _usMil = v),
                    _counter('B US civilian', _usCiv, (v) => _usCiv = v),
                    _counter('C Non-US mil.', _nonUsMil, (v) => _nonUsMil = v),
                    _counter('D Non-US civ.', _nonUsCiv, (v) => _nonUsCiv = v),
                    _counter('E EPW', _epw, (v) => _epw = v),
                    _counter('F Child', _child, (v) => _child = v),
                  ],
                ),
              ]),
              _line('9', 'Terrain / obstacles', [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tr in CasevacTerrain.values)
                      FilterChip(
                        label: Text(tr.label),
                        selected: tr == CasevacTerrain.none
                            ? _terrain.isEmpty
                            : _terrain.contains(tr),
                        onSelected: (on) => setState(() {
                          if (tr == CasevacTerrain.none) {
                            _terrain.clear();
                          } else if (on) {
                            _terrain.add(tr);
                          } else {
                            _terrain.remove(tr);
                          }
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Text('NBC contamination'),
                    const SizedBox(width: 12),
                    DropdownButton<CasevacNbc>(
                      value: _nbc,
                      items: [
                        for (final n in CasevacNbc.values)
                          DropdownMenuItem(value: n, child: Text(n.label)),
                      ],
                      onChanged: (n) =>
                          setState(() => _nbc = n ?? CasevacNbc.none),
                    ),
                  ],
                ),
              ]),
              const SizedBox(height: 10),
              TextField(
                controller: _remarks,
                maxLength: teamMaxCasevacRemarksBytes,
                decoration: const InputDecoration(
                  labelText: 'Remarks (injuries, hazards)',
                ),
                onChanged: (_) => setState(() {}),
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
              Text('Preview', style: t.labelLarge),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: CasevacCard(request: d),
                ),
              ),
              const SizedBox(height: 8),
              TeamSheetActions(
                onCancel: _close,
                submitLabel: 'Request CASEVAC',
                submitIcon: Icons.local_hospital,
                onSubmit: _sending ? null : _send,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------- card

class CasevacCard extends StatelessWidget {
  final TeamCasevac request;
  const CasevacCard({super.key, required this.request});

  @override
  Widget build(BuildContext context) {
    final c = request;
    final mono = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: casevacColor(c),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                c.precedenceLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '🚑 CASEVAC · ${c.totalPatients} patient'
                '${c.totalPatients == 1 ? '' : 's'}'
                '${c.place.isNotEmpty ? ' · ${c.place}' : ''}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (final l in c.nineLines()) Text(l, style: mono),
        if (c.remarks.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(c.remarks),
          ),
      ],
    );
  }
}

// ------------------------------------------------------------------ sheet

Future<void> showCasevacSheet(BuildContext context, TeamCasevac c) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (s) {
        final team = s.watch<TeamService>();
        final mine = team.isMyCasevac(c);
        final fix = team.fix;
        final who = mine
            ? 'You'
            : team.memberByKey(c.authorKey4)?.callsign ??
                  c.authorKey4.toUpperCase();
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CasevacCard(request: c),
                const SizedBox(height: 8),
                Text(
                  [
                    'Requested by $who at ${c.timeLabel}',
                    if (fix != null)
                      teamRangeBearing(
                        teamDistanceMeters(fix.lat, fix.lon, c.lat, c.lon),
                        teamBearingDeg(fix.lat, fix.lon, c.lat, c.lon),
                      ),
                  ].join(' · '),
                  style: Theme.of(s).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      icon: const Icon(Icons.track_changes),
                      label: const Text('Bloodhound to pickup'),
                      onPressed: () {
                        team.houndPoint(c.lat, c.lon, 'CASEVAC pickup');
                        Navigator.pop(s);
                      },
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.check_circle_outline),
                      label: Text(mine ? 'Close request' : 'Hide here'),
                      onPressed: () {
                        unawaited(team.closeCasevac(c));
                        Navigator.pop(s);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
