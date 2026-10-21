// MeshCore Open TAK - Sound link: messages over sound, in Wavest's format
// (github.com/bennjordan/Wavest), with an optional bridge to a channel, and
// this phone's contact (or a channel) shared by sound.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../models/channel.dart';
import '../services/otp_pad_check.dart';
import '../utils/channel_qr.dart';
import 'ggwave_ffi.dart';
import 'sound_link.dart';
import 'wavest_format.dart';

class _Line {
  final WavestMessage m;
  final bool sent;
  final DateTime at;
  _Line(this.m, this.sent) : at = DateTime.now();
}

class SoundLinkScreen extends StatefulWidget {
  const SoundLinkScreen({super.key});

  @override
  State<SoundLinkScreen> createState() => _SoundLinkScreenState();
}

class _SoundLinkScreenState extends State<SoundLinkScreen> {
  static const _kCallsign = 'sound_callsign';
  static const _kPasskey = 'sound_passkey';
  static const _kProtocol = 'sound_protocol';
  static const _kVolume = 'sound_volume';
  static const _kForward = 'sound_forward_channel';
  static const _kPlayChannel = 'sound_play_channel';

  final _text = TextEditingController();
  final _callsign = TextEditingController();
  final _passkey = TextEditingController();
  final _lines = <_Line>[];
  GgwaveProtocol _protocol = GgwaveProtocol.audibleFast;
  int _volume = 60;
  int? _forwardTo; // channel index heard messages are posted to
  bool _playChannel = false; // that channel's new messages are played
  bool _listening = false;
  bool _sending = false;
  String? _error;
  StreamSubscription<String>? _sub;
  MeshCoreConnector? _connector;
  int _seen = -1; // messages already in the bridged channel
  final _queue = <String>[]; // channel messages waiting to be played

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    final c = context.read<MeshCoreConnector>();
    setState(() {
      _callsign.text = p.getString(_kCallsign) ?? wavestCallsign(c.selfName ?? 'Mesh');
      _passkey.text = p.getString(_kPasskey) ?? '';
      _protocol = GgwaveProtocol.values[(p.getInt(_kProtocol) ?? 1).clamp(0, 5)];
      _volume = p.getInt(_kVolume) ?? 60;
      _forwardTo = p.getInt(_kForward);
      _playChannel = p.getBool(_kPlayChannel) ?? false;
    });
    _connector = c..addListener(_onConnector);
    _onConnector();
    await _setListening(true);
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kCallsign, _callsign.text);
    await p.setString(_kPasskey, _passkey.text);
    await p.setInt(_kProtocol, _protocol.index);
    await p.setInt(_kVolume, _volume);
    if (_forwardTo == null) {
      await p.remove(_kForward);
    } else {
      await p.setInt(_kForward, _forwardTo!);
    }
    await p.setBool(_kPlayChannel, _playChannel);
  }

  @override
  void dispose() {
    _connector?.removeListener(_onConnector);
    unawaited(_sub?.cancel());
    unawaited(SoundLink.instance.stopListening());
    _text.dispose();
    _callsign.dispose();
    _passkey.dispose();
    super.dispose();
  }

  Channel? get _bridged {
    final c = _connector;
    final i = _forwardTo;
    if (c == null || i == null) return null;
    for (final ch in c.channels) {
      if (ch.index == i) return ch;
    }
    return null;
  }

  // ---- hearing -------------------------------------------------------------

  Future<void> _setListening(bool on) async {
    if (on == _listening) return;
    if (!on) {
      await _sub?.cancel();
      _sub = null;
      await SoundLink.instance.stopListening();
      if (mounted) setState(() => _listening = false);
      return;
    }
    try {
      final s = await SoundLink.instance.listen();
      _sub = s.listen((h) => unawaited(_onHeard(h)));
      if (mounted) {
        setState(() {
          _listening = true;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _onHeard(String heard) async {
    final check = parsePadCheck(heard);
    if (check != null) {
      if (!mounted) return;
      // An OTP pad's check code: say whether a pad here is the same one.
      final l10n = context.l10n;
      final result = _comparePadCheck(check, l10n);
      setState(
        () => _lines.insert(
          0,
          _Line(
            WavestMessage(sender: l10n.otpCheck_heard, text: result, raw: true),
            false,
          ),
        ),
      );
      return;
    }
    final m = await wavestParse(heard, passkey: _passkey.text);
    if (!mounted) return;
    setState(() => _lines.insert(0, _Line(m, false)));
    // Bridge: post what was heard to the channel (readable messages only).
    final ch = _bridged;
    final c = _connector;
    if (ch != null && c != null && !m.raw && m.readable && m.text.isNotEmpty) {
      await c.sendChannelMessage(ch, '$_bridgeTag ${m.sender}: ${m.text}');
    }
  }

  String _comparePadCheck(PadCheck check, AppLocalizations l10n) {
    final c = _connector;
    if (c == null) return l10n.otpCheck_noMatch;
    if (c.otpLocked) return l10n.otpCheck_locked;
    for (final contact in c.contacts) {
      final pad = c.getContactOtpPad(contact.publicKeyHex);
      if (pad != null && padCheckOfHex(pad.padHex).sameAs(check)) {
        return l10n.otpCheck_matches(contact.name);
      }
    }
    for (final channel in c.channels) {
      final pad = c.getChannelOtpPad(channel.index);
      if (pad != null && padCheckOfHex(pad.padHex).sameAs(check)) {
        return l10n.otpCheck_matches(channel.name);
      }
    }
    return l10n.otpCheck_noMatch;
  }

  // ---- sending -------------------------------------------------------------

  Future<void> _send(String text, {bool raw = false}) async {
    if (text.trim().isEmpty || _sending) return;
    final payload = raw
        ? text
        : await wavestBuild(_callsign.text, text, passkey: _passkey.text);
    if (!mounted) return;
    if (!await wavestFits(_callsign.text, raw ? '' : text, passkey: _passkey.text) ||
        payload.length > wavestMaxBytes) {
      setState(() => _error = context.l10n.sound_tooLong);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await SoundLink.instance.play(payload, protocol: _protocol, volume: _volume);
      if (!mounted) return;
      setState(() {
        _lines.insert(
          0,
          _Line(
            raw
                ? WavestMessage(sender: '', text: text, raw: true)
                : WavestMessage(
                    sender: wavestCallsign(_callsign.text),
                    text: text,
                    encrypted: _passkey.text.isNotEmpty,
                  ),
            true,
          ),
        );
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    unawaited(_drainQueue());
  }

  // ---- the bridge: channel messages played as sound -------------------------

  static const _bridgeTag = '[Wavest]';

  void _onConnector() {
    final ch = _bridged;
    final c = _connector;
    if (ch == null || c == null) {
      _seen = -1;
      return;
    }
    final msgs = c.getChannelMessages(ch);
    if (_seen < 0 || _seen > msgs.length) {
      _seen = msgs.length; // only what arrives from now on
      return;
    }
    for (var i = _seen; i < msgs.length; i++) {
      final m = msgs[i];
      // Not our own, and not what this bridge posted (no echo).
      if (!_playChannel || m.isOutgoing || m.text.startsWith(_bridgeTag)) continue;
      var t = m.text.trim();
      while (t.isNotEmpty && !_fitsSync(m.senderName, t)) {
        t = t.substring(0, t.length - 1);
      }
      if (t.isNotEmpty) _queue.add('${m.senderName}\u0000$t');
    }
    _seen = msgs.length;
    unawaited(_drainQueue());
  }

  bool _fitsSync(String sender, String text) =>
      'U:${wavestCallsign(sender)}|$text'.length <= wavestMaxBytes;

  Future<void> _drainQueue() async {
    if (_sending || _queue.isEmpty || !mounted) return;
    final item = _queue.removeAt(0);
    final cut = item.indexOf('\u0000');
    final sender = item.substring(0, cut), text = item.substring(cut + 1);
    final payload = await wavestBuild(sender, text);   // plain: it came off the mesh as plain text
    if (!mounted) return;
    setState(() => _sending = true);
    try {
      await SoundLink.instance.play(payload, protocol: _protocol, volume: _volume);
      if (mounted) {
        setState(() => _lines.insert(
          0,
          _Line(WavestMessage(sender: wavestCallsign(sender), text: text), true),
        ));
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    unawaited(_drainQueue());
  }

  // ---- sharing -------------------------------------------------------------

  String? _myContactLink() {
    final c = _connector;
    final key = c?.selfPublicKeyHex ?? '';
    if (c == null || key.length != 64) return null;
    return Uri(
      scheme: 'meshcore',
      host: 'contact',
      path: '/add',
      queryParameters: {'name': c.selfName ?? '', 'public_key': key, 'type': '1'},
    ).toString();
  }

  Future<void> _shareChannel() async {
    final c = _connector;
    if (c == null) return;
    final chans = [for (final ch in c.channels) if (!ch.isEmpty) ch];
    final picked = await showModalBottomSheet<Channel>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        children: [
          for (final ch in chans)
            ListTile(
              leading: const Icon(Icons.tag),
              title: Text(ch.name),
              onTap: () => Navigator.pop(ctx, ch),
            ),
        ],
      ),
    );
    if (picked == null) return;
    final link = channelShareLink(picked.name, picked.pskHex);
    if (link != null) await _send(link, raw: true);
  }

  // ---- UI ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final connector = context.watch<MeshCoreConnector>();
    if (!SoundLink.instance.available) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.sound_title)),
        body: Center(child: Text(l10n.sound_unavailable)),
      );
    }
    final chans = [for (final ch in connector.channels) if (!ch.isEmpty) ch];
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.sound_title),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(
              children: [
                Icon(
                  Icons.hearing,
                  size: 18,
                  color: _listening ? theme.colorScheme.primary : theme.disabledColor,
                ),
                Switch(
                  value: _listening,
                  onChanged: (v) => unawaited(_setListening(v)),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Text(l10n.sound_intro, style: theme.textTheme.bodySmall),
                const SizedBox(height: 8),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(l10n.sound_settings),
                  children: [
                    TextField(
                      controller: _callsign,
                      decoration: InputDecoration(labelText: l10n.sound_callsign),
                      onChanged: (_) => unawaited(_save()),
                    ),
                    TextField(
                      controller: _passkey,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: l10n.sound_passkey,
                        helperText: l10n.sound_passkeyHelp,
                        helperMaxLines: 3,
                      ),
                      onChanged: (_) => unawaited(_save()),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<GgwaveProtocol>(
                      key: ValueKey(_protocol),
                      initialValue: _protocol,
                      decoration: InputDecoration(labelText: l10n.sound_mode),
                      items: [
                        for (final p in GgwaveProtocol.values)
                          DropdownMenuItem(value: p, child: Text(_protocolName(context, p))),
                      ],
                      onChanged: (p) {
                        if (p == null) return;
                        setState(() => _protocol = p);
                        unawaited(_save());
                      },
                    ),
                    Row(
                      children: [
                        Text(l10n.sound_volume),
                        Expanded(
                          child: Slider(
                            value: _volume.toDouble(),
                            min: 10,
                            max: 100,
                            divisions: 9,
                            label: '$_volume',
                            onChanged: (v) => setState(() => _volume = v.round()),
                            onChangeEnd: (_) => unawaited(_save()),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(l10n.sound_bridge),
                  subtitle: Text(
                    _bridged == null ? l10n.sound_bridgeOff : '#${_bridged!.name}',
                  ),
                  children: [
                    DropdownButtonFormField<int?>(
                      key: ValueKey(_forwardTo),
                      initialValue: _forwardTo,
                      decoration: InputDecoration(labelText: l10n.sound_bridgeChannel),
                      items: [
                        DropdownMenuItem<int?>(value: null, child: Text(l10n.sound_bridgeOff)),
                        for (final ch in chans)
                          DropdownMenuItem<int?>(value: ch.index, child: Text(ch.name)),
                      ],
                      onChanged: (i) {
                        setState(() {
                          _forwardTo = i;
                          _seen = -1;
                        });
                        _onConnector();
                        unawaited(_save());
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10n.sound_bridgePlay),
                      subtitle: Text(l10n.sound_bridgeHelp),
                      value: _playChannel,
                      onChanged: _forwardTo == null
                          ? null
                          : (v) {
                              setState(() => _playChannel = v);
                              unawaited(_save());
                            },
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _sending || _myContactLink() == null
                          ? null
                          : () => unawaited(_send(_myContactLink()!, raw: true)),
                      icon: const Icon(Icons.person),
                      label: Text(l10n.sound_shareContact),
                    ),
                    OutlinedButton.icon(
                      onPressed: _sending ? null : () => unawaited(_shareChannel()),
                      icon: const Icon(Icons.tag),
                      label: Text(l10n.sound_shareChannel),
                    ),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                  ),
                const Divider(),
                for (final l in _lines) _lineTile(context, l),
                if (_lines.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _listening ? l10n.sound_listeningHelp : l10n.sound_notListening,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _text,
                      maxLength: 120,
                      decoration: InputDecoration(
                        hintText: l10n.sound_messageHint,
                        counterText: '',
                      ),
                      onSubmitted: (t) {
                        unawaited(_send(t));
                        _text.clear();
                      },
                    ),
                  ),
                  IconButton(
                    icon: _sending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.graphic_eq),
                    tooltip: l10n.sound_send,
                    onPressed: _sending
                        ? null
                        : () {
                            unawaited(_send(_text.text));
                            _text.clear();
                          },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _lineTile(BuildContext context, _Line l) {
    final theme = Theme.of(context);
    final m = l.m;
    final who = m.raw ? context.l10n.sound_heardRaw : m.sender;
    final link = m.raw && m.text.startsWith('meshcore://');
    return ListTile(
      dense: true,
      leading: Icon(
        l.sent ? Icons.north_east : Icons.south_west,
        size: 18,
        color: l.sent ? theme.colorScheme.primary : theme.colorScheme.tertiary,
      ),
      title: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: who, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (m.encrypted) const WidgetSpan(child: Icon(Icons.lock, size: 14)),
          ],
        ),
      ),
      subtitle: Text(
        m.readable ? m.text : context.l10n.sound_locked,
        style: link ? theme.textTheme.bodySmall : null,
      ),
      trailing: link
          ? Tooltip(
              message: context.l10n.sound_linkHint,
              child: const Icon(Icons.info_outline, size: 18),
            )
          : null,
    );
  }

  String _protocolName(BuildContext context, GgwaveProtocol p) {
    final l10n = context.l10n;
    return switch (p) {
      GgwaveProtocol.audibleNormal => l10n.sound_modeAudibleNormal,
      GgwaveProtocol.audibleFast => l10n.sound_modeAudibleFast,
      GgwaveProtocol.audibleFastest => l10n.sound_modeAudibleFastest,
      GgwaveProtocol.ultrasoundNormal => l10n.sound_modeUltraNormal,
      GgwaveProtocol.ultrasoundFast => l10n.sound_modeUltraFast,
      GgwaveProtocol.ultrasoundFastest => l10n.sound_modeUltraFastest,
    };
  }
}
