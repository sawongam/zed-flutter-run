import '../common/json_types.dart';

/// When a save triggers a hot reload.
enum ReloadOnSaveMode { changed, always, off }

/// Reload-on-save settings taken from the stripped launch keys
/// `reloadOnSave`, `reloadOnSaveGlobs` and `reloadOnSaveDebounceMs`.
class ReloadOnSaveConfig {
  const ReloadOnSaveConfig({
    this.mode = ReloadOnSaveMode.changed,
    this.globs = const [],
    this.debounce = const Duration(milliseconds: 200),
    this.warnings = const [],
  });

  /// Tolerant parser: bad values fall back to the defaults and add a warning.
  factory ReloadOnSaveConfig.fromOwnConfig(Json ownConfig) {
    final warnings = <String>[];

    var mode = ReloadOnSaveMode.changed;
    final rawMode = ownConfig['reloadOnSave'];
    if (rawMode == null) {
      // Default.
    } else if (rawMode is bool) {
      mode = rawMode ? ReloadOnSaveMode.changed : ReloadOnSaveMode.off;
    } else if (rawMode is String) {
      switch (rawMode.trim().toLowerCase()) {
        case 'changed':
        case 'true':
          mode = ReloadOnSaveMode.changed;
        case 'always':
          mode = ReloadOnSaveMode.always;
        case 'off':
        case 'false':
          mode = ReloadOnSaveMode.off;
        default:
          warnings.add(
            'Warning: "reloadOnSave" must be "changed", "always" or "off", '
            'but it is "$rawMode". Using "changed".',
          );
      }
    } else {
      warnings.add(
        'Warning: "reloadOnSave" must be "changed", "always" or "off". '
        'Using "changed".',
      );
    }

    final globs = <String>[];
    final rawGlobs = ownConfig['reloadOnSaveGlobs'];
    if (rawGlobs == null) {
      // Default.
    } else if (rawGlobs is List) {
      for (final entry in rawGlobs) {
        if (entry is String && entry.trim().isNotEmpty) {
          globs.add(entry.trim());
        } else {
          warnings.add(
            'Warning: "reloadOnSaveGlobs" must only contain non-empty '
            'strings. Ignoring one entry.',
          );
        }
      }
    } else {
      warnings.add(
        'Warning: "reloadOnSaveGlobs" must be a list of strings. Ignoring it.',
      );
    }

    var millis = defaultDebounceMs;
    final rawDebounce = ownConfig['reloadOnSaveDebounceMs'];
    if (rawDebounce != null) {
      num? parsed;
      if (rawDebounce is num && rawDebounce.isFinite) {
        parsed = rawDebounce;
      } else if (rawDebounce is String) {
        parsed = num.tryParse(rawDebounce.trim());
      }
      if (parsed == null || !parsed.isFinite) {
        warnings.add(
          'Warning: "reloadOnSaveDebounceMs" must be a number of '
          'milliseconds. Using $defaultDebounceMs.',
        );
      } else {
        millis = parsed.round().clamp(minDebounceMs, maxDebounceMs);
      }
    }

    return ReloadOnSaveConfig(
      mode: mode,
      globs: List.unmodifiable(globs),
      debounce: Duration(milliseconds: millis),
      warnings: List.unmodifiable(warnings),
    );
  }

  static const int defaultDebounceMs = 200;
  static const int minDebounceMs = 10;
  static const int maxDebounceMs = 5000;

  final ReloadOnSaveMode mode;
  final List<String> globs;
  final Duration debounce;
  final List<String> warnings;
}
