import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../theme/mesh_theme.dart';
import '../widgets/adaptive_app_bar_title.dart';
import '../widgets/mesh_ui.dart';

/// OTP passphrase lock: set up protection, unlock it, or panic-wipe every
/// pad — reached from the OTP pad manager screen (see [OtpPadScreen]).
///
/// Scope: this screen (and the passphrase-derived encryption it unlocks)
/// gates the OTP pad-manager screens and OTP pad data specifically, NOT the
/// whole app — see the design note on `MeshCoreConnector.otpProtectionEnabled`
/// for the reasoning. Everything else in this app (contacts, channels,
/// plain messaging) is unaffected by lock state.
class OtpLockScreen extends StatefulWidget {
  const OtpLockScreen({super.key});

  @override
  State<OtpLockScreen> createState() => _OtpLockScreenState();
}

class _OtpLockScreenState extends State<OtpLockScreen> {
  final _passphraseController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _passphraseController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const AdaptiveAppBarTitle('OTP Protection'),
        centerTitle: true,
      ),
      body: Consumer<MeshCoreConnector>(
        builder: (context, connector, _) {
          if (!connector.otpProtectionEnabled) {
            return _buildSetupView(context, connector);
          }
          if (connector.otpLocked) {
            return _buildUnlockView(context, connector);
          }
          return _buildUnlockedView(context, connector);
        },
      ),
    );
  }

  // ── Not set up yet ──────────────────────────────────────────────────

  Widget _buildSetupView(BuildContext context, MeshCoreConnector connector) {
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
                  Icon(Icons.lock_outline, color: MeshPalette.blue),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Protect your OTP pads with a passphrase',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Once set, OTP pads are encrypted at rest and the OTP pad '
                'manager stays locked until you unlock with this passphrase. '
                'Nothing else in the app is affected — contacts, channels, '
                'and plain messaging work exactly as before, locked or not.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 4),
              Text(
                'There is no "forgot passphrase" recovery — if you lose it, '
                'the only way back in is the panic wipe, which destroys '
                'every pad along with the lock.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: MeshPalette.warn,
                ),
              ),
            ],
          ),
        ),
        MeshCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _passphraseController,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Passphrase',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(MeshRadii.sm),
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _confirmController,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Confirm passphrase',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(MeshRadii.sm),
                  ),
                  errorText: _error,
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _enable(connector),
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.lock_outline),
                  label: Text(_busy ? 'Deriving key…' : 'Enable protection'),
                ),
              ),
              if (_busy)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Key derivation is deliberately slow (3001 HMAC rounds) '
                    '— this can take a moment.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _enable(MeshCoreConnector connector) async {
    final passphrase = _passphraseController.text;
    final confirm = _confirmController.text;
    if (passphrase.length < 6) {
      setState(() => _error = 'Use at least 6 characters');
      return;
    }
    if (passphrase != confirm) {
      setState(() => _error = "Passphrases don't match");
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await connector.enableOtpProtection(passphrase);
    if (!mounted) return;
    _passphraseController.clear();
    _confirmController.clear();
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('OTP protection enabled')),
    );
  }

  // ── Locked ───────────────────────────────────────────────────────────

  Widget _buildUnlockView(BuildContext context, MeshCoreConnector connector) {
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
                'Enter your passphrase to unlock the pad manager and OTP '
                'decryption for every contact and channel.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        MeshCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _passphraseController,
                obscureText: _obscure,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Passphrase',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(MeshRadii.sm),
                  ),
                  errorText: _error,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                onSubmitted: (_) => _unlock(connector),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _unlock(connector),
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.lock_open),
                  label: Text(_busy ? 'Checking…' : 'Unlock'),
                ),
              ),
            ],
          ),
        ),
        _buildPanicCard(context, connector),
      ],
    );
  }

  Future<void> _unlock(MeshCoreConnector connector) async {
    final passphrase = _passphraseController.text;
    if (passphrase.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await connector.unlockOtpProtection(passphrase);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!ok) _error = 'Wrong passphrase';
    });
    if (ok) {
      _passphraseController.clear();
    }
  }

  // ── Unlocked ─────────────────────────────────────────────────────────

  Widget _buildUnlockedView(BuildContext context, MeshCoreConnector connector) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        MeshCard(
          child: Row(
            children: [
              const Icon(Icons.lock_open, color: MeshPalette.blue),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Protection is on and unlocked',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        MeshCard(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.lock_clock_outlined),
            title: const Text('Lock now'),
            subtitle: const Text(
              'Re-lock the pad manager without changing anything',
            ),
            onTap: () => connector.lockOtpProtection(),
          ),
        ),
        Text(
          'Danger zone',
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(color: MeshPalette.alert),
        ),
        const SizedBox(height: 8),
        _buildPanicCard(context, connector),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'There is no separate "turn off protection" — either stay '
            'unlocked/lock again as needed, or panic-wipe to remove '
            'protection along with every pad.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _buildPanicCard(BuildContext context, MeshCoreConnector connector) {
    final armed = connector.otpPanicArmed;
    return MeshCard(
      borderColor: MeshPalette.alert,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: MeshPalette.alert),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Panic wipe',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: MeshPalette.alert,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Immediately and permanently deletes every OTP pad on this '
            'device and turns protection off entirely. Cannot be undone. '
            'Tap once to arm, tap again within 4 seconds to confirm.',
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                backgroundColor: MeshPalette.alert.withValues(alpha: 0.15),
                foregroundColor: MeshPalette.alert,
              ),
              onPressed: () => _tapPanic(connector),
              icon: const Icon(Icons.delete_forever),
              label: Text(armed ? 'PANIC again to confirm' : 'PANIC wipe'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _tapPanic(MeshCoreConnector connector) async {
    final confirmed = await connector.tapOtpPanicWipe();
    if (!mounted) return;
    if (confirmed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('All OTP pads wiped. Protection turned off.'),
        ),
      );
    }
  }
}
