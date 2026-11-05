import 'dart:io';

import 'package:flutter_run/src/common/host_environment.dart';
import 'package:flutter_run/src/common/json_types.dart';
import 'package:flutter_run/src/control/control_protocol.dart';
import 'package:flutter_run/src/control/session_info.dart';

HostEnvironment linuxEnv({String? stateDir, String cwd = '/work/app'}) =>
    HostEnvironment(
      os: HostOs.linux,
      environment: {'FLUTTER_RUN_STATE_DIR': ?stateDir},
      currentDirectory: cwd,
    );

/// Environment on the real host, with state files in [stateDir].
HostEnvironment hostEnv(String stateDir) {
  final system = HostEnvironment.system();
  return system.copyWith(
    environment: {...system.environment, 'FLUTTER_RUN_STATE_DIR': stateDir},
  );
}

SessionInfo sessionInfo({
  int pid = 100,
  int port = 5000,
  String token = 'tok',
  String projectRoot = '/work/app',
  String kind = 'flutter',
  bool appStarted = true,
  String? deviceId = 'linux',
  DateTime? startedAt,
}) => SessionInfo(
  pid: pid,
  port: port,
  token: token,
  projectRoot: projectRoot,
  cwd: projectRoot,
  kind: kind,
  request: 'launch',
  startedAt: startedAt ?? DateTime.utc(2026, 11, 3, 12),
  deviceId: deviceId,
  mode: 'debug',
  appStarted: appStarted,
);

class FakeControl implements SessionControl {
  FakeControl({this.reloadDelay = Duration.zero, this.pid = 4242});

  final Duration reloadDelay;
  final int pid;
  final List<Json> reloadArgs = [];
  Object? reloadError;

  @override
  Json ping() => {'pid': pid, 'version': '0.1.0', 'protocol': 1};

  @override
  Future<Json> reload(Json args) async {
    reloadArgs.add(args);
    await Future<void>.delayed(reloadDelay);
    final error = reloadError;
    if (error != null) throw error;
    return {'durationMs': 593, 'coalesced': false};
  }

  @override
  Future<Json> restart(Json args) async => {'durationMs': 320};
}

Future<Directory> tempDir(String prefix) =>
    Directory.systemTemp.createTemp(prefix);
