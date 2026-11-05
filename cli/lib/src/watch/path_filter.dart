import 'package:glob/glob.dart';

import '../common/host_environment.dart';
import '../common/paths.dart';

/// Decides which file system paths may trigger a reload (ADR 0006 D6).
class PathFilter {
  PathFilter({
    required String projectRoot,
    required HostEnvironment env,
    List<String> globs = const [],
  }) : _env = env,
       _root = env.pathContext.normalize(env.pathContext.absolute(projectRoot)),
       _globs = [
         for (final g in globs)
           if (_normalizeGlob(g, env).isNotEmpty)
             Glob(
               _normalizeGlob(g, env),
               caseSensitive: !env.pathsCaseInsensitive,
             ),
       ];

  final HostEnvironment _env;
  final String _root;
  final List<Glob> _globs;

  /// Top-level project folders that are never watched or reported (hidden
  /// segments are ignored at any depth).
  static const Set<String> ignoredSegments = {
    '.dart_tool',
    'build',
    '.git',
    'node_modules',
  };

  /// True for `.dart` files and files matching a glob, unless ignored.
  bool shouldTrigger(String absolutePath) {
    final segments = _relativeSegments(absolutePath);
    if (segments == null || segments.isEmpty) return false;
    if (_hasIgnoredSegment(segments)) return false;
    final name = segments.last;
    if (name.toLowerCase().endsWith('.dart')) return true;
    final relative = segments.join('/');
    return _globs.any((g) => g.matches(relative));
  }

  /// True when the path is outside the project or has an ignored segment.
  bool isIgnored(String absolutePath) {
    final segments = _relativeSegments(absolutePath);
    if (segments == null) return true;
    return _hasIgnoredSegment(segments);
  }

  /// [absolutePath] relative to the project root with `/` separators, or null
  /// when it lies outside the project.
  String? relativePath(String absolutePath) =>
      _relativeSegments(absolutePath)?.join('/');

  bool _hasIgnoredSegment(List<String> segments) {
    for (final s in segments) {
      if (s.startsWith('.')) return true;
    }
    // Generated folders only matter at the top level of the project.
    if (segments.isEmpty) return false;
    final first = _env.pathsCaseInsensitive
        ? segments.first.toLowerCase()
        : segments.first;
    return ignoredSegments.contains(first);
  }

  List<String>? _relativeSegments(String absolutePath) {
    final ctx = _env.pathContext;
    final normalized = ctx.normalize(ctx.absolute(absolutePath));
    if (!isWithin(_root, normalized, _env)) return null;
    // Compare lengths on the normalised strings: case folding keeps length.
    var rest = normalized.substring(
      normalized.length < _root.length ? normalized.length : _root.length,
    );
    rest = rest.replaceAll('\\', '/');
    return rest.split('/').where((s) => s.isNotEmpty && s != '.').toList();
  }

  static String _normalizeGlob(String glob, HostEnvironment env) {
    var g = glob.trim();
    if (env.isWindows) g = g.replaceAll('\\', '/');
    while (g.startsWith('./')) {
      g = g.substring(2);
    }
    return g;
  }

  static final RegExp _magic = RegExp(r'[*?\[\]{}()!\\]');

  /// Absolute directories to watch: `lib`, `bin` (Dart programs only) and the
  /// static directory prefix of every glob. Whether a directory exists is for
  /// the watcher to decide. Globs without a usable directory prefix (such as
  /// `**.json`) are added to [rejectedGlobs].
  static List<String> watchDirectories({
    required String projectRoot,
    required bool isDartProgram,
    required List<String> globs,
    required HostEnvironment env,
    List<String>? rejectedGlobs,
  }) {
    final ctx = env.pathContext;
    final root = ctx.normalize(ctx.absolute(projectRoot));
    final prefixes = <String>['lib', if (isDartProgram) 'bin'];

    for (final glob in globs) {
      final prefix = _staticPrefix(_normalizeGlob(glob, env), env);
      if (prefix == null) {
        rejectedGlobs?.add(glob);
      } else {
        prefixes.add(prefix);
      }
    }

    final dirs = <String>[];
    for (final prefix in prefixes) {
      final dir = ctx.normalize(ctx.join(root, prefix));
      if (dirs.any((d) => isWithin(d, dir, env))) continue;
      dirs.removeWhere((d) => isWithin(dir, d, env));
      dirs.add(dir);
    }
    return dirs;
  }

  static String? _staticPrefix(String glob, HostEnvironment env) {
    if (glob.isEmpty || glob.startsWith('/')) return null;
    if (RegExp(r'^[A-Za-z]:').hasMatch(glob)) return null;
    final segments = glob.split('/').where((s) => s.isNotEmpty && s != '.');
    final list = segments.toList();
    final prefix = <String>[];
    // The last segment is the file pattern, never part of the directory.
    for (var i = 0; i < list.length - 1; i++) {
      if (_magic.hasMatch(list[i])) break;
      prefix.add(list[i]);
    }
    if (prefix.isEmpty) return null;
    final first = env.pathsCaseInsensitive
        ? prefix.first.toLowerCase()
        : prefix.first;
    if (ignoredSegments.contains(first)) return null;
    for (final s in prefix) {
      if (s == '..' || s.startsWith('.') || s.toLowerCase() == 'pods') {
        return null;
      }
    }
    return prefix.join('/');
  }
}
