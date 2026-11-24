# Architecture

How the parts fit together and where the code is. [DESIGN.md](DESIGN.md) explains why it is built this way. [CONFIGURATION.md](CONFIGURATION.md) lists every key, flag and exit code.

`zed-flutter-run` has two parts. A Rust extension (`extension/`, compiled to WebAssembly) registers the debug adapter `FlutterRun` with Zed and tells Zed how to start it. A Dart executable (`cli/`, compiled with `dart compile exe`) does all the work. As `flutter_run dap` it is the adapter that Zed talks to: a proxy in front of `flutter debug_adapter` (or `dart debug_adapter`) that adds hot reload, reload on save, device selection and DevTools. As `flutter_run <command>` it is the command line that Zed tasks run.

## Components

```
                            Zed
   .zed/debug.json     .zed/tasks.json                 Debug panel, Console
          |                   |                              ^        |
          | scenario          | task in a terminal           | output | DAP over stdio
          v                   v                              | events | (Content-Length)
  +---------------+   +--------------------+                 |        v
  | extension     |   | flutter_run <cmd>  |  TCP 127.0.0.1  +-------------------------+
  | (Rust, wasm)  |   | reload, restart,   |  token, one     | flutter_run dap         |
  | lib.rs        |   | status, devices,   |  JSON line per  | DapProxy, HotActions    |
  | proxy_args.rs |   | select-device,     |  connection     | ControlServer           |
  | locator.rs    |   | emulators,         +---------------->| ReloadOnSaveWatcher     |
  | install.rs    |   | devtools, init,    |                 | session file            |
  +---------------+   | doctor             |                 +------------+------------+
                      +---------+----------+                              | DAP over stdio
                                |  reads <state>/sessions/<pid>.json      v
                                |  reads and writes <state>/devices/   flutter debug_adapter
                                +-------------------------------------   dart debug_adapter
```

## Process tree during a launch

```
Zed
 +-- flutter_run dap --cwd <dir> --kind flutter --request launch --client-version <v>
      |                [--flutter-sdk <dir>] [--use-fvm] [--log-file <path>]
      |   (listens on 127.0.0.1:<random port>, owns <state>/sessions/<its pid>.json)
      +-- flutter debug_adapter        (attach: flutter debug_adapter --no-dds)
           +-- everything the adapter starts: flutter tool, frontend server, DDS, the app
```

Commands such as `flutter_run reload` run in their own terminal, outside this tree. `DapCommand` (`cli/lib/src/cli/dap_command.dart`) resolves the SDK, starts the adapter without a shell and hands the session to `DapSessionHost`.

## The extension

`extension/src/lib.rs` holds the Zed trait glue and the file system work. The logic is in plain modules that the host tests can run.

- `get_dap_binary` parses the scenario with `proxy_args::parse_config`, finds the binary with `resolve_command`, and returns the command, the arguments from `build_proxy_args`, the environment (Zed's shell environment with the scenario's `env` on top) and the working directory. A relative `cwd` is joined onto the worktree root. The scenario is passed to Zed unchanged as the request arguments.
- `resolve_command` is one linear flow: the `dap.FlutterRun.binary` setting, then `flutter_run` on `PATH`, then a cached download whose SHA-256 matches the pin, then a fresh download. `install::select_command` makes the first two choices and returns `Use`, `OnlyBatchShim` or `Nothing`. On Windows `flutter_run.exe` is preferred and a `.bat` or `.cmd` wrapper is refused, because Zed would supervise the wrapper and not the real process.
- A download needs a checksum in `checksums.rs`. The table is empty in development builds, so they never download. The file comes from this repository's GitHub releases, is checked before it is moved into place and is stored as `flutter_run-<version>/flutter_run[.exe]` in the extension's work directory. Older version folders and leftover `.part-<n>` files are removed.
- `dap_request_kind` returns launch or attach from the `request` key. `dap_config_to_scenario` turns Zed's own debug configuration into a scenario. A program under `bin/` or `tool/` becomes `type: dart`, anything else stays Flutter.
- `locator.rs` is the debug locator. `scenario_config` maps a task (`flutter run`, `fvm flutter run`, `puro flutter run`, `dart run <file>.dart`, `dart <file>.dart`) to scenario JSON and returns `None` for any other task or any flag it cannot read with certainty. A `$ZED_*` variable in the task's `cwd` is dropped. Only the pair `FlutterRun` and `FlutterRun` is served, and the scenario has no build step.

