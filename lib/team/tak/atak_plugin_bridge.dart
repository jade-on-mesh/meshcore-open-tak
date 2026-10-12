// MeshCore Open TAK - bridge for the ATAK plugin (atak-plugin/).
//
// The plugin runs inside ATAK and binds to TakBridgeService (Android), the
// way Meshtastic's ATAK plugin binds to the Meshtastic app. That service
// relays over the 'meshcore/tak_bridge' method channel to this class, which
// lets the plugin use this app's radio connection, team identity and voice
// and photo codecs:
//
//   plugin -> app : send channel data/text/DMs, send team items, publish the
//                   ATAK user's identity and fix, voice/photo send and fetch
//   app -> plugin : radio state, team payloads (heard and own), team-channel
//                   text, DMs, clip progress, decoded audio and pictures
//
// Message shapes are mirrored in TakBridgeService.kt and the plugin's
// BridgeProtocol.java.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../connector/meshcore_connector.dart';
import '../../connector/meshcore_protocol.dart';
import '../../models/channel.dart';
import '../../models/channel_message.dart';
import '../../models/contact.dart';
import '../../vox/image_codec.dart';
import '../../vox/image_message_bubble.dart' show voxRgbToUiImage;
import '../../vox/image_send_sheet.dart' show voxLoadReference;
import '../../vox/voice_codec.dart';
import '../../vox/voice_service.dart';
import '../../vox/voice_wire.dart';
import '../team_service.dart';
import '../team_wire.dart';

