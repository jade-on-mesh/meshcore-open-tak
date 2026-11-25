import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/helpers/edit_helper.dart';
import 'package:meshcore_open/helpers/reaction_helper.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/models/channel_message.dart';
import 'package:meshcore_open/review_mode/review_frames.dart';
import 'package:meshcore_open/review_mode/review_radio.dart';
import 'package:meshcore_open/services/message_retry_service.dart';
import 'package:meshcore_open/services/path_history_service.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _waitFor(bool Function() condition, {int seconds = 8}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('Timed out waiting for condition');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _TestRadio extends ReviewRadio {
  _TestRadio()
    : super(
        scheduledMessageInterval: const Duration(hours: 1),
        ackDelay: const Duration(milliseconds: 50),
        replyDelay: const Duration(hours: 1),
      );
}

late MeshCoreConnector _connector;

Future<void> _connect() async {
  final radio = _TestRadio();
  _connector.reviewRadioFactoryForTest = () => radio;
  await _connector.connectReview();
  addTearDown(_connector.disconnect);
  await _waitFor(() => _connector.channelMapConfirmed);
}

Channel _channelAt(int slot) =>
    _connector.channels.firstWhere((c) => c.index == slot);

List<ChannelMessage> _messages(int slot) =>
    _connector.getChannelMessages(_channelAt(slot));

int _nowSecs() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

String _editWire(String sender, int ts, String before, String after) =>
    MessageEdit.between(
      targetHash: ReactionHelper.computeReactionHash(ts, sender, before),
      before: before,
      after: after,
    )!.encode(before.length);

void _receive(int slot, String sender, String text, int ts) =>
    _connector.handleFrameForTest(
      ReviewFrames.channelMessage(
        channelIndex: slot,
        sender: sender,
        message: text,
        timestampSecs: ts,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    _connector = MeshCoreConnector();
    final retryService = MessageRetryService();
    _connector.initialize(
      retryService: retryService,
      pathHistoryService: PathHistoryService(StorageService()),
    );
    addTearDown(() {
      _connector.dispose();
      retryService.dispose();
    });
  });

  test('an incoming edit corrects the message in place', () async {
    await _connect();
    const before = 'see you at 5 tonight';
    const after = 'see you at 6 tonight';
    final ts = _nowSecs();
    _receive(1, 'Sam', before, ts);
    await _waitFor(() => _messages(1).any((m) => m.text == before));
    final count = _messages(1).length;
    final unread = _channelAt(1).unreadCount;

    final wire = _editWire('Sam', ts, before, after);
    _receive(1, 'Sam', wire, ts + 30);
    await _waitFor(() => _messages(1).any((m) => m.text == after));

    final edited = _messages(1).firstWhere((m) => m.text == after);
    expect(edited.isEdited, isTrue);
    expect(edited.firstText, before);
    expect(_messages(1).length, count, reason: 'no bubble for the edit');
    expect(_channelAt(1).unreadCount, unread);

    // A mesh repeat of the same edit changes nothing.
    _receive(1, 'Sam', wire, ts + 30);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(_messages(1).length, count);
    expect(_messages(1).where((m) => m.text == after), hasLength(1));
  });

  test('an edit for a message we never got shows as a correction', () async {
    await _connect();
    final ts = _nowSecs();
    final wire = _editWire('Ana', ts, 'meet at the park', 'meet at the old park');
    _receive(2, 'Ana', wire, ts + 10);
    await _waitFor(() => _messages(2).any((m) => m.text == wire));
  });

  test('an edit from someone else is not applied', () async {
    await _connect();
    const before = 'lunch at noon';
    final ts = _nowSecs();
    _receive(0, 'Kim', before, ts);
    await _waitFor(() => _messages(0).any((m) => m.text == before));
    final wire = _editWire('Kim', ts, before, 'lunch at one');
    _receive(0, 'Mallory', wire, ts + 10);
    await _waitFor(() => _messages(0).any((m) => m.text == wire));
    expect(_messages(0).firstWhere((m) => m.text == before).isEdited, isFalse);
  });

  test('photos, reactions and edits themselves are not editable', () {
    expect(MeshCoreConnector.isEditableText('hello'), isTrue);
    expect(MeshCoreConnector.isEditableText('r:3fa1:00'), isFalse);
    expect(
      MeshCoreConnector.isEditableText('VI1:1miqcby:14:h:23 IMAGE hi'),
      isFalse,
    );
    expect(
      MeshCoreConnector.isEditableText(_editWire('a', 1, 'ab cd', 'ab ce')),
      isFalse,
    );
  });

  test('an edit that would not fit is refused', () {
    final long = 'x' * 120;
    expect(
      MeshCoreConnector.editWireText(
        targetHash: '0000',
        before: 'short',
        after: long,
        maxBytes: 100,
      ),
      isNull,
    );
  });
}
