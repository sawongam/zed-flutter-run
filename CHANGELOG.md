# Changelog

This project follows [Semantic Versioning](https://semver.org/). The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - Unreleased

First preview release.

- Zed extension `flutter-run-debugger` with the debug adapter `FlutterRun`.
- `flutter_run` command-line tool and debug adapter proxy.
- Launch and attach for Flutter apps and Dart programs, with breakpoints, stepping, variables and the debug console.
- Hot reload and hot restart from tasks and key bindings, and hot reload on save.
- Device picker, emulator launcher and DevTools.
- Flutter SDK discovery: explicit path, `FLUTTER_RUN_FLUTTER_SDK`, FVM, Puro, `FLUTTER_ROOT`, then `PATH`.
- `flutter_run init` writes `.zed/debug.json` and `.zed/tasks.json`.
