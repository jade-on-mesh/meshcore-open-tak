import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/services/media_mesh.dart';

/// Answers `get radio2` from [radio2] in turn (null: throws, as a timeout
/// does); anything else gets an empty reply.
class _CliConnector extends MeshCoreConnector {
  final List<String?> radio2;
  int asked = 0;
  _CliConnector(this.radio2);

  @override
  Future<String> runLocalCliCommand(String command) async {
    if (command != 'get radio2') return '';
    final i = asked++;
    final reply = i < radio2.length ? radio2[i] : radio2.last;
    if (reply == null) throw Exception('timed out');
    return reply;
  }
}

void main() {
  setUp(() => MediaMeshController.retryDelay = Duration.zero);

  test('a missed first `get radio2` is asked again', () async {
    final c = _CliConnector(['', '> 911.150,250.000,7,5,rxtx,16 (auto)']);
    final state = await MediaMeshController(c).load();
    expect(c.asked, 2);
    expect(state.support, isNot(MediaMeshSupport.none));
    expect(state.settings.frequencyMHz, 911.15);
  });

  test('answered at once: asked once', () async {
    final c = _CliConnector(['> off']);
    final state = await MediaMeshController(c).load();
    expect(c.asked, 1);
    expect(state.support, isNot(MediaMeshSupport.none));
  });

  test('no radio2 after two asks: says what the radio said', () async {
    final empty = await MediaMeshController(_CliConnector([''])).load();
    expect(empty.support, MediaMeshSupport.none);
    expect(empty.radio2Answer, 'an empty reply');

    final unknown = await MediaMeshController(
      _CliConnector(['Unknown command']),
    ).load();
    expect(unknown.radio2Answer, '"Unknown command"');

    final none = await MediaMeshController(_CliConnector([null])).load();
    expect(none.radio2Answer, startsWith('no answer ('));
    expect(none.radio2Answer, contains('timed out'));
  });
}
