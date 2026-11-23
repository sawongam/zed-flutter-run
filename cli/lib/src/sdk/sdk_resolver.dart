import 'dart:convert';

import 'package:path/path.dart' as p;

import '../common/errors.dart';
import '../common/host_environment.dart';
import '../common/logger.dart';
import '../common/paths.dart';
import 'sdk_steps.dart';

enum SdkKind { flutter, dart }

/// A resolved Flutter SDK (or a launcher shim for one).
class FlutterSdk {
  FlutterSdk({
    required this.root,
    required this.flutterExecutable,
    required this.sourceStep,
    this.bundledDartExecutable,
    SdkFileSystem? fileSystem,
  }) : _fs = fileSystem ?? LocalSdkFileSystem();

  /// Null for shims that cannot be traced back to an SDK folder.
  final String? root;

  /// Absolute path to `bin/flutter(.bat)` or the shim as found.
  final String flutterExecutable;
  final String? bundledDartExecutable;

  /// `ResolutionStep.id` that produced this SDK.
  final String sourceStep;
  final SdkFileSystem _fs;

  /// Flutter framework version, read from `<root>/version` (or the cached
  /// `bin/cache/flutter.version.json`); no subprocess.
  String? get flutterVersion {
    final r = root;
    if (r == null) return null;
    final plain = _firstLine(_fs.readText(p.join(r, 'version')));
    if (plain != null) return plain;
    final json = _fs.readText(
      p.join(r, 'bin', 'cache', 'flutter.version.json'),
    );
    if (json == null) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map && decoded['frameworkVersion'] is String) {
        return decoded['frameworkVersion'] as String;
      }
    } on FormatException {
      // Malformed cache file: no version.
    }
    return null;
  }

  /// Dart version of the bundled SDK, from `bin/cache/dart-sdk/version`.
  String? get dartVersion {
    final r = root;
    if (r == null) return null;
    return _firstLine(
      _fs.readText(p.join(r, 'bin', 'cache', 'dart-sdk', 'version')),
    );
  }

  static String? _firstLine(String? text) {
    if (text == null) return null;
    final line = text.split(RegExp(r'\r?\n')).first.trim();
    return line.isEmpty ? null : line;
  }
}

class SdkResolution {
  const SdkResolution({
    this.flutter,
    this.dartExecutable,
    this.trace = const <ResolutionStep>[],
  });

  final FlutterSdk? flutter;

  /// Set for [SdkKind.dart].
  final String? dartExecutable;
  final List<ResolutionStep> trace;

  /// One line per step, for `doctor` and error messages.
  String describeTrace() {
    final buffer = StringBuffer();
    for (var i = 0; i < trace.length; i++) {
      if (i > 0) buffer.writeln();
      buffer.write('${i + 1}. ${trace[i]}');
    }
    return buffer.toString();
  }
}

/// How to point flutter_run at an SDK when none was found.
const String sdkSearchHint =
    'Set flutterSdkPath in the launch entry (or pass --flutter-sdk), set the '
    'FLUTTER_RUN_FLUTTER_SDK environment variable, or put flutter on your '
    'PATH.';

final RegExp _versionPattern = RegExp(r'^[A-Za-z0-9_@\-][A-Za-z0-9._@\-]*$');

class SdkResolver {
  SdkResolver(this.env, {Logger? logger, SdkFileSystem? fileSystem})
    : _logger = logger ?? Logger.silent(),
      _fs = fileSystem ?? LocalSdkFileSystem(env);

  final HostEnvironment env;
  final Logger _logger;
  final SdkFileSystem _fs;

  p.Context get _ctx => env.pathContext;
  String get _flutterBin => env.isWindows ? 'flutter.bat' : 'flutter';
  String get _dartBin => env.isWindows ? 'dart.exe' : 'dart';

