# Configuration reference

Everything you can set: `debug.json` keys, environment variables, commands, exit codes, Zed settings, and what `init` writes.

## `.zed/debug.json`

Each entry is one debug scenario. The file is JSONC (comments and trailing commas are allowed). `adapter` must be `"FlutterRun"`. The schema ships with the extension (`extension/debug_adapter_schemas/FlutterRun.json`) and unknown keys are allowed.

### Keys the tool handles itself

These keys are read by `flutter_run` and removed before the request goes to the Dart/Flutter debug adapter.

| Key | Default | Meaning |
|---|---|---|
| `adapter` | | Must be `"FlutterRun"`. |
| `label` | | Name shown in the F4 picker. |
| `flutterMode` | `debug` | `debug`, `profile` or `release`. `profile` and `release` add `--profile` or `--release` to `toolArgs`, unless `toolArgs` already selects a mode (then it is ignored with a note). Launch only. |
| `deviceId` | | Device id. Adds `-d <id>` unless `toolArgs` already selects a device. |
| `platform` | | Accepted for copy-paste compatibility with Dart-Code. Ignored. |
| `useFvm` | `false` | Require the SDK selected by FVM for the project. |
| `flutterSdkPath` | | Flutter SDK root. First step of SDK resolution. |
| `reloadOnSave` | `changed` | `changed` reloads only when file content changed. `always` reloads on every save. `off` disables it. |
| `reloadOnSaveGlobs` | | Extra globs, relative to the project, that also trigger a reload. Each must start with a directory, for example `assets/**.json`. |
| `reloadOnSaveDebounceMs` | `200` | Wait after the last change, 10 to 5000. |
| `openDevTools` | `never` | Page to open in the browser when the app starts: `never`, `inspector`, `performance`, `cpu-profiler`, `memory`, `network`, `logging`. Needs DDS, so it does not work with `--no-dds`. |
| `logFile` | | Write the proxy's debug log and DAP traffic here. The name must end in `.log`, the folder must already exist, and the file is created owner-only. |

Reload on save watches `lib/` (and `bin/` for Dart programs) plus the folders named by `reloadOnSaveGlobs`. It ignores `build/`, `.dart_tool/`, `ios/` and dot-folders. Edits in sibling path packages do not trigger it.

### Keys passed to the debug adapter

| Key | Default | Meaning |
|---|---|---|
| `request` | `launch` | `launch` a new app or `attach` to a running one. |
| `type` | `flutter` | `flutter` app or plain `dart` program. |
| `program` | `lib/main.dart` | Entry point. Filled in for Flutter launches when empty. |
| `cwd` | worktree root | Working directory. Use `$ZED_WORKTREE_ROOT`. Filled in when empty. |
| `args` | | Arguments passed to the app. |
| `toolArgs` | | Extra arguments for `flutter run` or `flutter attach`, for example `--flavor dev` or `-d <id>`. Must be a list. |
| `env` | | Environment variables for the adapter and the app. |
| `vmServiceUri` | | VM service URI to attach to (`request: attach`). Also set `toolArgs` with `-d <device>`. |
| `vmServiceInfoFile` | | File containing JSON `{"uri": "ws://..."}` (`request: attach`). The bare-string file from `flutter run --vmservice-out-file` does not work. Use `vmServiceUri`. |
| `stopOnEntry` | | Pause at the first line. |
| `noDebug` | | Run without the debugger attached. |
| `debugSdkLibraries` | | Passed through. |
| `debugExternalPackageLibraries` | | Passed through. |
| `evaluateGettersInDebugViews` | | Passed through. |
| `evaluateToStringInDebugViews` | | Passed through. |
| `sendLogsToClient` | | Passed through. |

### Dart programs

With `"type": "dart"`, breakpoints and hot reload work. Hot restart and DevTools are not available (the Dart debug adapter does not support them) and the matching tasks refuse with a hint. Device handling does not apply.

### Choosing the device

In this order: `-d` or `--device-id` in `toolArgs`, `deviceId`, the `FLUTTER_RUN_DEVICE` variable, the device saved by `select-device`, then Flutter's own default. The debug console says which source was used. A device id with unsafe characters is dropped with a note.

