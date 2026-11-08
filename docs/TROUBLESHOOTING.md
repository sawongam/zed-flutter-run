# Troubleshooting

Start with this in your project:

```sh
flutter_run doctor
```

It shows the Flutter SDK it found, whether `flutter_run` is on PATH, running sessions and your `.zed` files.

## Setup

**"No Flutter SDK found" (exit 6).** Set `flutterSdkPath` in the scenario, set `FLUTTER_RUN_FLUTTER_SDK`, or put `flutter` on PATH. `doctor` lists every place it looked.

**`flutter_run` is not on PATH.** The debugger still starts (through the extension), but tasks fail. Add the pub-cache `bin` folder (or the folder you copied the binary to) to PATH, see the [README](../README.md#step-1-flutter_run-on-your-path).

**The debugger cannot find `flutter_run` on macOS.** A Zed started from the Dock may not see your shell PATH. Start Zed with `zed .` from a terminal, or set `dap.FlutterRun.binary` in Zed settings, see [CONFIGURATION.md](CONFIGURATION.md#zed-settings).

**Windows: the pub-cache launcher does not work.** It is a `.bat` file and Zed cannot supervise it. Compile a native `.exe` or set `dap.FlutterRun.binary`.

**The extension says to install `flutter_run`.** Dev builds never download. Install the tool first. Release builds of the extension download a checksummed binary only if no other copy is found. No release exists yet.

**`.zed/debug.json` is rejected.** The file is JSONC. Fix syntax errors. When `init` cannot parse your file it prints the new content instead of overwriting (exit 9). Old files need `"adapter": "FlutterRun"`.

## Running and debugging

**Tasks say "No running Flutter app found" (exit 3).** No debug session is running for this directory, or it is still starting. Start the app with F4 first. `flutter_run status` lists sessions.

**Hot reload or restart keys do nothing.** The keys only work while a debug session runs (context `Workspace && debugger_session`). Check that you pasted the keymap snippet from `init`. On macOS check System Settings > Keyboard for a conflict, and note that F keys need `fn` unless you change the setting.

**F5 does nothing.** While the app runs, F5 does nothing. It runs the last scenario when stopped and continues when paused. Stop with Shift+F5.

**Several devices connected.** Flutter refuses to choose. Run **Flutter: Select Device** (or `flutter_run select-device`) or set `deviceId`.

**Reload while paused at a breakpoint.** Resume (F5) first. A paused isolate cannot finish a reload.

**Reload fails.** The error appears in the Debug panel's Console tab with a hint to try hot restart.

**Attach waits forever.** You gave no VM service URI, or you used `vmServiceInfoFile` with the file `flutter run --vmservice-out-file` writes (a bare string). Use `vmServiceUri`.

**DevTools does not open.** DevTools needs DDS. It is not available when DDS is off (`--no-dds`, which attach sessions use). Use `flutter_run devtools --print` to get the URL.

**Dart program: hot restart or DevTools refuse.** The Dart debug adapter does not support them. Hot reload and breakpoints work.

**Reload on save ignores my change.** Only `lib/` (and `bin/` for Dart programs) and folders named in `reloadOnSaveGlobs` are watched. Sibling path packages are not. `reloadOnSave: "changed"` skips saves where the content did not change.

## Leftovers

If the proxy is killed hard (SIGKILL), the app and adapter may keep running and the session file stays until the next `flutter_run status` or `reload` removes it. Stop the leftover processes by hand. A dead session whose port was reused may show as "unresponsive".

## Getting more detail

Set `"logFile": "/tmp/flutter_run.log"` in the scenario, or set `FLUTTER_RUN_LOG=/tmp/flutter_run.log` and `FLUTTER_RUN_LOG_LEVEL=debug`. The file includes the full DAP traffic, so check it before sharing. Add `--verbose` to any command for more output.

## Still stuck

Open an issue with the output of `flutter_run doctor`, your Zed, Flutter and OS versions, and the log file if you made one. Security problems go to [SECURITY.md](../SECURITY.md) instead.
