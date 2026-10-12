/// Human-readable identifier for the OTP-messenger patch series applied to
/// this Flutter build, mirroring OTP_3_RC1.lua's `BUILD_ID` convention
/// (`local BUILD_ID = "20261005.48-wall-clock-timestamps"`, shown on the
/// Lua app's Settings screen as "Build: <BUILD_ID>").
///
/// Bump this string in the same patch that changes OTP behavior, so
/// Settings > About always shows which numbered patch(es) actually landed
/// on a given install. This is the quickest way to confirm what a device
/// is running when comparing bug reports across the Lua and Flutter sides
/// of a mesh test, without digging through `git log`.
const String otpBuildId = '0026-pad-consumption-fix';
