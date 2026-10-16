import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';
import '../models/radio_settings.dart';
import '../services/media_mesh.dart';
import '../services/repeater_command_service.dart';
import '../services/repeater_radio2.dart';
import '../theme/mesh_theme.dart';
import '../widgets/mesh_ui.dart';
import '../widgets/radio_disconnected_banner.dart';
import 'repeater_cli_screen.dart';

/// MediaMesh (radio2) on a repeater over remote admin: the second profile,
/// forwarding between the two, where the repeater's replies go, a temporary
/// profile, and live figures. See lib/services/repeater_radio2.dart.
class RepeaterRadio2Screen extends StatefulWidget {
  final Contact repeater;
  final String password;

  const RepeaterRadio2Screen({
    super.key,
    required this.repeater,
    required this.password,
  });

  @override
  State<RepeaterRadio2Screen> createState() => _RepeaterRadio2ScreenState();
}

enum _Busy { none, profile, cross, reply, temp, status }

class _RepeaterRadio2ScreenState extends State<RepeaterRadio2Screen> {
  static const _mainColor = MeshPalette.blue;
  static const _radio2Color = MeshPalette.magenta;
  static const _tempMinutes = [15, 60, 120, 360];

  late final RepeaterCommandService _service;
  late final RepeaterRadio2Controller _ctl;
  StreamSubscription<Uint8List>? _frames;
  Future<void> _queue = Future.value();
  Timer? _ticker;

  bool _loading = true;
  bool? _supported;
  String? _loadError;

  MainRadio? _main;
  Radio2Profile _saved = Radio2Profile.defaults;
  Radio2Profile _edit = Radio2Profile.defaults;
  Radio2Cross? _cross;
  TxReplySetting? _reply;
  TempRadio2? _temp;
  Radio2Status? _status;
  DateTime? _statusAt;
  _Busy _busy = _Busy.none;

  final _freqController = TextEditingController();
  final _preambleController = TextEditingController();
  bool _freqInvalid = false;
  bool _preambleInvalid = false;