  Future<SdkResolution> resolve({
    required String projectDir,
    SdkKind kind = SdkKind.flutter,
    String? explicitSdkPath,
    bool strictFvm = false,
  }) async {
    final trace = <ResolutionStep>[];
    final sdk = _walkFlutter(
      projectDir,
      explicitSdkPath,
      strictFvm,
      trace,
      fatalExplicit: kind == SdkKind.flutter,
    );
    final dart = kind == SdkKind.dart
        ? _resolveDart(sdk, strictFvm, trace)
        : null;
    return SdkResolution(
      flutter: sdk,
      dartExecutable: dart,
      trace: List.unmodifiable(trace),
    );
  }

  Future<SdkResolution> resolveOrThrow({
    required String projectDir,
    SdkKind kind = SdkKind.flutter,
    String? explicitSdkPath,
    bool strictFvm = false,
  }) async {
    final result = await resolve(
      projectDir: projectDir,
      kind: kind,
      explicitSdkPath: explicitSdkPath,
      strictFvm: strictFvm,
    );
    final ok = kind == SdkKind.flutter
        ? result.flutter != null
        : result.dartExecutable != null;
    if (ok) return result;
    final what = kind == SdkKind.flutter ? 'Flutter' : 'Dart';
    final explicitBad = result.trace.any(
      (s) => s.id == 'explicit' && s.outcome == StepOutcome.invalid,
    );
    final String headline;
    final String hint;
    if (explicitBad && kind == SdkKind.flutter) {
      headline =
          'The Flutter SDK folder you configured does not contain ${_ctx.join('bin', _flutterBin)}.';
      hint = 'Fix the flutterSdkPath setting (or the --flutter-sdk option) so it points to the root of a Flutter SDK, or remove it to let flutter_run search.';
    } else if (strictFvm) {
      headline = 'No Flutter SDK was found through fvm for this project, and fvm is required (useFvm).';
      hint = 'Run "fvm use" in the project so that .fvm/flutter_sdk exists, install the version listed in .fvmrc, or turn off useFvm.';
    } else {
      headline = 'Could not find a $what SDK.';
      hint = sdkSearchHint;
    }
    throw SdkNotFoundException(
      '$headline\nLocations that were tried:\n${result.describeTrace()}',
      hint: hint,
    );
  }

  // ---------------------------------------------------------------- flutter

  /// Walks the lookup order; every step adds one entry to [trace].
  FlutterSdk? _walkFlutter(
    String projectDir,
    String? explicit,
    bool strict,
    List<ResolutionStep> trace, {
    required bool fatalExplicit,
  }) {
    FlutterSdk? done(FlutterSdk? sdk) {
      if (sdk != null) _logger.debug('SDK resolved by ${sdk.sourceStep}.');
      return sdk;
    }

    final byOption = _namedRoot(
      trace,
      'explicit',
      'Option --flutter-sdk / setting flutterSdkPath',
      explicit,
      relativeTo: projectDir,
    );
    if (byOption != null) return done(byOption);
    // A path the user configured explicitly must not fall back silently.
    if (fatalExplicit && trace.last.outcome == StepOutcome.invalid) return null;

    final byEnv = _namedRoot(
      trace,
      'env',
      'Environment variable FLUTTER_RUN_FLUTTER_SDK',
      env.env('FLUTTER_RUN_FLUTTER_SDK'),
    );
    if (byEnv != null) return done(byEnv);

    final byLink = _fvmLink(projectDir, trace);
    if (byLink != null) return done(byLink);

    final version = _fvmVersion(projectDir, trace);
    final byCache = _fvmCache(version, trace);
    if (byCache != null) return done(byCache);

    if (strict) {
      const why = 'useFvm is on, so only fvm sources are used';
      trace.addAll(const [
        ResolutionStep('puro', 'puro environment', StepOutcome.skipped, why),
        ResolutionStep(
          'flutter-root',
          'Environment variable FLUTTER_ROOT',
          StepOutcome.skipped,
          why,
        ),
        ResolutionStep('path', 'flutter on PATH', StepOutcome.skipped, why),
      ]);
      return null;
    }

    final byPuro = _puro(projectDir, trace);
    if (byPuro != null) return done(byPuro);

    final byFlutterRoot = _namedRoot(
      trace,
      'flutter-root',
      'Environment variable FLUTTER_ROOT',
      env.env('FLUTTER_ROOT'),
    );
    if (byFlutterRoot != null) return done(byFlutterRoot);

    return done(_flutterOnPath(trace));
  }

