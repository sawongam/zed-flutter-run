import 'dart:io';

import 'package:args/command_runner.dart';

import '../common/clock.dart';
import '../common/console.dart';
import '../common/host_environment.dart';
import '../common/logger.dart';
import '../common/paths.dart';
import '../common/version.dart';
import '../control/control_client.dart';
import '../control/reload_command.dart';
import '../control/restart_command.dart';
import '../control/session_store.dart';
import '../control/status_command.dart';
import '../devices/commands/devices_command.dart';
import '../devices/commands/emulators_command.dart';
import '../devices/commands/select_device_command.dart';
import '../devices/device_store.dart';
import '../devtools/commands/devtools_command.dart';
import '../init/commands/init_command.dart';
import '../sdk/process_runner.dart';
import '../sdk/sdk_resolver.dart';
import 'doctor_command.dart';
import 'path_notice.dart';
import 'version_command.dart';
import 'wiring.dart';

/// Everything a command may need, bundled once, so each command is built in
/// one line.
class CommandContext {
  CommandContext(Wiring wiring)
    : wiring = wiring,
      env = wiring.env,
      console = wiring.console,
      logger = wiring.logger,
      clock = wiring.clock,
      processRunner = wiring.processRunner,
      sessionStore = wiring.sessionStore,
      controlClient = wiring.controlClient,
      deviceStore = wiring.deviceStore,
      sdkResolver = wiring.sdkResolver;

  final Wiring wiring;
  final HostEnvironment env;
  final Console console;
  final Logger logger;
  final Clock clock;
  final ProcessRunner processRunner;
  final SessionStore sessionStore;
  final ControlClient controlClient;
  final DeviceStore deviceStore;
  final SdkResolver sdkResolver;

  /// Every command except `dap`, which the runner builds from [wiring].
  List<Command<int>> commands() => [
    ReloadCommand(
      store: sessionStore,
      client: controlClient,
      env: env,
      console: console,
      clock: clock,
    ),
    RestartCommand(
      store: sessionStore,
      client: controlClient,
      env: env,
      console: console,
      clock: clock,
    ),
    StatusCommand(store: sessionStore, env: env, console: console),
    DevicesCommand(
      runnerFor: wiring.flutterRunnerFactory,
      store: deviceStore,
      env: env,
      console: console,
    ),
    SelectDeviceCommand(
      runnerFor: wiring.flutterRunnerFactory,
      store: deviceStore,
      env: env,
      console: console,
      clock: clock,
    ),
    EmulatorsCommand(
      runnerFor: wiring.flutterRunnerFactory,
      store: deviceStore,
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
      sdkResolver: sdkResolver,
      sessionStore: sessionStore,
      env: env,
      console: console,
    ),
    VersionCommand(console),
  ];
}
