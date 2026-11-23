// MeshCore Open TAK - logging in to a repeater or room server, shared by the
// repeater and room login dialogs.
//
// Why logins failed even with the repeater on the desk:
// - The route was picked once and every retry used it. A stored multi-hop
//   path (from an advert heard through other repeaters, or route history)
//   never reaches a repeater in direct range, so all five attempts failed.
//   Now, when the first attempt on a stored path gets no answer, the path is
//   reset and the rest go out as floods, which reach it directly and teach
//   the radio a fresh path from its answer (as a reset path does anywhere).
//   A path the user set by hand is kept.
// - The wait came from the message-timeout estimate, which for zero hops can
//   be ~2.5 s. A login reply waits on the repeater checking the password and
//   its random relay delay, and a radio that also listens on radio2 can be
//   away for part of that. Each wait is now at least 8 s direct, 15 s flood.
// - Each attempt only listened while it waited, so an answer to an earlier
//   attempt that came late was dropped. One listener now covers the login.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../models/contact.dart';
import '../models/path_selection.dart';
import '../utils/app_logger.dart';

/// The least a login attempt waits for its answer (see the file comment).
const Duration nodeLoginMinWaitDirect = Duration(seconds: 8);
const Duration nodeLoginMinWaitFlood = Duration(seconds: 15);

/// How a login ended. [result] is true (logged in), false (refused: wrong
/// password) or null (no answer to any attempt). [selection] is the route
/// the last attempt used.
typedef NodeLoginOutcome = ({
  bool? result,
  bool isAdmin,
  PathSelection selection,
});

/// The wait for one attempt on [selection]: the timeout estimate plus 2 s,
/// never under [nodeLoginMinWaitDirect] / [nodeLoginMinWaitFlood].
Duration nodeLoginWait(int estimateMs, {required bool flood}) {
  final wait = Duration(milliseconds: estimateMs + 2000);
  final floor = flood ? nodeLoginMinWaitFlood : nodeLoginMinWaitDirect;
  return wait < floor ? floor : wait;
}

/// Whether attempt [attempt] (0-based) should give up the stored path and
/// flood: from the second attempt, when the first went on a stored path the
/// user didn't set by hand.
bool nodeLoginFloodsAttempt(
  int attempt, {
  required PathSelection first,
  required bool pathSetByHand,
}) => attempt >= 1 && !first.useFlood && !pathSetByHand;

/// Logs in to [node] with [password]: up to [maxAttempts] sends, the first on
/// the chosen route, then floods if that one got no answer. [onAttempt] is
/// told each attempt's number (1-based) as it goes out; [tag] names the log.
Future<NodeLoginOutcome> loginToNode({
  required MeshCoreConnector connector,
  required Contact node,
  required String password,
  int maxAttempts = 5,
  void Function(int attempt)? onAttempt,
  required String tag,
}) async {
  final first = await connector.preparePathForContactSend(node);
  final frame = buildSendLoginFrame(node.publicKey, password);
  final responseBytes = frame.length > maxFrameSize
      ? frame.length
      : maxFrameSize;
  final prefix = node.publicKey.sublist(0, 6);
  final pathSetByHand = node.pathOverride != null;

  // One listener for the whole login: a late answer to any attempt counts.
  bool? result;
  var isAdmin = false;
  Completer<void>? answered;
  final sub = connector.receivedFrames.listen((f) {
    if (f.length < 8) return;
    final code = f[0];
    if (code != pushCodeLoginSuccess && code != pushCodeLoginFail) return;
    if (!listEquals(f.sublist(2, 8), prefix)) return;
    // The repeater firmware only ever sends 1 or 0 here, not the permissions.
    isAdmin = f[1] == 1;
    result = code == pushCodeLoginSuccess;
    if (answered != null && !answered!.isCompleted) answered!.complete();
  });

  var selection = first;
  try {
    for (var attempt = 0; attempt < maxAttempts && result == null; attempt++) {
      if (nodeLoginFloodsAttempt(
            attempt,
            first: first,
            pathSetByHand: pathSetByHand,
          ) &&
          !selection.useFlood) {
        appLogger.warn(
          'No answer on the stored ${first.hopCount}-hop path; resetting it '
          'and flooding',
          tag: tag,
        );
        connector.recordRepeaterPathResult(node, first, false, null);
        await connector.clearContactPath(node);
        selection = const PathSelection(
          pathBytes: [],
          hopCount: -1,
          useFlood: true,
        );
      }
      final estimate = connector.calculateTimeout(
        pathLength: selection.useFlood ? -1 : selection.hopCount,
        messageBytes: responseBytes,
      );
      final wait = nodeLoginWait(estimate, flood: selection.useFlood);
      onAttempt?.call(attempt + 1);
      appLogger.info(
        'Sending login attempt ${attempt + 1}/$maxAttempts '
        '(${selection.useFlood ? 'flood' : '${selection.hopCount} hops'}, '
        'waiting ${wait.inSeconds}s)',
        tag: tag,
      );
      answered = Completer<void>();
      await connector.sendFrame(frame);
      if (result != null) break;
      await answered!.future.timeout(wait, onTimeout: () {});
      if (result == null) {
        appLogger.warn(
          'Login attempt ${attempt + 1} got no answer in ${wait.inSeconds}s',
          tag: tag,
        );
      }
    }
  } finally {
    await sub.cancel();
  }
  return (result: result, isAdmin: isAdmin, selection: selection);
}
