import 'package:args/command_runner.dart';

import '../../common/console.dart';
import '../../common/errors.dart';
import '../../common/global_options.dart';
import '../../common/host_environment.dart';
import '../device_lister.dart';
import '../device_store.dart';
import '../flutter_device.dart';
import '../picker.dart';

/// `flutter_run select-device [--device <id>] [--clear]`.
class SelectDeviceCommand extends Command<int> {
  SelectDeviceCommand({
    required FlutterRunnerFactory runnerFor,
    required DeviceStore store,
    required HostEnvironment env,
    required Console console,
  }) : _runnerFor = runnerFor,
       _store = store,
       _env = env,
       _console = console {
    GlobalOptions.addTo(argParser);
    argParser
      ..addOption(
        'device',
        valueHelp: 'id',
        help: 'Save this device without asking (see "flutter_run devices").',
      )
      ..addFlag(
        'clear',
        negatable: false,
        help: 'Remove the saved device for this project.',
      );
  }

  final FlutterRunnerFactory _runnerFor;
  final DeviceStore _store;
  final HostEnvironment _env;
  final Console _console;

  @override
  String get name => 'select-device';

  @override
  String get description =>
      'Choose the device used the next time the app starts.';

  @override
  Future<int> run() async {
    final options = GlobalOptions.of(this);
    final deviceId = argResults!['device'] as String?;
    final clear = argResults!['clear'] as bool;
    if (clear && deviceId != null) {
      throw const UsageError('Use either --clear or --device, not both.');
    }

    final root = requireProjectRoot(options.project, _env);

    if (clear) {
      final removed = await _store.clear(root);
      _console.out(
        removed
            ? 'Cleared the saved device. Flutter picks a device again.'
            : 'There was no saved device for this project.',
      );
      return ExitCodes.ok;
    }

    if (deviceId == null && !_console.isInteractive) {
      throw const UsageError(
        'select-device needs a terminal; use --device <id>.',
      );
    }

    final run = await _runnerFor(
      projectDir: root,
      explicitSdk: options.flutterSdk,
    );
    Future<List<FlutterDevice>> scan() =>
        listDevices(run, workingDirectory: root);

    var devices = await scan();
    if (devices.isEmpty) throw const DeviceException(noDevicesMessage);

    FlutterDevice? chosen;
    if (deviceId != null) {
      for (final d in devices) {
        if (d.id == deviceId) chosen = d;
      }
      if (chosen == null) {
        throw DeviceException(
          'The device id "$deviceId" is not connected. Available ids: '
          '${devices.map((d) => d.id).join(', ')}.',
          hint: 'Run "flutter_run devices" to see the current list.',
        );
      }
    } else {
      chosen = await pickFromList<FlutterDevice>(
        devices,
        (d) => '${d.name} (${d.id}) - ${d.platform}',
        _console,
        savedId: _store.readSync(root)?.deviceId,
        idOf: (d) => d.id,
        rescan: () async => devices = await scan(),
      );
      if (chosen == null) {
        _console.out('No device was chosen. Nothing was changed.');
        return ExitCodes.ok;
      }
    }

    await _store.write(
      root,
      SavedDevice(
        deviceId: chosen.id,
        name: chosen.name,
        platform: chosen.platform,
        savedAt: DateTime.now().toUtc(),
      ),
    );
    _console.out(
      'Saved device: ${chosen.name} (${chosen.id}). It is used the next time '
      'you start the app. The running app keeps its device.',
    );
    _console.out(
      'Start the app from the debugger (F4 opens the picker in Zed).',
    );
    return ExitCodes.ok;
  }
}
