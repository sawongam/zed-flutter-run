# Changelog

This project follows [Semantic Versioning](https://semver.org/). The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

- Every command now uses colour in a terminal, not only `doctor`, `devices` and error lines. This covers `help` and `--help` (headings, flags, command names and exit codes), `init`, `keymap`, `select-device`, `emulators`, `reload`, `restart`, `status` and `devtools`. The text is the same as before, and the colour rules have not changed.
- `devtools` prints a browser failure as `error:` and `hint:`, like the other commands. A usage error now starts with `error:`.

## [0.1.3] - 2026-11-25

Release process fix. No change in behaviour.

- The package changelog now has the notes for each release. 0.1.2 was never published to pub.dev, so this is the first pub.dev version with coloured output.

## [0.1.2] - 2026-11-24

- Coloured output for `doctor`, `devices` and error lines when the stream is a terminal. Respects `NO_COLOR`; `FORCE_COLOR` turns it on for pipes.

## [0.1.1] - 2026-11-24

Documentation release. No change in behaviour.

### Changed

- The README and the example now install with `dart pub global activate flutter_run`.
- Removed the preview notice.

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
