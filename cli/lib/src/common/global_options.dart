import 'package:args/args.dart';
import 'package:args/command_runner.dart';

/// Flags shared by the runner and every command.
class GlobalOptions {
  const GlobalOptions({this.verbose = false, this.project, this.flutterSdk});

  final bool verbose;
  final String? project;
  final String? flutterSdk;

  /// Registers `--verbose/-v`, `--project` and `--flutter-sdk` on [parser].
  static void addTo(ArgParser parser) {
    parser
      ..addFlag(
        'verbose',
        abbr: 'v',
        negatable: false,
        help: 'Print debug details.',
      )
      ..addOption(
        'project',
        valueHelp: 'dir',
        help: 'Flutter or Dart project directory (default: current directory).',
      )
      ..addOption(
        'flutter-sdk',
        valueHelp: 'dir',
        help: 'Flutter SDK root to use.',
      );
  }

  /// Merges the runner's global results with the command's own results; the
  /// command's value wins when both were given.
  factory GlobalOptions.of(Command<Object?> command) {
    final global = command.globalResults;
    final own = command.argResults;

    bool flag(ArgResults? r, String name) =>
        r != null && r.options.contains(name) && (r[name] as bool? ?? false);

    String? option(ArgResults? r, String name) =>
        r != null && r.options.contains(name) ? r[name] as String? : null;

    return GlobalOptions(
      verbose: flag(global, 'verbose') || flag(own, 'verbose'),
      project: option(own, 'project') ?? option(global, 'project'),
      flutterSdk: option(own, 'flutter-sdk') ?? option(global, 'flutter-sdk'),
    );
  }
}
