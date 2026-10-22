// MeshCore Open TAK - full-screen alarm when a teammate raises an alert.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import 'quick_reply_ui.dart';
import 'team_service.dart';
import 'team_wire.dart';

/// Wrap the app with this (MaterialApp.builder). It covers the screen with
/// an alarm while any teammate alert is unacknowledged.
class TeamAlertHost extends StatefulWidget {
  final Widget child;
  const TeamAlertHost({super.key, required this.child});

  @override
  State<TeamAlertHost> createState() => _TeamAlertHostState();
}

class _TeamAlertHostState extends State<TeamAlertHost> {
  AudioPlayer? _player;
  bool _sounding = false;
  Timer? _buzz;

  static Uint8List _alarmWav() {
    const rate = 16000;
    const seconds = 1;
    final n = rate * seconds;
    final data = ByteData(44 + n * 2);
    void str(int o, String s) {
      for (var i = 0; i < s.length; i++) {
        data.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    data.setUint32(4, 36 + n * 2, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, rate, Endian.little);
    data.setUint32(28, rate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    str(36, 'data');
    data.setUint32(40, n * 2, Endian.little);
    for (var i = 0; i < n; i++) {
      // Two-tone siren: 960 Hz / 720 Hz, alternating every 250 ms.
      final f = (i ~/ (rate ~/ 4)).isEven ? 960.0 : 720.0;
      final v = (sin(2 * pi * f * i / rate) * 0.6 * 32767).round();
      data.setInt16(44 + i * 2, v, Endian.little);
    }
    return data.buffer.asUint8List();
  }

  Future<void> _sound(bool on) async {
    if (on == _sounding) return;
    _sounding = on;
    if (on) {
      final p = _player ??= AudioPlayer();
      await p.setReleaseMode(ReleaseMode.loop);
      await p.play(BytesSource(_alarmWav()));
      _buzz = Timer.periodic(
        const Duration(milliseconds: 800),
        (_) => HapticFeedback.heavyImpact(),
      );
    } else {
      _buzz?.cancel();
      await _player?.stop();
    }
  }

  @override
  void dispose() {
    _buzz?.cancel();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final team = context.watch<TeamService>();
    final alerts = team.unacknowledgedAlerts;
    unawaited(_sound(alerts.isNotEmpty));
    if (alerts.isEmpty) return widget.child;
    final a = alerts.first;
    final fix = team.fix;
    final where = a.lat == null
        ? 'No position sent'
        : fix == null
        ? '${a.lat!.toStringAsFixed(5)}, ${a.lon!.toStringAsFixed(5)}'
        : teamRangeBearing(
            teamDistanceMeters(fix.lat, fix.lon, a.lat!, a.lon!),
            teamBearingDeg(fix.lat, fix.lon, a.lat!, a.lon!),
          );
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: Material(
            color: const Color(0xF0B71C1C),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.sos, color: Colors.white, size: 96),
                    const SizedBox(height: 12),
                    Text(
                      a.type.label.toUpperCase(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 34,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      a.callsign.isEmpty
                          ? a.senderKey4.toUpperCase()
                          : a.callsign,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 26),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      where,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 20),
                    ),
                    if (a.note.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        a.note,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 18,
                        ),
                      ),
                    ],
                    if (alerts.length > 1)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '+${alerts.length - 1} more alert${alerts.length > 2 ? 's' : ''}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                    const SizedBox(height: 24),
                    // One tap answers the teammate and silences the alarm.
                    Text(
                      context.l10n.quickReply_answerAlert,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: QuickReplyChips(
                        codes: teamAlertReplies,
                        onColor: true,
                        onPick: (code, arg) {
                          unawaited(
                            team.sendReply(
                              ref: TeamReplyRef.alert,
                              toKey4: a.senderKey4,
                              refId: a.alertId,
                              code: code,
                              arg: arg,
                            ),
                          );
                          team.acknowledge(a);
                        },
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (a.lat != null)
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.red.shade900,
                          padding: const EdgeInsets.all(16),
                        ),
                        icon: const Icon(Icons.track_changes),
                        label: const Text('Acknowledge and track (Bloodhound)'),
                        onPressed: () {
                          team.houndPoint(
                            a.lat!,
                            a.lon!,
                            '${a.type.label} ${a.callsign}',
                          );
                          team.acknowledge(a);
                        },
                      ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white),
                        padding: const EdgeInsets.all(16),
                      ),
                      onPressed: () => team.acknowledge(a),
                      child: const Text('Acknowledge'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