### SDK resolution

In this order: `--flutter-sdk` or `flutterSdkPath`, the `FLUTTER_RUN_FLUTTER_SDK` variable, FVM (`.fvm/flutter_sdk`, `.fvmrc`, `.fvm/fvm_config.json`), Puro (`.puro.json`), `FLUTTER_ROOT`, then `flutter` on PATH. `flutter_run doctor` shows each step.

### Attach

Start the app yourself with `flutter run -d <device>`, copy the VM service URL it prints, and use:

```json
{
  "label": "Flutter: Attach",
  "adapter": "FlutterRun",
  "request": "attach",
  "type": "flutter",
  "cwd": "$ZED_WORKTREE_ROOT",
  "vmServiceUri": "http://127.0.0.1:PORT/TOKEN=/",
  "toolArgs": ["-d", "<device>"]
}
```

- With more than one device connected, a device is required (`deviceId`, `-d` in `toolArgs`, or a saved device).
- The placeholder `http://127.0.0.1:PORT/TOKEN=/` that `flutter_run init` writes is rejected with a message telling you to paste the real URI.
- A Dart attach (`"type": "dart"`) needs `vmServiceUri` (or `vmServiceInfoFile`) and is refused without one.
- A Flutter attach without a URI is allowed: Flutter waits for an app to start. After 15 seconds without an app, `flutter_run` prints "Still waiting for the app" in the Console.
- Stopping an attach session only detaches. Your app keeps running.

### Debugging from tasks

The extension has a debug locator ([ADR 0009](decisions/0009-debug-locator.md)) that turns a Zed task into a `FlutterRun` scenario, so a task that already runs your app can be debugged without writing a `debug.json` entry. It matches only tasks that start an app: `flutter run`, `fvm flutter run`, `puro flutter run`, `dart run <file>.dart` and `dart <file>.dart`. A positional file (`flutter run lib/foo.dart`) is treated like `-t`. A `$ZED_*` variable in the task's `cwd` is dropped, so the launch uses the worktree root. Other tasks (`flutter build`, `flutter test`, `dart pub get`) are left alone.

| Task argument | Scenario key |
|---|---|
| `-d X`, `--device-id X`, `--device-id=X` | `deviceId` |
| `--debug`, `--profile`, `--release` | `flutterMode` |
| `-t X`, `--target X`, `--target=X` | `program` |
| other flags (`--flavor dev`, `--dart-define=A=1`) | `toolArgs`, in order |
| arguments after a bare `--` | `args` |
| `fvm` prefix | `useFvm: true` |
| task `env` and `cwd` | `env`, `cwd` |

Zed only asks a locator when the language of the open file lists the adapter, so set `"languages": {"Dart": {"debuggers": ["FlutterRun"]}}` in your Zed settings. The locator has not been run in a real Zed yet. Scenarios in `debug.json` keep working as described above.

## Environment variables

| Variable | Meaning |
|---|---|
| `FLUTTER_RUN_FLUTTER_SDK` | Flutter SDK root. Second step of SDK resolution. |
| `FLUTTER_RUN_DEVICE` | Device id used when `toolArgs` and `deviceId` give none. |
| `FLUTTER_RUN_LOG` | Log file. Same rules as `logFile`: `.log` suffix, existing folder, owner-only. |
| `FLUTTER_RUN_LOG_LEVEL` | `error`, `warn`, `info` (default) or `debug`. |
| `FLUTTER_RUN_STATE_DIR` | Per-user state folder (saved device, session files). Must be writable by you only. |

Default state folder: `$XDG_STATE_HOME/flutter_run` or `~/.local/state/flutter_run` (Linux), `~/Library/Application Support/flutter_run` (macOS), `%LOCALAPPDATA%\flutter_run` (Windows).

## Commands

Global options: `-h`/`--help`, `-v`/`--verbose`, `-V`/`--version`, `--project=<dir>` (default: current directory), `--flutter-sdk=<dir>`. Run `flutter_run help <command>` for details.

