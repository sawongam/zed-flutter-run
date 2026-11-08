import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';

import '../common/errors.dart';
import '../common/global_options.dart';
import '../common/logger.dart';
import '../dap/channel.dart';
import '../dap/launch_rewriter.dart';
import '../dap/messages.dart';
import '../dap/notices.dart';
import '../sdk/managed_process.dart';
import '../sdk/process_spec.dart';
import '../sdk/sdk_resolver.dart';
import 'dap_session_host.dart';
import 'signal_source.dart';
import 'wiring.dart';

/// First sequence number of messages the proxy makes up itself.
const int _syntheticSeq = 1000000000;

/// Answers the client's first request with a failure, mirrors the text to the
/// client's console (stderr category) and closes the channel.
///
/// Zed only shows "adapter exited" when the proxy dies silently, so this is
/// how startup problems (no SDK, adapter cannot be started) reach the user.
Future<void> answerStartupFailure(
  DapChannel client,
  String text, {
  Duration wait = const Duration(seconds: 2),
}) async {
  DapJson? first;
  try {
    first = await client.messages.firstWhere(isRequest).timeout(wait);
  } on TimeoutException {
    // The client sent nothing; still write the console text.
  } on StateError {
    // The client closed its output.
  }
  if (first != null) {
    final seq = first['seq'];
    client.send(
      makeResponse(
        requestSeq: seq is int ? seq : 0,
        command: first['command'] as String? ?? 'initialize',
        success: false,
        message: text,
        seq: _syntheticSeq,
      ),
    );
  }
  client.send(
    makeOutputEvent(
      formatNotice(text, NoticeLevel.error),
      category: 'stderr',
      seq: _syntheticSeq + 1,
    ),
  );
  await client.flush();
  await client.close();
}

/// `flutter_run dap`: the DAP proxy that Zed starts for a debug session.
class DapCommand extends Command<int> {
  DapCommand(
    this._wiring, {
    Stream<List<int>>? input,
    StreamSink<List<int>>? output,
    IOSink? errorSink,
    String? resolvedExecutable,
    this.attachWatchdog = const Duration(seconds: 15),
    this.startupResponseWait = const Duration(seconds: 2),
    this.sessionWriteDebounce = const Duration(milliseconds: 50),
    SignalSource? signalSource,
  }) : _signals = signalSource ?? const SystemSignalSource(),
       _input = input,
       _output = output,
       _errorSink = errorSink,
       _resolvedExecutable = resolvedExecutable {
    GlobalOptions.addTo(argParser);
    argParser
      ..addOption(
        'cwd',
        valueHelp: 'dir',
        help: 'Working directory of the debug session (required).',
      )
      ..addOption(
        'kind',
        allowed: ['flutter', 'dart'],
        defaultsTo: 'flutter',
        help: 'Which debug adapter to start.',
      )
      ..addOption(
        'request',
        allowed: ['launch', 'attach'],
        defaultsTo: 'launch',
        help: 'The kind of session the editor will start.',
      )
      ..addFlag(
        'use-fvm',
        negatable: false,
        help: 'Require the Flutter SDK that fvm selected for the project.',
      )
      ..addOption(
        'log-file',
        valueHelp: 'path',
        help: 'Write the debug log and all DAP traffic to this file.',
      )
      ..addOption(
        'client-version',
        valueHelp: 'x.y.z',
        help: 'Version of the Zed extension that started this command.',
      );
  }

  final Wiring _wiring;
  final SignalSource _signals;
  final Stream<List<int>>? _input;
  final StreamSink<List<int>>? _output;
  final IOSink? _errorSink;
  final String? _resolvedExecutable;
  final Duration attachWatchdog;
  final Duration startupResponseWait;
  final Duration sessionWriteDebounce;

  @override
  String get name => 'dap';

  @override
  String get description =>
      'Debug adapter proxy (started by the Zed extension, not by hand).';

  @override
  bool get hidden => false;