  /// A step whose value is the path of an SDK root: the `--flutter-sdk`
  /// option, `FLUTTER_RUN_FLUTTER_SDK` or `FLUTTER_ROOT`. A relative [value]
  /// is taken relative to [relativeTo].
  FlutterSdk? _namedRoot(
    List<ResolutionStep> trace,
    String id,
    String description,
    String? value, {
    String? relativeTo,
  }) {
    final path = value?.trim() ?? '';
    if (path.isEmpty) {
      trace.add(
        ResolutionStep(id, description, StepOutcome.skipped, 'not set'),
      );
      return null;
    }
    final root = relativeTo == null || _ctx.isAbsolute(path)
        ? path
        : _ctx.join(_ctx.absolute(relativeTo), path);
    final sdk = _fromRoot(root, id);
    trace.add(
      sdk != null
          ? ResolutionStep(id, description, StepOutcome.found, sdk.root)
          : ResolutionStep(
              id,
              description,
              StepOutcome.invalid,
              '$path has no ${_ctx.join('bin', _flutterBin)}',
            ),
    );
    return sdk;
  }

  FlutterSdk? _fvmLink(String projectDir, List<ResolutionStep> trace) {
    const description = 'fvm link .fvm/flutter_sdk in the project or a parent';
    final link = _findUp(projectDir, _ctx.join('.fvm', 'flutter_sdk'));
    if (link == null) {
      trace.add(
        const ResolutionStep('fvm-link', description, StepOutcome.notFound),
      );
      return null;
    }
    final target = _fs.resolveLink(link);
    final sdk = target == null ? null : _fromRoot(target, 'fvm-link');
    trace.add(
      sdk != null
          ? ResolutionStep('fvm-link', description, StepOutcome.found, sdk.root)
          : ResolutionStep(
              'fvm-link',
              description,
              StepOutcome.invalid,
              '$link does not lead to a Flutter SDK '
                  '(target: ${target ?? 'unreadable'})',
            ),
    );
    return sdk;
  }

  /// The fvm version from `.fvmrc`, else from the legacy
  /// `.fvm/fvm_config.json`; null when neither names one.
  String? _fvmVersion(String projectDir, List<ResolutionStep> trace) {
    final fromRc = _versionFile(
      trace,
      projectDir,
      id: 'fvmrc',
      description: 'fvm file .fvmrc in the project or a parent',
      relative: '.fvmrc',
      key: 'flutter',
    );
    const legacyDescription =
        'fvm file .fvm/fvm_config.json in the project or a parent';
    if (fromRc != null) {
      trace.add(
        const ResolutionStep(
          'fvm-legacy',
          legacyDescription,
          StepOutcome.skipped,
          'a version came from .fvmrc',
        ),
      );
      return fromRc;
    }
    return _versionFile(
      trace,
      projectDir,
      id: 'fvm-legacy',
      description: legacyDescription,
      relative: _ctx.join('.fvm', 'fvm_config.json'),
      key: 'flutterSdkVersion',
    );
  }

  String? _versionFile(
    List<ResolutionStep> trace,
    String projectDir, {
    required String id,
    required String description,
    required String relative,
    required String key,
  }) {
    final file = _findUp(projectDir, relative);
    if (file == null) {
      trace.add(ResolutionStep(id, description, StepOutcome.notFound));
      return null;
    }
    final version = _jsonString(_fs.readText(file), key);
    if (version != null && _versionPattern.hasMatch(version)) {
      trace.add(
        ResolutionStep(
          id,
          description,
          StepOutcome.found,
          'version $version (SDK is looked up in the fvm cache)',
        ),
      );
      return version;
    }
    trace.add(
      ResolutionStep(
        id,
        description,
        StepOutcome.invalid,
        '$file has no usable "$key"',
      ),
    );
    return null;
  }

