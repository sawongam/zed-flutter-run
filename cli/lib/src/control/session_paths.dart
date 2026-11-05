import '../common/host_environment.dart';
import '../common/paths.dart';

/// `<stateBaseDirectory>/sessions`.
String sessionsDirectory(HostEnvironment env) =>
    env.pathContext.join(stateBaseDirectory(env), 'sessions');

/// `<pid>.json`.
String sessionFileName(int pid) => '$pid.json';
