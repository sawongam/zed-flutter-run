import 'dart:convert';
import 'dart:io';

import '../common/files.dart';
import '../common/host_environment.dart';
import '../common/json_types.dart';
import '../common/logger.dart';
import '../common/paths.dart';

/// The device the user chose for a project.
class SavedDevice {
  const SavedDevice({
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.savedAt,
  });

  /// Throws [FormatException] when a required field is missing.
  factory SavedDevice.fromJson(Json j) {
    final id = j['deviceId'];
    final name = j['name'];
    final platform = j['platform'];
    final at = j['savedAt'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('The saved device has no deviceId.');
    }
    return SavedDevice(
      deviceId: id,
      name: name is String ? name : id,
      platform: platform is String ? platform : 'unknown',
      savedAt: (at is String ? DateTime.tryParse(at) : null) ?? DateTime.now(),
    );
  }

  final String deviceId;
  final String name;
  final String platform;
  final DateTime savedAt;

  Json toJson() => <String, Object?>{
    'deviceId': deviceId,
    'name': name,
    'platform': platform,
    'savedAt': savedAt.toUtc().toIso8601String(),
  };
}

/// Saved device per project, in the per-user state directory (ADR 0006 D7).
class DeviceStore {
  DeviceStore(this._env, {Logger? logger})
    : _logger = logger ?? Logger.silent();

  static const int fileVersion = 1;

  final HostEnvironment _env;
  final Logger _logger;

  /// `<stateBaseDirectory>/devices/<projectRootHash>.json`.
  String filePath(String projectRoot) => _env.pathContext.join(
    stateBaseDirectory(_env),
    'devices',
    '${projectRootHash(projectRoot, _env)}.json',
  );

  /// The saved device, or null when missing, malformed or of another version.
  SavedDevice? readSync(String projectRoot) {
    try {
      final file = File(filePath(projectRoot));
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, Object?>) {
        _logger.debug('Ignoring device file ${file.path}: not an object.');
        return null;
      }
      if (decoded['version'] != fileVersion) {
        _logger.debug(
          'Ignoring device file ${file.path}: version ${decoded['version']}.',
        );
        return null;
      }
      final stored = decoded['projectRoot'];
      if (stored is String && !pathsEqual(stored, projectRoot, _env)) {
        _logger.debug('Ignoring device file ${file.path}: other project.');
        return null;
      }
      return SavedDevice.fromJson(decoded);
    } on Object catch (e) {
      _logger.debug('Ignoring unreadable device file: $e');
      return null;
    }
  }

  Future<void> write(String projectRoot, SavedDevice device) async {
    final json = <String, Object?>{
      'version': fileVersion,
      'projectRoot': projectRoot,
      ...device.toJson(),
    };
    await atomicWriteString(
      filePath(projectRoot),
      '${const JsonEncoder.withIndent('  ').convert(json)}\n',
      env: _env,
    );
  }

  /// Removes the saved device; true when there was one.
  Future<bool> clear(String projectRoot) async {
    final file = File(filePath(projectRoot));
    if (!file.existsSync()) return false;
    try {
      await file.delete();
      return true;
    } on FileSystemException catch (e) {
      _logger.debug('Could not delete ${file.path}: $e');
      return file.existsSync() ? throw e : false;
    }
  }
}
