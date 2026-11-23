# flutter_onnxruntime (vendored)

`flutter_onnxruntime` 1.9.0 from https://github.com/masicai/flutter_onnxruntime
(tag `v1.9.0`, commit 2f0fc6c), without its example, tests, docs, scripts and
git hooks. The only change is on iOS and macOS:

- `ios/flutter_onnxruntime/Package.swift` and `macos/flutter_onnxruntime/Package.swift`
  depend on a local copy of `masicai/onnxruntime-swift-package-manager` 1.28.0
  (commit 3fb68950, the version the plugin pins) in
  `<platform>/flutter_onnxruntime/onnxruntime-swift-package-manager/`, instead
  of the GitHub package.
- That copy drops the `onnxruntime_extensions` product. Its binary target was
  downloaded from `download.onnxruntime.ai`, whose TLS certificate Apple's
  build machines rejected from November 2026, so Xcode failed to resolve
  packages and every iOS and macOS build failed. The plugin never uses the
  extensions. The ONNX Runtime binary itself still comes from masicai's GitHub
  release, pinned by the same SwiftPM checksum.

Android, Windows, Linux and web are the upstream code unchanged.

To go back to upstream: point `flutter_onnxruntime` in `pubspec.yaml` at the
hosted package again (`flutter_onnxruntime: ^1.9.0`), run `flutter pub get`,
and delete this folder.
