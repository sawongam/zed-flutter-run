import '../common/json_types.dart';
import 'hot_command.dart';

/// `flutter_run reload`: hot reload on every matching running Flutter app.
class ReloadCommand extends HotActionCommand {
  ReloadCommand({
    required super.store,
    required super.client,
    required super.env,
    required super.console,
    super.waitingNoticeAfter = const Duration(seconds: 3),
  });

  @override
  String get name => 'reload';

  @override
  String get description =>
      'Hot reload every running Flutter app of the project.';

  @override
  String get controlCommand => 'reload';

  @override
  String get actionLabel => 'Hot reload';

  @override
  Json get controlArgs => const {'reason': 'manual'};
}
