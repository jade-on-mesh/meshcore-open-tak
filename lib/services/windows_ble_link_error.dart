// Windows: the Bluetooth link to the radio never opened.
//
// flutter_blue_plus_winrt reports a failed connect by returning instead of
// throwing (its native side gives up when GetGattServicesAsync fails or the
// device does not reach Connected within 5 s). flutter_blue_plus then carries
// on as if connected, and the next step fails with the misleading
// "discoverServices | fbp-code: 6 | device is not connected".
// MeshCoreConnector checks the link right after connect and throws this.

/// Thrown on Windows when the radio's Bluetooth link did not open after the
/// connect attempts (see the file comment).
class WindowsBleLinkException implements Exception {
  const WindowsBleLinkException();

  @override
  String toString() =>
      'WindowsBleLinkException: Windows could not open a Bluetooth link to the radio';
}
