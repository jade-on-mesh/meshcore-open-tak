import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../screens/backup_restore_screen.dart';
import '../services/app_update_service.dart';
import '../utils/platform_info.dart';

/// The app's navigator, so the update banner (which sits above it in
/// MaterialApp.builder) can open the update dialog.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// True while the update dialog is open, so the banner steps aside.
final ValueNotifier<bool> _dialogOpen = ValueNotifier<bool>(false);

/// A red dot on [child] while a new app build is waiting.
class UpdateDot extends StatelessWidget {
  final Widget child;
  const UpdateDot({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final updates = AppUpdateService.instance;
    return ListenableBuilder(
      listenable: updates,
      builder: (context, child) => Badge(
        smallSize: 9,
        isLabelVisible: updates.shouldNotify,
        child: child,
      ),
      child: child,
    );
  }
}

/// Wrap the app with this (MaterialApp.builder). While a new build is
/// waiting it shows a card at the bottom with Later / Update.
class AppUpdateBanner extends StatelessWidget {
  final Widget child;
  const AppUpdateBanner({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final updates = AppUpdateService.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([updates, _dialogOpen]),
      builder: (context, child) {
        final latest = updates.latest;
        return Stack(
          children: [
            child!,
            if (updates.shouldNotify && latest != null && !_dialogOpen.value)
              Positioned(
                left: 12,
                right: 12,
                bottom: 0,
                child: SafeArea(
                  minimum: const EdgeInsets.only(bottom: 84),
                  child: _BannerCard(
                    version: latest.version,
                    buildNumber: latest.build,
                  ),
                ),
              ),
          ],
        );
      },
      child: child,
    );
  }
}

class _BannerCard extends StatelessWidget {
  final String version;
  final int buildNumber;
  const _BannerCard({required this.version, required this.buildNumber});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 6,
      color: scheme.primaryContainer,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.system_update, color: scheme.onPrimaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.appUpdate_bannerTitle,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                      Text(
                        l10n.appUpdate_bannerSubtitle(version, buildNumber),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: AppUpdateService.instance.dismiss,
                  child: Text(l10n.appUpdate_later),
                ),
                FilledButton(
                  onPressed: () {
                    final nav = appNavigatorKey.currentContext;
                    if (nav != null) showAppUpdateDialog(nav);
                  },
                  child: Text(l10n.appUpdate_view),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showAppUpdateDialog(BuildContext context) async {
  if (_dialogOpen.value) return;
  _dialogOpen.value = true;
  try {
    await showDialog<void>(
      context: context,
      builder: (_) => const _AppUpdateDialog(),
    );
  } finally {
    _dialogOpen.value = false;
  }
}

class _AppUpdateDialog extends StatefulWidget {
  const _AppUpdateDialog();

  @override
  State<_AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<_AppUpdateDialog> {
  final _updates = AppUpdateService.instance;
  bool _needsPermission = false;

  @override
  void initState() {
    super.initState();
    if (_updates.status == AppUpdateStatus.idle ||
        (_updates.status == AppUpdateStatus.error && _updates.latest == null)) {
      _updates.check();
    }
  }

  Future<void> _install() async {
    if (!await _updates.canInstall()) {
      if (mounted) setState(() => _needsPermission = true);
      return;
    }
    if (mounted) setState(() => _needsPermission = false);
    await _updates.downloadAndInstall();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListenableBuilder(
      listenable: _updates,
      builder: (context, _) {
        final theme = Theme.of(context);
        final small = theme.textTheme.bodySmall;
        final errorStyle = small?.copyWith(color: theme.colorScheme.error);
        final status = _updates.status;
        final latest = _updates.latest;
        final available = _updates.updateAvailable;
        final AppUpdateInfo? newer = available ? latest : null;
        final busy =
            status == AppUpdateStatus.checking ||
            status == AppUpdateStatus.downloading ||
            status == AppUpdateStatus.installing;
        final progress = _updates.progress;

        String headline;
        if (status == AppUpdateStatus.checking) {
          headline = l10n.appUpdate_checking;
        } else if (newer != null) {
          headline = l10n.appUpdate_available(newer.version, newer.build);
        } else if (latest != null) {
          headline = l10n.appUpdate_upToDate;
        } else {
          headline = l10n.appUpdate_notChecked;
        }

        return AlertDialog(
          title: Text(l10n.appUpdate_title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(headline, style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  l10n.appUpdate_installed(
                    _updates.installedVersion,
                    _updates.installedBuild,
                  ),
                  style: small,
                ),
                if (_updates.isLocalBuild) ...[
                  const SizedBox(height: 8),
                  Text(l10n.appUpdate_localBuild, style: small),
                ],
                if (newer != null && !newer.signedWithReleaseKey) ...[
                  const SizedBox(height: 8),
                  Text(l10n.appUpdate_debugSigned, style: errorStyle),
                ],
                if (newer != null && newer.changes.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    l10n.appUpdate_changes,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  for (final change in newer.changes.take(8))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text('• $change', style: small),
                    ),
                ],
                if (status == AppUpdateStatus.downloading) ...[
                  const SizedBox(height: 16),
                  LinearProgressIndicator(value: progress),
                  const SizedBox(height: 4),
                  Text(
                    progress == null
                        ? l10n.appUpdate_downloading
                        : l10n.appUpdate_downloadingPercent(
                            (progress * 100).round(),
                          ),
                    style: small,
                  ),
                ],
                if (status == AppUpdateStatus.installing) ...[
                  const SizedBox(height: 16),
                  Text(l10n.appUpdate_installing, style: small),
                ],
                if (available && !busy) ...[
                  const SizedBox(height: 12),
                  Text(
                    _updates.needsManualDownload
                        ? l10n.appUpdate_manualDownload
                        : !_updates.canSelfInstall
                        ? l10n.appUpdate_noFileForPlatform
                        : switch (AppUpdateService.platform) {
                            'windows' => l10n.appUpdate_installerHintWindows,
                            'macos' => l10n.appUpdate_installerHintMacos,
                            'linux' => l10n.appUpdate_installerHintLinux,
                            _ => l10n.appUpdate_installerHint,
                          },
                    style: small,
                  ),
                ],
                if (_needsPermission) ...[
                  const SizedBox(height: 12),
                  Text(l10n.appUpdate_permissionNeeded, style: errorStyle),
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: _updates.openInstallPermission,
                    child: Text(l10n.appUpdate_openPermission),
                  ),
                ],
                if (status == AppUpdateStatus.error &&
                    _updates.error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _updates.failedStep == AppUpdateStatus.idle
                        ? l10n.appUpdate_checkFailed(_updates.error!)
                        : l10n.appUpdate_installFailed(_updates.error!),
                    style: errorStyle,
                  ),
                ],
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.appUpdate_autoCheck),
                  subtitle: Text(l10n.appUpdate_autoCheckHint),
                  value: _updates.autoCheck,
                  onChanged: _updates.isLocalBuild
                      ? null
                      : (on) => _updates.setAutoCheck(on),
                ),
                if (!_updates.isLocalBuild)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.history),
                      label: Text(l10n.appUpdate_earlier),
                      onPressed: busy
                          ? null
                          : () => showDialog<void>(
                              context: context,
                              builder: (_) => const _EarlierBuildsDialog(),
                            ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.common_close),
            ),
            if (!available)
              TextButton(
                onPressed: busy ? null : _updates.check,
                child: Text(l10n.appUpdate_checkNow),
              )
            else if (!_updates.canSelfInstall)
              FilledButton(
                onPressed: _updates.openReleasePage,
                child: Text(l10n.appUpdate_openDownloadPage),
              )
            else
              FilledButton(
                onPressed: busy ? null : _install,
                child: Text(l10n.appUpdate_install),
              ),
          ],
        );
      },
    );
  }
}

