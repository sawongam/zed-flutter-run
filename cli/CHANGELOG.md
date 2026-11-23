# Changelog

This project follows [Semantic Versioning](https://semver.org/). The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-11-23

First preview release.

### Added

- Zed extension `flutter-run-debugger`, which registers the debug adapter `FlutterRun`.
- `flutter_run`, a command-line tool and debug adapter proxy, with the commands `dap`, `init`, `reload`, `restart`, `status`, `devices`, `select-device`, `emulators`, `devtools`, `doctor` and `version`.
- Launch and attach for Flutter apps and Dart programs, with breakpoints, stepping, variables and the debug console.
- Hot reload and hot restart from Zed tasks and key bindings.
- Hot reload on save (`reloadOnSave`, `reloadOnSaveGlobs`, `reloadOnSaveDebounceMs`).
- Device picker that remembers the chosen device per project, and an emulator launcher.
- DevTools in the browser, optionally opened on every launch (`openDevTools`).
- Flutter SDK discovery: explicit path, `FLUTTER_RUN_FLUTTER_SDK`, FVM, Puro, `FLUTTER_ROOT`, then `PATH`.
- `flutter_run init`, which writes `.zed/debug.json` and `.zed/tasks.json` and prints a keymap snippet.
- Debug locator: Zed tasks that run `flutter run` or `dart run <file>.dart` can be started as debug sessions when `FlutterRun` is listed in `languages.Dart.debuggers`.
- Log file for diagnosis (`logFile`, `FLUTTER_RUN_LOG`).
