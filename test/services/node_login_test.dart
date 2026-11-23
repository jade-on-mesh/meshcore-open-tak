import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/path_selection.dart';
import 'package:meshcore_open/services/node_login.dart';

const direct = PathSelection(pathBytes: [], hopCount: 0, useFlood: false);
const twoHops = PathSelection(pathBytes: [1, 2], hopCount: 2, useFlood: false);
const flood = PathSelection(pathBytes: [], hopCount: -1, useFlood: true);

void main() {
  test('a login waits at least 8 s direct and 15 s flooded', () {
    expect(nodeLoginWait(500, flood: false), const Duration(seconds: 8));
    expect(nodeLoginWait(500, flood: true), const Duration(seconds: 15));
    // A longer estimate (many hops, slow radio) is kept, plus 2 s.
    expect(nodeLoginWait(20000, flood: false), const Duration(seconds: 22));
  });

  test('after a silent first attempt on a stored path, the rest flood', () {
    for (final first in [direct, twoHops]) {
      expect(
        nodeLoginFloodsAttempt(0, first: first, pathSetByHand: false),
        isFalse,
      );
      expect(
        nodeLoginFloodsAttempt(1, first: first, pathSetByHand: false),
        isTrue,
      );
      expect(
        nodeLoginFloodsAttempt(4, first: first, pathSetByHand: false),
        isTrue,
      );
    }
  });

  test('a hand-set path, or a flood to start with, is kept', () {
    expect(
      nodeLoginFloodsAttempt(1, first: twoHops, pathSetByHand: true),
      isFalse,
    );
    expect(
      nodeLoginFloodsAttempt(1, first: flood, pathSetByHand: false),
      isFalse,
    );
  });
}
