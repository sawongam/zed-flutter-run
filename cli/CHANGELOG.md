# Changelog

All notable changes to this package are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/). The full project changelog is at <https://github.com/sawongam/zed-flutter-run/blob/master/CHANGELOG.md>.

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
