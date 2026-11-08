import 'dart:io';

import '../common/errors.dart';
import '../common/host_environment.dart';
import '../common/json_types.dart';
import '../common/logger.dart';
import '../common/paths.dart';
import '../common/version.dart';
import '../dap/launch_rewriter.dart';
import '../dap/notices.dart';
import '../dap/proxy_state.dart';
import '../devtools/browser_opener.dart';
import '../devtools/devtools_opener.dart';
import '../devtools/pages.dart';
import 'path_notice.dart';

/// Shows a message in the client's console (`DapProxy.notice`).
typedef NoticeSink = void Function(String text, [NoticeLevel level]);

/// The user-facing messages of a debug session: the notices at launch, the
/// reload-on-save watcher's messages and the DevTools auto-open.
class SessionNotices {
  SessionNotices({
    required this.env,
    required this.logger,
    required this.browserOpener,
    required this.kind,
    required this.clientVersion,
    required this.resolvedExecutable,
    required this.notice,
  });

  final HostEnvironment env;
  final Logger logger;
  final BrowserOpener browserOpener;
  final DapKind kind;
  final String? clientVersion;
  final String resolvedExecutable;
  final NoticeSink notice;

  /// The notices shown once, at the first launch or attach.
  void showStart(RewriteResult result, {String? setupProblem}) {
    final version = clientVersion;
    if (version != null && version.isNotEmpty && version != packageVersion) {
      notice(
        'The Zed extension is version $version but the flutter_run command is '
        '$packageVersion. Update flutter_run to match (see the README install '
        'section).',
        NoticeLevel.warn,
      );
    }
    if (_pathNoticeNeeded()) {
      notice(
        pathNoticeText(env, resolvedExecutable, _isCompiledExe),
        NoticeLevel.warn,
      );
    }
    if (setupProblem != null) notice(setupProblem, NoticeLevel.warn);
    if (kind == DapKind.flutter) {
      final id = result.deviceId;
      switch (result.deviceSource) {
        case DeviceSource.saved:
          notice('Using device $id (saved selection).');
        case DeviceSource.env:
          notice(
            'Using device $id (environment variable '
            '${LaunchRewriter.deviceEnvVariable}).',
          );
        case DeviceSource.none:
          notice(
            'No device was chosen, so Flutter will pick one. If it cannot, '
            'run the task "Flutter: Select Device".',
          );
        case DeviceSource.config || DeviceSource.toolArgs:
          break;
      }
    }
  }

  /// Relays a reload-on-save watcher message, honouring its level prefix.
  void watcherNotice(String text, {required bool isError}) {
    var level = isError ? NoticeLevel.error : NoticeLevel.info;
    var message = text;
    if (message.startsWith('Error: ')) {
      message = message.substring('Error: '.length);
      level = NoticeLevel.error;
    } else if (message.startsWith('Warning: ')) {
      message = message.substring('Warning: '.length);
      level = NoticeLevel.warn;
    }
    notice(message, level);
  }

  /// Opens DevTools for the first debugger address when the launch entry
  /// asks for it (`openDevTools` in [ownConfig]).
  Future<void> openDevTools(DebuggerUris event, Json ownConfig) async {
    if (!event.isFirst) return;
    final value = ownConfig['openDevTools'];
    if (value is! String || value == 'never') return;
    final page = DevToolsPage.parse(value);
    if (page == null) {
      notice(
        'The launch entry has openDevTools "$value", which is not a DevTools '
        'page. Use "never" or one of: ${DevToolsPage.names}.',
        NoticeLevel.warn,
      );
      return;
    }
    try {
      final url = await openDevToolsOnce(
        event.vmServiceUri,
        page,
        browserOpener,
        logger: logger,
        isDartSession: kind == DapKind.dart,
      );
      notice('Opened DevTools: $url');
    } on FlutterRunException catch (e) {
      // DevToolsOpenException already includes the address to open by hand.
      notice(e.message, NoticeLevel.warn);
    }
  }

  bool get _isCompiledExe {
    final base = env.pathContext.basename(resolvedExecutable).toLowerCase();
    return base != 'dart' && base != 'dart.exe';
  }

  bool _pathNoticeNeeded() {
    final found = findExecutableOnPath(toolName, env);
    if (found == null) return true;
    if (!_isCompiledExe) return false;
    return !_samePath(found, resolvedExecutable);
  }

  bool _samePath(String a, String b) {
    String real(String path) {
      try {
        return File(path).resolveSymbolicLinksSync();
      } on FileSystemException {
        return path;
      }
    }

    return pathsEqual(real(a), real(b), env);
  }
}