  @override
  void initState() {
    super.initState();
    final connector = context.read<MeshCoreConnector>();
    _service = RepeaterCommandService(connector);
    _ctl = RepeaterRadio2Controller(_send);
    _frames = connector.receivedFrames.listen(_onFrame);
    // Re-renders "updated 12 s ago" and the temporary countdown.
    _ticker = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _frames?.cancel();
    _service.dispose();
    _freqController.dispose();
    _preambleController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ transport

  void _onFrame(Uint8List frame) {
    if (frame.isEmpty) return;
    if (frame[0] != respCodeContactMsgRecv &&
        frame[0] != respCodeContactMsgRecvV3) {
      return;
    }
    final parsed = parseContactMessageText(frame);
    if (parsed == null) return;
    final target = widget.repeater.publicKey;
    if (parsed.senderPrefix.length < 6 || target.length < 6) return;
    for (var i = 0; i < 6; i++) {
      if (parsed.senderPrefix[i] != target[i]) return;
    }
    _service.handleResponse(widget.repeater, parsed.text);
  }

  Contact _resolveRepeater(MeshCoreConnector connector) {
    for (final c in connector.contacts) {
      if (c.publicKeyHex == widget.repeater.publicKeyHex) return c;
    }
    return widget.repeater;
  }

  /// One command at a time: the mesh is slow and replies are matched by tag.
  Future<String> _send(String command) {
    final connector = context.read<MeshCoreConnector>();
    final disconnected = context.l10n.repeater_radioDisconnected;
    final done = Completer<String>();
    _queue = _queue.then((_) async {
      try {
        if (!connector.isConnected) {
          throw Radio2CommandException(disconnected);
        }
        done.complete(
          await _service.sendCommand(
            _resolveRepeater(connector),
            command,
            retries: 2,
          ),
        );
      } catch (e) {
        done.completeError(e);
      }
    });
    return done.future;
  }

  // ---------------------------------------------------------------- loads

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final radio2 = await _ctl.radio2();
      if (!mounted) return;
      if (radio2 == null) {
        setState(() {
          _supported = false;
          _loading = false;
        });
        return;
      }
      _setSaved(Radio2Profile.fromReply(radio2, fallback: _saved));
      setState(() => _supported = true);
      final main = await _ctl.mainRadio();
      if (!mounted) return;
      setState(() => _main = main);
      final cross = await _ctl.cross();
      if (!mounted) return;
      setState(() => _cross = cross);
      final reply = await _ctl.txReply();
      if (!mounted) return;
      setState(() => _reply = reply);
      await _loadLive();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadLive() async {
    final temp = await _ctl.temp();
    if (!mounted) return;
    setState(() => _temp = temp);
    final status = await _ctl.status();
    if (!mounted) return;
    setState(() {
      _status = status;
      _statusAt = DateTime.now();
    });
  }

  Future<void> _refreshLive() async {
    if (_busy != _Busy.none) return;
    setState(() => _busy = _Busy.status);
    try {
      await _loadLive();
    } catch (e) {
      if (mounted) _toast(context.l10n.rr2_noAnswer, error: true);
    } finally {
      if (mounted) setState(() => _busy = _Busy.none);
    }
  }

  void _setSaved(Radio2Profile p) {
    _saved = p;
    _edit = p;
    _freqController.text = p.frequencyMHz.toStringAsFixed(3);
    _preambleController.text = p.preamble?.toString() ?? '';
    _freqInvalid = false;
    _preambleInvalid = false;
  }

  // --------------------------------------------------------------- writes

  Future<void> _write(_Busy what, Future<void> Function() body) async {
    if (_busy != _Busy.none) return;
    HapticFeedback.selectionClick();
    setState(() => _busy = what);
    try {
      await body();
    } on Radio2CommandException catch (e) {
      if (!mounted) return;
      if (e.needsUsb) {
        await _showUsbOnly();
      } else {
        _toast(context.l10n.rr2_refused(e.message), error: true);
      }
    } catch (e) {
      if (mounted) _toast(context.l10n.rr2_noAnswer, error: true);
    } finally {
      if (mounted) setState(() => _busy = _Busy.none);
    }
  }

  Future<void> _applyProfile() async {
    if (!_profileValid || !_dirty) return;
    final ok = await _confirmProfile();
    if (ok != true || !mounted) return;
    await _write(_Busy.profile, () async {
      final reply = await _ctl.applyProfile(_edit);
      if (!mounted) return;
      _toast(
        _edit.mode == Radio2Mode.off
            ? context.l10n.rr2_turnedOff
            : context.l10n.rr2_applied(reply),
      );
      setState(() => _setSaved(_edit));
      // The repeater switches once its reply has gone out.
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      final back = await _ctl.radio2();
      if (back != null && mounted) {
        setState(() => _setSaved(Radio2Profile.fromReply(back, fallback: _edit)));
      }
      await _loadLive();
    });
  }

  Future<void> _setCross(Radio2Cross c) async {
    if (_cross == c) return;
    await _write(_Busy.cross, () async {
      await _ctl.setCross(c);
      if (!mounted) return;
      setState(() => _cross = c);
      _toast(context.l10n.rr2_saved);
    });
  }

  Future<void> _setReply(TxReplySetting s) async {
    await _write(_Busy.reply, () async {
      await _ctl.setTxReply(s);
      final back = await _ctl.txReply();
      if (!mounted) return;
      setState(() => _reply = back ?? s);
      _toast(context.l10n.rr2_saved);
    });
  }

  Future<void> _startTemp(int minutes) async {
    if (!_profileValid) return;
    await _write(_Busy.temp, () async {
      await _ctl.startTemp(_edit, minutes);
      if (!mounted) return;
      _toast(context.l10n.rr2_tempStarted);
      await Future<void>.delayed(const Duration(seconds: 2));
      await _loadLive();
    });
  }

  Future<void> _stopTemp() async {
    await _write(_Busy.temp, () async {
      await _ctl.stopTemp();
      if (!mounted) return;
      _toast(context.l10n.rr2_tempStopped);
      await Future<void>.delayed(const Duration(seconds: 2));
      await _loadLive();
    });
  }

  // ----------------------------------------------------------- validation

  void _onFreqChanged(String text) {
    final f = double.tryParse(text.trim());
    setState(() {
      _freqInvalid = f == null || f < 150 || f > 960;
      if (!_freqInvalid) _edit = _edit.copyWith(frequencyMHz: f);
    });
  }

  void _onPreambleChanged(String text) {
    final p = int.tryParse(text.trim());
    setState(() {
      _preambleInvalid = p == null || p < 8 || p > 512;
      if (!_preambleInvalid) _edit = _edit.copyWith(preamble: () => p);
    });
  }

  bool get _onMain =>
      _edit.mode != Radio2Mode.off && _edit.sameChannelAs(_main);

  bool get _profileValid =>
      _edit.mode == Radio2Mode.off ||
      (!_freqInvalid && !_onMain && (_edit.preamble == null || !_preambleInvalid));

  bool get _dirty => !_edit.sameAs(_saved);

  // ------------------------------------------------------------- dialogs

  void _toast(String text, {bool error = false}) {
    if (!mounted) return;
    showDismissibleSnackBar(
      context,
      content: Text(text),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    );
  }

  Future<void> _showUsbOnly() => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.usb),
      title: Text(ctx.l10n.rr2_usbOnlyTitle),
      content: Text(ctx.l10n.rr2_usbOnly),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(ctx.l10n.common_ok),
        ),
      ],
    ),
  );

  Future<bool?> _confirmProfile() {
    final l10n = context.l10n;
    final off = _edit.mode == Radio2Mode.off;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          off ? Icons.power_settings_new : Icons.settings_input_antenna,
          color: _radio2Color,
        ),
        title: Text(off ? l10n.rr2_confirmOffTitle : l10n.rr2_confirmTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!off) ...[
              _ProfileLine(profile: _saved, label: l10n.rr2_now, dim: true),
              const SizedBox(height: 6),
              _ProfileLine(profile: _edit, label: l10n.rr2_new),
              const SizedBox(height: 14),
            ],
            Text(l10n.rr2_confirmBody),
            const SizedBox(height: 8),
            Text(
              l10n.rr2_confirmShared,
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(off ? l10n.rr2_turnOff : l10n.rr2_apply),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Column(
          children: [
            Text(l10n.rr2_title),
            Text(
              widget.repeater.name,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: l10n.rr2_reload,
            onPressed: _loading || _busy != _Busy.none ? null : _load,
            icon: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: _children(context),
          ),
        ),
      ),
    );
  }

  List<Widget> _children(BuildContext context) {
    final l10n = context.l10n;
    if (_loadError != null && _supported == null) {
      return [
        const RadioDisconnectedBanner(),
        const SizedBox(height: 16),
        ErrorRetryCard(
          message: l10n.rr2_loadFailed,
          onRetry: _load,
          retryLabel: l10n.rr2_reload,
        ),
      ];
    }
    if (_supported == null) {
      return [
        const RadioDisconnectedBanner(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
          child: _BandsCard(
            main: null,
            radio2: null,
            cross: null,
            loadingText: l10n.rr2_asking,
          ),
        ),
      ];
    }
    if (_supported == false) return [_unsupported(context)];
    var i = 0;
    return [
      const RadioDisconnectedBanner(),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: ListEntrance(
          index: i++,
          child: _BandsCard(
            main: _main,
            radio2: _saved,
            cross: _cross,
            temp: _temp,
            pending: _status?.pending ?? false,
          ),
        ),
      ),
      ..._live(context),
      SectionHeader(l10n.rr2_profileSection),
      ListEntrance(index: i++, child: _profileCard(context)),
      SectionHeader(l10n.rr2_crossSection),
      ListEntrance(index: i++, child: _crossCard(context)),
      SectionHeader(l10n.rr2_replySection),
      ListEntrance(index: i++, child: _replyCard(context)),
      SectionHeader(l10n.rr2_tempSection),
      ListEntrance(index: i++, child: _tempCard(context)),
      const SizedBox(height: 8),
      MeshCard(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => RepeaterCliScreen(
              repeater: widget.repeater,
              password: widget.password,
            ),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.terminal, color: MeshPalette.warn),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.rr2_cli,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(
                    l10n.rr2_cliSubtitle,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    ];
  }

  Widget _unsupported(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 20, 0, 0),
      child: MeshCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: MeshPalette.magentaBg,
                    borderRadius: BorderRadius.circular(MeshRadii.md),
                    border: Border.all(color: MeshPalette.magentaLine),
                  ),
                  child: const Icon(
                    Icons.settings_input_antenna,
                    color: _radio2Color,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    l10n.rr2_unsupportedTitle,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(l10n.rr2_unsupported),
            const SizedBox(height: 8),
            Text(l10n.rr2_unsupportedStock, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.rr2_reload),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ----------------------------------------------------------------- live

  List<Widget> _live(BuildContext context) {
    final l10n = context.l10n;
    final status = _status;
    final theme = Theme.of(context);
    final ago = _statusAt == null
        ? null
        : DateTime.now().difference(_statusAt!).inSeconds;
    final header = SectionHeader(
      l10n.rr2_liveSection,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (ago != null)
            Text(
              ago < 60
                  ? l10n.rr2_updatedSeconds(ago)
                  : l10n.rr2_updatedMinutes(ago ~/ 60),
              style: theme.textTheme.bodySmall,
            ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: l10n.rr2_refreshLive,
            onPressed: _busy == _Busy.none ? _refreshLive : null,
            icon: _busy == _Busy.status
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh, size: 20),
          ),
        ],
      ),
    );
    if (status == null) {
      return [
        header,
        MeshCard(
          child: Text(
            _loading ? l10n.rr2_asking : l10n.rr2_noLive,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ];
    }
    if (status.pending) {
      return [
        header,
        _Banner(
          color: MeshPalette.warn,
          icon: Icons.hourglass_top,
          text: l10n.rr2_pending,
        ),
      ];
    }
    if (status.mode == 'off') {
      return [
        header,
        MeshCard(
          child: Text(l10n.rr2_liveOff, style: theme.textTheme.bodySmall),
        ),
      ];
    }
    final rxTotal = status.rx[0] + status.rx[1];
    return [
      header,
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: StatTile(
                    icon: Icons.south_west,
                    label: l10n.rr2_heardMain,
                    value: '${status.rx[0]}',
                    color: _mainColor,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: StatTile(
                    icon: Icons.south_west,
                    label: l10n.rr2_heardRadio2,
                    value: '${status.rx[1]}',
                    color: _radio2Color,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: StatTile(
                    icon: Icons.north_east,
                    label: l10n.rr2_sentMain,
                    value: '${status.tx[0]}',
                    color: _mainColor,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: StatTile(
                    icon: Icons.north_east,
                    label: l10n.rr2_sentRadio2,
                    value: '${status.tx[1]}',
                    color: _radio2Color,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      MeshCard(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (rxTotal > 0) ...[
              Text(
                l10n.rr2_heardShare(
                  (status.rx[1] * 100 / rxTotal).round(),
                ),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 6),
              _ShareBar(
                a: status.rx[0],
                b: status.rx[1],
                aColor: _mainColor,
                bColor: _radio2Color,
              ),
              const SizedBox(height: 12),
            ],
            _Fact(
              label: l10n.rr2_switchTime,
              value: status.switchMeasured && status.switchUs != null
                  ? '${status.switchUs} µs'
                  : l10n.rr2_measuring,
            ),
            if (status.preamble != null)
              _Fact(
                label: l10n.rr2_preambles,
                value: '${status.preamble![0]} / ${status.preamble![1]}',
              ),
            if (status.switches != null)
              _Fact(
                label: l10n.rr2_switches,
                value: status.switchErrors == null || status.switchErrors == 0
                    ? '${status.switches}'
                    : l10n.rr2_switchesErrors(
                        status.switches!,
                        status.switchErrors!,
                      ),
                warn: (status.switchErrors ?? 0) > 0,
              ),
          ],
        ),
      ),
      for (final w in status.warnings)
        _Banner(color: MeshPalette.warn, icon: Icons.warning_amber, text: w),
    ];
  }

  // -------------------------------------------------------------- profile

  Widget _profileCard(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final busy = _busy == _Busy.profile;
    final on = _edit.mode != Radio2Mode.off;
    final help = switch (_edit.mode) {
      Radio2Mode.off => l10n.rr2_modeOffHelp,
      Radio2Mode.rx => l10n.rr2_modeRxHelp,
      Radio2Mode.rxtx => l10n.rr2_modeRxtxHelp,
    };
    return MeshCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<Radio2Mode>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: Radio2Mode.off,
                  icon: const Icon(Icons.power_settings_new, size: 18),
                  label: Text(l10n.mediaMesh_modeOff),
                ),
                ButtonSegment(
                  value: Radio2Mode.rx,
                  icon: const Icon(Icons.hearing, size: 18),
                  label: Text(l10n.mediaMesh_modeListen),
                ),
                ButtonSegment(
                  value: Radio2Mode.rxtx,
                  icon: const Icon(Icons.swap_vert, size: 18),
                  label: Text(l10n.mediaMesh_modeListenSend),
                ),
              ],
              selected: {_edit.mode},
              onSelectionChanged: busy
                  ? null
                  : (s) => setState(() => _edit = _edit.copyWith(mode: s.first)),
            ),
          ),
          const SizedBox(height: 8),
          Text(help, style: small),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: on ? _profileFields(context) : const SizedBox(width: double.infinity),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              if (_dirty)
                TextButton(
                  onPressed: busy ? null : () => setState(() => _setSaved(_saved)),
                  child: Text(l10n.rr2_reset),
                ),
              const Spacer(),
              FilledButton.icon(
                onPressed: busy || !_dirty || !_profileValid || _busy != _Busy.none
                    ? null
                    : _applyProfile,
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_to_mobile, size: 18),
                label: Text(l10n.rr2_applyToRepeater),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _profileFields(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final main = _main;
    final faster = main == null
        ? null
        : Radio2Profile.airtimeMs(
                bandwidthHz: main.bandwidthKHz * 1000,
                sf: main.spreadingFactor,
                cr: main.codingRate,
              ) /
              Radio2Profile.airtimeMs(
                bandwidthHz: _edit.bandwidth.hz.toDouble(),
                sf: _edit.spreadingFactor.value,
                cr: _edit.codingRate.value,
              );
    InputDecoration deco(String label, {String? suffix, String? error}) =>
        InputDecoration(
          labelText: label,
          suffixText: suffix,
          errorText: error,
          isDense: true,
          border: const OutlineInputBorder(),
        );
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _freqController,
            onChanged: _onFreqChanged,
            enabled: _busy != _Busy.profile,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: MeshTheme.mono(fontSize: 16, fontWeight: FontWeight.w600),
            decoration: deco(
              l10n.rr2_frequency,
              suffix: 'MHz',
              error: _freqInvalid
                  ? l10n.mediaMesh_frequencyRange
                  : _onMain
                  ? l10n.mediaMesh_frequencyMain
                  : null,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 5,
                child: DropdownButtonFormField<LoRaBandwidth>(
                  key: ValueKey('bw${_edit.bandwidth}'),
                  initialValue: _edit.bandwidth,
                  isExpanded: true,
                  decoration: deco(l10n.rr2_bw),
                  items: [
                    for (final bw in LoRaBandwidth.values)
                      DropdownMenuItem(value: bw, child: Text(bw.label)),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _edit = _edit.copyWith(bandwidth: v));
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<LoRaSpreadingFactor>(
                  key: ValueKey('sf${_edit.spreadingFactor}'),
                  initialValue: _edit.spreadingFactor,
                  isExpanded: true,
                  decoration: deco(l10n.rr2_sf),
                  items: [
                    for (final sf in LoRaSpreadingFactor.values)
                      DropdownMenuItem(value: sf, child: Text(sf.label)),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _edit = _edit.copyWith(spreadingFactor: v));
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<LoRaCodingRate>(
                  key: ValueKey('cr${_edit.codingRate}'),
                  initialValue: _edit.codingRate,
                  isExpanded: true,
                  decoration: deco(l10n.rr2_cr),
                  items: [
                    for (final cr in LoRaCodingRate.values)
                      DropdownMenuItem(value: cr, child: Text(cr.label)),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _edit = _edit.copyWith(codingRate: v));
                    }
                  },
                ),
              ),
            ],
          ),
          if (faster != null && faster.isFinite) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  faster >= 1 ? Icons.speed : Icons.slow_motion_video,
                  size: 16,
                  color: faster >= 1 ? MeshPalette.signal : MeshPalette.warn,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    faster >= 1.05
                        ? l10n.rr2_faster(faster.toStringAsFixed(1))
                        : faster <= 0.95
                        ? l10n.rr2_slower((1 / faster).toStringAsFixed(1))
                        : l10n.rr2_sameSpeed,
                    style: small,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(l10n.rr2_preambleAuto),
            subtitle: Text(l10n.rr2_preambleAutoHelp, style: small),
            value: _edit.preamble == null,
            onChanged: (auto) => setState(() {
              if (auto) {
                _edit = _edit.copyWith(preamble: () => null);
                _preambleInvalid = false;
              } else {
                final p = int.tryParse(_preambleController.text) ??
                    _status?.preamble?[1] ??
                    32;
                _preambleController.text = '$p';
                _edit = _edit.copyWith(preamble: () => p);
              }
            }),
          ),
          if (_edit.preamble != null)
            TextField(
              controller: _preambleController,
              onChanged: _onPreambleChanged,
              keyboardType: TextInputType.number,
              style: MeshTheme.mono(fontSize: 15),
              decoration: deco(
                l10n.rr2_preamble,
                suffix: l10n.rr2_symbols,
                error: _preambleInvalid ? l10n.rr2_preambleRange : null,
              ),
            ),
          const SizedBox(height: 8),
          Text(l10n.rr2_sharedNote, style: small),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- cross

  Widget _crossCard(BuildContext context) {
    final l10n = context.l10n;
    final busy = _busy == _Busy.cross;
    if (_cross == null && !_loading) {
      return MeshCard(child: Text(l10n.rr2_notReported));
    }
    return Column(
      children: [
        _ChoiceTile(
          icon: Icons.sync_alt,
          color: MeshPalette.signal,
          title: l10n.rr2_crossOn,
          subtitle: l10n.rr2_crossOnHelp,
          selected: _cross == Radio2Cross.on,
          busy: busy,
          onTap: _busy == _Busy.none ? () => _setCross(Radio2Cross.on) : null,
        ),
        _ChoiceTile(
          icon: Icons.auto_mode,
          color: _mainColor,
          title: l10n.rr2_crossAuto,
          subtitle: l10n.rr2_crossAutoHelp,
          selected: _cross == Radio2Cross.auto,
          busy: busy,
          onTap: _busy == _Busy.none ? () => _setCross(Radio2Cross.auto) : null,
        ),
        _ChoiceTile(
          icon: Icons.link_off,
          color: MeshPalette.warn,
          title: l10n.rr2_crossOff,
          subtitle: l10n.rr2_crossOffHelp,
          selected: _cross == Radio2Cross.off,
          busy: busy,
          onTap: _busy == _Busy.none ? () => _setCross(Radio2Cross.off) : null,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- reply

  Widget _replyCard(BuildContext context) {
    final l10n = context.l10n;
    final reply = _reply;
    final busy = _busy == _Busy.reply;
    if (reply == null) {
      return MeshCard(
        child: Text(_loading ? l10n.rr2_asking : l10n.rr2_replyMissing),
      );
    }
    final listenOnly = _saved.mode == Radio2Mode.rx;
    Widget tile(ReplyRoute r, IconData icon, Color color, String t, String s) =>
        _ChoiceTile(
          icon: icon,
          color: color,
          title: t,
          subtitle: s,
          selected: reply.route == r,
          busy: busy,
          onTap: _busy == _Busy.none && reply.route != r
              ? () => _setReply(
                  TxReplySetting(route: r, force: reply.force && r.canForce),
                )
              : null,
        );
    return Column(
      children: [
        tile(
          ReplyRoute.both,
          Icons.call_split,
          MeshPalette.signal,
          l10n.rr2_replyBoth,
          l10n.rr2_replyBothHelp,
        ),
        tile(
          ReplyRoute.radio,
          Icons.cell_tower,
          _mainColor,
          l10n.rr2_replyMain,
          l10n.rr2_replyMainHelp,
        ),
        tile(
          ReplyRoute.radio2,
          Icons.settings_input_antenna,
          _radio2Color,
          l10n.rr2_replyRadio2,
          l10n.rr2_replyRadio2Help,
        ),
        tile(
          ReplyRoute.auto,
          Icons.auto_mode,
          MeshPalette.ink3,
          l10n.rr2_replyAuto,
          l10n.rr2_replyAutoHelp,
        ),
        if (reply.route.canForce && (listenOnly || reply.force))
          MeshCard(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: SwitchListTile(
              title: Text(l10n.rr2_force),
              subtitle: Text(l10n.rr2_forceHelp),
              value: reply.force,
              onChanged: _busy == _Busy.none
                  ? (v) => _setReply(TxReplySetting(route: reply.route, force: v))
                  : null,
            ),
          ),
        if (reply.radio2Unavailable)
          _Banner(
            color: MeshPalette.warn,
            icon: Icons.info_outline,
            text: l10n.rr2_replyUnavailable,
          ),
      ],
    );
  }

  // ----------------------------------------------------------------- temp

  Widget _tempCard(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final temp = _temp;
    final busy = _busy == _Busy.temp;
    if (temp != null) {
      return MeshCard(
        borderColor: MeshPalette.warnLine,
        color: MeshPalette.warnBg,
        child: Row(
          children: [
            const Icon(Icons.timer_outlined, color: MeshPalette.warn),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.rr2_tempRunning(temp.frequencyMHz.toStringAsFixed(3)),
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _minutesText(context, temp.minutesLeft),
                    style: MeshTheme.mono(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: MeshPalette.warn,
                    ),
                  ),
                ],
              ),
            ),
            OutlinedButton(
              onPressed: _busy == _Busy.none ? _stopTemp : null,
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.rr2_tempStop),
            ),
          ],
        ),
      );
    }
    return MeshCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.rr2_tempHelp, style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          _ProfileLine(profile: _edit, label: l10n.rr2_tempUses),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in _tempMinutes)
                ActionChip(
                  avatar: busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.timer_outlined, size: 16),
                  label: Text(_minutesText(context, m, left: false)),
                  onPressed: _busy == _Busy.none && _profileValid
                      ? () => _startTemp(m)
                      : null,
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _minutesText(BuildContext context, int minutes, {bool left = true}) {
    final l10n = context.l10n;
    final h = minutes ~/ 60;
    final m = minutes % 60;
    final text = h == 0
        ? l10n.rr2_minutes(m)
        : m == 0
        ? l10n.rr2_hours(h)
        : l10n.rr2_hoursMinutes(h, m);
    return left ? l10n.rr2_left(text) : text;
  }
}