## The proxy

`DapProxy` (`cli/lib/src/dap/proxy.dart`) routes messages and owns the helpers below. It reads messages through `DapMessage`, a read-only view over the decoded JSON, and forwards `message.raw`, so fields it does not know reach the other side untouched.

Routing:

- Client requests go to the adapter unchanged, except `launch` and `attach` (rewritten), `terminate` and `disconnect` (held by `ShutdownCoordinator`) and `restart` (refused with an explanation for Dart sessions).
- Adapter responses to injected requests are consumed. Responses to `terminate` and `disconnect` are held. All other adapter messages go to the client, and events also feed `SessionTracker`.
- Proxy-made messages (notices, synthetic responses) go to the client as `output` events with the `[flutter_run]` prefix.

Launch rewriting (`launch_rewriter.dart`): `LaunchRewriter.rewrite` removes the keys in `ownKeys`, turns `flutterMode` `profile` or `release` into `--profile` or `--release` in `toolArgs`, adds `-d <id>` from the device lookup order, defaults `cwd` and (Flutter launch) `program`, and checks attach arguments. It returns a `RewriteResult` with the new arguments, the removed keys (`ownConfig`), notes and an optional rejection. A rejected attach gets a failed response and never reaches the adapter.

Injected requests (`injected_requests.dart`): requests the proxy sends itself (`hotReload`, `hotRestart`, `terminate`, `disconnect`) and the notices it makes up use sequence numbers from 1,000,000,000 up. Client numbers are never changed. A client number in that range is logged and reported. `supportedInjections` says which adapter kind accepts `hotReload` and `hotRestart`. The Dart adapter has no hot restart.

`HotActions` (`hot_actions.dart`) runs reload and restart. One action runs at a time. A request for the action that is already running joins it (`coalesced`). A request for the other action, or any request during a client `restart`, waits for the running one and then runs; if it is still running after the timeout, the answer is `busy`. Nothing is sent before `flutter.appStarted`. The default timeout is 120 seconds and a notice appears after 3 seconds of waiting.

Lifecycle: `SessionPhaseMachine` (`session_phase.dart`) moves `SessionPhase` through `starting`, `running`, `stopping`, `finishing` and `finished`, forward only. `stopping` may be skipped by a crash or a failed start. An illegal move is logged and ignored.

Start-up: `InitializeWatchdog` starts when `initialize` arrives. After 10 seconds without an answer it posts one "still starting" notice. After 120 seconds `FailureReporter` fails the request with the adapter's last stderr line and the session ends. If the adapter cannot be started at all, `answerStartupFailure` in `dap_command.dart` answers the first request with the error, so Zed shows the reason instead of "adapter exited".

`SessionTracker` follows `flutter.appStart` (device, mode), `dart.debuggerUris` (VM service address), `flutter.appStarted`, `terminated` and `exited`, and publishes `ProxyState` and `ProxyEvent`s. A Dart adapter never sends `flutter.appStarted`, so its first `dart.debuggerUris` counts as started.

Launch, as seen from the proxy:

```
Zed                  flutter_run dap                              flutter debug_adapter
 |-initialize ------->| watchdog armed -------------------------------->|
 |<-response ---------|<------------------------------------------------|
 |-launch ----------->| LaunchRewriter: strip own keys, mode, -d <id> -->| starts the app
 |<-notices: version mismatch, PATH, device in use (after the control server is up)
 |<-flutter.appStart  | state: device, mode  -> session file (debounced 50 ms)
 |<-dart.debuggerUris | vmServiceUri; first one may open DevTools (openDevTools)
 |<-flutter.appStarted| appStarted -> session file now; reload on save armed
```

`DapSessionHost` (`cli/lib/src/cli/dap_session_host.dart`) starts the control server and writes the session file concurrently with the proxy (`_controlReady`), so they never delay the first message from Zed. The first launch notices wait for it, so a failure to publish the session can be reported. If publishing fails, debugging still works and a notice says the reload tasks cannot find the session.

### Reload from a task

