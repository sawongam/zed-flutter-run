import 'dart:convert';

import 'package:args/command_runner.dart';

import '../../common/console.dart';
import '../../common/errors.dart';
import '../../common/global_options.dart';
import '../../common/host_environment.dart';
import '../../common/paths.dart';
import '../device_lister.dart';
import '../device_store.dart';
import '../emulators.dart';
import '../picker.dart';

/// `flutter_run emulators [--launch <id>] [--json]`.
class EmulatorsCommand extends Command<int> {
  EmulatorsCommand({
    required FlutterRunnerFactory runnerFor,
    required DeviceStore store,
    required HostEnvironment env,
    required Console console,
  }) : _runnerFor = runnerFor,
       _env = env,
       _console = console {
    GlobalOptions.addTo(argParser);
    argParser
      ..addOption(
        'launch',
        valueHelp: 'id',
        help: 'Start the emulator with this id.',
      )
      ..addFlag('json', negatable: false, help: 'Print the emulators as JSON.');
  }

  final FlutterRunnerFactory _runnerFor;
  final HostEnvironment _env;
  final Console _console;

  @override
  String get name => 'emulators';

  @override
  String get description => 'List emulators and simulators, or start one.';

  @override
  Future<int> run() async {
    final options = GlobalOptions.of(this);
    final launchId = argResults!['launch'] as String?;
    final json = argResults!['json'] as bool;
    if (launchId != null && json) {
      throw const UsageError('Use either --launch or --json, not both.');
    }
    if (launchId != null && !safeEmulatorIdPattern.hasMatch(launchId)) {
      throw UsageError(
        'The emulator id "$launchId" is not valid.',
        hint: 'Run "flutter_run emulators" to see the available ids.',
      );
    }

    final found = findProjectRootFor(options.project, _env);
    final root = found == null ? null : canonicalDirectory(found, _env);
    final dir = root ?? options.project ?? _env.currentDirectory;
    final run = await _runnerFor(
      projectDir: dir,
      explicitSdk: options.flutterSdk,
    );

    if (launchId != null) {
      await _launch(run, launchId, launchId, dir);
      return ExitCodes.ok;
    }

    final emulators = await listEmulators(run, workingDirectory: dir);
    if (json) {
      _console.out(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'emulators': [for (final e in emulators) e.toJson()],
        }),
      );
      return ExitCodes.ok;
    }
    if (emulators.isEmpty) throw const DeviceException(noDevicesMessage);

    if (!_console.isInteractive) {
      _printTable(emulators);
      return ExitCodes.ok;
    }

    final chosen = await pickFromList<Emulator>(
      emulators,
      (e) => '${e.name} (${e.id}) - ${e.platform}',
      _console,
      idOf: (e) => e.id,
      rescan: () => listEmulators(run, workingDirectory: dir),
    );
    if (chosen == null) {
      _console.out('No emulator was chosen. Nothing was started.');
      return ExitCodes.ok;
    }
    await _launch(run, chosen.id, chosen.name, dir);
    return ExitCodes.ok;
  }

  Future<void> _launch(
    FlutterRunner run,
    String id,
    String label,
    String dir,
  ) async {
    _console.out('Starting $label...');
    await launchEmulator(run, id, workingDirectory: dir);
    _console.out(
      'Started $label. It can take a few seconds to appear in "flutter_run '
      'devices".',
    );
  }

  void _printTable(List<Emulator> emulators) {
    int width(String Function(Emulator) f, String header) => [
      header.length,
      ...emulators.map((e) => f(e).length),
    ].reduce((a, b) => a > b ? a : b);
    final wId = width((e) => e.id, 'Id');
    final wName = width((e) => e.name, 'Name');
    final wMan = width((e) => e.manufacturer, 'Manufacturer');
    String row(String i, String n, String m, String p) =>
        '${i.padRight(wId)}  ${n.padRight(wName)}  ${m.padRight(wMan)}  $p'
            .trimRight();
    _console.out(row('Id', 'Name', 'Manufacturer', 'Platform'));
    for (final e in emulators) {
      _console.out(row(e.id, e.name, e.manufacturer, e.platform));
    }
  }
}
