import 'dart:io';

import 'package:flutter_run/flutter_run.dart';

Future<void> main(List<String> args) async {
  exit(await FlutterRunRunner.create(args: args).runWithExit(args));
}