/// "Install an earlier version": the last few builds from the
/// previous-builds release (AppUpdateService.fetchEarlierBuilds).
class _EarlierBuildsDialog extends StatefulWidget {
  const _EarlierBuildsDialog();

  @override
  State<_EarlierBuildsDialog> createState() => _EarlierBuildsDialogState();
}

class _EarlierBuildsDialogState extends State<_EarlierBuildsDialog> {
  final _updates = AppUpdateService.instance;
  late final Future<List<AppUpdateInfo>> _builds = _updates
      .fetchEarlierBuilds();
  String? _error;

  Future<void> _pick(AppUpdateInfo build) async {
    final l10n = context.l10n;
    if (!await _updates.canInstall()) {
      await _updates.openInstallPermission();
      return;
    }
    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.appUpdate_earlierBuild(build.version, build.build)),
        content: SingleChildScrollView(
          child: Text(
            PlatformInfo.isAndroid
                ? l10n.appUpdate_earlierAndroid(build.build)
                : l10n.appUpdate_earlierConfirm(
                    build.build,
                    _updates.installedBuild,
                  ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.common_cancel),
          ),
          if (PlatformInfo.isAndroid)
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext, false);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const BackupRestoreScreen(),
                  ),
                );
              },
              child: Text(l10n.appUpdate_earlierBackUp),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              PlatformInfo.isAndroid
                  ? l10n.appUpdate_earlierSave
                  : l10n.appUpdate_earlierInstall,
            ),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() => _error = null);
    final String? saved;
    try {
      saved = await _updates.installEarlier(build);
    } catch (e) {
      if (mounted) setState(() => _error = _updates.error ?? '$e');
      return;
    }
    if (saved == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.appUpdate_earlierBuild(build.version, build.build)),
        content: Text(l10n.appUpdate_earlierSaved(saved)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.common_close),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _updates.uninstallSelf();
            },
            child: Text(l10n.appUpdate_earlierUninstall),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    return ListenableBuilder(
      listenable: _updates,
      builder: (context, _) {
        final downloading = _updates.status == AppUpdateStatus.downloading;
        final progress = _updates.progress;
        return AlertDialog(
          title: Text(l10n.appUpdate_earlierTitle),
          content: SizedBox(
            width: 360,
            child: FutureBuilder<List<AppUpdateInfo>>(
              future: _builds,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return Text(l10n.appUpdate_earlierLoading, style: small);
                }
                if (snap.hasError) {
                  return Text(
                    l10n.appUpdate_earlierFailed('${snap.error}'),
                    style: small?.copyWith(color: theme.colorScheme.error),
                  );
                }
                final builds = snap.data ?? const <AppUpdateInfo>[];
                if (builds.isEmpty) {
                  return Text(l10n.appUpdate_earlierNone, style: small);
                }
                return SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final b in builds)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.history),
                          title: Text(
                            l10n.appUpdate_earlierBuild(b.version, b.build),
                          ),
                          subtitle: b.changes.isEmpty
                              ? null
                              : Text(
                                  b.changes.first,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          enabled: !downloading,
                          onTap: () => _pick(b),
                        ),
                      if (downloading) ...[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(value: progress),
                        const SizedBox(height: 4),
                        Text(
                          progress == null
                              ? l10n.appUpdate_downloading
                              : l10n.appUpdate_downloadingPercent(
                                  (progress * 100).round(),
                                ),
                          style: small,
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          l10n.appUpdate_installFailed(_error!),
                          style: small?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.common_close),
            ),
          ],
        );
      },
    );
  }
}