  @override
  Future<int> run() {
    final cwdOption = argResults!['cwd'] as String?;
    if (cwdOption == null || cwdOption.isEmpty) {
      usageException('The option --cwd is required.');
    }
    final errorSink = _errorSink ?? stderr;
    final done = Completer<int>();
    runZonedGuarded(
      () async {
        try {
          done.complete(await _run(cwdOption));
        } on Object catch (e, st) {
          _wiring.logger.error('The debug proxy failed unexpectedly', e, st);
          if (!done.isCompleted) done.complete(ExitCodes.internal);
        }
      },
      (e, st) => _wiring.logger.error('Unexpected error in the proxy', e, st),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => errorSink.writeln(line),
      ),
    );
    return done.future;
  }

  Future<int> _run(String cwdOption) async {
    final env = _wiring.env;
    final options = GlobalOptions.of(this);
    final kind = argResults!['kind'] == 'dart' ? DapKind.dart : DapKind.flutter;
    final request = argResults!['request'] as String;
    final useFvm = argResults!['use-fvm'] as bool;
    final clientVersion = argResults!['client-version'] as String?;
    final logFile = argResults!['log-file'] as String?;

    final Logger logger;
    var ownLogger = false;
    if (logFile != null && logFile.isNotEmpty) {
      logger = Logger(
        level: options.verbose ? LogLevel.debug : _wiring.logger.level,
        logFilePath: logFile,
      );
      ownLogger = true;
    } else {
      logger = _wiring.logger;
    }

    final client = StreamDapChannel(
      _input ?? stdin,
      _output ?? stdout,
      logger: logger,
      label: 'C',
    );
    final cwd = env.pathContext.normalize(env.pathContext.absolute(cwdOption));

    final ManagedProcess process;
    try {
      final resolution = await _wiring.sdkResolver.resolveOrThrow(
        projectDir: cwd,
        kind: kind == DapKind.dart ? SdkKind.dart : SdkKind.flutter,
        explicitSdkPath: options.flutterSdk,
        strictFvm: useFvm,
      );
      final executable = kind == DapKind.dart
          ? resolution.dartExecutable!
          : resolution.flutter!.flutterExecutable;
      // Attaching must not start a second DDS (it would outlive the session,
      // see the attach probe). Only the Flutter adapter has the flag.
      final args = <String>[
        'debug_adapter',
        if (kind == DapKind.flutter && request == 'attach') '--no-dds',
      ];
      final base = buildProcessSpec(executable, args, env);
      process = await ManagedProcess.start(
        ProcessSpec(base.executable, base.arguments, workingDirectory: cwd),
        logger: logger,
      );
    } on FlutterRunException catch (e) {
      logger.error('Could not start the debug adapter: ${e.message}');
      final hint = e.hint;
      await answerStartupFailure(
        client,
        hint == null ? e.message : '${e.message}\n$hint',
        wait: startupResponseWait,
      );
      if (ownLogger) await logger.close();
      return e is SdkNotFoundException ? ExitCodes.sdkNotFound : 1;
    } on ArgumentError catch (e) {
      await answerStartupFailure(
        client,
        'The debug adapter could not be started: ${e.message}',
        wait: startupResponseWait,
      );
      if (ownLogger) await logger.close();
      return 1;
    }

    final host = DapSessionHost(
      env: env,
      clock: _wiring.clock,
      logger: logger,
      signals: _signals,
      sessionStore: _wiring.sessionStore,
      deviceStore: _wiring.deviceStore,
      browserOpener: _wiring.browserOpener,
      client: client,
      adapter: ManagedAdapterConnection(process, logger: logger),
      kind: kind,
      request: request,
      cwd: cwd,
      clientVersion: clientVersion,
      resolvedExecutable: _resolvedExecutable ?? Platform.resolvedExecutable,
      attachWatchdog: attachWatchdog,
      sessionWriteDebounce: sessionWriteDebounce,
    );
    final code = await host.run();
    if (ownLogger) await logger.close();
    return code;
  }
}
