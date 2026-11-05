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
    SdkFileSystem fileSystem = const LocalSdkFileSystem(),
  }) : _fs = fileSystem;

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
      // Ignore.
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

final RegExp _versionPattern = RegExp(r'^[A-Za-z0-9_@\-][A-Za-z0-9._@\-]*$');

class SdkResolver {
  SdkResolver(
    this.env, {
    Logger? logger,
    SdkFileSystem fileSystem = const LocalSdkFileSystem(),
  }) : _logger = logger ?? Logger.silent(),
       _fs = fileSystem;

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
    final fatalExplicit = kind == SdkKind.flutter;
    final sdk = _walkFlutter(
      projectDir,
      explicitSdkPath,
      strictFvm,
      trace,
      fatalExplicit: fatalExplicit,
    );
    if (kind == SdkKind.flutter) {
      return SdkResolution(flutter: sdk, trace: List.unmodifiable(trace));
    }
    final dart = _resolveDart(sdk, strictFvm, trace);
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
      hint =
          'Fix the flutterSdkPath setting (or the --flutter-sdk option) so it points to the root of a Flutter SDK, or remove it to let flutter_run search.';
    } else if (strictFvm) {
      headline =
          'No Flutter SDK was found through fvm for this project, and fvm is required (useFvm).';
      hint =
          'Run "fvm use" in the project so that .fvm/flutter_sdk exists, install the version listed in .fvmrc, or turn off useFvm.';
    } else {
      headline = 'Could not find a $what SDK.';
      hint =
          'Set flutterSdkPath in the launch entry (or pass --flutter-sdk), set the FLUTTER_RUN_FLUTTER_SDK environment variable, or put flutter on your PATH.';
    }
    final tried = [for (final s in result.trace) s.toString()];
    throw SdkNotFoundException(
      '$headline\nLocations that were tried:\n${result.describeTrace()}',
      tried: tried,
      hint: hint,
    );
  }

  // ---------------------------------------------------------------- flutter

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

    // 1. explicit
    const explicitDesc = 'Option --flutter-sdk / setting flutterSdkPath';
    if (explicit == null || explicit.trim().isEmpty) {
      trace.add(
        const ResolutionStep(
          'explicit',
          explicitDesc,
          StepOutcome.skipped,
          'not set',
        ),
      );
    } else {
      final explicitPath = _ctx.normalize(
        _ctx.isAbsolute(explicit.trim())
            ? explicit.trim()
            : _ctx.join(_ctx.absolute(projectDir), explicit.trim()),
      );
      final sdk = _fromRoot(explicitPath, 'explicit');
      if (sdk != null) {
        trace.add(
          ResolutionStep('explicit', explicitDesc, StepOutcome.found, sdk.root),
        );
        return done(sdk);
      }
      trace.add(
        ResolutionStep(
          'explicit',
          explicitDesc,
          StepOutcome.invalid,
          '${explicit.trim()} has no ${_ctx.join('bin', _flutterBin)}',
        ),
      );
      if (fatalExplicit) return null;
    }

    // 2. env
    const envDesc = 'Environment variable FLUTTER_RUN_FLUTTER_SDK';
    final fromEnv = env.env('FLUTTER_RUN_FLUTTER_SDK');
    if (fromEnv == null || fromEnv.trim().isEmpty) {
      trace.add(
        const ResolutionStep('env', envDesc, StepOutcome.skipped, 'not set'),
      );
    } else {
      final sdk = _fromRoot(fromEnv.trim(), 'env');
      if (sdk != null) {
        trace.add(ResolutionStep('env', envDesc, StepOutcome.found, sdk.root));
        return done(sdk);
      }
      trace.add(
        ResolutionStep(
          'env',
          envDesc,
          StepOutcome.invalid,
          '${fromEnv.trim()} has no ${_ctx.join('bin', _flutterBin)}',
        ),
      );
    }

    // 3. fvm-link
    const linkDesc = 'fvm link .fvm/flutter_sdk in the project or a parent';
    final link = _findUp(projectDir, _ctx.join('.fvm', 'flutter_sdk'));
    if (link == null) {
      trace.add(
        const ResolutionStep('fvm-link', linkDesc, StepOutcome.notFound),
      );
    } else {
      final target = _fs.resolveLink(link);
      final sdk = target == null ? null : _fromRoot(target, 'fvm-link');
      if (sdk != null) {
        trace.add(
          ResolutionStep('fvm-link', linkDesc, StepOutcome.found, sdk.root),
        );
        return done(sdk);
      }
      trace.add(
        ResolutionStep(
          'fvm-link',
          linkDesc,
          StepOutcome.invalid,
          '$link does not lead to a Flutter SDK (target: ${target ?? 'unreadable'})',
        ),
      );
    }

    // 4 / 4b. fvm version files
    String? version;
    const rcDesc = 'fvm file .fvmrc in the project or a parent';
    final rc = _findUp(projectDir, '.fvmrc');
    if (rc == null) {
      trace.add(const ResolutionStep('fvmrc', rcDesc, StepOutcome.notFound));
    } else {
      final v = _jsonString(_fs.readText(rc), 'flutter');
      if (v != null && _versionPattern.hasMatch(v)) {
        version = v;
        trace.add(
          ResolutionStep(
            'fvmrc',
            rcDesc,
            StepOutcome.found,
            'version $v (SDK is looked up in the fvm cache)',
          ),
        );
      } else {
        trace.add(
          ResolutionStep(
            'fvmrc',
            rcDesc,
            StepOutcome.invalid,
            '$rc has no usable "flutter" version',
          ),
        );
      }
    }
    const legacyDesc =
        'fvm file .fvm/fvm_config.json in the project or a parent';
    if (version != null) {
      trace.add(
        const ResolutionStep(
          'fvm-legacy',
          legacyDesc,
          StepOutcome.skipped,
          'a version came from .fvmrc',
        ),
      );
    } else {
      final legacy = _findUp(projectDir, _ctx.join('.fvm', 'fvm_config.json'));
      if (legacy == null) {
        trace.add(
          const ResolutionStep('fvm-legacy', legacyDesc, StepOutcome.notFound),
        );
      } else {
        final v = _jsonString(_fs.readText(legacy), 'flutterSdkVersion');
        if (v != null && _versionPattern.hasMatch(v)) {
          version = v;
          trace.add(
            ResolutionStep(
              'fvm-legacy',
              legacyDesc,
              StepOutcome.found,
              'version $v (SDK is looked up in the fvm cache)',
            ),
          );
        } else {
          trace.add(
            ResolutionStep(
              'fvm-legacy',
              legacyDesc,
              StepOutcome.invalid,
              '$legacy has no usable "flutterSdkVersion"',
            ),
          );
        }
      }
    }

    // 5. fvm-cache
    const cacheDesc = 'fvm cache (FVM_CACHE_PATH, FVM_HOME or the home folder)';
    if (version == null) {
      trace.add(
        const ResolutionStep(
          'fvm-cache',
          cacheDesc,
          StepOutcome.skipped,
          'no fvm version file found',
        ),
      );
    } else {
      final candidates = fvmCacheCandidates(version);
      FlutterSdk? found;
      for (final c in candidates) {
        found = _fromRoot(c, 'fvm-cache');
        if (found != null) break;
      }
      if (found != null) {
        trace.add(
          ResolutionStep('fvm-cache', cacheDesc, StepOutcome.found, found.root),
        );
        return done(found);
      }
      trace.add(
        ResolutionStep(
          'fvm-cache',
          cacheDesc,
          StepOutcome.notFound,
          'version $version is not installed in: ${candidates.join(', ')}',
        ),
      );
    }

    if (strict) {
      const why = 'useFvm is on, so only fvm sources are used';
      trace
        ..add(
          const ResolutionStep(
            'puro',
            'puro environment',
            StepOutcome.skipped,
            why,
          ),
        )
        ..add(
          const ResolutionStep(
            'flutter-root',
            'Environment variable FLUTTER_ROOT',
            StepOutcome.skipped,
            why,
          ),
        )
        ..add(
          const ResolutionStep(
            'path',
            'flutter on PATH',
            StepOutcome.skipped,
            why,
          ),
        );
      return null;
    }

    // 6. puro
    const puroDesc = 'puro file .puro.json in the project or a parent';
    final puroFile = _findUp(projectDir, '.puro.json');
    if (puroFile == null) {
      trace.add(const ResolutionStep('puro', puroDesc, StepOutcome.notFound));
    } else {
      final name = _jsonString(_fs.readText(puroFile), 'env');
      if (name == null || !_versionPattern.hasMatch(name)) {
        trace.add(
          ResolutionStep(
            'puro',
            puroDesc,
            StepOutcome.invalid,
            '$puroFile has no usable "env" name',
          ),
        );
      } else {
        final rootEnv = env.env('PURO_ROOT');
        final base = (rootEnv != null && rootEnv.isNotEmpty)
            ? rootEnv
            : (env.home == null ? null : _ctx.join(env.home!, '.puro'));
        final sdk = base == null
            ? null
            : _fromRoot(_ctx.join(base, 'envs', name, 'flutter'), 'puro');
        if (sdk != null) {
          trace.add(
            ResolutionStep('puro', puroDesc, StepOutcome.found, sdk.root),
          );
          return done(sdk);
        }
        trace.add(
          ResolutionStep(
            'puro',
            puroDesc,
            StepOutcome.notFound,
            base == null
                ? 'no home folder and PURO_ROOT is not set'
                : 'environment "$name" is not installed under $base',
          ),
        );
      }
    }

    // 7. FLUTTER_ROOT
    const rootDesc = 'Environment variable FLUTTER_ROOT';
    final flutterRoot = env.env('FLUTTER_ROOT');
    if (flutterRoot == null || flutterRoot.trim().isEmpty) {
      trace.add(
        const ResolutionStep(
          'flutter-root',
          rootDesc,
          StepOutcome.skipped,
          'not set',
        ),
      );
    } else {
      final sdk = _fromRoot(flutterRoot.trim(), 'flutter-root');
      if (sdk != null) {
        trace.add(
          ResolutionStep('flutter-root', rootDesc, StepOutcome.found, sdk.root),
        );
        return done(sdk);
      }
      trace.add(
        ResolutionStep(
          'flutter-root',
          rootDesc,
          StepOutcome.invalid,
          '${flutterRoot.trim()} has no ${_ctx.join('bin', _flutterBin)}',
        ),
      );
    }

    // 8. PATH
    const pathDesc = 'flutter on PATH';
    final onPath = findExecutableOnPath(
      'flutter',
      env,
      isExecutableFile: _fs.isExecutableFile,
    );
    if (onPath == null) {
      trace.add(const ResolutionStep('path', pathDesc, StepOutcome.notFound));
      return null;
    }
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
          ResolutionStep('path', pathDesc, StepOutcome.found, sdk.root),
        );
        return done(sdk);
      }
    }
    // A shim (asdf, mise, a wrapper script): use it as found.
    trace.add(
      ResolutionStep(
        'path',
        pathDesc,
        StepOutcome.found,
        '$onPath (launcher; the SDK folder is unknown)',
      ),
    );
    return done(
      FlutterSdk(
        root: null,
        flutterExecutable: onPath,
        sourceStep: 'path',
        fileSystem: _fs,
      ),
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
          flutter.root == null
              ? 'the Flutter command is a launcher'
              : 'bin/cache/dart-sdk is missing; run flutter once to download it',
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

  String? _findUp(String startDir, String relative) {
    var dir = _ctx.normalize(_ctx.absolute(startDir));
    while (true) {
      final candidate = _ctx.join(dir, relative);
      if (_fs.exists(candidate)) return candidate;
      final parent = _ctx.dirname(dir);
      if (parent == dir) return null;
      dir = parent;
    }
  }

  static String? _jsonString(String? text, String key) {
    if (text == null) return null;
    try {
      final decoded = jsonDecode(text.replaceFirst('﻿', ''));
      if (decoded is Map) {
        final value = decoded[key];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
    } on FormatException {
      // Fall through.
    }
    return null;
  }
}
