import '../common/json_types.dart';
import '../common/logger.dart';

enum DapKind { flutter, dart }

enum DeviceSource { toolArgs, config, env, saved, none }

class RewriteResult {
  const RewriteResult({
    required this.arguments,
    required this.ownConfig,
    required this.deviceId,
    required this.deviceSource,
    required this.notes,
  });

  /// What goes to the adapter.
  final Json arguments;

  /// The stripped own keys, values as given.
  final Json ownConfig;

  final String? deviceId;
  final DeviceSource deviceSource;
  final List<String> notes;
}

/// Rewrites a `launch`/`attach` request's arguments: strips this tool's own
/// keys, applies `flutterMode`, injects the device and fills defaults.
class LaunchRewriter {
  LaunchRewriter({
    required this.kind,
    required this.cwd,
    required this.environment,
    required String? Function() savedDevice,
    Logger? logger,
    bool Function(String id)? isSafeDeviceId,
  }) : _isSafeDeviceId = isSafeDeviceId ?? ((_) => true),
       _savedDevice = savedDevice,
       _logger = logger ?? Logger.silent();

  final DapKind kind;
  final String cwd;
  final Map<String, String> environment;
  final String? Function() _savedDevice;
  final Logger _logger;
  final bool Function(String id) _isSafeDeviceId;

  /// Single source of truth for the keys interpreted by this tool.
  static const Set<String> ownKeys = {
    'flutterSdkPath',
    'deviceId',
    'reloadOnSave',
    'reloadOnSaveGlobs',
    'reloadOnSaveDebounceMs',
    'openDevTools',
    'logFile',
    'useFvm',
    'adapter',
    'label',
    'flutterMode',
    'platform',
  };

  static const String deviceEnvVariable = 'FLUTTER_RUN_DEVICE';

  RewriteResult rewrite(String request, Json arguments) {
    final notes = <String>[];
    final args = Map<String, Object?>.of(arguments);
    final own = <String, Object?>{};
    for (final key in ownKeys) {
      if (args.containsKey(key)) own[key] = args.remove(key);
    }

    final rawToolArgs = args['toolArgs'];
    if (rawToolArgs != null && rawToolArgs is! List) {
      notes.add('toolArgs must be a list, so it was ignored.');
    }
    final toolArgs = rawToolArgs is List
        ? List<Object?>.of(rawToolArgs)
        : <Object?>[];
    var toolArgsChanged = false;
    final isFlutter = kind == DapKind.flutter;

    if (isFlutter && request == 'launch') {
      final mode = own['flutterMode'];
      if (mode is String) {
        toolArgsChanged |= _applyMode(mode, toolArgs, notes);
      } else if (mode != null) {
        notes.add('Ignored flutterMode: expected a string.');
      }
    }

    String? deviceId;
    var source = DeviceSource.none;
    if (isFlutter) {
      final strings = toolArgs.whereType<String>().toList();
      final existing = _deviceInToolArgs(strings);
      if (existing != null) {
        source = DeviceSource.toolArgs;
        deviceId = existing.isEmpty ? null : existing;
      } else {
        final fromConfig = _nonBlank(own['deviceId']);
        final fromEnv = _nonBlank(environment[deviceEnvVariable]);
        if (fromConfig != null) {
          source = DeviceSource.config;
          deviceId = fromConfig;
        } else if (fromEnv != null) {
          source = DeviceSource.env;
          deviceId = fromEnv;
        } else {
          final saved = _nonBlank(_savedDevice());
          if (saved != null) {
            source = DeviceSource.saved;
            deviceId = saved;
          }
        }
        if (deviceId != null && !_isSafeDeviceId(deviceId)) {
          notes.add(
            'The device id "$deviceId" has characters that are not allowed, '
            'so no device was chosen. Use the id shown by "flutter_run devices".',
          );
          deviceId = null;
          source = DeviceSource.none;
        }
        if (deviceId != null) {
          toolArgs
            ..add('-d')
            ..add(deviceId);
          toolArgsChanged = true;
        }
      }
    }

    if (toolArgsChanged || rawToolArgs is List) {
      args['toolArgs'] = toolArgs;
    } else if (rawToolArgs != null) {
      args.remove('toolArgs');
    }

    final currentCwd = args['cwd'];
    if (currentCwd is! String || currentCwd.isEmpty) args['cwd'] = cwd;
    if (isFlutter && request == 'launch') {
      final program = args['program'];
      if (program is! String || program.isEmpty) {
        args['program'] = 'lib/main.dart';
      }
    }

    for (final note in notes) {
      _logger.info(note);
    }
    return RewriteResult(
      arguments: args,
      ownConfig: own,
      deviceId: deviceId,
      deviceSource: source,
      notes: List.unmodifiable(notes),
    );
  }

  bool _applyMode(String mode, List<Object?> toolArgs, List<String> notes) {
    switch (mode) {
      case 'debug':
        return false;
      case 'profile':
      case 'release':
        final strings = toolArgs.whereType<String>();
        final present = strings.any(_isModeFlag);
        if (present) {
          notes.add(
            'toolArgs already selects a build mode, so flutterMode "$mode" '
            'was ignored.',
          );
          return false;
        }
        toolArgs.add('--$mode');
        return true;
    }
    notes.add(
      'Ignored flutterMode "$mode": expected debug, profile or release.',
    );
    return false;
  }

  static bool _isModeFlag(String a) =>
      a == '--debug' ||
      a == '--profile' ||
      a == '--release' ||
      a.startsWith('--debug-') ||
      a.startsWith('--profile-');

  /// Returns the device id found in [args] ('' when present but unreadable),
  /// or null when no device flag is present.
  static String? _deviceInToolArgs(List<String> args) {
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (a == '-d' || a == '--device-id') {
        return i + 1 < args.length ? args[i + 1].trim() : '';
      }
      if (a.startsWith('--device-id=')) {
        return a.substring('--device-id='.length).trim();
      }
      if (a.startsWith('-d') && !a.startsWith('--') && a.length > 2) {
        return a.substring(2).trim();
      }
    }
    return null;
  }

  static String? _nonBlank(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
