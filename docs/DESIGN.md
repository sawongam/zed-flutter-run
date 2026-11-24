# Design notes

Why the project is built the way it is. [ARCHITECTURE.md](ARCHITECTURE.md) describes what the code does; this page records the choices behind it, so that a change which undoes one of them is made on purpose.

## A separate tool, not a patch to Zed's Dart extension

Zed's Dart extension already starts `flutter debug_adapter`, so breakpoints work there. What it cannot do is hot reload, reload on save, device selection or DevTools, because Zed gives extensions no way to add buttons, pickers or on-save hooks.

This project gets those features without waiting for new Zed APIs, by putting a proxy between Zed and the debug adapter. It registers its own debug adapter name, `FlutterRun`, and leaves the Dart extension alone. Use that one for the language server and this one for running and debugging.

The adapter is not called `Flutter` because several other extensions already register that name, and Zed silently lets the last one loaded win.

## A proxy in front of Flutter's own debug adapter

`flutter_run dap` forwards Debug Adapter Protocol messages between Zed and `flutter debug_adapter` and changes as little as it can:

- It rewrites the `launch` and `attach` arguments (device, mode, defaults) and removes its own keys.
- It sends its own `hotReload` and `hotRestart` requests to the adapter and swallows their responses.
- Everything else passes through untouched, including fields it does not know about, so newer Zed and Flutter versions keep working.

Requests the proxy injects use sequence numbers from 1,000,000,000 upward. Zed's own counter starts at 1, so the two ranges never meet, and the proxy does not need to renumber Zed's requests. Renumbering would break `cancel`, which refers to a request by its number.

Writing a new debug adapter was never an option worth taking: Flutter's adapter is maintained by the Flutter team and tracks every SDK change.

## Rust for the extension, Dart for everything else

Zed extensions must be Rust compiled to WebAssembly. The extension is kept to the minimum: find the `flutter_run` binary, build its command line, supply the `debug.json` schema, and map tasks to debug scenarios.

All behaviour lives in the Dart tool. Flutter developers can read and change it without learning Rust, and anyone with Flutter installed can install it with `dart pub global activate`.

## Two install steps

Hot reload, hot restart and the device picker are Zed tasks that run `flutter_run <command>`. Zed tasks can only run commands found on `PATH`, and an extension's download folder is not on it. So `flutter_run` must be installed on `PATH`, separately from the extension.

The extension looks for the binary in this order: the `dap.FlutterRun.binary` setting, `PATH`, then a download from this repository's GitHub releases. A download only happens when a SHA-256 for that release is compiled into the extension. If the proxy starts but `flutter_run` is not on `PATH`, it says so once in the debug console, because the tasks will not work.

## Stopping follows what Zed really does

When you press stop, Zed sends `terminate` and kills the adapter process as soon as the response arrives. If the proxy forwarded that response straight away, it would be killed before it could clean up, leaving the app, the Dart Development Service or the frontend server running.

So the proxy holds the `terminate` response until the adapter has answered and cleanup is finished (session file removed, file watcher stopped, leftover child processes ended), with a limit of five seconds. A `disconnect` without `terminate`, the end of standard input, a signal and an adapter crash all run the same cleanup.

## Which processes the proxy may end

On a normal stop the proxy ends the adapter and the processes that are its descendants at that moment. It does not touch processes it saw earlier that have since left the tree, such as a Gradle daemon started by an Android build.

To know the earlier descendants, the proxy reads the process table while the adapter runs. That reading costs a `ps` (or PowerShell on Windows) each time and only matters after a crash, so it slows down once the tree has stopped changing and relies on the session's own events to read again when processes are likely to appear.

Only after the adapter crashes does it also end earlier descendants that were orphaned, and it checks each process's start time first so that a reused process ID is never mistaken for one of ours. It never ends `adb`, Gradle or Kotlin daemons: killing `adb` would disconnect every device on the machine.

If the proxy itself is killed with `SIGKILL` it cannot clean up. This is a known limitation.

## The control channel

`flutter_run reload` and the other commands need to reach a running session. The proxy listens on `127.0.0.1` on a random port and writes the port and a random token to a session file in a per-user directory that only the owner can read. Every request must carry the token, and only a fixed set of commands is accepted.

