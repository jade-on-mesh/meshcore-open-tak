// MeshCore Open TAK - the team's roles: rename the defaults, give any role an
// icon from the library, add roles of the team's own. Shared on the team
// channel (TeamRoleDef), so every phone and T-Deck shows the same names.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'role_icon_library.dart';
import 'team_map.dart';
import 'team_service.dart';
import 'team_wire.dart';

class TeamRolesScreen extends StatelessWidget {
  const TeamRolesScreen({super.key});

  void _edit(BuildContext context, int? roleId) => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => RoleEditorScreen(roleId: roleId)),
  );

  @override
  Widget build(BuildContext context) {
    final team = context.watch<TeamService>();
    final added = [
      for (final r in team.roleIds)
        if (team.isAddedRole(r)) r,
    ];
    Widget tile(int r) {
      final edited = team.roleEdit(r) != null;
      return ListTile(
        leading: CircleAvatar(
          backgroundColor: Color(team.color.argb),
          child: Icon(teamRoleIconFor(team, r), color: Colors.black),
        ),
        title: Text(team.roleName(r)),
        subtitle: Text(
          [
            if (team.isAddedRole(r))
              'Added by the team'
            else if (edited)
              'Default: ${team.defaultRoleName(r)}'
            else
              'Default',
            if (team.roleId == r) 'your role',
          ].join(' · '),
        ),
        trailing: const Icon(Icons.edit_outlined),
        onTap: () => _edit(context, r),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Team roles'),
        actions: [
          IconButton(
            icon: const Icon(Icons.campaign_outlined),
            tooltip: 'Share roles with the team',
            onPressed: !team.active
                ? null
                : () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final n = await team.shareRoles();
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                          n == 0
                              ? 'Nothing to share: every role is the default.'
                              : 'Shared $n role ${n == 1 ? 'edit' : 'edits'}.',
                        ),
                      ),
                    );
                  },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Names and icons are shared with everyone on the team channel, '
              'and the newest edit wins. T-Deck radios show the names.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const _Header('Default roles'),
          for (var r = 0; r < teamFirstAddedRole; r++) tile(r),
          _Header(
            'Added roles (${added.length} of '
            '${teamMaxRoleId - teamFirstAddedRole + 1})',
          ),
          if (added.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text('None yet. Add a role for anything the defaults miss.'),
            ),
          for (final r in added) tile(r),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Add role'),
        onPressed: team.canAddRole ? () => _edit(context, null) : null,
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

// ------------------------------------------------------------------ editor

/// Edits role [roleId], or creates a role when it is null.
class RoleEditorScreen extends StatefulWidget {
  final int? roleId;
  const RoleEditorScreen({super.key, this.roleId});
  @override
  State<RoleEditorScreen> createState() => _RoleEditorScreenState();
}

class _RoleEditorScreenState extends State<RoleEditorScreen> {
  late final TeamService _team = context.read<TeamService>();
  late final TextEditingController _name;
  final _search = TextEditingController();
  late int _iconId;
  String? _group; // null = all
  bool _busy = false;

  int? get _id => widget.roleId;
  bool get _isNew => _id == null;
  bool get _isAdded => _isNew || _team.isAddedRole(_id!);

  @override
  void initState() {
    super.initState();
    final edit = _id == null ? null : _team.roleEdit(_id!);
    _name = TextEditingController(
      text: _id == null ? '' : _team.roleName(_id!),
    );
    // A new role starts on a generic badge so the grid shows a selection.
    _iconId = _isNew ? _badgeId : (edit?.iconId ?? 0);
  }

  static final int _badgeId = roleIconLibrary
      .firstWhere(
        (i) => i.name == 'badge',
        orElse: () => roleIconLibrary.first,
      )
      .id;

  @override
  void dispose() {
    _name.dispose();
    _search.dispose();
    super.dispose();
  }

  IconData get _previewIcon {
    final chosen = roleIconById(_iconId);
    if (chosen != null) return chosen.icon;
    if (_id != null && _id! < teamFirstAddedRole) {
      return teamRoleIcon(TeamRole.fromIndex(_id!));
    }
    return Icons.badge_outlined;
  }

  List<RoleIcon> get _shown {
    final q = _search.text.trim().toLowerCase();
    return [
      for (final i in roleIconLibrary)
        if ((_group == null || i.group == _group) &&
            (q.isEmpty ||
                i.name.contains(q) ||
                i.group.toLowerCase().contains(q)))
          i,
    ];
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    void toast(String m) =>
        messenger.showSnackBar(SnackBar(content: Text(m)));
    final name = _name.text.trim();
    if (_isAdded && name.isEmpty) {
      toast('Give the role a name.');
      return;
    }
    setState(() => _busy = true);
    final nav = Navigator.of(context);
    final offline = !_team.active;
    final defaultName = _id == null ? '' : _team.defaultRoleName(_id!);
    if (_isNew) {
      final id = await _team.addRole(name: name, iconId: _iconId);
      if (id == null) {
        if (mounted) setState(() => _busy = false);
        toast('The team already has the most roles it can.');
        return;
      }
    } else if (!_isAdded && name == defaultName && _iconId == 0) {
      await _team.resetRole(_id!);
    } else {
      await _team.editRole(
        _id!,
        // An unchanged default name is stored empty, so it stays translated.
        name: !_isAdded && name == defaultName ? '' : name,
        iconId: _iconId,
      );
    }
    if (offline) {
      toast(
        'Saved on this phone. Share roles with the team once it is connected.',
      );
    }
    nav.pop();
  }

  Future<void> _reset() async {
    final added = _isAdded;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(added ? 'Remove this role?' : 'Back to the default?'),
        content: Text(
          added
              ? 'Teammates with this role will show as "Role $_id" until '
                    'they pick another.'
              : 'It goes back to "${_team.defaultRoleName(_id!)}" and its '
                    'own icon for the whole team.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(added ? 'Remove' : 'Reset'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final nav = Navigator.of(context);
    await _team.resetRole(_id!);
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final team = context.watch<TeamService>();
    final scheme = Theme.of(context).colorScheme;
    final shown = _shown;
    final canReset = !_isNew && (_isAdded || team.roleEdit(_id!) != null);
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New role' : 'Edit role'),
        actions: [
          if (canReset)
            IconButton(
              icon: Icon(_isAdded ? Icons.delete_outline : Icons.restore),
              tooltip: _isAdded ? 'Remove role' : 'Reset to default',
              onPressed: _busy ? null : _reset,
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('Save'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: Color(team.color.argb),
                  child: Icon(_previewIcon, size: 30, color: Colors.black),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextField(
                    controller: _name,
                    maxLength: teamMaxRoleNameBytes,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(
                      labelText: 'Role name',
                      hintText: _id == null
                          ? 'e.g. Search dog'
                          : team.defaultRoleName(_id!),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search ${roleIconLibrary.length} icons',
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(_search.clear),
                      ),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final g in <String?>[null, ...roleIconGroups])
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: ChoiceChip(
                      label: Text(g ?? 'All'),
                      selected: _group == g,
                      onSelected: (_) => setState(() => _group = g),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 56,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
              ),
              // A default role can go back to its own icon (cell 0).
              itemCount: shown.length + (_isAdded ? 0 : 1),
              itemBuilder: (context, i) {
                if (!_isAdded && i == 0) {
                  return _IconCell(
                    icon: teamRoleIcon(TeamRole.fromIndex(_id!)),
                    tooltip: 'Default icon',
                    selected: _iconId == 0,
                    badge: true,
                    onTap: () => setState(() => _iconId = 0),
                  );
                }
                final ic = shown[i - (_isAdded ? 0 : 1)];
                return _IconCell(
                  icon: ic.icon,
                  tooltip: ic.name,
                  selected: _iconId == ic.id,
                  onTap: () => setState(() => _iconId = ic.id),
                );
              },
            ),
          ),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'No icon matches "${_search.text.trim()}".',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

class _IconCell extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool selected;
  final bool badge;
  final VoidCallback onTap;
  const _IconCell({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
    this.badge = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: selected
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: selected
              ? BorderSide(color: scheme.primary, width: 2)
              : BorderSide.none,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                icon,
                color: selected ? scheme.onPrimaryContainer : scheme.onSurface,
              ),
              if (badge)
                Positioned(
                  right: 4,
                  bottom: 2,
                  child: Text(
                    'default',
                    style: TextStyle(
                      fontSize: 8,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
