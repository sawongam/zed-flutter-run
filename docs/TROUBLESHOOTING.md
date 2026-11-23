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

**"Target file "lib/main.dart" not found".** Your app starts from another file, such as `lib/main_dev.dart`. Set `program` (and `toolArgs: ["--flavor", "dev"]` if the app has flavors) in `.zed/debug.json`. `init` does this for you when it finds `.vscode/launch.json` or `lib/main_<flavor>.dart` files, so with a project set up before that, delete the generated scenarios and run `flutter_run init` again.

## Running and debugging

**Tasks say "No running Flutter app found" (exit 3).** No debug session is running for this directory, or it is still starting. Start the app with F4 first. `flutter_run status` lists sessions.

**Hot reload or restart keys do nothing.** Work through these in order:

1. Run `flutter_run keymap`. If it says the keymap already has Flutter keys, they are bound.
2. Start a debug session first. The keys only work while one runs (context `Workspace && debugger_session`).
3. Run `flutter_run init` in the project. The keys start the tasks **Flutter: Hot Reload** and **Flutter: Hot Restart**, and a key does nothing if the project has no task by that name.
4. Restart Zed. Zed normally reloads the keymap when the file changes, but it can miss the change, and then the key keeps its old job (for example Ctrl+Shift+S still opens Save As).
5. Look for a clash. `flutter_run keymap` warns about the ones it knows (see [Keys](CONFIGURATION.md#keys)). Your desktop or OS can also take a key first: on macOS check System Settings > Keyboard > Keyboard Shortcuts, and on Linux your desktop's keyboard settings.
6. On laptops, F keys often control volume or brightness unless you hold Fn or turn on Fn Lock. On macOS, F keys need `fn` unless you turn on "Use F1, F2, etc. keys as standard function keys".

To check whether the key or the tool is at fault, run the **Flutter: Hot Reload** task from `task: spawn`. If the task works, the problem is the key.

**Ctrl+S seems not to reload, but reloads happen while I type.** Zed's autosave (`"autosave": {"after_delay": ...}`) saves for you, and each save hot reloads. When you then press Ctrl+S, the file has no unsaved changes, so nothing is written and nothing reloads. To make Ctrl+S the only thing that reloads, turn autosave off for the project in `.zed/settings.json`: `{ "autosave": "off" }`.

**Hot restart says another reload or restart is still running.** A restart now waits for a running reload and then runs. You only see this message if the running action takes longer than the timeout (120 s), for example when the app is paused at a breakpoint. Resume (F5) and try again.

**F5 does nothing.** While the app runs, F5 does nothing. It runs the last scenario when stopped and continues when paused. Stop with Shift+F5.

**Several devices connected.** Flutter refuses to choose. Run **Flutter: Select Device** (or `flutter_run select-device`) or set `deviceId`.

**Reload while paused at a breakpoint.** Resume (F5) first. A paused isolate cannot finish a reload.

**Reload fails.** The error appears in the Debug panel's Console tab with a hint to try hot restart.

**Attach waits forever.** You gave no VM service URI, or you used `vmServiceInfoFile` with the file `flutter run --vmservice-out-file` writes (a bare string). Use `vmServiceUri`.

**DevTools does not open.** DevTools needs DDS. It is not available when DDS is off (`--no-dds`, which attach sessions use). Use `flutter_run devtools --print` to get the URL.

**Dart program: hot restart or DevTools refuse.** The Dart debug adapter does not support them. Hot reload and breakpoints work.

**Reload on save ignores my change.** Only `lib/` (and `bin/` for Dart programs) and folders named in `reloadOnSaveGlobs` are watched. `init` adds local path packages inside the project (such as `packages/app_ui`), but not packages outside it. `reloadOnSave: "changed"` skips saves where the content did not change.

## Leftovers

If the proxy is killed hard (SIGKILL), the app and adapter may keep running and the session file stays until the next `flutter_run status` or `reload` removes it. Stop the leftover processes by hand. A dead session whose port was reused may show as "unresponsive".

## Getting more detail

Set `"logFile": "/tmp/flutter_run.log"` in the scenario, or set `FLUTTER_RUN_LOG=/tmp/flutter_run.log` and `FLUTTER_RUN_LOG_LEVEL=debug`. The file includes the full DAP traffic, so check it before sharing. Add `--verbose` to any command for more output.

## Known limitations

**From Zed**

- Zed has no extension API for toolbar buttons, a status bar device selector or on-save hooks. Hot reload, hot restart, device selection and DevTools are tasks and key bindings, and reload on save uses the proxy's own file watcher.
- Zed tasks can only run commands on `PATH`, so `flutter_run` must be installed separately from the extension.
- There is no key for "run without debugging". Choose **Flutter: Run (no debug)** from the F4 list.

**From Flutter and Dart**

- For plain Dart programs, breakpoints and hot reload work. Hot restart and DevTools do not, because `dart debug_adapter` does not support them.
- `vmServiceInfoFile` must contain JSON of the form `{"uri": "..."}`. The file written by `flutter run --vmservice-out-file` is a bare address, and Flutter's adapter waits forever on it. Use `vmServiceUri` instead.
- DevTools is served by the Dart Development Service. Attach sessions run without it, so `flutter_run devtools` is not available while attached.

**From this project**

- Reload on save watches `lib/`, `bin/` for Dart programs, and folders named in `reloadOnSaveGlobs`. Edits in a sibling package of a monorepo do not trigger a reload unless you add a glob for it.
- If the proxy is killed with `SIGKILL`, the app and the debug adapter can be left running, and the session file stays until the next `flutter_run status` or `flutter_run reload` removes it. Zed's normal stop does not do this.
- On Windows, finding leftover child processes needs PowerShell or `wmic`. Without either, cleanup after an adapter crash can miss processes.
- On Windows, the `flutter_run.bat` launcher created by `dart pub global activate` cannot be used by Zed's debugger. Use a compiled `flutter_run.exe`.

## Still stuck

Open an issue with the output of `flutter_run doctor`, your Zed, Flutter and OS versions, and the log file if you made one. Security problems go to [SECURITY.md](../SECURITY.md) instead.
