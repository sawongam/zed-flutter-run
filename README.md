# Flutter Run & Debug for Zed

VS Code-style Flutter run and debug in the [Zed](https://zed.dev) editor: one-key launch, breakpoints, hot reload, reload on save, a device picker and DevTools.

[![CI](https://github.com/sawongam/zed-flutter-run/actions/workflows/ci.yml/badge.svg)](https://github.com/sawongam/zed-flutter-run/actions/workflows/ci.yml)
[![License: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](LICENSE)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/sawongam/zed-flutter-run/badge)](https://scorecard.dev/viewer/?uri=github.com/sawongam/zed-flutter-run)
![Status: preview](https://img.shields.io/badge/status-preview-orange.svg)

<!-- DEMO SLOT: add a short screen recording here (F4, breakpoint hit, Ctrl+F5 hot reload).
     Use: ![Demo](docs/assets/demo.gif)  -- only after the file exists. -->

> **Status: 0.1.0 preview.** Tested headlessly (unit and integration tests on Linux, macOS and Windows CI). **Not yet tested in a real Zed session or on a real device.** Nothing is published: no pub.dev package, no Zed registry entry, no GitHub release. See [docs/STATUS.md](docs/STATUS.md).

> Not affiliated with, endorsed by or sponsored by Google, Flutter, Dart or Zed Industries. Flutter and Dart are trademarks of Google LLC. Zed is a trademark of Zed Industries, Inc.

It has two parts: a thin Rust Zed extension (`flutter-run-debugger`, which registers the debug adapter `FlutterRun`) and a Dart command-line tool and DAP proxy, `flutter_run`.

## Quick start

1. **Install `flutter_run`** (needs the Dart SDK, which comes with Flutter):

   ```sh
   dart pub global activate --source git https://github.com/sawongam/zed-flutter-run --git-path cli
   ```

   Make sure the pub-cache `bin` folder is on your PATH, then check with `flutter_run doctor`.

2. **Install the Zed extension** as a dev extension. In Zed run **`zed: install dev extension`** and choose the `extension/` folder of a clone of this repository. This needs [rustup](https://rustup.rs).

3. **Set up your project and debug:**

   ```sh
   cd my_flutter_app
   flutter_run init
   ```

   Open the folder in Zed, press **F4** and pick **Flutter: Debug**. Save a file to hot reload.

Details for each step are under [Install](#install).

## Features compared with VS Code

| Feature | Here |
|---|---|
| Launch, breakpoints, stepping, variables, debug console | Yes |
| Hot reload and hot restart | Yes, by key or task |
| Reload on save | Yes (`reloadOnSave`) |
| Attach to a running app | Yes |
| Device picker, emulator launch | Yes, as tasks or CLI (no status-bar selector) |
| DevTools | Opens in your browser (not embedded) |
| Reload and restart toolbar buttons | No (keys and tasks) |
| Status bar device or SDK indicator | No |
| "Run without debugging" key | No key; pick **Flutter: Run (no debug)** with F4 |
| Language features (completion, analysis) | Not part of this project; use Zed's Dart extension |

## Install

### Step 1: `flutter_run` on your PATH

**(a) From Git with `dart pub global activate`** (recommended)

```sh
dart pub global activate --source git https://github.com/sawongam/zed-flutter-run --git-path cli
```

Add the pub-cache bin folder to your PATH:

| OS | Folder | How |
|---|---|---|
| Linux, macOS | `~/.pub-cache/bin` | `export PATH="$PATH:$HOME/.pub-cache/bin"` in `~/.bashrc` or `~/.zshrc` |
| Windows | `%LOCALAPPDATA%\Pub\Cache\bin` | add it to your user PATH |

On Windows the pub-cache entry is a `.bat` wrapper. Zed cannot supervise a `.bat` file, so use option (b) there, or set `dap.FlutterRun.binary`.

**(b) Compile a native binary from `master`**

```sh
git clone https://github.com/sawongam/zed-flutter-run
cd zed-flutter-run/cli
dart pub get
dart compile exe bin/flutter_run.dart -o flutter_run        # Windows: -o flutter_run.exe
```

Copy the file somewhere on your PATH:

| OS | Example |
|---|---|
| Linux, macOS | `mkdir -p ~/.local/bin && cp flutter_run ~/.local/bin/`, then make sure `~/.local/bin` is on PATH |
| Windows (PowerShell) | `mkdir $HOME\bin; copy flutter_run.exe $HOME\bin\`, then add `%USERPROFILE%\bin` to your user PATH |

**(c) Not available yet:** release binaries, Homebrew, Scoop, and `dart pub global activate flutter_run` from pub.dev.

Check it:

```sh
flutter_run version
flutter_run doctor
```

### Step 2: the Zed extension

Until it is in the Zed extension registry, install it as a dev extension:

1. Install Rust with [rustup](https://rustup.rs). Zed builds dev extensions.
2. In Zed run **`zed: install dev extension`** and choose the `extension/` folder of this repository.

You need a Zed with debugger extension support (extension API 0.7.0, which per the `zed_extension_api` README means Zed 0.205 or newer). See [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).

The extension looks for `flutter_run` in this order: the `dap.FlutterRun.binary` setting, then `PATH`, then (release builds only) a checksum-pinned download from GitHub releases. A dev build never downloads.

**macOS:** a Zed started from the Dock may not see the PATH from your shell profile. Start Zed from a terminal (`zed .`) or set the path in your Zed settings:

```json
{
  "dap": {
    "FlutterRun": { "binary": "/absolute/path/to/flutter_run" }
  }
}
```

## Using it

`flutter_run init` writes `.zed/debug.json` and `.zed/tasks.json` and prints a keymap snippet. It never overwrites your settings silently: it merges when it can and prints the files for you to paste when it cannot. Use `--dry-run` to preview.

In Zed: open the project, press **F4**, pick **Flutter: Debug**, set breakpoints in the gutter, edit and save (reload on save).

### Keys

| Key | Action | Source |
|---|---|---|
| F4 | Start or choose a debug scenario | Zed default |
| F5 | Run the last scenario again; Continue when paused | Zed default |
| Shift+F5 | Stop | Zed default |
| F6 | Pause | Zed default |
| Ctrl+F5 | Hot reload | keymap snippet from `init` |
| Ctrl+Shift+F5 (macOS: Shift+Cmd+F5) | Hot restart | keymap snippet from `init` |
| Ctrl+Alt+Shift+D | Open DevTools | keymap snippet from `init` |

Our bindings only work while a debug session is running. Paste the snippet after running **`zed: open keymap file`**. Zed binds its own restart to Ctrl+Shift+F5; `init` prints a second snippet without the hot restart key if you want to keep that. On macOS the F keys also need `fn` unless you change the keyboard setting. More in [docs/CONFIGURATION.md](docs/CONFIGURATION.md#tasks-and-keymap-written-by-init).

### Devices, DevTools, attach

- `flutter_run devices`, `flutter_run select-device`, `flutter_run emulators` (also available as tasks).
- `flutter_run devtools [page]`, or set `"openDevTools": "inspector"` in a scenario.
- Attach to an app you started with `flutter run`: use `request: attach` with `vmServiceUri`. See [docs/CONFIGURATION.md](docs/CONFIGURATION.md#attach).

## Documentation

| Guide | What is in it |
|---|---|
| [Configuration](docs/CONFIGURATION.md) | Every `debug.json` key, environment variable, command, flag and exit code |
| [Compatibility](docs/COMPATIBILITY.md) | Zed, Flutter, OS and device support, and what has been tested |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Common problems and fixes. Start with `flutter_run doctor` |
| [Privacy](docs/PRIVACY.md) | No telemetry; the few network uses |
| [Status](docs/STATUS.md) | What is verified, what is not |
| [Architecture](docs/ARCHITECTURE.md) | How it works |

## Privacy

No telemetry. See [docs/PRIVACY.md](docs/PRIVACY.md).

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md), [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), [SECURITY.md](SECURITY.md) and [CHANGELOG.md](CHANGELOG.md). Project notes and decisions live in [docs/](docs/README.md). Licensed under the BSD 3-Clause License, see [LICENSE](LICENSE).
