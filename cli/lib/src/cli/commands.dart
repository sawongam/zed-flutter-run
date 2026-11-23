import 'dart:io';

import 'package:args/command_runner.dart';

import '../common/paths.dart';
import '../common/version.dart';
import '../control/reload_command.dart';
import '../control/restart_command.dart';
import '../control/status_command.dart';
import '../devices/commands/devices_command.dart';
import '../devices/commands/emulators_command.dart';
import '../devices/commands/select_device_command.dart';
import '../devtools/commands/devtools_command.dart';
import '../init/commands/init_command.dart';
import 'doctor_command.dart';
import 'path_notice.dart';
import 'version_command.dart';
import 'wiring.dart';

/// Every command except `dap`, which the runner builds from [wiring] itself.
List<Command<int>> buildCommands(Wiring wiring) {
  final env = wiring.env;
  final console = wiring.console;
  return [
    ReloadCommand(
      store: wiring.sessionStore,
      client: wiring.controlClient,
      env: env,
      console: console,
      clock: wiring.clock,
    ),
    RestartCommand(
      store: wiring.sessionStore,
      client: wiring.controlClient,
      env: env,
      console: console,
      clock: wiring.clock,
    ),
    StatusCommand(store: wiring.sessionStore, env: env, console: console),
    DevicesCommand(
      runnerFor: wiring.flutterRunnerFactory,
      store: wiring.deviceStore,
      env: env,
      console: console,
    ),
    SelectDeviceCommand(
      runnerFor: wiring.flutterRunnerFactory,
      store: wiring.deviceStore,
      env: env,
      console: console,
      clock: wiring.clock,
    ),
    EmulatorsCommand(
      runnerFor: wiring.flutterRunnerFactory,
      env: env,
      console: console,
    ),
    DevToolsCommand(
      resolveTarget: wiring.vmServiceTargetResolver,
      opener: wiring.browserOpener,
      env: env,
      console: console,
    ),
    InitCommand(
      env: env,
      console: console,
      findFlutterRunOnPath: () => findExecutableOnPath(toolName, env),
      pathFixHint: pathFixHint(
        env.os,
        env.pathContext.dirname(Platform.resolvedExecutable),
      ),
    ),
    DoctorCommand(
      sdkResolver: wiring.sdkResolver,
      sessionStore: wiring.sessionStore,
      env: env,
      console: console,
    ),
    VersionCommand(console),
  ];
}
