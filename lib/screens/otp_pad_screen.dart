import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../build_info.dart';
import '../connector/meshcore_connector.dart';
import '../models/channel.dart';
import '../models/contact.dart';
import '../models/otp_pad.dart';
import '../models/otp_sync_status.dart';
import '../models/otp_theme.dart';
import '../services/app_settings_service.dart';
import '../services/otp_service.dart';
import '../theme/mesh_theme.dart';
import '../theme/otp_bubble_colors.dart';
import '../widgets/adaptive_app_bar_title.dart';
import '../widgets/mesh_ui.dart';
import '../widgets/qr_code_display.dart';
import '../widgets/qr_scanner_widget.dart';
import 'otp_lock_screen.dart';

/// Pad management screen for a contact or a channel — import via paste or
/// QR scan, pick A/B role, see live consumption, replace or clear.
///
/// Use [OtpPadScreen.forContact] or [OtpPadScreen.forChannel]; exactly one
/// of the two is ever set.
class OtpPadScreen extends StatefulWidget {
  final Contact? contact;
  final Channel? channel;

  const OtpPadScreen.forContact(Contact contact, {super.key})
    : contact = contact,
      channel = null;

  const OtpPadScreen.forChannel(Channel channel, {super.key})
    : contact = null,
      channel = channel;

  @override
  State<OtpPadScreen> createState() => _OtpPadScreenState();
}

class _OtpPadScreenState extends State<OtpPadScreen> {
  final _pasteController = TextEditingController();
  final _labelController = TextEditingController();
  OtpPadRole _selectedRole = OtpPadRole.a;
  int _generateBytes = 2048;
  bool _busy = false;
  String? _formError;

  bool get _isChannel => widget.channel != null;

  String get _targetName {
    if (widget.contact != null) return widget.contact!.name;
    final channel = widget.channel!;
    return channel.name.isEmpty ? 'Channel ${channel.index}' : channel.name;
  }

  @override
  void dispose() {
    _pasteController.dispose();
    _labelController.dispose();
    super.dispose();
  }

  OtpPad? _currentPad(MeshCoreConnector connector) => _isChannel
      ? connector.getChannelOtpPad(widget.channel!.index)
      : connector.getContactOtpPad(widget.contact!.publicKeyHex);

  int _maxPlaintextPerMessage(MeshCoreConnector connector) => _isChannel
      ? OtpService.maxPlaintextBytesForChannel(connector.selfName)
      : OtpService.maxPlaintextBytesForContact();

  /// The Party A/B role this DM would get automatically, or `null` when it
  /// can't be resolved yet (e.g. this device's own public key isn't known
  /// yet) or this is a channel (channels have no A/B role at all). Uses the
  /// same deterministic tie-break as the Lua app's `resolve_dm_role`, so
  /// both sides land on complementary roles without coordinating by hand.
  OtpPadRole? _autoResolvedRole(MeshCoreConnector connector) {
    if (_isChannel) return null;
    return resolveDmRole(
      selfPublicKeyHex: connector.selfPublicKeyHex,
      contactPublicKeyHex: widget.contact!.publicKeyHex,
    );
  }

  // The 4 sizes always offered, regardless of what's currently imported.
  static const List<int> _fixedGenerateSizes = [
    512,
    OtpService.maxQrShareablePadBytes,
    4096,
    OtpService.maxTotalPadBytes,
  ];