| Command | What it does | Flags |
|---|---|---|
| `init` | Write `.zed/debug.json` and `.zed/tasks.json`, print the keymap snippet | `--dry-run`, `--force` (replaces files, keeps a `.bak`) |
| `reload` | Hot reload every running Flutter app of the project | `--timeout=<seconds>` (default 120) |
| `restart` | Hot restart every running Flutter app of the project | `--timeout=<seconds>` |
| `status` | List running debug sessions | `--json` |
| `devices` | List devices and mark the saved one | `--json` |
| `select-device` | Choose the device for the next start | `--device=<id>`, `--clear` |
| `emulators` | List emulators and simulators, or start one | `--launch=<id>`, `--json` |
| `devtools [page]` | Open DevTools for the running app. Pages: `inspector`, `performance`, `cpu-profiler`, `memory`, `network`, `logging` | `--print` (only print the URL) |
| `doctor` | Show how `flutter_run` sees SDK, PATH, sessions and `.zed` files | |
| `version` | Print the version | |
| `dap` | Debug adapter proxy. The extension starts it. Do not run it by hand | `--cwd`, `--kind` (`flutter`, `dart`), `--request` (`launch`, `attach`), `--use-fvm`, `--log-file`, `--client-version` |

`init` never overwrites silently. It merges into existing files when it can. When it cannot (for example a file it cannot parse) it prints the content and exits with code 9.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Unexpected error (run with `--verbose`) |
| 2 | Bad flags or arguments |
| 3 | No Flutter debug session found for the directory |
| 4 | A session could not act or failed (reload failed, app still starting) |
| 5 | A session did not answer within `--timeout` |
| 6 | Flutter or Dart SDK not found |
| 7 | No devices, or an unknown device id |
| 8 | No `pubspec.yaml` at or above the directory |
| 9 | `init` could not edit a file safely and printed it for you to paste |
| 10 | A flutter, dart or browser command failed |
| 130 | Interrupted (Ctrl+C) |

## Zed settings

In your Zed `settings.json`, to point Zed at a specific binary:

```json
{
  "dap": {
    "FlutterRun": { "binary": "/absolute/path/to/flutter_run" }
  }
}
```

The extension looks for `flutter_run` in this order: `dap.FlutterRun.binary`, `PATH`, then (release builds only) a checksum-pinned download from GitHub releases. A dev build never downloads.

## Tasks and keymap written by `init`

For a Flutter project, `init` adds these tasks to `.zed/tasks.json`. Each runs `flutter_run` in `$ZED_WORKTREE_ROOT`.

| Task | Runs |
|---|---|
| Flutter: Hot Reload | `flutter_run reload` (saves all files first) |
| Flutter: Hot Restart | `flutter_run restart` (saves all files first) |
| Flutter: Select Device | `flutter_run select-device` |
| Flutter: Launch Emulator | `flutter_run emulators` |
| Flutter: Devices | `flutter_run devices` |
| Flutter: Open DevTools | `flutter_run devtools` |
| Flutter: DevTools Inspector | `flutter_run devtools inspector` |
| Flutter: DevTools Performance | `flutter_run devtools performance` |
| Flutter: Doctor | `flutter_run doctor` |

For a Dart project it adds only **Flutter: Doctor**.

Scenarios written to `.zed/debug.json`: for Flutter, **Flutter: Debug**, **Flutter: Run (no debug)**, **Flutter: Profile** and **Flutter: Attach**. For Dart, one **Dart: Debug <entry>** scenario.

The keymap snippet (printed, never written) uses the context `Workspace && debugger_session`:

| Key | Task |
|---|---|
| `ctrl-f5` | Flutter: Hot Reload |
| `ctrl-shift-f5` (macOS: `shift-cmd-f5`) | Flutter: Hot Restart |
| `ctrl-alt-shift-d` | Flutter: Open DevTools |

Zed binds its own restart to `ctrl-shift-f5`. `init` prints a second snippet without the restart key if you want to keep Zed's. Because the context needs a running session, these keys do nothing otherwise. Zed has no key for "run without debugging"; use the **Flutter: Run (no debug)** scenario.