// ------------------------------------------------------------------ pieces

/// The two profiles side by side, joined by the forwarding state.
class _BandsCard extends StatelessWidget {
  final MainRadio? main;
  final Radio2Profile? radio2;
  final Radio2Cross? cross;
  final TempRadio2? temp;
  final bool pending;
  final String? loadingText;

  const _BandsCard({
    required this.main,
    required this.radio2,
    required this.cross,
    this.temp,
    this.pending = false,
    this.loadingText,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final r2 = radio2;
    final on2 = r2 != null && r2.mode != Radio2Mode.off ? r2 : null;
    final r2On = on2 != null;
    final m = main;
    final (linkIcon, linkColor, linkText) = !r2On
        ? (Icons.remove, MeshPalette.ink4, '')
        : switch (cross) {
            Radio2Cross.on => (
              Icons.sync_alt,
              MeshPalette.signal,
              l10n.rr2_linkBridged,
            ),
            Radio2Cross.off => (
              Icons.link_off,
              MeshPalette.warn,
              l10n.rr2_linkSeparate,
            ),
            Radio2Cross.auto => (
              Icons.auto_mode,
              MeshPalette.blue,
              l10n.rr2_linkAuto,
            ),
            null => (Icons.more_horiz, MeshPalette.ink4, ''),
          };
    final modeChip = r2 == null
        ? null
        : switch (r2.mode) {
            Radio2Mode.off => StatusChip(
              label: l10n.rr2_chipOff,
              color: MeshPalette.ink4,
            ),
            Radio2Mode.rx => StatusChip(
              label: l10n.rr2_chipListening,
              color: MeshPalette.blue,
              pulse: true,
            ),
            Radio2Mode.rxtx => StatusChip(
              label: l10n.rr2_chipActive,
              color: MeshPalette.signal,
              pulse: true,
            ),
          };
    return MeshCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
      child: Column(
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _BandPane(
                    label: l10n.rr2_main,
                    color: MeshPalette.blue,
                    frequency: m?.frequencyMHz,
                    detail: m == null
                        ? null
                        : 'BW ${_khz(m.bandwidthKHz)} · SF${m.spreadingFactor} · CR${m.codingRate}',
                  ),
                ),
                SizedBox(
                  width: 64,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(linkIcon, color: linkColor, size: 22),
                      if (linkText.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          linkText,
                          textAlign: TextAlign.center,
                          style: MeshTheme.accentLabel(
                            color: linkColor,
                            fontSize: 10.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: _BandPane(
                    label: 'RADIO2',
                    color: MeshPalette.magenta,
                    dim: !r2On,
                    frequency: on2?.frequencyMHz,
                    offText: r2 != null && !r2On ? l10n.rr2_chipOff : null,
                    detail: on2 == null
                        ? null
                        : 'BW ${formatBandwidthKHz(on2.bandwidth)} · ${on2.spreadingFactor.label} · CR${on2.codingRate.value}',
                  ),
                ),
              ],
            ),
          ),
          if (loadingText != null) ...[
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(loadingText ?? '', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ] else if (modeChip != null) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: [
                modeChip,
                if (temp case final t?)
                  StatusChip(
                    label: l10n.rr2_chipTemp(t.minutesLeft),
                    color: MeshPalette.warn,
                    icon: Icons.timer_outlined,
                  ),
                if (pending)
                  StatusChip(
                    label: l10n.rr2_chipPending,
                    color: MeshPalette.warn,
                    icon: Icons.hourglass_top,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _khz(double khz) {
    var t = khz.toStringAsFixed(2);
    t = t.replaceFirst(RegExp(r'0+$'), '');
    return t.endsWith('.') ? t.substring(0, t.length - 1) : t;
  }
}

class _BandPane extends StatelessWidget {
  final String label;
  final Color color;
  final double? frequency;
  final String? detail;
  final String? offText;
  final bool dim;

  const _BandPane({
    required this.label,
    required this.color,
    required this.frequency,
    this.detail,
    this.offText,
    this.dim = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = dim ? scheme.onSurfaceVariant : color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: c.withValues(alpha: dim ? 0.05 : 0.10),
        borderRadius: BorderRadius.circular(MeshRadii.sm),
        border: Border.all(color: c.withValues(alpha: dim ? 0.2 : 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: MeshTheme.accentLabel(color: c, fontSize: 11)),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              frequency?.toStringAsFixed(3) ?? offText ?? '—',
              style: MeshTheme.mono(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: dim ? scheme.onSurfaceVariant : scheme.onSurface,
              ),
            ),
          ),
          if (frequency != null)
            Text(
              'MHz',
              style: MeshTheme.mono(
                fontSize: 11,
                color: scheme.onSurfaceVariant,
              ),
            ),
          if (detail case final d?) ...[
            const SizedBox(height: 6),
            Text(
              d,
              style: MeshTheme.mono(
                fontSize: 11,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A radio-button card: icon, title, one-line explanation.
class _ChoiceTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool selected;
  final bool busy;
  final VoidCallback? onTap;

  const _ChoiceTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: MeshCard(
        onTap: selected ? null : onTap,
        color: selected ? color.withValues(alpha: 0.10) : null,
        borderColor: selected ? color.withValues(alpha: 0.55) : null,
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(MeshRadii.sm),
                border: Border.all(color: color.withValues(alpha: 0.3)),
              ),
              child: Icon(icon, size: 20, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: selected
                  ? Icon(
                      Icons.check_circle,
                      key: const ValueKey('on'),
                      color: color,
                    )
                  : busy
                  ? const SizedBox(
                      key: ValueKey('busy'),
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      Icons.radio_button_unchecked,
                      key: const ValueKey('off'),
                      color: scheme.outline,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileLine extends StatelessWidget {
  final Radio2Profile profile;
  final String label;
  final bool dim;

  const _ProfileLine({
    required this.profile,
    required this.label,
    this.dim = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = profile.mode != Radio2Mode.off;
    final tuple =
        '${profile.frequencyMHz.toStringAsFixed(3)} MHz · '
        'BW ${formatBandwidthKHz(profile.bandwidth)} · '
        '${profile.spreadingFactor.label} · '
        'CR${profile.codingRate.value}'
        '${on ? ' · ${profile.mode.cli}' : ''}';
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label  ',
            style: MeshTheme.accentLabel(
              color: scheme.onSurfaceVariant,
              fontSize: 11,
            ),
          ),
          TextSpan(
            text: tuple,
            style: MeshTheme.mono(
              fontSize: 12.5,
              color: dim ? scheme.onSurfaceVariant : scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  final String label;
  final String value;
  final bool warn;

  const _Fact({required this.label, required this.value, this.warn = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            value,
            style: MeshTheme.mono(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: warn ? MeshPalette.warn : scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _ShareBar extends StatelessWidget {
  final int a;
  final int b;
  final Color aColor;
  final Color bColor;

  const _ShareBar({
    required this.a,
    required this.b,
    required this.aColor,
    required this.bColor,
  });

  @override
  Widget build(BuildContext context) {
    final total = a + b;
    return ClipRRect(
      borderRadius: BorderRadius.circular(MeshRadii.pill),
      child: SizedBox(
        height: 8,
        child: Row(
          children: [
            if (a > 0) Expanded(flex: a * 1000 ~/ total + 1, child: ColoredBox(color: aColor)),
            if (b > 0) Expanded(flex: b * 1000 ~/ total + 1, child: ColoredBox(color: bColor)),
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String text;

  const _Banner({required this.color, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return MeshCard(
      color: color.withValues(alpha: 0.10),
      borderColor: color.withValues(alpha: 0.45),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}