```
Zed task "Flutter: Hot Reload"  ->  flutter_run reload
  1. list <state>/sessions/*.json and ping each concurrently; a stale file is deleted,
     a session that does not answer is kept and marked unresponsive
  2. keep sessions whose project root contains or lies inside --project (default: current directory)
  3. skip Dart sessions, unresponsive sessions and sessions whose app has not started
  4. for each remaining session, in parallel, over TCP:
       {"v":1,"token":...,"id":1,"command":"reload","args":{"reason":"manual"}}
       -> ProxySessionControl.reload -> HotActions.reload -> injected hotReload -> adapter
  5. print one line per session; exit 0, 4 (failed), 5 (no answer within --timeout, default 120 s), 3 (no session)
```

`restart` is the same with `hotRestart`. After 3 seconds the command prints a note that the app may be paused at a breakpoint. The adapter answers a reload only after the app resumes, so a paused app delays the answer.

### Stopping

Zed's stop button sends `terminate` and kills the adapter process as soon as the response arrives. The proxy holds that response until cleanup is done. [DESIGN.md](DESIGN.md) gives the reasons. `ShutdownCoordinator` (`shutdown_coordinator.dart`) owns every way a session can end.

```
Zed Stop
 |-terminate-------> 1. onShutdownStarted: hot actions now answer session_ended, watcher and timers
 |                      stop, session file deleted
 |                   2. snapshot the adapter's descendants (at most 3 s)
 |                   3. forward terminate; after 1 s still running: notice "Stopping the app..."
 |                   4. adapter answers: response held. App exits: `terminated` event
 |                   5. when the response is held and `terminated` seen, or after 5 s:
 |                      stop the watcher, close the control server, kill what is left
 |<-response--------- 6. held response released and flushed
 |-(Zed kills the proxy; nothing runs after this)
```

The other ways to end:

- `disconnect` without `terminate`: for a launch session the proxy injects `terminate` (at most 5 s), forwards `disconnect`, waits for the answer plus 500 ms or at most 5 s for the adapter to exit, runs the same cleanup, answers Zed and exits 0.
- Standard input closes, or SIGINT, SIGTERM or SIGHUP arrives (Windows watches only SIGINT): the same cleanup with an injected `terminate` and then `disconnect`, and no response to Zed. A SIGKILL cannot be handled.
- The adapter exits on its own with code 0 after `terminated`: the session ends with 0. Any other unasked exit is a crash. The proxy fails a pending `initialize`, relays the adapter's stderr, posts a notice, sends a `terminated` event and exits with the adapter's code.
- Attach sessions never get an injected `terminate`, so the app keeps running. `attach` also starts `flutter debug_adapter --no-dds`, because `flutter run` already runs a DDS.

While the adapter runs, the coordinator records its descendants so a crash can still be cleaned up. It polls every 2 seconds (6 on Windows). After three readings in a row that show the same tree it polls every 20 seconds (30 on Windows), and process activity the tracker reports (a new VM service, the app starting) takes a reading at once and goes back to the fast rate.

The kill step ends the adapter if it is still alive and its descendants as read at that moment. `ManagedProcess.terminateTree` reads the process table once and passes the reader to `killTree` (`sdk/process_tree.dart`). On POSIX `killTree` sends SIGTERM, waits two seconds and sends SIGKILL, signalling only pids that are provably ours: current descendants, or snapshot pids whose recorded start time still matches. Pids 0 and 1 are never signalled. On Windows it runs `taskkill /T /F`. Processes seen earlier that have left the tree, such as a Gradle daemon, are not touched. After a crash, earlier descendants are included, except `adb`, Gradle and Kotlin daemons and the Dart tooling daemon (`isSharedDaemonCommand`). All waits are in `proxy_options.dart` (`ProxyOptions`, `ProxyTimings`), so tests shrink them.

## Control channel

The session file is `<state>/sessions/<pid>.json`. The directory is created with mode 0700 on POSIX. Writes are atomic and serialised, and an update after `delete` does nothing. It is written when the proxy starts, rewritten (debounced 50 ms) when the device or VM service address changes, written at once on `flutter.appStarted`, and deleted first thing in shutdown.

```json
{"version":1,"pid":12345,"port":40123,"token":"<43 base64url characters>",
 "projectRoot":"/home/me/app","cwd":"/home/me/app","kind":"flutter","request":"launch",
 "startedAt":"2026-01-01T12:00:00.000Z","deviceId":"linux","mode":"debug",
 "vmServiceUri":"ws://127.0.0.1:33171/abc=/ws","appStarted":true}
```

`deviceId`, `mode` and `vmServiceUri` are omitted until known. A file with another `version`, or one that does not parse, is skipped.

