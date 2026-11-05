# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- Renamed the project to **zed-flutter-run** (ADR 0008). Repo `sawongam/zed-flutter-run`, display name "Flutter Run & Debug", Dart package and executable `flutter_run` (was `flutter_rd`), Zed extension id `flutter-run-debugger` (was `flutter-rd-debugger`), Rust crate `flutter_run_debugger`, debug adapter `FlutterRun` (was `FlutterRD`), environment variables `FLUTTER_RUN_*` (was `FLUTTER_RD_*`). Existing `.zed/debug.json` files need `"adapter": "FlutterRun"`. Nothing had been published under the old names.

### Added
- `flutter_run --version` and `-V` print the same as `flutter_run version`.

### Fixed
- Atomic file writes retry a refused rename with backoff for about 5 s (Windows sharing violations), and the session store test no longer starves the rename with a busy reader.
- The sample fixture app accepts Dart `^3.5.0` instead of `^3.13.7`.

## [0.1.0] - unreleased

The release date will be set when 0.1.0 is published.

### Added
- Zed extension `flutter-run-debugger` registering the debug adapter `FlutterRun`.
- `flutter_run` CLI and DAP proxy with the commands `dap`, `init`, `reload`, `restart`, `status`, `devices`, `select-device`, `emulators`, `devtools`, `doctor` and `version`.
- Launch and attach for Flutter apps and Dart programs.
- Hot reload and hot restart from tasks and key bindings; reload on save (`reloadOnSave`, `reloadOnSaveGlobs`, `reloadOnSaveDebounceMs`).
- Device picker with a per-user saved device, and emulator launcher.
- DevTools opener and optional auto-open on start (`openDevTools`).
- Flutter SDK discovery (explicit path, environment variable, FVM, Puro, `FLUTTER_ROOT`, `PATH`).
- `init` writes `.zed/debug.json` and `.zed/tasks.json` and prints a keymap snippet.
- Log file support (`logFile`, `FLUTTER_RUN_LOG`).
- Documented exit codes.
- `logFile` / `FLUTTER_RUN_LOG` safety rules: must end in `.log`, existing folder, owner-only file, control characters escaped.
- Dart programs: hot reload works; hot restart and DevTools are refused with a hint.
- Hot Reload and Hot Restart tasks save all files first (`"save": "all"`).
