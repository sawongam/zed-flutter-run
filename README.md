# Flutter Run & Debug for Zed

Run and debug Flutter apps in [Zed](https://zed.dev) the way you do in VS Code: press a key to launch, set breakpoints, hot reload on save, pick a device, open DevTools.

[![CI](https://github.com/sawongam/zed-flutter-run/actions/workflows/ci.yml/badge.svg)](https://github.com/sawongam/zed-flutter-run/actions/workflows/ci.yml)
[![pub package](https://img.shields.io/pub/v/flutter_run.svg)](https://pub.dev/packages/flutter_run)
[![Release](https://img.shields.io/github/v/release/sawongam/zed-flutter-run)](https://github.com/sawongam/zed-flutter-run/releases/latest)
[![License: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](LICENSE)

## What you get

| | |
|---|---|
| Launch, breakpoints, stepping, variables, debug console | Yes |
| Hot reload and hot restart | Yes, by key or task |
| Hot reload on save | Yes, including local packages such as `packages/app_ui` |
| Flavors and several entry points | Yes, copied from `.vscode/launch.json` or found automatically |
| Attach to a running app | Yes |
| Device picker and emulator launcher | Yes, as tasks or commands |
| DevTools | Opens in your browser |
| FVM and Puro SDKs | Found automatically |
| Toolbar buttons, status bar device selector, settings screen | No. Zed has no extension API for them |

Code completion and analysis are not part of this project. Use Zed's Dart extension for those; the two work side by side.

## Quick start

With Flutter, Zed and [rustup](https://rustup.rs) installed:

```sh
# 1. The command-line tool (once per computer)
dart pub global activate flutter_run
flutter_run doctor

# 2. The Zed extension (once per computer)
git clone --branch prod https://github.com/sawongam/zed-flutter-run ~/zed-flutter-run
#    then in Zed: command palette > "zed: install dev extension" > ~/zed-flutter-run/extension

# 3. The keys for hot reload and hot restart (once per computer)
flutter_run keymap

# 4. Your project (once per project)
cd my_flutter_app
flutter_run init
zed .
```

In Zed, press **F4** and choose **Flutter: Debug**. Each step is explained below.

## Install

You need:

- **Flutter**, with Dart 3.13 or newer (`flutter --version` shows both).
- **Zed 0.205 or newer.**
- **[rustup](https://rustup.rs)**, because Zed builds the extension from source. You never run Rust yourself.

There are two parts. The `flutter_run` command-line tool does the work. The small Zed extension connects it to Zed's debugger. You need both.

### Step 1. Install `flutter_run`

```sh
dart pub global activate flutter_run
```

Then make sure `~/.pub-cache/bin` is on your `PATH`. If `flutter_run` is not found, add this line to `~/.bashrc`, `~/.zshrc` or your shell's equivalent, and open a new terminal:

```sh
export PATH="$PATH:$HOME/.pub-cache/bin"
```

**Windows:** Zed cannot manage the `.bat` launcher that `dart pub global activate` creates. Download `flutter_run-<version>-windows-x64.exe` from the [latest release](https://github.com/sawongam/zed-flutter-run/releases/latest), rename it to `flutter_run.exe` and put it in a folder on your `PATH`. Or build it yourself:

```powershell
git clone --branch prod https://github.com/sawongam/zed-flutter-run
cd zed-flutter-run\cli
dart pub get
dart compile exe bin\flutter_run.dart -o flutter_run.exe
```

Prebuilt binaries for Linux, macOS and Windows are on the release page. Each one has a published SHA-256 and a build provenance attestation.

**Check it.** This should find your Flutter SDK and list your devices:

```sh
flutter_run doctor
```

### Step 2. Install the Zed extension

The extension is not in Zed's extension store yet, so install it from a clone of this repository:

1. Clone the repository, if you have not already: `git clone --branch prod https://github.com/sawongam/zed-flutter-run`
2. In Zed, open the command palette (Ctrl+Shift+P, or Cmd+Shift+P on macOS) and run **`zed: install dev extension`**.
3. Choose the `extension` folder inside the clone.

The first build takes a few minutes. When it is done, **Flutter Run & Debug** shows on the Extensions page (`zed: extensions`). If it does not, run `zed: open log` to see why.

**macOS:** Zed opened from the Dock or Finder may not see your shell's `PATH`, and then it cannot find `flutter_run`. Start Zed from a terminal (`zed .`), or tell Zed where the tool is, as shown in [Zed settings](docs/CONFIGURATION.md#zed-settings).

### Step 3. Add the keys

```sh
flutter_run keymap
```

Zed extensions cannot add key bindings, so this command adds them to your Zed keymap for you. You only do this once per computer, and the keys then work in every project.

| Key | Action |
|---|---|
| Ctrl+F5 | Hot reload |
| Ctrl+Shift+F5 (macOS: Shift+Cmd+F5) | Hot restart |
| Ctrl+Alt+Shift+D | Open DevTools |

**Want other keys?** Pass them when you run it. For example, to hot reload with Ctrl+S and hot restart with Ctrl+Shift+S:

```sh
flutter_run keymap --reload-key ctrl-s --restart-key ctrl-shift-s
```

The keys only change while a debug session runs, so outside one Ctrl+S still just saves and Ctrl+Shift+S is still Save As. The command also warns you when a key clashes with your Zed keymap (JetBrains, Sublime Text, Emacs, Vim) or your OS. Add `--dry-run` to see the change before it is made. To change keys later, edit them in Zed's keymap editor (`zed: open keymap`). See [Keys](docs/CONFIGURATION.md#keys) for every option.

### Step 4. Set up your project

In the folder that has your app's `pubspec.yaml`:

```sh
flutter_run init
```

This writes two files into `.zed/`:

- **`debug.json`:** what you can start with F4.
- **`tasks.json`:** hot reload, hot restart, device picker, DevTools and doctor, which the keys from step 3 use.

`init` works out how your app starts:

- With a `.vscode/launch.json`, it copies those configurations, including flavors and `--dart-define`s.
- With `lib/main.dart`, you get **Flutter: Debug**, **Flutter: Run (no debug)** and **Flutter: Profile**.
- With flavor files such as `lib/main_dev.dart` and `lib/main_prod.dart`, you get **Flutter: Debug dev**, **Flutter: Debug prod** and so on, with `--flavor` when Android or iOS defines the flavor.
- Local packages in the project, such as `packages/app_ui`, are watched too, so saving there also hot reloads.

`init` adds to files you already have and never overwrites them without telling you. Add `--dry-run` to see what it would write. Commit the `.zed` folder so your teammates get it too. They still need steps 1 to 3 on their own computer.

## Use

1. Open the project in Zed (`zed .`).
2. Press **F4** and choose a scenario, such as **Flutter: Debug**. The first build takes as long as `flutter run` does.
3. Set breakpoints by clicking in the gutter next to a line number.
4. Edit and save a file: the app hot reloads. The **Console** tab of the Debug panel shows `[flutter_run]` messages, including how long each reload took.
5. Press **Shift+F5** to stop. Nothing is left running.

| Key | Action |
|---|---|
| F4 | Start, or choose what to run |
| F5 | Run the last choice again; continue when paused at a breakpoint |
| Shift+F5 | Stop |
| Ctrl+F5 | Hot reload |
| Ctrl+Shift+F5 (macOS: Shift+Cmd+F5) | Hot restart |
| Ctrl+Alt+Shift+D | Open DevTools |

The first three are Zed's own keys. The last three come from `flutter_run keymap` and only work while a debug session runs.

**No keys?** Every action is also a task. Open `task: spawn` (Alt+Shift+T, or Cmd+Shift+R on macOS) and type "Flutter".

### More things you can do

- **Choose a device:** run the **Flutter: Select Device** task, or `flutter_run select-device`. The choice is remembered per project. Do this when you have more than one device connected, or Flutter may pick the wrong one.
- **Start an emulator:** run the **Flutter: Launch Emulator** task, or `flutter_run emulators`.
- **Open DevTools:** press Ctrl+Alt+Shift+D, or run `flutter_run devtools` (`flutter_run devtools inspector` opens one page). To open it on every launch, set `"openDevTools": "inspector"` in a scenario.
- **Run without the debugger:** pick a **(no debug)** scenario with F4. Zed has no separate key for this.
- **Attach to an app you started yourself:** see [Attach](docs/CONFIGURATION.md#attach).
- **Change a scenario:** edit `.zed/debug.json`. Every key is listed in [Configuration](docs/CONFIGURATION.md).

## Common problems

| Problem | Fix |
|---|---|
| `flutter_run: command not found` | The pub cache `bin` folder is not on your `PATH`. See [step 1](#step-1-install-flutter_run). |
| Zed says it cannot find `flutter_run` | Start Zed from a terminal (`zed .`) so it gets your `PATH`. |
| `Target file "lib/main.dart" not found` | Your app starts from another file. Run `flutter_run init` again, or set `program` in `.zed/debug.json`. |
| Hot reload or restart keys do nothing | Is a debug session running? Did you run `flutter_run keymap` and `flutter_run init`? If you just changed keys, restart Zed. On laptops, F keys may need Fn. |
| Saving does not reload | Only `lib/` and the folders `init` found are watched. With Zed's autosave on, the reload already happened before you pressed Ctrl+S. |
| The wrong device starts | Run the **Flutter: Select Device** task. |

`flutter_run doctor` explains most setup problems. For everything else see [Troubleshooting](docs/TROUBLESHOOTING.md).

## Update and uninstall

**Update:** run `dart pub global activate flutter_run` again (on Windows, download the new `.exe`). For the extension, `git pull` in the clone, then click **Rebuild** next to the extension on the Extensions page. Stop any running debug session first.

**Uninstall:**

1. Run `dart pub global deactivate flutter_run`, or on Windows delete `flutter_run.exe`.
2. Uninstall the extension from Zed's Extensions page.
3. Remove the block with `"Flutter: Hot Reload"` from your keymap (`zed: open keymap file`).
4. Delete the `.zed` files `init` wrote, if you no longer want them.

## Compatibility

Zed 0.205 or newer (the first version with debugger extensions), the latest stable Flutter, and Linux, macOS or Windows.

CI runs the unit tests and the Dart debug adapter on all three systems, and the Flutter debug adapter on Linux with the headless `flutter-tester` device. Each release is also checked by hand in Zed with a checklist that covers launching, breakpoints, hot reload and restart, DevTools, attach, stopping cleanly and error messages.

If something does not work on your device or setup, open an [issue](https://github.com/sawongam/zed-flutter-run/issues) with your versions and the output of `flutter_run doctor`.

## Privacy

No telemetry, and nothing phones home. The only network use by this project is the one-time download of the `flutter_run` binary from this repository's GitHub releases, which is checked against a pinned SHA-256 and happens only when no `flutter_run` is on your `PATH`. The control channel is loopback only, with a per-session token. Log files exist only when you turn them on, and can contain your app's output, so check them before sharing.

## Documentation

- [Configuration](docs/CONFIGURATION.md): every `debug.json` key, command, flag, key binding, environment variable and exit code
- [Troubleshooting](docs/TROUBLESHOOTING.md): start with `flutter_run doctor`. Also lists known limitations
- [Architecture](docs/ARCHITECTURE.md) and [design notes](docs/DESIGN.md): how it works and why

## How it works

Zed speaks the Debug Adapter Protocol. So does Flutter's own `flutter debug_adapter`. `flutter_run dap` sits between the two and passes messages through, adding what Zed does not offer on its own: it injects your chosen device, watches your source files and sends a hot reload when you save, and makes sure nothing is left running when you stop. Commands such as `flutter_run reload` reach the running session over a local, token-protected connection.

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) to get set up, and [SECURITY.md](SECURITY.md) to report a vulnerability.

## License

[BSD 3-Clause](LICENSE).

This project is not affiliated with or endorsed by Google or Zed Industries. Flutter and Dart are trademarks of Google LLC. Zed is a trademark of Zed Industries, Inc.
