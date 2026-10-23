/// Human-readable identifier for the OTP-messenger patch series applied to
/// this Flutter build, mirroring OTP_3_RC1.lua's `BUILD_ID` convention
/// (`local BUILD_ID = "20261005.48-wall-clock-timestamps"`, shown on the
/// Lua app's Settings screen as "Build: `<BUILD_ID>`").
///
/// Bump this string in the same patch that changes OTP behavior, so
/// the OTP Pad screen always shows which numbered patch(es) actually landed
/// on a given install. This is the quickest way to confirm what a device
/// is running when comparing bug reports across the Lua and Flutter sides
/// of a mesh test, without digging through `git log`.
const String otpBuildId = '0026-pad-consumption-fix';

/// The release this app was built as, from the CI build (`--dart-define`s in
/// .github/workflows/build.yml): its build number, the day it was built and
/// the commit. Empty in a local build.
const int appReleaseBuild = int.fromEnvironment('APP_BUILD');
const String appReleaseDate = String.fromEnvironment('APP_BUILD_DATE');
const String appReleaseCommit = String.fromEnvironment('APP_COMMIT');

/// "build 1234 · 22 Oct 2026 · a1b2c3d" for Settings > About, or
/// "local build" when the app wasn't built by CI.
String appReleaseInfo() {
  final parts = <String>[
    if (appReleaseBuild > 0) 'build $appReleaseBuild',
    if (appReleaseDate.isNotEmpty) appReleaseDate,
    if (appReleaseCommit.isNotEmpty) appReleaseCommit,
  ];
  return parts.isEmpty ? 'local build' : parts.join(' · ');
}
