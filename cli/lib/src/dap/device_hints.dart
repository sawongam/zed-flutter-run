/// Returns the notice sentence for Flutter's "several devices" / "no devices"
/// failures found in [adapterText], or null when it does not match.
String? deviceHintFor(String adapterText) {
  final text = adapterText.toLowerCase();
  if (text.contains('more than one device connected')) {
    return 'Several devices are available (or none is). Run the task '
        '"Flutter: Select Device", or add "deviceId" to this launch entry.';
  }
  if (text.contains('no supported devices connected') ||
      text.contains('no devices found') ||
      text.contains('no connected devices')) {
    return 'No devices found. Start an emulator or simulator (task '
        '"Flutter: Launch Emulator"), connect a phone, or enable '
        'Chrome/desktop with "flutter config --enable-<platform>-desktop". '
        'A simulator can take a few seconds to appear.';
  }
  return null;
}