`ControlServer` (`control/control_server.dart`) listens on `127.0.0.1` with a random port. The token is 32 random bytes. Each connection carries one request line of JSON, ended by a newline, and gets one reply line:

```
{"v":1,"token":"...","id":1,"command":"reload","args":{"reason":"manual"}}
{"v":1,"id":1,"ok":true,"result":{"durationMs":600,"coalesced":false}}
{"v":1,"id":1,"ok":false,"error":{"code":"busy","message":"..."}}
```

The commands are `ping` (result `pid`, `version`, `protocol`), `reload` (`durationMs`, `coalesced`) and `restart` (`durationMs`, `coalesced`). Error codes are in `ControlErrorCode`: `bad_request`, `unsupported_version`, `unauthorized`, `payload_too_large`, `unknown_command`, `app_not_started`, `busy`, `adapter_error`, `timeout`, `session_ended` and `internal`. The token is compared in constant time.

Limits: a request line is at most 64 KiB and must arrive within 3 seconds. At most 64 connections are open and at most 16 of them may be waiting for a line. A connection over the limit gets `busy` with `id: null`.

`ControlClient.ping` returns alive, unresponsive or stale. A refused connection, a reply that is not the protocol, a wrong token or a different pid proves the session is gone, so `SessionStore.list` deletes the file, but only if it still holds the pinged token and pid. A timeout leaves the file. `status` reads the files and has no control command.

## Reload on save

Zed has no on-save hook for extensions, so `ReloadOnSaveWatcher` (`cli/lib/src/watch/`) watches files itself, once the app has started.

- Watched folders (`PathFilter.watchDirectories`): `lib/`, `bin/` for Dart programs, and the fixed folder prefix of each entry in `reloadOnSaveGlobs`. A glob without a folder prefix is reported and ignored.
- A path triggers if it ends in `.dart` or matches a glob. Hidden segments are ignored at any depth. `build`, `.dart_tool`, `.git` and `node_modules` are ignored at the project's top level.
- In `changed` mode a file triggers only if the SHA-256 of its content differs from the last seen one (`ContentHashTracker`; files over 2 MiB always count, at most 5000 entries kept). The files already present when the watcher starts are hashed once, on a background isolate (`ContentHashTracker.seed`), so the CPU this takes does not hold up the DAP traffic.
- `ReloadCoalescer` waits for the debounce (default 200 ms, range 10 to 5000), runs one reload at a time and queues at most one follow-up. If `HotActions` answers busy, it retries with a growing delay of at most 2 seconds.
- The reload is `HotActions.reload(reason: 'save')`. A save-triggered reload has no timeout of its own, because the app may be paused at a breakpoint.
- It is not started when `reloadOnSave` is `off` or the app runs in profile, release or jit_release mode.

## SDK discovery

`SdkResolver` (`cli/lib/src/sdk/sdk_resolver.dart`) takes the first hit and records each step for `doctor`:

1. `--flutter-sdk` or the scenario's `flutterSdkPath`. An explicit path that is not an SDK is an error and is not skipped.
2. `FLUTTER_RUN_FLUTTER_SDK`.
3. fvm: the `.fvm/flutter_sdk` link in the project or a parent, then the version from `.fvmrc` or `.fvm/fvm_config.json` looked up in the fvm cache (`FVM_CACHE_PATH`, `FVM_HOME`, `~/fvm`, and `%LOCALAPPDATA%\fvm` on Windows).
4. puro (`.puro.json`).
5. `FLUTTER_ROOT`.
6. `flutter` on `PATH`.

With `useFvm`, the search ends after step 3. For `type: dart` the same walk runs, then the Dart bundled with that SDK is used, then `DART_SDK`, then `dart` on `PATH`.

## Device selection

`LaunchRewriter` picks the device for a Flutter launch or attach in this order: `-d` or `--device-id` already in `toolArgs`, the scenario's `deviceId`, `FLUTTER_RUN_DEVICE`, the device saved by `select-device`, then nothing (Flutter chooses). An id outside `safeIdPattern` (`sdk/process_spec.dart`) is dropped with a note. `SessionNotices` says so when the device came from the environment or the saved selection, or when none was chosen. Dart sessions skip this.

## Module map

All of this is under `cli/lib/src/`.

