import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../models/companion_radio_stats.dart';
import 'radio_stats_entry.dart' show pushCompanionRadioStatsScreen;

/// Coarse RSSI-margin signal-quality grade ("excellent"/"good"/"fair"/
/// "poor"/"very poor"/"no data"), ported back by request to match the
/// grading the Lua apps use (OTP_2_RC16.lua's rssi_grade/sig_grade_for_
/// margin, carried into OTP_3_RC1.lua's signal_tick) - the same five
/// margin thresholds and the same fixed, theme-independent traffic-
/// light colors, so "good" means the same thing and looks the same
/// regardless of which app someone's looking at.
///
/// Margin here is simply the companion radio's own last-received-
/// packet RSSI minus its noise floor (CompanionRadioStats, from the
/// STATS_TYPE_RADIO frame) - "how well is my own radio hearing
/// anything right now." This is deliberately a different metric from
/// the existing SNRIndicator already in this app's app bar, which
/// grades SNR to one specific known direct repeater (a path-specific
/// signal, not a general one) - the two aren't meant to replace each
/// other, they answer different questions.
const int sigRed = 0xFFE74C3C;
const int sigOrange = 0xFFE67E22;
const int sigYellow = 0xFFF1C40F;
const int sigGreen = 0xFF2ECC71;
const int sigGreenBright = 0xFF39FF14;

class SignalGrade {
  final String label;
  final Color color;
  const SignalGrade(this.label, this.color);
}

/// The raw margin a single stats sample represents, or null when there's
/// no sample at all - split out from grading so the rolling averager
/// below (and any test) can work with plain numbers.
int? marginForStats(CompanionRadioStats? stats) {
  if (stats == null) return null;
  return stats.lastRssiDbm - stats.noiseFloorDbm;
}

/// Thresholds only - unchanged from the original port, and exactly
/// matching both Lua builds' sig_grade_for_margin.
SignalGrade gradeForMargin(num margin) {
  if (margin >= 20) return const SignalGrade('excellent', Color(sigGreenBright));
  if (margin >= 12) return const SignalGrade('good', Color(sigGreen));
  if (margin >= 6) return const SignalGrade('fair', Color(sigYellow));
  if (margin >= 0) return const SignalGrade('poor', Color(sigOrange));
  return const SignalGrade('very poor', Color(sigRed));
}

/// Grades a single sample in isolation, with no smoothing - kept as its
/// own function (unchanged signature) in case anything wants an
/// instantaneous reading, but no longer what the indicator widget below
/// actually displays - see SignalMarginAverager for why.
SignalGrade signalGradeForStats(CompanionRadioStats? stats) {
  final margin = marginForStats(stats);
  if (margin == null) return const SignalGrade('no data', Color(sigRed));
  return gradeForMargin(margin);
}

/// Smooths a running series of CompanionRadioStats samples into a rolling
/// average, mirroring Lua's own sig_history/SIGNAL_HISTORY_LEN exactly
/// (an 8-sample rolling average) - this indicator was ported with the
/// intent that "good" means the same thing on both platforms, but the
/// first version only carried over the five margin thresholds and
/// missed the averaging that makes that comparison fair in practice.
///
/// Without this, the indicator graded whatever the single most recent
/// BLE stats frame happened to report - and "most recent successfully
/// parsed frame" skews optimistic on its own (a frame that didn't arrive
/// cleanly just doesn't update anything, so the display can only ever
/// move towards whichever readings came through best), on top of one
/// single sample being far noisier than an 8-sample average to begin
/// with. Together, that's a plausible explanation for a phone
/// consistently showing "excellent" while every Lua node on the same
/// mesh reports "poor": Lua's reading was already an 8-sample average
/// the whole time, and this one wasn't.
class SignalMarginAverager {
  SignalMarginAverager({this.historyLen = 8});

  final int historyLen;
  final List<int> _history = [];
  CompanionRadioStats? _lastSeen;

  /// Drops the whole rolling window - call this on disconnect/reconnect
  /// so a new session (possibly a different companion radio entirely)
  /// never gets graded against samples left over from a previous one.
  void reset() {
    _history.clear();
    _lastSeen = null;
  }

  /// Feed the latest known stats (or null) and get back the grade for
  /// the current rolling average. Safe to call repeatedly with the same
  /// stats object (e.g. on every widget rebuild) - a sample already in
  /// the window is never counted twice.
  SignalGrade update(CompanionRadioStats? stats) {
    if (stats == null) {
      _history.clear();
      _lastSeen = null;
      return const SignalGrade('no data', Color(sigRed));
    }
    if (!identical(stats, _lastSeen)) {
      _lastSeen = stats;
      final margin = marginForStats(stats);
      if (margin != null) {
        _history.add(margin);
        if (_history.length > historyLen) {
          _history.removeAt(0);
        }
      }
    }
    if (_history.isEmpty) {
      return const SignalGrade('no data', Color(sigRed));
    }
    final avg = _history.reduce((a, b) => a + b) / _history.length;
    return gradeForMargin(avg);
  }
}

IconData iconForSignalGrade(String label) {
  switch (label) {
    case 'excellent':
      return Icons.signal_cellular_4_bar;
    case 'good':
      return Icons.signal_cellular_alt;
    case 'fair':
      return Icons.signal_cellular_alt_2_bar;
    case 'poor':
    case 'very poor':
      return Icons.signal_cellular_alt_1_bar;
    default:
      return Icons.signal_cellular_off;
  }
}

/// Small tappable "Signal: <grade>" readout for the chat/channel chat
/// app bars - taps through to the existing CompanionRadioStatsScreen
/// for the raw dBm numbers, same as RadioStatsIconButton right next to
/// it. Reuses the connector's existing ref-counted radio-stats polling
/// (acquireRadioStatsPolling/releaseRadioStatsPolling) - safe to mount
/// alongside RadioStatsIconButton, which already polls the same data.
class SignalGradeIndicator extends StatefulWidget {
  const SignalGradeIndicator({super.key});

  @override
  State<SignalGradeIndicator> createState() => _SignalGradeIndicatorState();
}

class _SignalGradeIndicatorState extends State<SignalGradeIndicator> {
  MeshCoreConnector? _connector;
  // Same 8-sample rolling average Lua's sig_history uses - see
  // SignalMarginAverager's own comment for why this matters here.
  final _averager = SignalMarginAverager();

  @override
  void initState() {
    super.initState();
    final c = context.read<MeshCoreConnector>();
    _connector = c;
    c.acquireRadioStatsPolling();
  }

  @override
  void dispose() {
    _connector?.releaseRadioStatsPolling();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Selector<MeshCoreConnector, ({bool connected, bool supported})>(
      selector: (_, c) =>
          (connected: c.isConnected, supported: c.supportsCompanionRadioStats),
      builder: (context, state, _) {
        if (!state.connected || !state.supported) {
          // A stale rolling average from a previous connection (or a
          // previous companion radio entirely) must never leak into a
          // later session's reading.
          _averager.reset();
          return const SizedBox.shrink();
        }
        final connector = context.read<MeshCoreConnector>();
        return ValueListenableBuilder<CompanionRadioStats?>(
          valueListenable: connector.radioStatsNotifier,
          builder: (context, stats, _) {
            final grade = _averager.update(stats);
            return Tooltip(
              message: 'Signal: ${grade.label}',
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => pushCompanionRadioStatsScreen(context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 12,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        iconForSignalGrade(grade.label),
                        size: 16,
                        color: grade.color,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        grade.label,
                        style: TextStyle(fontSize: 10, color: grade.color),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