  FlutterSdk? _fvmCache(String? version, List<ResolutionStep> trace) {
    const description =
        'fvm cache (FVM_CACHE_PATH, FVM_HOME or the home folder)';
    if (version == null) {
      trace.add(
        const ResolutionStep(
          'fvm-cache',
          description,
          StepOutcome.skipped,
          'no fvm version file found',
        ),
      );
      return null;
    }
    final candidates = fvmCacheCandidates(version);
    for (final candidate in candidates) {
      final sdk = _fromRoot(candidate, 'fvm-cache');
      if (sdk != null) {
        trace.add(
          ResolutionStep('fvm-cache', description, StepOutcome.found, sdk.root),
        );
        return sdk;
      }
    }
    trace.add(
      ResolutionStep(
        'fvm-cache',
        description,
        StepOutcome.notFound,
        'version $version is not installed in: ${candidates.join(', ')}',
      ),
    );
    return null;
  }

  FlutterSdk? _puro(String projectDir, List<ResolutionStep> trace) {
    const description = 'puro file .puro.json in the project or a parent';
    final file = _findUp(projectDir, '.puro.json');
    if (file == null) {
      trace.add(
        const ResolutionStep('puro', description, StepOutcome.notFound),
      );
      return null;
    }
    final name = _jsonString(_fs.readText(file), 'env');
    if (name == null || !_versionPattern.hasMatch(name)) {
      trace.add(
        ResolutionStep(
          'puro',
          description,
          StepOutcome.invalid,
          '$file has no usable "env" name',
        ),
      );
      return null;
    }
    final rootEnv = env.env('PURO_ROOT');
    final home = env.home;
    final base = (rootEnv != null && rootEnv.isNotEmpty)
        ? rootEnv
        : (home == null ? null : _ctx.join(home, '.puro'));
    final sdk = base == null
        ? null
        : _fromRoot(_ctx.join(base, 'envs', name, 'flutter'), 'puro');
    trace.add(
      sdk != null
          ? ResolutionStep('puro', description, StepOutcome.found, sdk.root)
          : ResolutionStep(
              'puro',
              description,
              StepOutcome.notFound,
              base == null
                  ? 'no home folder and PURO_ROOT is not set'
                  : 'environment "$name" is not installed under $base',
            ),
    );
    return sdk;
  }

  FlutterSdk? _flutterOnPath(List<ResolutionStep> trace) {
    const description = 'flutter on PATH';
    final onPath = findExecutableOnPath(
      'flutter',
      env,
      isExecutableFile: _fs.isExecutableFile,
    );
    if (onPath == null) {
      trace.add(
        const ResolutionStep('path', description, StepOutcome.notFound),
      );
      return null;
    }
    // Follow symlinks (Homebrew, snap): the SDK folder is above the real bin/.
    final real = _fs.resolveLink(onPath) ?? onPath;
    final binDir = _ctx.dirname(real);
    final base = _ctx.basename(real).toLowerCase();
    if ((base == 'flutter' || base == 'flutter.bat') &&
        _ctx.basename(binDir) == 'bin') {
      final candidateRoot = _ctx.dirname(binDir);
      final looksLikeSdk =
          _fs.exists(
            _ctx.join(candidateRoot, 'bin', 'internal', 'engine.version'),
          ) ||
          _fs.isDirectory(_ctx.join(candidateRoot, 'packages', 'flutter'));
      final sdk = looksLikeSdk ? _fromRoot(candidateRoot, 'path') : null;
      if (sdk != null) {
        trace.add(
          ResolutionStep('path', description, StepOutcome.found, sdk.root),
        );
        return sdk;
      }
    }
    // A shim (asdf, mise, a wrapper script): use it as found.
    trace.add(
      ResolutionStep(
        'path',
        description,
        StepOutcome.found,
        '$onPath (launcher; the SDK folder is unknown)',
      ),
    );
    return FlutterSdk(
      root: null,
      flutterExecutable: onPath,
      sourceStep: 'path',
      fileSystem: _fs,
    );
  }