class AtakPluginBridge {
  AtakPluginBridge(this._connector, this._team, this._voice) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _channel.setMethodCallHandler(_onCall);
    _connector.addListener(_stateSoon);
    _team.addListener(_stateSoon);
    _voice.addListener(_onVoiceChanged);
    _frames = _connector.receivedFrames.listen(_onFrame);
    _team.onTeamPayload = _onTeamPayload;
    unawaited(_loadEnabled());
  }

  /// Setting key; TakBridgeService.kt reads the same Flutter preference.
  static const String enabledKey = 'atak_bridge_enabled';

  static const _channel = MethodChannel('meshcore/tak_bridge');

  final MeshCoreConnector _connector;
  final TeamService _team;
  final VoxVoiceService _voice;
  StreamSubscription<Uint8List>? _frames;

  bool _enabled = true;
  bool _clients = false;
  Timer? _stateTimer;
  final Map<String, VoxVoiceEnvelope> _tracked = {};
  final Map<String, String> _lastClipState = {};

  bool get enabled => _enabled;

  Future<void> _loadEnabled() async {
    try {
      final p = await SharedPreferences.getInstance();
      _enabled = p.getBool(enabledKey) ?? true;
    } catch (_) {}
  }

  Future<void> setEnabled(bool v) async {
    _enabled = v;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(enabledKey, v);
    } catch (_) {}
    _stateSoon();
  }

  Future<void> _invoke(String method, Map<String, Object?> args) async {
    if (!_clients || !_enabled) return;
    try {
      await _channel.invokeMethod<void>(method, args);
    } catch (e) {
      debugPrint('ATAK bridge $method failed: $e');
    }
  }

  // ------------------------------------------------------------- state

  void _stateSoon() {
    if (!_clients) return;
    _stateTimer ??= Timer(const Duration(milliseconds: 300), () {
      _stateTimer = null;
      unawaited(_pushState());
    });
  }

  Future<void> _pushState() async {
    final key = _connector.selfPublicKey;
    final chs = _connector.channels.where((c) => c.name.isNotEmpty).toList();
    final contacts = _connector.contacts;
    final keys = BytesBuilder();
    for (final c in contacts) {
      keys.add(c.publicKey);
    }
    await _invoke('state', {
      'connected': _connector.isConnected && key != null,
      'detail': _connector.isConnected
          ? (_team.teamChannel == null ? 'No team channel in the app' : '')
          : 'MeshCore Open TAK is not connected to a radio',
      'selfKey': key,
      'selfName': _connector.selfName ?? '',
      'sf': _connector.currentSf ?? 0,
      'bw': _connector.currentBwHz ?? 0,
      'cr': _connector.currentCr ?? 0,
      'channelData': _connector.supportsChannelData,
      'teamChannel': _team.teamChannel?.index ?? -1,
      'appOwnsTeam': _team.enabled && _team.sharePosition,
      'chIndex': Int32List.fromList([for (final c in chs) c.index]),
      'chName': [for (final c in chs) c.name],
      'chPrivate': [for (final c in chs) c.isPrivateChannel],
      'cKeys': keys.toBytes(),
      'cNames': [for (final c in contacts) c.name],
      'cPath': Int32List.fromList([for (final c in contacts) c.pathLength]),
      'cType': Int32List.fromList([for (final c in contacts) c.type]),
      'mimi': _voice.mimi.isReady,
      'av1': _voice.imagesAvailable,
      'codec2': voxCodecAvailable,
    });
  }

  // ------------------------------------------------------- app -> plugin

  void _onTeamPayload(Uint8List payload, bool own) {
    unawaited(_invoke('teamPayload', {'payload': payload, 'own': own}));
  }

  void _onFrame(Uint8List frame) {
    if (!_clients || frame.isEmpty) return;
    final code = frame[0];
    if (code == respCodeChannelMsgRecv || code == respCodeChannelMsgRecvV3) {
      final m = ChannelMessage.fromFrame(frame);
      if (m == null || m.channelIndex == null) return;
      unawaited(
        _invoke('channelText', {
          'ch': m.channelIndex,
          'sender': m.senderName,
          'text': m.text,
          'ts': m.timestamp.millisecondsSinceEpoch ~/ 1000,
          'hops': m.pathLength ?? -1,
        }),
      );
    } else if (code == respCodeContactMsgRecv ||
        code == respCodeContactMsgRecvV3) {
      final m = parseContactMessageText(frame);
      if (m == null || VoxVoiceTextRequest.looksLikeRequest(m.text)) return;
      unawaited(
        _invoke('directText', {
          'sender': pubKeyToHex(m.senderPrefix),
          'text': m.text,
          'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        }),
      );
    }
  }

  void _onVoiceChanged() {
    if (!_clients) return;
    for (final env in _tracked.values) {
      final st = _voice.stateFor(env);
      final status = switch (st.status) {
        VoxClipStatus.remote => 'IDLE',
        VoxClipStatus.requesting => 'REQUESTING',
        VoxClipStatus.receiving => 'RECEIVING',
        VoxClipStatus.complete => 'COMPLETE',
        VoxClipStatus.unavailable => 'UNAVAILABLE',
      };
      final sig = '$status/${st.received}/${st.message}';
      if (_lastClipState[env.sessionId] == sig) continue;
      _lastClipState[env.sessionId] = sig;
      unawaited(
        _invoke('mediaState', {
          'sid': env.sessionId,
          'status': status,
          'have': st.received,
          'total': st.total,
          'msg': st.message,
        }),
      );
    }
  }

  // ------------------------------------------------------- plugin -> app

  Future<Object?> _onCall(MethodCall call) async {
    final a = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
    if (call.method == 'hello') {
      _clients = true;
      await _pushState();
      return true;
    }
    if (call.method == 'bye') {
      _clients = false;
      return true;
    }
    if (!_enabled) {
      return {
        'ok': false,
        'msg': 'The ATAK bridge is off in MeshCore Open TAK',
      };
    }
    try {
      switch (call.method) {
        case 'sendChannelData':
          final ok = await _connector.sendChannelDataBlobs(
            _blobs(a['blobs']),
            channelIndex: a['ch']! as int,
            dataType: a['type']! as int,
            interChunkDelay: Duration(milliseconds: (a['gap'] as int?) ?? 0),
          );
          return {'ok': ok, 'msg': ok ? null : 'Send failed'};
        case 'sendChannelText':
          final ch = _channelByIndex(a['ch']! as int);
          if (ch == null) return {'ok': false, 'msg': 'No such channel'};
          await _connector.sendChannelMessage(ch, a['text']! as String);
          return {'ok': true};
        case 'sendDirectText':
          final c = _contactByKey(a['key']! as Uint8List);
          if (c == null) {
            return {'ok': false, 'msg': 'Not in the radio contacts'};
          }
          await _connector.sendMessage(c, a['text']! as String);
          return {'ok': true};
        case 'sendTeam':
          final ok = await _team.sendExternal(
            _blobs(a['blobs']),
            Duration(milliseconds: (a['gap'] as int?) ?? 0),
          );
          return {
            'ok': ok,
            'msg': ok ? null : 'No team channel or send failed',
          };
        case 'publishSelf':
          final p = TeamPosition.tryParse(a['payload']! as Uint8List);
          if (p != null) _team.setAtakIdentity(p);
          return {'ok': true};
        case 'refreshContacts':
          await _connector.refreshContacts();
          return {'ok': true};
        case 'mediaSend':
        case 'mediaRegister':
          return await _mediaSend(a, register: call.method == 'mediaRegister');
        case 'mediaFetch':
          final env = VoxVoiceEnvelope.tryParse(a['env']! as String);
          if (env == null) return {'ok': false, 'msg': 'Bad envelope'};
          _tracked[env.sessionId] = env;
          final sender = a['sender'] as String?;
          final ch = (a['ch'] as int?) ?? -1;
          unawaited(
            _voice.requestClip(
              env,
              sender: sender == null ? null : _voice.contactByKeyPrefix(sender),
              channelIndex: ch >= 0 ? ch : null,
            ),
          );
          _onVoiceChanged();
          return {'ok': true};
        case 'mediaGet':
          return await _mediaGet(a);
      }
    } catch (e) {
      return {'ok': false, 'msg': '$e'};
    }
    return {'ok': false, 'msg': 'Unknown request ${call.method}'};
  }

  static List<Uint8List> _blobs(Object? packed) {
    final out = <Uint8List>[];
    final b = packed is Uint8List ? packed : Uint8List(0);
    var i = 0;
    while (i < b.length) {
      final n = b[i++];
      if (i + n > b.length) break;
      out.add(Uint8List.fromList(b.sublist(i, i + n)));
      i += n;
    }
    return out;
  }

  Channel? _channelByIndex(int i) {
    for (final c in _connector.channels) {
      if (c.index == i) return c;
    }
    return null;
  }

  Contact? _contactByKey(Uint8List key) {
    for (final c in _connector.contacts) {
      if (listEquals(c.publicKey, key)) return c;
    }
    return null;
  }

  Future<Map<String, Object?>> _mediaSend(
    Map<String, Object?> a, {
    required bool register,
  }) async {
    final bytes = a['bytes']! as Uint8List;
    final kind = a['kind'] as String? ?? '';
    final VoxEncodedClip clip;
    if (kind == 'pcm16') {
      final pcm = Int16List(bytes.length ~/ 2);
      final bd = ByteData.sublistView(bytes);
      for (var i = 0; i < pcm.length; i++) {
        pcm[i] = bd.getInt16(i * 2, Endian.little);
      }
      clip = await _voice.encodeRecording(pcm);
    } else {
      if (!_voice.imagesAvailable) {
        return {'ok': false, 'msg': 'This app build has no AV1 encoder'};
      }
      final ref = await voxLoadReference(bytes);
      final img = await _voice.encodeImage(
        ref,
        ((a['detailLevel'] as int?) ?? 0) >= 1
            ? VoxImageDetail.more
            : VoxImageDetail.standard,
      );
      clip = _voice.imageClip(img);
    }
    final VoxVoiceEnvelope env;
    if (register) {
      env = _voice.registerClip(clip);
    } else if (a['key'] is Uint8List) {
      final c = _contactByKey(a['key']! as Uint8List);
      if (c == null) return {'ok': false, 'msg': 'Not in the radio contacts'};
      env = await _voice.sendClipToContact(c, clip);
    } else {
      final ch = _channelByIndex((a['ch'] as int?) ?? -1);
      if (ch == null) return {'ok': false, 'msg': 'No such channel'};
      env = await _voice.sendClipToChannel(ch, clip);
    }
    unawaited(_invoke('mediaRegistered', {'id': a['id'], 'env': env.encode()}));
    return {'ok': true, 'registered': true};
  }

  Future<Map<String, Object?>> _mediaGet(Map<String, Object?> a) async {
    final env = VoxVoiceEnvelope.tryParse(a['env']! as String);
    final xfer = a['xfer'] as int? ?? 0;
    if (env == null) return {'ok': false, 'msg': 'Bad envelope'};
    Uint8List? data;
    var rate = 0;
    String? msg;
    if ((a['kind'] as String?) == 'pcm16') {
      final wav = await _voice.wavFor(env);
      if (wav == null) {
        msg = _voice.canPlay(env) ? 'Not downloaded yet' : 'Codec unavailable';
      } else {
        final (pcm, r) = _wavPcm(wav);
        data = pcm;
        rate = r;
      }
    } else {
      final rgb = await _voice.imageFor(env);
      if (rgb == null) {
        msg = 'Picture not available';
      } else {
        final img = await voxRgbToUiImage(rgb);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        img.dispose();
        data = png?.buffer.asUint8List();
      }
    }
    unawaited(
      _invoke('mediaData', {
        'xfer': xfer,
        'ok': data != null,
        'bytes': data ?? Uint8List(0),
        'rate': rate,
        'msg': msg,
      }),
    );
    return {'ok': true};
  }

  /// PCM16 samples and sample rate from a WAV file.
  static (Uint8List, int) _wavPcm(Uint8List wav) {
    final bd = ByteData.sublistView(wav);
    var rate = 8000;
    var i = 12;
    while (i + 8 <= wav.length) {
      final id = String.fromCharCodes(wav.sublist(i, i + 4));
      final size = bd.getUint32(i + 4, Endian.little);
      if (id == 'fmt ') rate = bd.getUint32(i + 12, Endian.little);
      if (id == 'data') {
        final end = (i + 8 + size).clamp(0, wav.length);
        return (Uint8List.fromList(wav.sublist(i + 8, end)), rate);
      }
      i += 8 + size + (size & 1);
    }
    return (Uint8List(0), rate);
  }

  void dispose() {
    _stateTimer?.cancel();
    unawaited(_frames?.cancel());
    _connector.removeListener(_stateSoon);
    _team.removeListener(_stateSoon);
    _voice.removeListener(_onVoiceChanged);
    if (_team.onTeamPayload == _onTeamPayload) _team.onTeamPayload = null;
  }
}