  /// Dropdown items for the "Pad size" selector. Always includes the 4
  /// fixed sizes; if `_generateBytes` was just set to match a pad someone
  /// pasted or scanned in (see _importPad) and that size isn't one of the
  /// 4 fixed ones, an extra item for it is appended so the dropdown can
  /// actually display it — DropdownButtonFormField throws if its `value`
  /// doesn't match exactly one item.
  List<DropdownMenuItem<int>> _generateSizeItems() {
    final items = [
      const DropdownMenuItem(value: 512, child: Text('512 B')),
      DropdownMenuItem(
        value: OtpService.maxQrShareablePadBytes,
        child: Text('${OtpService.maxQrShareablePadBytes} B (QR-safe)'),
      ),
      const DropdownMenuItem(value: 4096, child: Text('4 KB')),
      DropdownMenuItem(
        value: OtpService.maxTotalPadBytes,
        child: Text('${OtpService.maxTotalPadBytes} B (max)'),
      ),
    ];
    if (!_fixedGenerateSizes.contains(_generateBytes)) {
      items.add(
        DropdownMenuItem(
          value: _generateBytes,
          child: Text('$_generateBytes B (imported)'),
        ),
      );
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: AdaptiveAppBarTitle('OTP Pad — $_targetName'),
        centerTitle: true,
        actions: [
          Consumer<MeshCoreConnector>(
            builder: (context, connector, _) => IconButton(
              tooltip: connector.otpProtectionEnabled
                  ? (connector.otpLocked ? 'Unlock OTP pads' : 'OTP protection')
                  : 'Set up passphrase protection',
              icon: Icon(
                !connector.otpProtectionEnabled
                    ? Icons.shield_outlined
                    : (connector.otpLocked
                          ? Icons.lock
                          : Icons.lock_open),
              ),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const OtpLockScreen()),
              ),
            ),
          ),
        ],
      ),
      body: Consumer<MeshCoreConnector>(
        builder: (context, connector, _) {
          if (connector.otpLocked) {
            return _buildLockedBody(context);
          }
          if (_isChannel && widget.channel!.isPublicChannel) {
            return _buildPublicChannelBlockedBody(context);
          }
          final pad = _currentPad(connector);
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              _buildHeroCard(context, connector, pad),
              const SectionHeader('Chat theme'),
              _buildThemeCard(context),
              _buildTextColorCard(context),
              if (pad != null) ...[
                const SectionHeader('Pad usage'),
                _buildUsageCard(context, connector, pad),
                const SectionHeader('Sync check'),
                _buildSyncCard(context, connector, pad),
                const SectionHeader('Manage'),
                _buildManageCard(context, connector, pad),
              ] else ...[
                const SectionHeader('Set up encryption'),
                _buildSetupCard(context, connector, _autoResolvedRole(connector)),
              ],
            ],
          );
        },
      ),
    );
  }

  // ── Public channel placeholder ───────────────────────────────────────

  /// The Public channel is the one channel every device on the mesh
  /// shares by construction (a fixed, well-known PSK), so it's meant to
  /// stay in the clear for anyone listening. There's nothing to set up
  /// here - no pad form, no role picker - since [setChannelOtpPad] would
  /// just refuse it anyway (see [OtpPublicChannelBlockedException]); this
  /// screen says so instead of showing controls that can't actually do
  /// anything.
  Widget _buildPublicChannelBlockedBody(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        MeshCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.public_off, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'OTP isn\'t available on the Public channel',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'The Public channel is shared by everyone on the mesh using '
                "the same well-known key. A pad only you and the group's "
                "members hold can't actually keep it private - anyone else "
                'would just see the ciphertext, or nothing, while you got '
                'a false sense of privacy. Use a private channel or a DM '
                'if you want OTP encryption.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Locked placeholder ──────────────────────────────────────────────

  Widget _buildLockedBody(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        MeshCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.lock, color: MeshPalette.warn),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'OTP pads are locked',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Enter your passphrase to manage this pad. Nothing else in '
                'the app is affected by this lock.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const OtpLockScreen()),
                  ),
                  icon: const Icon(Icons.lock_open),
                  label: const Text('Unlock'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Hero status card ────────────────────────────────────────────────

  Widget _buildHeroCard(
    BuildContext context,
    MeshCoreConnector connector,
    OtpPad? pad,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = pad?.enabled ?? false;
    final exhausted = pad?.isExhausted ?? false;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(MeshRadii.lg),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: enabled && !exhausted
                ? [MeshPalette.blueDim, MeshPalette.blue]
                : [scheme.surfaceContainerHigh, scheme.surfaceContainerHigh],
          ),
          border: Border.all(color: scheme.outlineVariant),
        ),
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: enabled ? 0.18 : 0.06),
                shape: BoxShape.circle,
              ),
              child: Icon(
                enabled
                    ? (exhausted ? Icons.lock_clock : Icons.lock)
                    : Icons.lock_open,
                color: enabled ? Colors.white : scheme.onSurfaceVariant,
                size: 26,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'One-Time-Pad Encryption',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: enabled ? Colors.white : scheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    pad == null
                        ? 'No pad set up for this ${_isChannel ? 'channel' : 'contact'} yet'
                        : exhausted
                        ? 'Pad exhausted — replace it to keep messaging'
                        : enabled
                        ? 'Messages are being encrypted with this pad'
                        : 'Pad is loaded but encryption is turned off',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: enabled
                          ? Colors.white.withValues(alpha: 0.85)
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (pad != null)
              Switch(
                value: enabled,
                onChanged: exhausted
                    ? null
                    : (value) => _setEnabled(connector, value),
                activeThumbColor: Colors.white,
                activeTrackColor: Colors.white.withValues(alpha: 0.4),
              ),
          ],
        ),
      ),
    );
  }

  // ── Usage card ───────────────────────────────────────────────────────

  Widget _buildUsageCard(
    BuildContext context,
    MeshCoreConnector connector,
    OtpPad pad,
  ) {
    final maxPerMsg = _maxPlaintextPerMessage(connector).clamp(1, 1 << 30);
    return MeshCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusChip(
                label: pad.isSharedSequential
                    ? 'Shared (group)'
                    : 'Role ${pad.role.label}',
                icon: pad.isSharedSequential
                    ? Icons.groups_outlined
                    : Icons.badge_outlined,
                color: MeshPalette.blue,
              ),
              const Spacer(),
              Text(
                '${pad.totalBytes} bytes total',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          if (pad.label != null && pad.label!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              pad.label!,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic),
            ),
          ],
          const SizedBox(height: 18),
          if (pad.isSharedSequential)
            // One shared front-of-pad counter for everyone in the group —
            // sending and receiving consume it identically, so there's
            // only one meter to show (see OtpPad.offset).
            _usageRow(
              context,
              label: 'Group usage',
              usedFraction: pad.myUsageFraction,
              remainingBytes: pad.myBytesRemaining,
              color: MeshPalette.blue,
              approxMessages: (pad.myBytesRemaining / maxPerMsg).floor(),
            )
          else ...[
            // Both rows below share ONE combined budget (mirrors Lua's
            // pks()/pdib() — Party A grows forward from byte 0, Party B
            // grows backward from the end of the same buffer, see
            // OtpPad.takeMyKeyBytes) — there's no independently-sized "my
            // half" vs "their half", so the "B left" figure is
            // deliberately identical on both rows; only the fill fraction
            // (how much of the shared pad each side has personally used)
            // differs between them.
            Text(
              'Shared budget — sending and receiving draw from the same pool',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            _usageRow(
              context,
              label: 'Your messages',
              usedFraction: pad.myUsageFraction,
              remainingBytes: pad.myBytesRemaining,
              color: MeshPalette.blue,
              approxMessages: (pad.myBytesRemaining / maxPerMsg).floor(),
            ),
            const SizedBox(height: 14),
            _usageRow(
              context,
              label: 'Their messages',
              usedFraction: pad.theirUsageFraction,
              remainingBytes: pad.theirBytesRemaining,
              color: MeshPalette.magenta,
              approxMessages: (pad.theirBytesRemaining / maxPerMsg).floor(),
            ),
          ],
          if (pad.myUsageFraction > 0.85 || pad.theirUsageFraction > 0.85) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: MeshPalette.warnBg,
                borderRadius: BorderRadius.circular(MeshRadii.sm),
                border: Border.all(color: MeshPalette.warnLine),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    color: MeshPalette.warn,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      pad.isExhausted
                          ? 'This pad is used up. Import a new one to keep sending encrypted messages.'
                          : 'Running low on pad — plan to exchange a fresh one soon.',
                      style: const TextStyle(
                        color: MeshPalette.warn,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          // Mirrors Lua's "Build: <BUILD_ID>" line on its own pad/settings
          // screens (see build_info.dart) — lets you confirm, at a glance,
          // which numbered OTP patch this install is actually running when
          // comparing behavior against the T-Deck/ThinkNode side.
          Text(
            'OTP build: $otpBuildId',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 10.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _usageRow(
    BuildContext context, {
    required String label,
    required double usedFraction,
    required int remainingBytes,
    required Color color,
    required int approxMessages,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              '$remainingBytes B left · ~$approxMessages msgs',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(MeshRadii.pill),
          child: LinearProgressIndicator(
            value: usedFraction.clamp(0.0, 1.0),
            minHeight: 8,
            backgroundColor: scheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation<Color>(
              usedFraction > 0.85 ? MeshPalette.warn : color,
            ),
          ),
        ),
      ],
    );
  }

  // ── Sync-check card ──────────────────────────────────────────────────
  // New feature (no Lua equivalent): confirms both sides' pad offsets
  // haven't drifted apart, without spending any pad bytes — see
  // otp_sync_service.dart / MeshCoreConnector.checkContactPadSync. This
  // button is a manual trigger on top of checks the connector already
  // runs on its own: every ~30s while connected, and right after any
  // send/receive/decrypt-failure. If a drift persists for more than a
  // few seconds (not just a message still in flight), the app corrects
  // its own receive-side counter automatically — see the "Auto-resynced"
  // status in _syncStatusRow and MeshCoreConnector's OTP pad auto-resync
  // section for the full safety reasoning.

  Widget _buildSyncCard(
    BuildContext context,
    MeshCoreConnector connector,
    OtpPad pad,
  ) {
    if (_isChannel) {
      final statuses = connector.getChannelOtpSyncStatuses(
        widget.channel!.index,
      );
      return MeshCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Check every participant is at the same offset',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () =>
                      connector.checkChannelPadSync(widget.channel!.index),
                  icon: const Icon(Icons.sync, size: 18),
                  label: const Text('Check sync'),
                ),
              ],
            ),
            if (statuses.isNotEmpty) ...[
              const Divider(height: 20),
              ...statuses.entries.map(
                (e) => _syncStatusRow(context, e.key, e.value),
              ),
            ],
          ],
        ),
      );
    }
    final status = connector.getContactOtpSyncStatus(
      widget.contact!.publicKeyHex,
    );
    return MeshCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Confirm your offsets haven\'t drifted apart',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              OutlinedButton.icon(
                onPressed: () =>
                    connector.checkContactPadSync(widget.contact!.publicKeyHex),
                icon: const Icon(Icons.sync, size: 18),
                label: const Text('Check sync'),
              ),
            ],
          ),
          if (status != null) ...[
            const Divider(height: 20),
            _syncStatusRow(context, _targetName, status),
          ],
        ],
      ),
    );
  }

  Widget _syncStatusRow(
    BuildContext context,
    String label,
    OtpSyncStatus status,
  ) {
    final Color color;
    final IconData icon;
    final String text;
    if (status.autoResyncedBytes != null) {
      color = MeshPalette.warn;
      icon = Icons.sync_problem;
      text =
          'Auto-resynced — skipped ${status.autoResyncedBytes} bytes to '
          'catch up (a message may have been lost)';
    } else if (status.inSync == true) {
      color = MeshPalette.blue;
      icon = Icons.check_circle_outline;
      text = 'In sync';
    } else if (status.roleCollision) {
      color = MeshPalette.alert;
      icon = Icons.error_outline;
      text =
          'Role collision — both devices resolved the same A/B role for '
          'this pad. Wipe and re-import on one device to fix.';
    } else if (status.inSync == false) {
      color = MeshPalette.alert;
      icon = Icons.warning_amber_rounded;
      final drift = status.driftBytes?.abs() ?? 0;
      final direction = status.driftDirection == 'mine-ahead'
          ? 'you are ahead'
          : 'they are ahead';
      text = 'Out of sync — drifted by $drift bytes ($direction)';
    } else if (status.timedOut) {
      color = MeshPalette.warn;
      icon = Icons.help_outline;
      text = 'No reply — unknown (they may not support sync-check, or are offline)';
    } else {
      color = MeshPalette.warn;
      icon = Icons.hourglass_top;
      text = 'Checking…';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_isChannel)
                  Text(
                    label,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                Text(
                  text,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: color),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Manage card (pad exists) ────────────────────────────────────────

  Widget _buildManageCard(
    BuildContext context,
    MeshCoreConnector connector,
    OtpPad pad,
  ) {
    return MeshCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.qr_code_2),
            title: const Text('Show pad as QR'),
            subtitle: const Text(
              'Let the other device scan this exact pad — only do this once, privately',
            ),
            onTap: () => _showPadQr(pad),
          ),
          const Divider(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.refresh, color: MeshPalette.warn),
            title: const Text('Replace pad'),
            subtitle: const Text('Import fresh pad material for this target'),
            onTap: () => setState(() {
              _pasteController.clear();
              _labelController.clear();
              _formError = null;
              // Re-render into setup mode by clearing the pad first is
              // destructive, so route through the same confirm+clear flow,
              // then the screen naturally falls into the setup card.
              _confirmAndClear(connector, andThenSetup: true);
            }),
          ),
          const Divider(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline, color: MeshPalette.alert),
            title: const Text('Clear pad'),
            subtitle: const Text('Turns off OTP and forgets this pad'),
            onTap: () => _confirmAndClear(connector),
          ),
        ],
      ),
    );
  }

  // ── Chat theme (one global choice, same set as OTP_3_RC1.lua's Themes
  // screen - every OTP-active chat uses it, not just this contact/channel) ──

  Widget _buildThemeCard(BuildContext context) {
    final settingsService = context.watch<AppSettingsService>();
    final theme = OtpTheme.all[settingsService.settings.otpThemeIndex];
    return MeshCard(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: _buildThemeSwatch(theme),
        title: Text(theme.name),
        subtitle: const Text(
          'Bubble colors for every OTP-active chat — not just this one',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _showThemePicker(context, settingsService),
      ),
    );
  }

  Widget _buildTextColorCard(BuildContext context) {
    final settingsService = context.watch<AppSettingsService>();
    return MeshCard(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Bubble text color'),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('Auto')),
              ButtonSegment(value: 1, label: Text('White')),
              ButtonSegment(value: 2, label: Text('Black')),
            ],
            selected: {settingsService.settings.otpTextMode},
            onSelectionChanged: (s) => settingsService.setOtpTextMode(s.first),
          ),
        ),
      ),
    );
  }

  /// A handful of dots from the palette's most visible roles — sent
  /// (outgoing), delivered, failed, retrying — enough to tell themes apart
  /// at a glance without redrawing a whole mock chat.
  Widget _buildThemeSwatch(OtpTheme theme) {
    final dots = [
      theme.channel,
      theme.resultOk,
      theme.encrypt,
      theme.keyphrase,
    ];
    return SizedBox(
      width: 40,
      height: 40,
      child: Wrap(
        spacing: 2,
        runSpacing: 2,
        children: [
          for (final c in dots)
            Container(
              width: 17,
              height: 17,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle),
            ),
        ],
      ),
    );
  }

  Future<void> _showThemePicker(
    BuildContext context,
    AppSettingsService settingsService,
  ) async {
    final currentIndex = settingsService.settings.otpThemeIndex;
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                'OTP bubble theme',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
            ),
            for (var i = 0; i < OtpTheme.all.length; i++)
              ListTile(
                leading: _buildThemeSwatch(OtpTheme.all[i]),
                title: Text(OtpTheme.all[i].name),
                trailing: i == currentIndex
                    ? const Icon(Icons.check, color: MeshPalette.me)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(i),
              ),
          ],
        ),
      ),
    );
    if (selected != null) {
      await settingsService.setOtpThemeIndex(selected);
    }
  }

  // ── Setup card (no pad yet) ─────────────────────────────────────────

  Widget _buildSetupCard(
    BuildContext context,
    MeshCoreConnector connector,
    OtpPadRole? autoRole,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        if (_isChannel)
          MeshCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Shared group pad',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Channels use one shared pad for everyone — there is no '
                  'A/B role to pick. Every member must import the exact '
                  'same pad bytes and process messages in the same order, '
                  'or the group will drift out of sync.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          )
        else if (autoRole != null)
          // Both sides can derive the same role from their own and the
          // contact's public key, so there's nothing to coordinate by
          // hand anymore. No picker: showing one would invite someone to
          // "fix" a role that was never wrong.
          MeshCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.auto_awesome, size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      'Party ${autoRole.label} — resolved automatically',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Worked out from this device\'s and this contact\'s keys, '
                  'so the other side automatically lands on the opposite '
                  'role — nothing to agree on beforehand.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          )
        else
          MeshCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Who are you in this pad?',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  "This device's own key isn't known yet, so the role can't "
                  'be worked out automatically this time — agree with the '
                  'other person beforehand instead: one of you is A, the '
                  "other is B. Getting it backwards just means messages "
                  "won't decrypt; nothing is silently reused.",
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 14),
                SegmentedButton<OtpPadRole>(
                  segments: const [
                    ButtonSegment(
                      value: OtpPadRole.a,
                      label: Text('I am Party A'),
                      icon: Icon(Icons.looks_one_outlined),
                    ),
                    ButtonSegment(
                      value: OtpPadRole.b,
                      label: Text('I am Party B'),
                      icon: Icon(Icons.looks_two_outlined),
                    ),
                  ],
                  selected: {_selectedRole},
                  onSelectionChanged: (selection) =>
                      setState(() => _selectedRole = selection.first),
                ),
              ],
            ),
          ),
        MeshCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Pad material',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _pasteController,
                maxLines: 4,
                minLines: 2,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  letterSpacing: 0.5,
                ),
                decoration: InputDecoration(
                  hintText: 'Hex pad data (paste, scan, or generate below)',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(MeshRadii.sm),
                  ),
                  errorText: _formError,
                ),
                onChanged: (_) {
                  if (_formError != null) setState(() => _formError = null);
                },
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _pasteFromClipboard,
                    icon: const Icon(Icons.paste, size: 18),
                    label: const Text('Paste'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _scanQr,
                    icon: const Icon(Icons.qr_code_scanner, size: 18),
                    label: const Text('Scan QR'),
                  ),
                ],
              ),
              const Divider(height: 28),
              Text(
                "Don't have a pad yet? Generate one here",
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'Uses this device\'s secure random generator. Generate on '
                'one device, then have the other person scan or paste the '
                'exact same pad from here — never generate it twice.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      // Keyed on the value itself: DropdownButtonFormField
                      // only reads `initialValue` once, in its own
                      // initState, so simply changing `_generateBytes` in a
                      // later setState (see _importPad's auto-sync after a
                      // paste/scan) would otherwise leave the dropdown
                      // showing whatever was selected when it first built.
                      // A key tied to the value forces Flutter to treat a
                      // changed `_generateBytes` as a fresh widget instance
                      // and actually pick up the new initialValue.
                      key: ValueKey('generate-bytes-$_generateBytes'),
                      initialValue: _generateBytes,
                      decoration: InputDecoration(
                        labelText: 'Pad size',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(MeshRadii.sm),
                        ),
                        isDense: true,
                      ),
                      items: _generateSizeItems(),
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _generateBytes = value);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _generatePad,
                    icon: const Icon(Icons.casino_outlined, size: 18),
                    label: const Text('Generate'),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '~${(_generateBytes / 2 / max(1, _maxPlaintextPerMessage(connector))).floor()} '
                  'messages per side at this size',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _labelController,
                decoration: InputDecoration(
                  labelText: 'Label (optional)',
                  hintText: 'e.g. "Camp trip pad"',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(MeshRadii.sm),
                  ),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _importPad(connector, autoRole),
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.lock_outline),
                  label: const Text('Enable OTP with this pad'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Actions ──────────────────────────────────────────────────────────

  Future<void> _pasteFromClipboard() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clip?.text?.trim();
    if (text == null || text.isEmpty) return;
    setState(() {
      _pasteController.text = text;
      _formError = null;
    });
  }

  Future<void> _scanQr() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _OtpPadQrScanScreen()),
    );
    if (result != null && mounted) {
      setState(() {
        _pasteController.text = result;
        _formError = null;
      });
    }
  }

  void _generatePad() {
    final random = Random.secure();
    final bytes = List<int>.generate(_generateBytes, (_) => random.nextInt(256));
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    setState(() {
      _pasteController.text = hex;
      _formError = null;
    });
  }

  String? _normalizeHex(String raw) {
    final cleaned = raw.trim().replaceAll(RegExp(r'\s+'), '');
    if (cleaned.isEmpty) return null;
    if (cleaned.length % 2 != 0) return null;
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(cleaned)) return null;
    return cleaned.toLowerCase();
  }

  Future<void> _importPad(
    MeshCoreConnector connector,
    OtpPadRole? autoRole,
  ) async {
    // Prefer the auto-resolved role whenever one is available, even if a
    // stale manual selection is sitting in _selectedRole (e.g. this
    // device's own key became known after the screen first built) - the
    // manual picker is only ever shown, and only ever the source of
    // truth, when autoRole is null.
    final role = autoRole ?? _selectedRole;
    final hex = _normalizeHex(_pasteController.text);
    if (hex == null) {
      setState(
        () => _formError =
            'Enter valid hex pad data (paste, scan, or generate one above)',
      );
      return;
    }
    if (hex.length < 8) {
      setState(() => _formError = 'Pad is too short to be useful');
      return;
    }
    final bytes = hex.length ~/ 2;
    if (bytes > OtpService.maxTotalPadBytes) {
      setState(
        () => _formError =
            'Pad is $bytes bytes - over the '
            '${OtpService.maxTotalPadBytes} byte safety cap. Use a smaller '
            'pad, or split it across separate contacts/channels.',
      );
      return;
    }
    setState(() => _busy = true);
    final label = _labelController.text.trim();
    try {
      if (_isChannel) {
        await connector.setChannelOtpPad(
          widget.channel!.index,
          hex,
          role,
          label: label.isEmpty ? null : label,
        );
      } else {
        await connector.setContactOtpPad(
          widget.contact!.publicKeyHex,
          hex,
          role,
          label: label.isEmpty ? null : label,
        );
      }
    } on OtpPadImportBlockedException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${e.queuedCount} message(s) are still queued waiting to send '
            'to this contact - cancel or wait for them to send before '
            'importing a new pad.',
          ),
        ),
      );
      return;
    } on OtpPublicChannelBlockedException {
      // Shouldn't normally be reachable - this screen shows
      // _buildPublicChannelBlockedBody instead of this form for the
      // Public channel - but the connector refuses unconditionally
      // regardless, so this is defense in depth, not the primary gate.
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("OTP isn't available on the Public channel."),
        ),
      );
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      // Match the "Pad size" generator dropdown to whatever was just
      // pasted/scanned in (e.g. importing an 8200-byte pad now shows
      // "8200 B (max)" selected instead of staying on the 2048 B
      // default), so a later top-up "Generate" for this same
      // contact/channel defaults to the same size rather than requiring
      // the person to notice and reselect it by hand. See
      // _generateSizeItems for what happens when the imported size isn't
      // one of the 4 fixed dropdown options.
      _generateBytes = bytes;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('OTP pad imported and enabled')),
    );
  }

  Future<void> _setEnabled(MeshCoreConnector connector, bool value) async {
    if (_isChannel) {
      await connector.setChannelOtpEnabled(widget.channel!.index, value);
    } else {
      await connector.setContactOtpEnabled(widget.contact!.publicKeyHex, value);
    }
  }

  Future<void> _showPadQr(OtpPad pad) async {
    final bytes = pad.padHex.length ~/ 2;
    // A pad this large is very likely to produce a QR symbol too dense to
    // scan reliably (see OtpService.maxQrShareablePadBytes for the actual
    // capacity math) - ask before even trying, rather than silently
    // rendering something the other device may not be able to read at all.
    if (bytes > OtpService.maxQrShareablePadBytes && mounted) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Pad too large for one QR code'),
          content: Text(
            'This pad is $bytes bytes - larger than the '
            '${OtpService.maxQrShareablePadBytes} bytes that reliably fit '
            'in a single scannable QR code. It may render, but the other '
            'device could fail to scan it. Paste the hex or transfer the '
            'file directly instead for a pad this size.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Show anyway'),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }
    if (!mounted) return;
    QrCodeShareDialog.show(
      context: context,
      // Uppercased so the QR encoder's alphanumeric mode applies (its
      // charset is digits, uppercase A-F, and a few symbols - exactly
      // uppercased hex) rather than the lower-capacity byte mode a
      // mixed-case string would force. Purely a QR-density optimization -
      // every import path already normalizes hex case-insensitively
      // (_normalizeHex below lowercases on the way in), so this changes
      // nothing about what gets stored or how it's decoded.
      data: pad.padHex.toUpperCase(),
      title: 'Scan on the other device',
      instructions: pad.isSharedSequential
          ? 'This shows the raw pad in plain sight — make sure no one else '
                'can see your screen while others scan it. Every member of '
                'this group must import this exact same pad — there is no '
                'role to pick for a shared group pad.'
          : 'This shows the raw pad in plain sight — make sure no one else '
                'can see your screen while the other device scans it. Their '
                'app will normally work out on its own that they\'re Party '
                '${pad.role == OtpPadRole.a ? 'B' : 'A'} for this pad; if it '
                "can't, they'll need to pick that role by hand.",
    );
  }

  Future<void> _confirmAndClear(
    MeshCoreConnector connector, {
    bool andThenSetup = false,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear this pad?'),
        content: Text(
          andThenSetup
              ? "This forgets the current pad so you can import a new one. "
                    "Any unused bytes in the old pad are discarded — that's fine, "
                    "they were never reused anywhere else."
              : 'This turns off OTP for this ${_isChannel ? 'channel' : 'contact'} '
                    'and forgets the pad. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(andThenSetup ? 'Clear & replace' : 'Clear pad'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (_isChannel) {
      await connector.clearChannelOtpPad(widget.channel!.index);
    } else {
      await connector.clearContactOtpPad(widget.contact!.publicKeyHex);
    }
  }
}

/// Thin wrapper around the app's existing [QrScannerWidget] that validates
/// scanned data looks like pad hex before returning it.
class _OtpPadQrScanScreen extends StatelessWidget {
  const _OtpPadQrScanScreen();

  bool _looksLikeHex(String data) {
    final cleaned = data.trim();
    return cleaned.length >= 8 &&
        cleaned.length % 2 == 0 &&
        RegExp(r'^[0-9a-fA-F]+$').hasMatch(cleaned);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const AdaptiveAppBarTitle('Scan OTP Pad'),
        centerTitle: true,
      ),
      body: QrScannerWidget(
        onScanned: (data) => Navigator.of(context).pop(data.trim()),
        validator: _looksLikeHex,
        onValidationFailed: (_) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('That QR code doesn\'t look like pad data'),
            ),
          );
        },
        instructions: 'Point the camera at the pad QR shown on the other device',
      ),
    );
  }
}
