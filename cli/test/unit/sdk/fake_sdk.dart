import 'dart:io';

import 'package:flutter_run/src/common/host_environment.dart';
import 'package:path/path.dart' as p;

/// Creates a fake Flutter SDK tree at [root]; returns [root].
String makeFakeSdk(
  String root, {
  String version = '3.99.0',
  String dartVersion = '3.99.1',
  bool withDart = true,
}) {
  final bin = Directory(p.join(root, 'bin'))..createSync(recursive: true);
  final flutter = File(
    p.join(bin.path, Platform.isWindows ? 'flutter.bat' : 'flutter'),
  )..writeAsStringSync('#!/bin/sh\n');
  if (!Platform.isWindows) Process.runSync('chmod', ['+x', flutter.path]);
  File(p.join(bin.path, 'internal', 'engine.version'))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('x');
  File(p.join(root, 'version')).writeAsStringSync('$version\n');
  if (withDart) {
    final dartDir = Directory(p.join(root, 'bin', 'cache', 'dart-sdk', 'bin'))
      ..createSync(recursive: true);
    final dart = File(
      p.join(dartDir.path, Platform.isWindows ? 'dart.exe' : 'dart'),
    )..writeAsStringSync('x');
    if (!Platform.isWindows) Process.runSync('chmod', ['+x', dart.path]);
    File(
      p.join(root, 'bin', 'cache', 'dart-sdk', 'version'),
    ).writeAsStringSync('$dartVersion\n');
  }
  return root;
}

HostEnvironment hostFor(
  String cwd, {
  Map<String, String> env = const {},
  HostOs? os,
}) => HostEnvironment(
  os: os ?? HostEnvironment.system().os,
  environment: {'PATH': '', ...env},
  currentDirectory: cwd,
);
