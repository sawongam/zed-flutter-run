import '../common/errors.dart';
import '../common/json_types.dart';
import 'device_lister.dart';

class Emulator {
  const Emulator({
    required this.id,
    required this.name,
    required this.manufacturer,
    required this.platform,
  });

  final String id;
  final String name;
  final String manufacturer;
  final String platform;

  Json toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'manufacturer': manufacturer,
    'platform': platform,
  };
}

final RegExp _emulatorLine = RegExp(
  r'^(\S+)\s+•\s+(.+?)\s+•\s+(.+?)\s+•\s+(.+)$',
);

/// Ids that are safe to hand to `flutter emulators --launch` (local copy of
/// the shared rule: no leading dash, no spaces, no shell characters).
final RegExp safeEmulatorIdPattern = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.:@-]*$');

/// Parses the text table printed by `flutter emulators`. Lines that do not
/// match (banners, header, hints) are ignored.
List<Emulator> parseEmulatorsOutput(String text) {
  final result = <Emulator>[];
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final m = _emulatorLine.firstMatch(raw.trim());
    if (m == null) continue;
    final id = m.group(1)!;
    if (id == 'Id' && m.group(4)!.trim() == 'Platform') continue; // header
    result.add(
      Emulator(
        id: id,
        name: m.group(2)!.trim(),
        manufacturer: m.group(3)!.trim(),
        platform: m.group(4)!.trim(),
      ),
    );
  }
  return result;
}

/// Lists emulators. Flutter exits non-zero when no emulator source exists
/// (no Android SDK); that is an empty list, not a failure.
Future<List<Emulator>> listEmulators(
  FlutterRunner run, {
  String? workingDirectory,
}) async {
  final result = await runFlutterChecked(
    run,
    const <String>['emulators'],
    workingDirectory: workingDirectory,
    acceptFailure: (r) =>
        r.stderr.contains('Unable to find any emulator sources') ||
        r.stdout.contains('Unable to find any emulator sources'),
  );
  return parseEmulatorsOutput(result.stdout);
}

/// Starts emulator [id]. Throws [UsageError] for an unsafe id.
Future<void> launchEmulator(
  FlutterRunner run,
  String id, {
  String? workingDirectory,
}) async {
  if (!safeEmulatorIdPattern.hasMatch(id)) {
    throw UsageError(
      'The emulator id "$id" is not valid.',
      hint: 'Run "flutter_run emulators" to see the available ids.',
    );
  }
  await runFlutterChecked(run, <String>[
    'emulators',
    '--launch',
    id,
  ], workingDirectory: workingDirectory);
}
