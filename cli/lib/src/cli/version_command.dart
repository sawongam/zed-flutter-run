import 'package:args/command_runner.dart';

import '../common/console.dart';
import '../common/global_options.dart';
import '../common/version.dart';

/// `flutter_run version`: prints the version.
class VersionCommand extends Command<int> {
  VersionCommand(this._console) {
    GlobalOptions.addTo(argParser);
  }

  final Console _console;

  @override
  String get name => 'version';

  @override
  String get description => 'Print the flutter_run version.';

  @override
  Future<int> run() async {
    _console.out('$toolName $packageVersion');
    return 0;
  }
}
