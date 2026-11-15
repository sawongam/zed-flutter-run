# Flutter Run & Debug for Zed

Run and debug Flutter apps in [Zed](https://zed.dev) the way you do in VS Code: press a key to launch, set breakpoints, hot reload on save, pick a device, open DevTools.

[![CI](https://github.com/sawongam/zed-flutter-run/actions/workflows/ci.yml/badge.svg)](https://github.com/sawongam/zed-flutter-run/actions/workflows/ci.yml)
[![License: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](LICENSE)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/sawongam/zed-flutter-run/badge)](https://scorecard.dev/viewer/?uri=github.com/sawongam/zed-flutter-run)

> **Preview (0.1.0).** The test suite drives the real Flutter and Dart debug adapters on Linux, macOS and Windows, but the tool has had little use in day-to-day Zed sessions yet. Expect rough edges and please [report them](https://github.com/sawongam/zed-flutter-run/issues).

## What you get

| | |
|---|---|
| Launch, breakpoints, stepping, variables, debug console | Yes |
| Hot reload and hot restart | Yes, by key or task |
| Hot reload on save | Yes |
| Attach to a running app | Yes |
| Device picker and emulator launcher | Yes, as tasks or commands |
| DevTools | Opens in your browser |
| FVM and Puro SDKs | Found automatically |
| Toolbar buttons, status bar device selector | No. Zed has no extension API for them |

Code completion and analysis are not part of this project. Use Zed's Dart extension for those; the two work side by side.

## Install

There are two parts: the `flutter_run` command-line tool, and a small Zed extension that connects it to Zed's debugger.

**1. Install `flutter_run`**

```sh
dart pub global activate --source git https://github.com/sawongam/zed-flutter-run --git-path cli
```

This needs the Dart SDK, which you already have with Flutter. Make sure the pub cache `bin` folder is on your `PATH` (`~/.pub-cache/bin` on Linux and macOS, `%LOCALAPPDATA%\Pub\Cache\bin` on Windows), then check the install:

```sh
flutter_run doctor
```

On Windows, compile a native executable instead, because Zed cannot manage the `.bat` launcher that pub creates:

```sh
git clone https://github.com/sawongam/zed-flutter-run
cd zed-flutter-run/cli
dart pub get
dart compile exe bin/flutter_run.dart -o flutter_run.exe
```

Then copy `flutter_run.exe` to a folder on your `PATH`.

**2. Install the Zed extension**

Clone this repository, run `zed: install dev extension` from Zed's command palette and choose the `extension/` folder. Zed builds the extension, so you need [rustup](https://rustup.rs). Zed 0.205 or newer is required.

**3. Set up your project**

```sh
cd my_flutter_app
flutter_run init
```

`init` writes `.zed/debug.json` and `.zed/tasks.json` and prints a keymap snippet for hot reload and hot restart. It merges with files you already have and never overwrites them without telling you. Use `--dry-run` to see what it would write.

## Use

Open the project in Zed, press **F4** and choose **Flutter: Debug**. Set breakpoints in the gutter. Save a file to hot reload.

| Key | Action |
|---|---|
| F4 | Start, or choose what to run |
| F5 | Run the last choice again; continue when paused |
| Shift+F5 | Stop |
| Ctrl+F5 | Hot reload |
| Ctrl+Shift+F5 (macOS: Shift+Cmd+F5) | Hot restart |
| Ctrl+Alt+Shift+D | Open DevTools |

The first three are Zed's defaults. The last three come from the keymap snippet that `init` prints; paste it into your keymap (`zed: open keymap file`). They work while a debug session is running.

Other things you can do:

- **Choose a device:** run the **Flutter: Select Device** task, or `flutter_run select-device`. The choice is remembered per project. `flutter_run devices` lists devices and `flutter_run emulators` lists and starts emulators.
- **Open DevTools:** `flutter_run devtools`, or `flutter_run devtools inspector` for a specific page. Set `"openDevTools": "inspector"` in a scenario to open it on every launch.
- **Attach to an app you started yourself:** use `"request": "attach"` with `"vmServiceUri"`. See [attach](docs/CONFIGURATION.md#attach).
- **Run without the debugger:** choose **Flutter: Run (no debug)** from the F4 list.

## Documentation

- [Configuration](docs/CONFIGURATION.md): every `debug.json` key, command, flag, environment variable and exit code
- [Troubleshooting](docs/TROUBLESHOOTING.md): start with `flutter_run doctor`
- [Compatibility](docs/COMPATIBILITY.md): supported Zed, Flutter and OS versions, and known limitations
- [Architecture](docs/ARCHITECTURE.md) and [design notes](docs/DESIGN.md): how it works and why
- [Privacy](docs/PRIVACY.md): no telemetry

## How it works

Zed speaks the Debug Adapter Protocol. So does Flutter's own `flutter debug_adapter`. `flutter_run dap` sits between the two and passes messages through, adding what Zed does not offer on its own: it injects your chosen device, watches your source files and sends a hot reload when you save, and makes sure nothing is left running when you stop. Commands such as `flutter_run reload` reach the running session over a local, token-protected connection.

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) to get set up, and [SECURITY.md](SECURITY.md) to report a vulnerability.

## License

[BSD 3-Clause](LICENSE).

This project is not affiliated with or endorsed by Google or Zed Industries. Flutter and Dart are trademarks of Google LLC. Zed is a trademark of Zed Industries, Inc.
