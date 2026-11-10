// The MeshCore Open TAK services that main.dart provides on top of upstream's
// (voice, team, watch feed, drones, MediaMesh coverage), for tests that pump
// the fork's screens. Upstream's tests build their own provider lists; these
// go alongside them.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/services/mediamesh_coverage.dart';
import 'package:meshcore_open/team/drone_detector.dart';
import 'package:meshcore_open/team/tak/tak_service.dart';
import 'package:meshcore_open/team/team_service.dart';
import 'package:meshcore_open/team/watch_feed.dart';
import 'package:meshcore_open/vox/voice_service.dart';
import 'package:meshcore_open/vox/walkie_service.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

/// Creates them on the real clock (the services run periodic timers), so a
/// fake-async test zone has no pending timers to complain about.
Future<List<SingleChildWidget>> forkProviders(
  WidgetTester tester,
  MeshCoreConnector connector,
) async {
  late List<SingleChildWidget> providers;
  await tester.runAsync(() async {
    providers = forkProvidersNow(connector);
  });
  return providers;
}

/// [forkProviders] for code already off the fake clock (inside runAsync).
List<SingleChildWidget> forkProvidersNow(MeshCoreConnector connector) {
  final voice = VoxVoiceService(connector);
  final team = TeamService(connector);
  final watch = WatchFeedService(connector);
  return [
    ChangeNotifierProvider<VoxVoiceService>.value(value: voice),
    ChangeNotifierProvider<WalkieService>.value(
      value: WalkieService(connector, voice),
    ),
    ChangeNotifierProvider<TeamService>.value(value: team),
    ChangeNotifierProvider<TakService>.value(value: TakService(team)),
    ChangeNotifierProvider<WatchFeedService>.value(value: watch),
    ChangeNotifierProvider<DroneDetectorService>.value(
      value: DroneDetectorService(connector, watch),
    ),
    ChangeNotifierProvider<MediaMeshCoverageService>.value(
      value: MediaMeshCoverageService(connector),
    ),
  ];
}