  FlutterSdk? _fromRoot(String root, String step) {
    final abs = _ctx.normalize(_ctx.absolute(root));
    final exe = _ctx.join(abs, 'bin', _flutterBin);
    if (!_fs.isFile(exe)) return null;
    final dart = _ctx.join(abs, 'bin', 'cache', 'dart-sdk', 'bin', _dartBin);
    return FlutterSdk(
      root: abs,
      flutterExecutable: exe,
      bundledDartExecutable: _fs.isFile(dart) ? dart : null,
      sourceStep: step,
      fileSystem: _fs,
    );
  }

  /// Candidate fvm cache folders for [version], in lookup order.
  List<String> fvmCacheCandidates(String version) {
    final out = <String>[];
    void add(String? base) {
      if (base == null || base.isEmpty) return;
      final c = _ctx.join(base, 'versions', version);
      if (!out.contains(c)) out.add(c);
    }

    add(env.env('FVM_CACHE_PATH'));
    add(env.env('FVM_HOME'));
    final home = env.home;
    if (home != null) add(_ctx.join(home, 'fvm'));
    if (env.isWindows) {
      final local = env.env('LOCALAPPDATA');
      if (local != null && local.isNotEmpty) add(_ctx.join(local, 'fvm'));
    }
    return out;
  }

  // ------------------------------------------------------------------- dart

  String? _resolveDart(
    FlutterSdk? flutter,
    bool strict,
    List<ResolutionStep> trace,
  ) {
    const bundledDesc = 'Dart bundled with the Flutter SDK';
    final bundled = flutter?.bundledDartExecutable;
    if (flutter == null) {
      trace.add(
        const ResolutionStep(
          'bundled-dart',
          bundledDesc,
          StepOutcome.skipped,
          'no Flutter SDK was found',
        ),
      );
    } else if (bundled == null) {
      trace.add(
        ResolutionStep(
          'bundled-dart',
          bundledDesc,
          StepOutcome.notFound,
          flutter.root == null ? 'the Flutter command is a launcher' : 'bin/cache/dart-sdk is missing; run flutter once to download it',
        ),
      );
    } else {
      trace.add(
        ResolutionStep('bundled-dart', bundledDesc, StepOutcome.found, bundled),
      );
      return bundled;
    }
    if (strict) {
      trace.add(
        const ResolutionStep(
          'dart-sdk-env',
          'Environment variable DART_SDK',
          StepOutcome.skipped,
          'useFvm is on',
        ),
      );
      trace.add(
        const ResolutionStep(
          'dart-path',
          'dart on PATH',
          StepOutcome.skipped,
          'useFvm is on',
        ),
      );
      return null;
    }

    const envDesc = 'Environment variable DART_SDK';
    final dartSdk = env.env('DART_SDK');
    if (dartSdk == null || dartSdk.isEmpty) {
      trace.add(
        const ResolutionStep(
          'dart-sdk-env',
          envDesc,
          StepOutcome.skipped,
          'not set',
        ),
      );
    } else {
      final exe = _ctx.join(dartSdk, 'bin', _dartBin);
      if (_fs.isFile(exe)) {
        trace.add(
          ResolutionStep('dart-sdk-env', envDesc, StepOutcome.found, exe),
        );
        return exe;
      }
      trace.add(
        ResolutionStep(
          'dart-sdk-env',
          envDesc,
          StepOutcome.invalid,
          '$exe does not exist',
        ),
      );
    }

    const pathDesc = 'dart on PATH';
    final onPath = findExecutableOnPath(
      'dart',
      env,
      isExecutableFile: _fs.isExecutableFile,
    );
    if (onPath == null) {
      trace.add(
        const ResolutionStep('dart-path', pathDesc, StepOutcome.notFound),
      );
      return null;
    }
    trace.add(ResolutionStep('dart-path', pathDesc, StepOutcome.found, onPath));
    return onPath;
  }

  // ---------------------------------------------------------------- helpers

  String? _findUp(String startDir, String relative) =>
      findUpwards(startDir, relative, env, exists: _fs.exists);

  static String? _jsonString(String? text, String key) {
    if (text == null) return null;
    try {
      final decoded = jsonDecode(text.replaceFirst('\uFEFF', ''));
      if (decoded is Map) {
        final value = decoded[key];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
    } on FormatException {
      // Malformed JSON counts as no value.
    }
    return null;
  }
}