A local TCP socket was chosen over a Unix socket or named pipe because it behaves the same on Linux, macOS and Windows.

## Reload on save watches an allow-list

Zed has no on-save hook for extensions, so the proxy watches files itself. It watches `lib/` (and `bin/` for Dart programs), plus any folders named in `reloadOnSaveGlobs`. It does not watch the project root, so `build/`, `.dart_tool/`, `ios/Pods` and `android/.gradle` are never walked.

In the default `changed` mode a save only triggers a reload when the file's content differs from what was last loaded. This matters because some editors and slow file systems report one save as two events. Overlapping reloads are merged, and a save during a hot restart is applied after the restart.

## Keys are written by a command, not printed

Zed extensions cannot add key bindings, and a printed snippet to paste was the step people missed. So `flutter_run keymap` appends one block to the user's Zed keymap. It is a separate command, not part of `init`, because the keymap belongs to the user rather than the project and is needed once per computer. It only appends (as text, so comments stay), never edits or removes bindings, and stops if our tasks are already bound. The block uses the context `Workspace && debugger_session`, so that keys such as Ctrl+S keep their usual meaning outside a debug session.

## `init` copies how the app is already started

A scenario that points at a missing `lib/main.dart` fails on the first F4, which is a poor first experience for apps with flavors. So `init` reads `.vscode/launch.json` first, since it records the targets, flavors and defines the team already uses, and otherwise looks for `lib/main_<flavor>.dart`. It adds `--flavor` only when Android or iOS defines that flavor, because a wrong `--flavor` breaks the build while a missing one only builds the default.

## A hot action waits rather than fails

With reload on save, a reload is often running when the user presses the hot restart key. Answering `busy` made the key look broken. A request now waits for the running action and then runs, bounded by the action timeout. A request for the action that is already running joins it, so pressing a key twice does not restart twice.

## The saved device lives outside the project

The device chosen with `select-device` is stored in the per-user state directory, keyed by project path. It survives `flutter clean` and never shows up in version control. A `deviceId` in `debug.json` takes priority.

## Log files are restricted

`logFile` comes from a project's `debug.json`, which may come from a repository you just cloned. To stop a hostile project from using it to write to files such as `~/.bashrc`, the path must end in `.log`, its folder must already exist, the file is created readable by its owner only, and control characters in logged text are escaped.

Settings that choose which programs run (`flutterSdkPath`, `.fvm/flutter_sdk`, `env`) are trusted in the same way Zed tasks are. Open only projects you trust.

## The debug locator is narrow

The extension can turn an existing Zed task into a debug scenario. It only claims tasks that start an app: `flutter run` (also through `fvm` or `puro`) and `dart run <file>.dart`. It ignores `flutter build`, `flutter test`, `dart pub get` and anything it cannot parse with certainty, such as a flag with a missing value. A wrong guess here would hijack an unrelated task.

Zed only calls a locator when the adapter is listed for the language, so this needs `"languages": {"Dart": {"debuggers": ["FlutterRun"]}}` in Zed settings.

## The release workflow pins the checksums itself

The extension carries the SHA-256 of each release binary, so the pin can only be written after the binaries exist. A person doing that after every release is a step that gets forgotten, so the last job of `release.yml` does it and pushes the commit straight to `prod`. A pull request would only add a click, because the commit is generated from `SHA256SUMS` and checked with the extension's fmt, clippy and tests. The commit is not part of the tagged release, and the registry points at it.

## Inside the Dart tool

- **Modules do not import each other.** Each folder under `cli/lib/src/` imports only `common/` and itself. `cli/lib/src/cli/` is the one place that wires them together. A test (`cli/test/unit/architecture_test.dart`) enforces this.
- **Time, processes, signals and the host OS are passed in.** The proxy's shutdown and start-up paths depend on timeouts, so they are tested with a fake clock instead of real waiting.
- **A session has explicit phases:** starting, running, stopping, finishing, finished. Moves are only allowed forward. This replaced a set of boolean flags whose legal combinations were not written down.
- **Messages are not modelled as classes.** The proxy reads about ten kinds of message and must forward the rest unchanged. `DapMessage` is a thin view over the decoded JSON with tolerant getters; a malformed field reads as missing instead of throwing.
