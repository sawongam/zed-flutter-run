import '../common/json_types.dart';
import 'hot_command.dart';

/// `flutter_run restart`: hot restart on every matching running Flutter app.
class RestartCommand extends HotActionCommand {
  RestartCommand({
    required super.store,
    required super.client,
    required super.env,
    required super.console,
    super.waitingNoticeAfter = const Duration(seconds: 3),
  });

  @override
  String get name => 'restart';

  @override
  String get description =>
      'Hot restart every running Flutter app of the project.';

  @override
  String get controlCommand => 'restart';

  @override
  String get actionLabel => 'Hot restart';

  @override
  Json get controlArgs => const {};
}