| Module | Contents |
|---|---|
| `common/` | Version and protocol constants, `ExitCodes` and exceptions, `Clock`, `HostEnvironment`, paths and state directory, atomic file writes, `Logger`, `Console`, `Style` (ANSI colour that is a no-op when colour is off) |
| `dap/` | The proxy, framing, `DapMessage`, launch rewriting, injected requests, `HotActions`, lifecycle, start-up watchdog, `ShutdownCoordinator`, notices |
| `control/` | Control protocol and server, `ControlClient`, session file model and `SessionStore`, the `reload`, `restart` and `status` commands |
| `sdk/` | `SdkResolver`, process start (`ManagedProcess`, `ProcessSpec`, `ProcessRunner`), process table and `killTree` |
| `devices/` | Device and emulator listing, `DeviceStore`, the picker, the `devices`, `select-device` and `emulators` commands |
| `watch/` | Reload-on-save settings, path filter, content hashes, coalescer, watcher |
| `devtools/` | Page names, URL building, browser opener, the `devtools` command |
| `init/` | Project detection (entry points from `.vscode/launch.json` or `lib/main_<flavor>.dart`, local packages), scenario and task templates, JSON and JSONC merge, key bindings and their known clashes, the `init` and `keymap` commands |
| `cli/` | `FlutterRunRunner`, `Wiring`, `buildCommands`, `DapCommand`, `DapSessionHost`, `SessionNotices`, `doctor` and `version` |

Import rule: `common/` imports no other module, each feature module imports only `common/` and itself, and only `cli/` imports the feature modules and connects them. `cli/test/unit/architecture_test.dart` checks every import.

Code that touches time, processes, signals or the OS takes an interface instead:

| Interface | Defined in | Real implementation |
|---|---|---|
| `Clock` | `common/clock.dart` | `SystemClock` |
| `HostEnvironment` | `common/host_environment.dart` | `HostEnvironment.system()` |
| `ProcessRunner` | `sdk/process_runner.dart` | `SystemProcessRunner` |
| `SignalSource` | `cli/signal_source.dart` | `SystemSignalSource` |
| `AdapterConnection` | `dap/channel.dart` | `ManagedAdapterConnection` (`cli/wiring.dart`) |
| `RequestInjector` | `dap/hot_actions.dart` | `DapProxy` |
| `SessionControl` | `control/control_protocol.dart` | `ProxySessionControl` (`cli/wiring.dart`) |
| `ControlEndpoint` | `control/control_protocol.dart` | `ControlServer` |

Objects are connected through constructor arguments, with no service locator.

## State and files

| OS | State directory |
|---|---|
| Linux | `$XDG_STATE_HOME/flutter_run`, else `~/.local/state/flutter_run` |
| macOS | `~/Library/Application Support/flutter_run` |
| Windows | `%LOCALAPPDATA%\flutter_run` |

`FLUTTER_RUN_STATE_DIR` overrides all three. It holds `sessions/<pid>.json` and `devices/<first 16 hex of the SHA-256 of the project root>.json`. The device file has `version`, `projectRoot`, `deviceId`, `name`, `platform` and `savedAt`, and is ignored if the version or project root does not match.

Outside the state directory: `.zed/debug.json` and `.zed/tasks.json` in the project (written only by `init`), the Zed `keymap.json` (appended to only by `keymap`), the downloaded binary in the extension's work directory, and the optional log file.

## Security

- The control server binds `127.0.0.1` only. The only credential is the token in the session file, which sits in a user-only directory. A process of the same user can read it, and nothing defends against that.
- Control commands are a fixed set (the handler map in `ControlServer`). Nothing in a request is executed.
- Child processes start without a shell. For `.bat` and `.cmd` targets on Windows, arguments with `cmd.exe` metacharacters are refused. Emulator ids are checked before `--launch`, and `select-device --device` must name a connected device.
- DevTools addresses are opened only if they point to `127.0.0.1`, `localhost` or `::1` (`isSafeBrowserUrl`).
- The extension downloads only from `github.com/sawongam/zed-flutter-run`, declared in the `download_file` capability of `extension.toml`, and only runs a file whose SHA-256 matches the pin.
- A log file name must end in `.log`, its folder must exist, the file is created owner-only on POSIX, and control characters in logged text are escaped. Logs can hold DAP traffic, so they are written only on request.
- `flutterSdkPath`, `.fvm/flutter_sdk` and `env` choose what runs, as Zed tasks do. Open only projects you trust.
