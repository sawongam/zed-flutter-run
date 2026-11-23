import 'dart:convert';

import 'package:args/command_runner.dart';

import '../../common/console.dart';
import '../../common/errors.dart';
import '../../common/global_options.dart';
import '../../common/host_environment.dart';
import '../device_lister.dart';
import '../device_store.dart';
import '../flutter_device.dart';
import '../table.dart';

/// `flutter_run devices [--json]`: lists devices and marks the saved one.
class DevicesCommand extends Command<int> {
  DevicesCommand({
    required this._runnerFor,
    required this._store,
    required this._env,
    required this._console,
  }) {
    GlobalOptions.addTo(argParser);
    argParser.addFlag(
      'json',
      negatable: false,
      help: 'Print the devices and the saved device as JSON.',
    );
  }

  final FlutterRunnerFactory _runnerFor;
  final DeviceStore _store;
  final HostEnvironment _env;
  final Console _console;

  @override
  String get name => 'devices';

  @override
  String get description =>
      'List the devices Flutter can run on and mark the saved one.';

  @override
  Future<int> run() async {
    final options = GlobalOptions.of(this);
    final root = findProjectRootFor(options.project, _env);
    final dir = root ?? options.project ?? _env.currentDirectory;
    final saved = root == null ? null : _store.readSync(root);

    final run = await _runnerFor(
      projectDir: dir,
      explicitSdk: options.flutterSdk,
    );
    final devices = await listDevices(run, workingDirectory: dir);

    if (argResults!['json'] as bool) {
      _console.out(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'devices': [for (final d in devices) d.toJson()],
          'saved': saved?.deviceId,
        }),
      );
      return ExitCodes.ok;
    }

    if (devices.isEmpty) throw const DeviceException(noDevicesMessage);
    _printTable(devices, saved?.deviceId);
    return ExitCodes.ok;
  }

  void _printTable(List<FlutterDevice> devices, String? savedId) {
    final lines = formatTable([
      ['Name', 'Id', 'Platform'],
      for (final d in devices) [d.name, d.id, d.platform],
    ]);
    final marks = [' ', for (final d in devices) d.id == savedId ? '*' : ' '];
    for (var i = 0; i < lines.length; i++) {
      _console.out('${marks[i]} ${lines[i]}');
    }
    if (savedId != null) {
      final connected = devices.any((d) => d.id == savedId);
      _console.out('');
      _console.out(
        connected
            ? '* is the saved device. It is used the next time you start the app.'
            : 'The saved device $savedId is not connected right now.',
      );
    }
  }
}
