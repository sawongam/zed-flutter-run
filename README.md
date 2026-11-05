# Flutter Run & Debug

VS Code-style **Flutter Run & Debug in the [Zed](https://zed.dev) editor**. It is a thin Rust Zed extension (`flutter-run-debugger`, which registers the debug adapter `FlutterRun`) plus a Dart command-line tool and DAP proxy, `flutter_run`. You get one-key launch, breakpoints, hot reload, hot restart, reload on save, a device picker and DevTools, on Linux, macOS and Windows.

> Not affiliated with, endorsed by or sponsored by Google, Flutter, Dart or Zed Industries. Flutter and Dart are trademarks of Google LLC. Zed is a trademark of Zed Industries, Inc.

**Status: 0.1.0 preview.** Verified headlessly (unit and integration tests, no real Zed UI session yet). Not published anywhere yet: no pub.dev package, no Zed extension registry entry, no GitHub release. See [docs/STATUS.md](docs/STATUS.md) for what is verified and what is not.

## Features

- Launch Flutter apps and Dart programs under the debugger (breakpoints, stepping, variables, debug console).
- Hot reload and hot restart from Zed tasks and key bindings (`flutter_run reload`, `flutter_run restart`).
- Reload on save (only changed files by default; configurable).
- Attach to an app that is already running.
- Device picker and emulator launcher (`devices`, `select-device`, `emulators`).
- DevTools in your browser (`devtools`, optional auto-open on start).
- `init` writes `.zed/debug.json` and `.zed/tasks.json` for you and prints a keymap snippet.
- Flutter SDK discovery: explicit path, environment variable, FVM, Puro, `FLUTTER_ROOT`, `PATH`.
- `doctor` explains what the tool sees. No telemetry.

## Requirements

- **Zed** with debugger extension support, extension API 0.7.0. According to the `zed_extension_api` README that means Zed **0.205 or newer** (use a recent Zed).
- A **Flutter SDK** (for Flutter apps) or a Dart SDK (for plain Dart programs).
- To build from source: the Dart SDK (bundled with Flutter) and, for the Zed extension, **Rust via [rustup](https://rustup.rs)** (Zed compiles dev extensions to WebAssembly itself).

## Install

Two steps: the `flutter_run` command must be on your `PATH` (Zed tasks can only run commands from there), and the Zed extension must be installed.

### Step 1: `flutter_run` on your PATH

**(a) Build from source** (works today; the code lives on branch `build/mvp` until it is merged)

```sh
git clone https://github.com/sawongam/zed-flutter-run
cd zed-flutter-run
git checkout build/mvp        # the code is on this branch until it is merged (PR #1)
cd cli
dart pub get
dart compile exe bin/flutter_run.dart -o flutter_run        # Windows: -o flutter_run.exe
```

Then put the file somewhere on your PATH.

| OS | Example |
|---|---|
| Linux | `mkdir -p ~/.local/bin && cp flutter_run ~/.local/bin/` and make sure `~/.local/bin` is on PATH (`export PATH="$HOME/.local/bin:$PATH"` in `~/.bashrc` or `~/.zshrc`) |
| macOS | `mkdir -p ~/.local/bin && cp flutter_run ~/.local/bin/` and add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` |
| Windows (PowerShell) | `mkdir $HOME\bin; copy flutter_run.exe $HOME\bin\` then add `%USERPROFILE%\bin` to your user PATH (System Properties > Environment Variables) |

**(b) Install with `dart pub global activate` from Git** (works today)

```sh
dart pub global activate --source git https://github.com/sawongam/zed-flutter-run --git-path cli --git-ref build/mvp
```

Drop `--git-ref build/mvp` once the branch is merged.

Add the pub-cache bin folder to your PATH:

| OS | Folder | How |
|---|---|---|
| Linux, macOS | `~/.pub-cache/bin` | `export PATH="$PATH:$HOME/.pub-cache/bin"` in `~/.bashrc` / `~/.zshrc` |
| Windows | `%LOCALAPPDATA%\Pub\Cache\bin` | add it to your user PATH |

On Windows the pub-cache entry is a `.bat` wrapper. Zed cannot supervise a `.bat` file, so prefer option (a) there (or set `dap.FlutterRun.binary`, see below).

**(c) Later (not available yet):** release binaries on GitHub, Homebrew, Scoop and `dart pub global activate flutter_run` from pub.dev.

Check it:

```sh
flutter_run version
flutter_run doctor
```

### Step 2: the Zed extension

Until it is in the Zed extension registry, install it as a dev extension:

1. Install Rust with [rustup](https://rustup.rs) (Zed builds dev extensions).
2. In Zed open the command palette and run **`zed: install dev extension`**, then choose the `extension/` folder of this repository.

**macOS note:** a Zed started from the Dock or Spotlight may not see the PATH from your shell profile. If the debugger cannot find `flutter_run`, start Zed from a terminal (`zed .`) or point Zed at the file in your Zed settings:

```json
{
  "dap": {
    "FlutterRun": { "binary": "/absolute/path/to/flutter_run" }
  }
}
```

The extension looks for `flutter_run` in this order: `dap.FlutterRun.binary`, then `PATH`, then (release builds only) a checksum-pinned download from GitHub releases. A dev build never downloads.

## Quick start

```sh
cd my_flutter_app
flutter_run init
```

Then in Zed:

1. Open the project folder.
2. Press **F4** and pick **Flutter: Debug**.
3. Set breakpoints by clicking the gutter.
4. Edit and **save** (reload on save), or press **Ctrl+F5** for hot reload and **Ctrl+Shift+F5** for hot restart.
5. **Shift+F5** stops the session.

`init` never overwrites your settings silently. It merges into existing `.zed/debug.json` and `.zed/tasks.json` when it can, and prints the files for you to paste when it cannot (`--force` replaces them and keeps a `.bak`). Use `--dry-run` to preview. It also prints a keymap snippet to paste after you run **`zed: open keymap file`**.

## Keys

| Key | Action | Source |
|---|---|---|
| F4 | Start or choose a debug scenario | Zed default |
| F5 | Run the last scenario again; Continue when paused (does nothing while the app runs) | Zed default |
| Shift+F5 | Stop | Zed default |
| F6 | Pause | Zed default |
| Ctrl+F5 | Hot reload (task `Flutter: Hot Reload`) | keymap snippet from `init` |
| Ctrl+Shift+F5 (macOS: Shift+Cmd+F5) | Hot restart (task `Flutter: Hot Restart`) | keymap snippet from `init` |
| Ctrl+Alt+Shift+D | Open DevTools | keymap snippet from `init` |

Our bindings use the context `Workspace && debugger_session`, so they only work while a debug session is running. Zed has no "run without debugging" key: pick **Flutter: Run (no debug)** with F4. Zed also binds its own restart to Ctrl+Shift+F5; `init` prints a second snippet without the hot restart key if you want to keep Zed's behaviour.

**macOS:** F keys also need the `fn` key unless you enable "Use F1, F2, etc. keys as standard function keys" in System Settings > Keyboard. If a key does nothing, check System Settings > Keyboard > Keyboard Shortcuts for a conflict.

## Configuration reference

Entries in `.zed/debug.json` (JSONC: comments and trailing commas are allowed). `adapter` must be `FlutterRun`.

**FlutterRun-specific keys**

| Key | Default | Meaning |
|---|---|---|
| `adapter` | | Must be `"FlutterRun"`. |
| `label` | | Name shown in the F4 picker. |
| `request` | `launch` | `launch` a new app or `attach` to a running one. |
| `type` | `flutter` | `flutter` app or plain `dart` program. |
| `program` | `lib/main.dart` | Entry point. |
| `cwd` | worktree root | Working directory (use `$ZED_WORKTREE_ROOT`). |
| `args` | | Arguments passed to the app. |
| `toolArgs` | | Extra arguments for `flutter run` / `flutter attach` (for example `--flavor dev`, `-d <id>`). |
| `env` | | Environment variables for the adapter and the app. |
| `flutterMode` | `debug` | `debug`, `profile` or `release` (added as `--profile` / `--release`). |
| `deviceId` | | Device id; adds `-d <id>` unless `toolArgs` already selects a device. |
| `platform` | | Accepted for copy-paste compatibility with Dart-Code; ignored. |
| `vmServiceUri` | | VM service URI to attach to (`request: attach`). |
| `vmServiceInfoFile` | | File with JSON `{"uri": "..."}` (`request: attach`). |
| `useFvm` | `false` | Require the SDK selected by FVM for the project. |
| `flutterSdkPath` | | Flutter SDK root; first step of SDK resolution. |
| `reloadOnSave` | `changed` | `changed` (only files whose content changed), `always` (every save) or `off`. |
| `reloadOnSaveGlobs` | | Extra globs, relative to the project, that also trigger a reload. Each must start with a directory, for example `assets/**.json`. |
| `reloadOnSaveDebounceMs` | `200` | Wait after the last change (10 to 5000). |
| `openDevTools` | `never` | Page to open in the browser when the app starts: `inspector`, `performance`, `cpu-profiler`, `memory`, `network`, `logging`. |
| `logFile` | | Write the proxy's debug log and DAP traffic to this file. The name must end in `.log` and its folder must already exist; the file is created owner-only. `FLUTTER_RUN_LOG` follows the same rules. |

**Dart programs (`type: dart`):** hot reload works; hot restart and DevTools are not available (the Dart debug adapter does not support them), and the matching tasks refuse with a hint.

Reload on save watches `lib/` (and `bin/` for Dart programs) plus the directories named by `reloadOnSaveGlobs`.

**Passed through to the Dart/Flutter debug adapter:** `stopOnEntry`, `noDebug`, `debugSdkLibraries`, `debugExternalPackageLibraries`, `evaluateGettersInDebugViews`, `evaluateToStringInDebugViews`, `sendLogsToClient`. Other keys are passed along too (the schema allows additional properties).

**SDK resolution order:** `--flutter-sdk` / `flutterSdkPath`, the `FLUTTER_RUN_FLUTTER_SDK` environment variable, FVM (`.fvm/flutter_sdk`, `.fvmrc`, `.fvm/fvm_config.json`), Puro (`.puro.json`), `FLUTTER_ROOT`, then `flutter` on PATH. `flutter_run doctor` shows every step.

**Environment variables:** `FLUTTER_RUN_FLUTTER_SDK`, `FLUTTER_RUN_DEVICE`, `FLUTTER_RUN_LOG` (log file), `FLUTTER_RUN_LOG_LEVEL`, `FLUTTER_RUN_STATE_DIR` (per-user state, including the saved device).

## Commands

Global options: `-h/--help`, `-v/--verbose`, `--project=<dir>` (default: current directory), `--flutter-sdk=<dir>`. Run `flutter_run help <command>` for details.

| Command | What it does | Main flags |
|---|---|---|
| `init` | Write `.zed/debug.json` and `.zed/tasks.json`, print the keymap snippet | `--dry-run`, `--force` |
| `reload` | Hot reload every running Flutter app of the project | `--timeout=<seconds>` (default 120) |
| `restart` | Hot restart every running Flutter app of the project | `--timeout=<seconds>` |
| `status` | List running debug sessions | `--json` |
| `devices` | List devices and mark the saved one | `--json` |
| `select-device` | Choose the device for the next start | `--device=<id>`, `--clear` |
| `emulators` | List emulators and simulators, or start one | `--launch=<id>`, `--json` |
| `devtools [page]` | Open DevTools for the running app | `--print` |
| `doctor` | Show how `flutter_run` sees SDK, PATH, sessions and `.zed` files | |
| `version` | Print the version | |
| `dap` | Debug adapter proxy, started by the extension (not by hand) | `--cwd`, `--kind`, `--request`, `--use-fvm`, `--log-file`, `--client-version` |

DevTools pages: `inspector`, `performance`, `cpu-profiler`, `memory`, `network`, `logging`.

**Exit codes**

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

## Devices and emulators

```sh
flutter_run devices            # the saved device is marked with *
flutter_run select-device      # interactive; or: --device <id>, --clear
flutter_run emulators          # list; or: --launch <id>
```

The saved device is kept in your per-user state folder (not in the repository), so it survives `flutter clean`. The device is chosen in this order: `deviceId` / `-d` in `toolArgs`, the `FLUTTER_RUN_DEVICE` variable, the saved device, then Flutter's own default. The debug console says which source it used. `init` also creates the tasks **Flutter: Select Device**, **Flutter: Launch Emulator** and **Flutter: Devices**.

## DevTools

While an app runs, press Ctrl+Alt+Shift+D (after pasting the keymap snippet), run the task **Flutter: Open DevTools**, or run `flutter_run devtools [page]`. Use `--print` to only print the URL. Set `"openDevTools": "inspector"` (or another page) to open it automatically on start. DevTools is served by the Dart Development Service, so it is not available when DDS is disabled (`--no-dds`).

## Attach

Attach to an app you started yourself. Start it with:

```sh
flutter run -d <device>
```

Copy the VM service URL it prints (`http://127.0.0.1:PORT/TOKEN=/`) and use an attach scenario:

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

- If more than one device is connected, a device is required (`deviceId`, `toolArgs` `-d`, or a saved device).
- `vmServiceInfoFile` must contain JSON `{"uri": "ws://..."}`. The file written by `flutter run --vmservice-out-file` is a bare string and makes the adapter wait forever, so use `vmServiceUri` instead.
- Without any URI the adapter waits silently; after 15 seconds `flutter_run` prints a notice.
- Stopping an attach session only detaches; your app keeps running.

## Compared with VS Code and Dart-Code

| Feature | Here |
|---|---|
| Launch, breakpoints, stepping, variables, debug console | Yes |
| Hot reload / hot restart | Yes, by key or task; reload on save |
| Hot reload on save | Yes (`reloadOnSave`) |
| Attach | Yes |
| Device picker, emulator launch | Yes, as tasks or CLI (no status-bar device selector) |
| DevTools | Opens in your browser (no embedded view) |
| Debug toolbar buttons for reload / restart | No (keys and tasks instead) |
| Status bar device or SDK indicator | No |
| "Run without debugging" key | No key; use the **Flutter: Run (no debug)** scenario |
| Flutter widget inspector inside the editor | No (use DevTools) |
| Language features (completion, analysis) | Not part of this project; use Zed's Dart extension |

## Troubleshooting

Start with `flutter_run doctor` in your project.

- **"No Flutter SDK found" / exit 6:** set `flutterSdkPath` in `debug.json`, set `FLUTTER_RUN_FLUTTER_SDK`, or put `flutter` on PATH. `doctor` lists every place it looked.
- **`flutter_run` not on PATH:** the debugger still starts (through the extension), but tasks fail. Fix PATH as in [Install](#install). On macOS see the Dock note.
- **Tasks say "No running Flutter app found":** no debug session is running for this directory, or it is still starting. Start the app with F4 first. `flutter_run status` lists sessions.
- **Several devices:** Flutter refuses to choose. Run **Flutter: Select Device** (or `flutter_run select-device`) or set `deviceId`.
- **App is paused at a breakpoint while you reload:** resume (F5) first; a paused isolate cannot finish a reload.
- **Reload fails:** the error appears in the Debug panel's Console tab, with a hint to try hot restart.
- **`debug.json` is rejected:** `.zed/debug.json` is JSONC. Remove syntax errors; `flutter_run init` prints the file instead of overwriting when it cannot parse yours.
- **Need more detail:** set `"logFile": "/tmp/flutter_run.log"` in the scenario, or set `FLUTTER_RUN_LOG=/tmp/flutter_run.log` (and `FLUTTER_RUN_LOG_LEVEL=debug`). The file includes the full DAP traffic.

## Privacy

No telemetry. The tool talks to nothing except a loopback control port on your machine, the Flutter and Dart tools you run, and (release builds of the extension only) GitHub to download `flutter_run`.

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md), [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), [SECURITY.md](SECURITY.md) and [CHANGELOG.md](CHANGELOG.md). Design notes live in [docs/](docs/README.md). Licensed under the BSD 3-Clause License, see [LICENSE](LICENSE).
