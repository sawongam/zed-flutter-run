# Architecture (as built, v0.1.0)

> **Updated 2026-11-08** for branch `improve/world-class`: internal ports and an injected clock, an explicit session phase model and `ShutdownCoordinator`, a typed `DapMessage` view, attach validation, the extension's install planner and the debug locator. See sections 4.9 to 4.15 and [ADR 0010](decisions/0010-internal-architecture-ports-and-phases.md). To add a command, request or key, see [EXTENDING.md](EXTENDING.md).

This describes the code that exists in `cli/lib/src/**` and `extension/src/**` on branch `improve/world-class` (it started on `build/mvp`). Where the plan ([IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md)) and the code differ, the code is described and the difference is called out. Nothing here has been run in a real Zed yet; see [MANUAL_ZED_TEST.md](MANUAL_ZED_TEST.md) for what still has to be confirmed.

Decisions behind this design: [0002](decisions/0002-architecture-dap-proxy.md) (shape), [0003](decisions/0003-languages-rust-extension-dart-proxy.md) (languages), [0004](decisions/0004-architecture-accepted-with-amendments.md) (amendments), [0005](decisions/0005-project-names.md) (names), [0006](decisions/0006-plan-review-resolutions.md) (install model, shutdown, seq range; wins over 0004 where they differ), [0007](decisions/0007-phase6-review-resolutions.md) (process-kill policy, log file rules, initialize timeout), [0009](decisions/0009-debug-locator.md) (debug locator), [0010](decisions/0010-internal-architecture-ports-and-phases.md) (ports, injected clock, session phases). Risks: [risk-register](research/risk-register.md).

## 1. Components

```
                     Zed (GUI)
  .zed/debug.json   .zed/tasks.json   keymap.json         Debug panel / Console tab
        |                 |                                      ^         |
        | scenario        | task::Spawn (real PTY terminal)      | output  | DAP over stdio
        v                 v                                      | events  | (Content-Length)
 +--------------+   +-------------------+                         |         v
 | Rust/WASM    |   | flutter_run <cmd>  |                    +---------------------------+
 | extension    |   | reload | restart  |                    | flutter_run dap            |
 | flutter-run-  |   | select-device     |                    | (Dart exe, one process    |
 | debugger     |   | devices           |  TCP 127.0.0.1     |  per debug session)       |
 |  get_dap_    |   | emulators         |  + token, 1 JSON   |                           |
 |  binary -----+-->| devtools | init   +------------------->|  ControlServer            |
 |  dap_request |   | doctor | status   |  line per conn     |  DapProxy + HotActions    |
 |  _kind       |   +-------------------+                    |  ReloadOnSaveWatcher      |
 |  dap_config_ |        reads session files                 |  DevTools opener          |
 |  to_scenario |        <state>/sessions/<pid>.json <-------+  session file writer      |
 +--------------+        reads/writes <state>/devices/*.json +-------------+-------------+
   locator.rs: task -> scenario                                             | DAP over stdio
                                                                           v
                                                          flutter debug_adapter   (type "flutter")
                                                          dart debug_adapter      (type "dart")
                                                                           |
                                                                           v
                                                          flutter run --machine  -->  app on device
```

| Component | Language | Source | Job |
|---|---|---|---|
| Zed extension `flutter-run-debugger` (adapter `FlutterRun`) | Rust, `wasm32-wasip2`, `zed_extension_api 0.7.0` | `extension/` | Finds the `flutter_run` binary, builds its argv and env from the scenario, hands Zed the scenario verbatim, ships the JSON schema. No debugging logic. |
| `flutter_run dap` (the proxy) | Dart, `dart compile exe` | `cli/lib/src/{dap,control,watch,devtools,sdk,cli}` | Everything that touches a debug session. |
| `flutter_run <command>` (the CLI) | same executable | `cli/lib/src/{control,devices,devtools,init,cli}` | Commands run from Zed tasks or a terminal. |

Install model (ADR 0006 D1): two steps, the Zed extension plus `flutter_run` on the PATH, because Zed tasks can only run PATH commands. The extension resolves the proxy as: `dap.FlutterRun.binary` setting, then `flutter_run` on the worktree PATH (Windows: `flutter_run.exe` first, `.bat`/`.cmd` shims ignored because Zed would kill only `cmd.exe`), then a download from GitHub Releases that is only attempted when a SHA-256 is pinned in `extension/src/checksums.rs` (it is empty in dev builds, so dev builds never download), then a clear error (`extension/src/install.rs`, `extension/src/lib.rs`).

## 2. Process tree during a Flutter launch

```
Zed
 +-- flutter_run dap --cwd <dir> --kind flutter --request launch --client-version 0.1.0 [--flutter-sdk ..] [--use-fvm] [--log-file ..]
      |   (listens on 127.0.0.1:<random port>; owns <state>/sessions/<its pid>.json)
      +-- flutter debug_adapter            (attach sessions: flutter debug_adapter --no-dds)
           +-- dart ... debug_adapter / flutter_tools
                +-- flutter run --machine
                     +-- frontend_server, dart development-service (DDS), the app (e.g. flutter_tester or the Linux runner)

Separate, short-lived, started by a Zed task in its own terminal (not in the tree above):
flutter_run reload | restart | select-device | devtools | ...
```

The adapter is started without a shell (`ManagedProcess.start`, `runInShell: false`). On Windows, `.bat` targets get every argument validated against `cmd.exe` metacharacters (`sdk/process_spec.dart`). Before any stop, the proxy snapshots the adapter's descendants (`ps` table on POSIX, with start-time tokens to avoid pid reuse) so survivors can be swept later (`sdk/process_tree.dart`).

## 3. Sequences as implemented

### 3.1 Launch

```
Zed             extension (wasm)        flutter_run dap                         flutter debug_adapter
 | F4 scenario     |                         |                                          |
 |-dap_request_kind->  Launch/Attach         |                                          |
 |-get_dap_binary-->|  command, argv, env    |                                          |
 |-spawn, stdio -------------------------->  | resolve SDK (see 4.4), start adapter --->| (starts, waits for client)
 |                                            | ControlServer.start; session file written (appStarted=false)
 |-initialize ------------------------------>| pass through ---------------------------->|
 |<-response (+ capabilities, initialized) ---|<-----------------------------------------|
 |-launch{program,cwd,toolArgs,deviceId,      |
 |        reloadOnSave,openDevTools,...} ---->| LaunchRewriter: strip own keys, flutterMode,
 |                                            | inject "-d <id>", default cwd/program ---->| flutter run --machine ...
 |<-output notices: "Using device X (saved selection)", PATH notice, version-mismatch notice
 |-setBreakpoints / configurationDone ------->| pass through
 |<-events flutter.appStart (device, mode) ---| state -> session file (debounced 50 ms)
 |<-event  dart.debuggerUris -----------------| vmServiceUri -> session file; first one: openDevTools page if configured
 |<-event  flutter.appStarted ----------------| appStarted=true -> session file rewritten now; ReloadOnSaveWatcher armed
```

The proxy never renumbers client messages (ADR 0006 D3 amends 0004 section 2). Its own requests (`hotReload`, `hotRestart`, injected `terminate`/`disconnect`) use seq numbers from 1,000,000,000 upward and their responses are swallowed (`dap/injected_requests.dart`). Messages the proxy makes up for the client (notices, synthetic responses) use the same range.

### 3.2 Reload from a task (ctrl-f5)

```
Zed task "Flutter: Hot Reload"  ->  flutter_run reload  (terminal tab, hidden on success)
   1. list <state>/sessions/*.json, ping every one concurrently; refused connection => file pruned;
      timeout => kept and flagged "unresponsive"
   2. keep sessions whose projectRoot contains or is inside --project/cwd
   3. skip: kind != flutter, unresponsive, appStarted=false (each gets one stderr line)
   4. for each eligible session, in parallel:
        TCP 127.0.0.1:<port>  {"v":1,"token":..,"id":..,"command":"reload","args":{"reason":"manual"}}
                                    -> ProxySessionControl.reload -> HotActions.reload('manual')
                                    -> inject hotReload{reason:"manual"} (seq >= 1e9) -> adapter
        adapter prints "Reloaded N libraries ..." as an output event -> proxy forwards it -> Zed Console
        adapter response (swallowed) -> {"ok":true,"result":{"durationMs":..,"coalesced":..}}
   5. print "Hot reload: <device> <project> ok in 0.6 s", exit 0 (exit 4 failed, 5 timeout, 3 no session)
   After 3 s without an answer the CLI prints "Waiting... the app may be paused at a breakpoint".
```

`restart` is the same with `hotRestart`. HotActions allows one action in flight: two reloads coalesce into one result (`coalesced: true`); a reload during a restart (or the reverse) answers `busy`, except a save-triggered reload, which waits for the restart and then runs (`dap/hot_actions.dart`). The adapter only answers a reload after the app resumes, so a reload while paused at a breakpoint waits (120 s default timeout, `--timeout`).

### 3.3 Reload on save

```
file saved -> package:watcher (only lib/, bin/ for Dart programs, and the static folder prefix of each reloadOnSaveGlobs entry)
  -> PathFilter: .dart files or glob matches; never hidden segments, build/, .dart_tool/, .git/, node_modules/
  -> mode "changed": SHA-256 of the content must differ from the last seen content (first event for a file counts as changed)
  -> ReloadCoalescer: trailing debounce (default 200 ms; 10..5000) ; one in flight, at most one follow-up
  -> notice "Hot reload on save: lib/main.dart (+N more)"   (shown once per batch)
  -> HotActions.reload('save') -> inject hotReload{reason:"save"}
  -> success: notice "Hot reload after saving finished in N ms."
     failure: notice "Error: Hot reload failed: <reason>. Try the task "Flutter: Hot Restart"."
     busy: files are kept and retried (max delay 2 s)
```

The watcher is armed only after `flutter.appStarted`, and not at all in profile/release/jit_release mode (one notice explains why). When it arms it prints "Reload on save is on for lib/ (changed files only). Set "reloadOnSave": "off" in .zed/debug.json to turn it off. With Zed autosave enabled, every autosave reloads."

### 3.4 Stop (Zed's real path) and the held terminate response

Zed's stop button sends `terminate` (if the adapter advertises `supportsTerminateRequest`, else `disconnect`) and kills the adapter process as soon as that response arrives (ADR 0006, `crates/project/src/debugger/session.rs:2249-2299` @ b61f33f8). So everything must be finished before the `terminate` response is released:

```
Zed Stop (Shift-F5)
 |-terminate-------------> ShutdownCoordinator.handleTerminate
 |                           1. onShutdownStarted: ProxySessionControl.markEnding (reload/restart now answer session_ended),
 |                              watchdog/timers cancelled, session file DELETED
 |                           2. snapshot adapter descendants (<= 3 s)
 |                           3. start a 1 s timer: notice "Stopping the app..." if still not done
 |                           4. forward terminate to the adapter ---------> app.stop; app exits; `terminated` event
 |                           5. adapter's terminate response arrives: HELD (not forwarded)
 |                           6. when response held AND `terminated` seen (or 5 s deadline):
 |                                cleanup = stop watcher, close ControlServer, sweep (see "Kill policy" below:
 |                                the adapter if alive plus its CURRENT descendants; POSIX SIGTERM then SIGKILL;
 |                                Windows taskkill /T /F)
 |<-terminate response----- 7. held response released, client flushed
 |-(Zed kills the proxy: SIGKILL / TerminateProcess; nothing needs to run after this)

Kill policy (ADR 0007 P1, decided; implementation in progress, not verified by me):
 - Normal stop (terminate, disconnect, stdin EOF): the sweep targets the adapter if still alive plus its descendants
   from a fresh snapshot taken right before the sweep. Processes seen earlier that have since left the tree (for
   example a Gradle daemon started during an Android build) are NOT killed. The 2 s snapshot poll keeps only pids
   that are still alive (bounded set) and stops at shutdown.
 - Only after an adapter CRASH are earlier-seen, reparented processes also swept, with the PID-reuse guard, and never
   shared daemons: adb, Gradle daemons, Kotlin compile daemons, other sessions' Dart tooling daemon.
 - POSIX: SIGTERM, SIGINT and SIGHUP handlers run the same cleanup as stdin EOF. A SIGKILL of the proxy cannot be
   handled; then the adapter may survive until its stdin read fails. Known issue; Zed only kills the proxy after the
   held terminate response, so the normal path is clean.

Variants (dap/shutdown_coordinator.dart; the state model is in 4.11):
 - disconnect without a prior terminate (launch): inject terminate (<= 5 s), forward disconnect, wait <= 5 s for
   the adapter to exit, same cleanup, then the held disconnect response is released and the proxy exits 0.
   (The spike showed that disconnect alone orphans the app and DDS.)
 - stdin EOF (Zed died / window closed): same cleanup with injected terminate then disconnect, no client response.
 - adapter crash or exit without an orderly stop: notice "The Flutter debug adapter stopped unexpectedly (exit code N)...",
   synthetic `terminated` event, session file deleted, exit with the adapter's code.
 - attach sessions: terminate/disconnect only detach; the adapter never kills the app (docs/research/attach-probe.md).
```

### 3.5 Attach (with `--no-dds`)

```
Scenario "Flutter: Attach": {"request":"attach","type":"flutter","vmServiceUri":"http://127.0.0.1:PORT/TOKEN/","toolArgs":["-d","<id>"]}
extension: --request attach  ->  proxy starts: flutter debug_adapter --no-dds
```

`flutter run` already runs a DDS. Without `--no-dds` the adapter starts a second one on top that is orphaned after every disconnect (attach probe, section "The extra DDS"). `--no-dds` is added for attach only (`cli/dap_command.dart`) and never for launch (the probe did not verify launch without DDS, and DevTools needs DDS). Facts from the probe that shape behaviour:

- `-d <deviceId>` in `toolArgs` is mandatory; without it the adapter dies with "More than one device connected". The proxy injects `-d` from the same sources as for launch (see 4.5), and shows the device hint if Flutter complains.
- `vmServiceInfoFile` with the file written by `flutter run --vmservice-out-file` hangs silently. Use `vmServiceUri`. A JSON `{"uri": "..."}` info file works but we do not generate one.
- Attaching with neither URI nor info file waits silently. This is allowed for Flutter (`flutter attach` finds an app that starts later); `DapSessionHost` starts a 15 s attach watchdog when the attach is rewritten and, if `flutter.appStarted` has not arrived, prints "Still waiting for the app. Start it with "flutter run", or set "vmServiceUri" in .zed/debug.json." Dart attach without a URI is refused up front (see 4.14).
- No `stopped(entry)` on attach; `flutter.appStarted` arrives about 2 s after `attach`, which arms reload on save and unlocks `reload`/`restart`.
- Stop detaches; the original `flutter run` and the app keep running.

## 4. Module map (`cli/lib/src`)

**Dependency rule (enforced).** Feature modules (`dap, control, sdk, devices, watch, devtools, init`) import `package:*`, `dart:*`, `common/` and themselves only. `common/` imports no sibling module. Only `cli/` imports the feature modules and wires them together (`cli/wiring.dart`, `cli/command_context.dart`, `cli/dap_command.dart`, `cli/dap_session_host.dart`). `cli/test/unit/architecture_test.dart` scans every import and export under `lib/src` and fails on a violation, so the rule cannot erode. Code that two modules both need goes into `common/`; a module that needs another module's behaviour gets it as an interface (a port, section 4.10) that `cli/` implements.

### 4.1 `common/`
`version.dart` holds `packageVersion` (`0.1.0`), `controlProtocolVersion = 1`, `sessionFileVersion = 1`, `adapterName = 'FlutterRun'`, `toolName`, `envPrefix`. `errors.dart` defines `FlutterRunException` and subclasses, each with an exit code (`ExitCodes`: 0 ok, 1 internal, 2 usage, 3 no session, 4 session error, 5 timeout, 6 SDK not found, 7 device error, 8 no project, 9 manual action required, 10 external tool failed, 130 interrupted). `paths.dart` has canonical/case-aware path comparison, `findProjectRoot` (nearest `pubspec.yaml`), `findExecutableOnPath` (PATHEXT on Windows), `projectRootHash` (first 16 hex of SHA-256) and `stateBaseDirectory` (see section 6). `files.dart` writes files atomically (temp file plus rename, 10 retries for Windows sharing violations, keeps symlinks intact) and creates owner-only directories. `logger.dart` logs to stderr and optionally a file (`--log-file`, `FLUTTER_RUN_LOG`), never to stdout; the file also receives all DAP traffic. `console.dart` is the CLI's stdout/stderr with `NO_COLOR` handling. `host_environment.dart` abstracts OS, env vars, cwd and path style so Windows logic is testable anywhere. `global_options.dart` registers `--verbose/-v`, `--project`, `--flutter-sdk`.

### 4.2 `dap/` (proxy core)
- `framing.dart`: incremental `Content-Length` decoder/encoder (8 KiB header limit, 64 MiB body limit (ADR 0007, S7), tolerant of split UTF-8). `channel.dart`: `DapChannel` (a DAP message channel with flush, `StreamDapChannel` over a byte stream pair) and the `AdapterConnection` port.
- `messages.dart`: the `DapMessage` view, `DapCommands` / `DapEvents` name constants and builders for synthetic messages (section 4.13).
- `proxy.dart`: `DapProxy`, which only routes messages. It owns a `SessionPhaseMachine`, a `SessionTracker`, an `InitializeWatchdog`, a `FailureReporter`, `InjectedRequests`, `HotActions` and a `ShutdownCoordinator` (sections 4.11 and 4.12). `proxy_options.dart`: `ProxyOptions` and `ProxyTimings` (4.12).
- `session_phase.dart`: `SessionPhase` and `SessionPhaseMachine`. `shutdown_coordinator.dart`: every stop path, the held `terminate`/`disconnect` responses, descendant snapshots and the sweep.
- `initialize_watchdog.dart`: timers for the `initialize` answer (ADR 0007 P2: 120 s, one notice after 10 s, "Flutter is still starting. ..."). `failure_reporter.dart`: turns a missed `initialize` or an adapter crash into a failed response plus a stderr-category output event with the adapter's last stderr lines. It only reports; the proxy ends the session.
- `session_tracker.dart`: follows `dart.debuggerUris`, `flutter.appStart`, `flutter.appStarted`, `thread`, `terminated`, `exited`, publishes `ProxyState` and `ProxyEvent`s (`LaunchRewritten`, `StateChanged`, `DebuggerUris`, `AppStarted`, `SessionEnded`) and the device hint on Flutter's "more than one device" / "no devices" errors (`device_hints.dart`). `proxy_state.dart` is the immutable snapshot that feeds the session file.
- `injected_requests.dart`: seq allocation from 1,000,000,000, the capability table (4.13), late-response swallowing. `hot_actions.dart`: the reload/restart coordinator of 3.2 and the `RequestInjector` port.
- `launch_rewriter.dart`: rewrites `launch`/`attach` arguments. It strips `LaunchRewriter.ownKeys` (`flutterSdkPath, deviceId, reloadOnSave, reloadOnSaveGlobs, reloadOnSaveDebounceMs, openDevTools, logFile, useFvm, adapter, label, flutterMode, platform`), turns `flutterMode` `profile`/`release` into `--profile`/`--release` in `toolArgs` (unless a mode flag is already there), injects `-d <id>`, defaults `cwd` and (Flutter launch) `program: lib/main.dart`, and validates attach (4.14).
- `notices.dart`: console notices (cyan `[flutter_run] ...`; warnings prefixed `Warning:`, errors `Error:`; ANSI is fine because Zed sends `supportsANSIStyling`). `bounded.dart`, `stderr_tail.dart`, `dap_text.dart`: small helpers.

### 4.3 `control/` (session files and the control channel)
`control_protocol.dart` defines error codes, the 64 KiB line limit, the command set (`ping`, `reload`, `restart`) and the `SessionControl` interface. `control_server.dart` is the loopback TCP server (one request line per connection, constant-time token compare, 64 connections max, 16 pending without a full line, 3 s to send the line). `control_client.dart` sends a request and parses the reply; `ping` returns alive/unresponsive/stale (only a refused connection or a wrong token/pid proves staleness). `session_info.dart` is the session file model. `session_store.dart` creates the sessions directory (0700 on POSIX), writes the file atomically with serialised updates (a late update cannot resurrect a deleted file), lists sessions, pings all concurrently and prunes stale files (only if the file still holds the pinged token and pid). `session_paths.dart`, `session_matcher.dart`, `find_sessions.dart` map project directories to sessions (a session matches when its project root contains the directory or lies inside it). `hot_command.dart` is the shared logic of `reload`/`restart` (`reload_command.dart`, `restart_command.dart`); `status_command.dart` prints sessions from the files (`--json` available).

### 4.4 `sdk/`
`sdk_resolver.dart` finds the Flutter (or, for `type: dart`, Dart) SDK and records every step for `doctor`. Flutter order: (1) `--flutter-sdk` / scenario `flutterSdkPath`, (2) env `FLUTTER_RUN_FLUTTER_SDK`, then fvm (project `.fvm/flutter_sdk` link, `.fvmrc`, legacy fvm config, fvm cache), puro, `FLUTTER_ROOT`, and finally `flutter` on the PATH. `useFvm` makes the fvm result mandatory. `sdk_steps.dart` is the file-system seam used by the resolver. `process_spec.dart` builds the process spec and validates `.bat` arguments. `managed_process.dart` starts children, exposes stdio, snapshots descendants, and terminates trees. `process_tree.dart` reads the process table and kills trees (SIGTERM, grace, SIGKILL; Windows `taskkill /PID n /T /F`; pids 0 and 1 are never signalled).

### 4.5 `devices/`
`flutter_device.dart` parses `flutter devices --machine` (tolerating banner lines). `device_lister.dart` runs it with a 60 s timeout. `device_store.dart` persists the chosen device per project in the state directory (section 6). `picker.dart` is the numbered terminal picker (number or id, rescan). `emulators.dart` parses `flutter emulators` and validates ids before `--launch`. `commands/` has `devices`, `select-device [--device ID | --clear]` and `emulators [--launch ID]`. Device precedence at launch, first hit wins: `-d`/`--device-id` already in `toolArgs`, scenario `deviceId`, env `FLUTTER_RUN_DEVICE`, saved device, none (Flutter decides; the proxy says so).

### 4.6 `watch/`
`reload_config.dart` is a tolerant parser for `reloadOnSave` (`changed` default, `always`, `off`; booleans accepted), `reloadOnSaveGlobs`, `reloadOnSaveDebounceMs`. `path_filter.dart` decides which paths trigger and which directories are watched. `content_hash.dart` keeps SHA-256 per file (2 MiB limit, 5000 entries). `coalescer.dart` is the debounce plus one-in-flight/one-follow-up logic. `reload_on_save_watcher.dart` ties them to `package:watcher`.

### 4.7 `devtools/`
`pages.dart` lists `inspector, performance, cpu-profiler, memory, network, logging`. `url_builder.dart` normalises the VM service address and builds `http://H:P/TOKEN=/devtools/<page>?uri=<ws uri>`, the URL under which DDS serves DevTools; `isSafeBrowserUrl` only allows http(s) to 127.0.0.1/localhost/::1. `browser_opener.dart` launches `xdg-open` / `open` / `rundll32 url.dll,FileProtocolHandler` detached, no shell. `devtools_opener.dart` is the proxy-side one-shot open (first `dart.debuggerUris` only, when the scenario sets `openDevTools`). `commands/devtools_command.dart` is `flutter_run devtools [page] [--print]`, using the newest live session that has a `vmServiceUri`.

### 4.8 `init/`
`project_detect.dart` finds the pubspec and classifies Flutter vs Dart package and fvm use. `templates.dart` generates the debug scenarios (Flutter: Debug, Run (no debug), Profile, Attach; or `Dart: Debug <entry>`) and tasks (Hot Reload, Hot Restart, Select Device, Launch Emulator, Devices, Open DevTools, DevTools Inspector, DevTools Performance, Doctor). `json_merge.dart` merges by `label` into existing JSON files, and refuses (exit 9, prints the snippet) when a file has comments, is not UTF-8 or is not an array; `--force` keeps a `.bak`. `keymap.dart` produces the keymap snippet (`ctrl-f5` reload, `ctrl-shift-f5` restart, or `shift-cmd-f5` on macOS, `ctrl-alt-shift-d` DevTools) and the key table. `commands/init_command.dart` is `init [--force] [--dry-run]`.

### 4.9 `cli/` (composition root)
- `runner.dart`: `FlutterRunRunner` registers `dap` plus `CommandContext(wiring).commands()`, maps exceptions to exit codes and prints the exit-code table. (Its Ctrl+C handling for non-`dap` commands still calls `ProcessSignal.sigint.watch()` directly; it is not routed through `SignalSource`.)
- `wiring.dart`: `Wiring` builds the shared objects (`HostEnvironment`, `Console`, `Logger`, `Clock`, `ProcessRunner`, SDK resolver, stores, control client, browser opener) and holds the adapters between modules: `ManagedAdapterConnection` (process to `AdapterConnection`), `ProxySessionControl` (control requests to `HotActions`, implements `SessionControl`) and `reloadForSave`.
- `command_context.dart`: `CommandContext` bundles those objects and `commands()` builds every command except `dap` in one line each.
- `dap_command.dart`: `flutter_run dap`. Resolves the SDK, starts the adapter, builds the `DapProxy` and hands the rest to `dap_session_host.dart`: `DapSessionHost` owns the control endpoint, the session file (debounced writes), the reload-on-save watcher, the attach watchdog, signal handlers and the startup-failure path. Everything it touches that is time, signals or the control server is injected (`Clock`, `SignalSource`, `ControlServerStarter`).
- `session_notices.dart`: `SessionNotices`, the user-facing messages of a session (version mismatch, PATH, device in use, watcher relays, DevTools auto-open). `control_endpoint.dart`, `signal_source.dart`: ports (4.10). `path_notice.dart`, `doctor_command.dart`, `version_command.dart`: as named.

### 4.10 Ports and where their adapters live
A port is a small interface in the module that needs it (or in `common/`); the real implementation sits next to it or in `cli/`, and tests supply a fake.

| Port | Defined in | Real adapter | Test fake | Used by |
|---|---|---|---|---|
| `Clock` (`now`, `timer`, `periodic`, `stopwatch`) | `common/clock.dart` | `SystemClock` | `FakeClock` over `fake_async` (`test/unit/dap/fakes.dart`) | proxy, watchdog, coordinator, `HotActions`, control server, watcher, device store, reload/restart commands |
| `HostEnvironment` (OS, env vars, cwd, home, path context) | `common/host_environment.dart` | `HostEnvironment.system()` | built by hand with any `HostOs` | SDK resolver, stores, `init`, notices |
| `ProcessRunner` (`start`, `run`) | `sdk/process_runner.dart` | `SystemProcessRunner` (`ManagedProcess.start`, `runTool`) | none yet (commands are tested through injected factories) | `Wiring` (flutter commands) |
| `SignalSource` (`watch(signal)`) | `cli/signal_source.dart` | `SystemSignalSource` | `FakeSignalSource` (`test/unit/cli/support.dart`) | `DapSessionHost` |
| `ControlEndpoint` (`port`, `token`, `close`) and `ControlServerStarter` | `cli/control_endpoint.dart` | `ServerEndpoint` over `ControlServer.start` | injected starter | `DapSessionHost` |
| `AdapterConnection` (channel, stderr lines, pid, exit code, snapshot, `terminateTree`) | `dap/channel.dart` | `ManagedAdapterConnection` (`cli/wiring.dart`) | `FakeAdapter` | `DapProxy`, `ShutdownCoordinator` |
| `RequestInjector` (`inject`, `appStarted`, `notice`) | `dap/hot_actions.dart` | `DapProxy` | `FakeInjector` | `HotActions` |
| `SessionControl` (`ping`, `reload`, `restart`) | `control/control_protocol.dart` | `ProxySessionControl` (`cli/wiring.dart`) | `FakeControl` | `ControlServer` |
| `ShutdownHost` | `dap/shutdown_coordinator.dart` | private `_Host` in `proxy.dart` | `FakeHost` | `ShutdownCoordinator` |

`DapChannel` is a port too (`StreamDapChannel` is the real one, `FakeChannel` the fake). Wiring is by constructor arguments with defaults for production values; there is no service locator or DI framework (ADR 0010).

### 4.11 Session phases and the shutdown coordinator
`SessionPhaseMachine` (`dap/session_phase.dart`) is the only place that decides which phase moves are legal. A session never moves backwards; an illegal move is logged and ignored (and asserts when `strict`). The old scattered booleans are gone: code asks `isStopping` / `isFinishing` / `isFinished`.

```
 starting --run()--> running --terminate / disconnect / EOF / signal--> stopping --> finishing --> finished
     |                  |                                                              ^
     |                  +-- crash, startup failure, adapter exit (skips stopping) ------+
     +-- failure before run() completes --------------------------------------------->+
```

Legal moves: `starting` to `running` or `finishing`; `running` to `stopping` or `finishing`; `stopping` to `finishing`; `finishing` to `finished`. `beginStopping()` only acts from `running`, so a `disconnect` after a `terminate` changes nothing.

`ShutdownCoordinator` (`dap/shutdown_coordinator.dart`) owns what happens inside `stopping`. Its two request flows each have a `StopFlow` (`idle`, `requested`, `finishing`, `finished`):

```
terminate flow:   idle -> requested (inject/forward terminate, start snapshots)
                       -> finishing (adapter answered AND `terminated` seen, or terminateTimeout)
                       -> finished (cleanup + sweep done, HELD response released)
disconnect flow:  idle -> requested -> finishing (adapter answered; wait <= exitWait / disconnectGrace)
                       -> finished (cleanup done, HELD response released, proxy exits 0)
```

It also handles stdin EOF and signals (`shutdown(reason)`, idempotent: same cleanup, injected `terminate` then `disconnect`, no client response), an adapter exit it did not ask for (`finishAfterAdapterExit`, with `crashed` set), and the order every stop follows: `startShutdown` (owner hook `onShutdownStarted`, then descendant snapshot), forward, cleanup (`onShutdownCleanup` hook, then sweep). The kill policy in 3.4 is implemented by `_sweep` and `_killTree`. The coordinator talks to the proxy only through `ShutdownHost`, so its tests use `FakeHost` and `FakeClock`.

### 4.12 `ProxyTimings` and `ProxyOptions` defaults
All fixed waits are in `dap/proxy_options.dart`; tests shrink them. Values read from the code:

| Field | Default | Meaning |
|---|---|---|
| `ProxyOptions.terminateTimeout` | 5 s | adapter finishing a `terminate` (also the injected one) |
| `ProxyOptions.exitWait` | 5 s | adapter exiting after `disconnect` |
| `ProxyOptions.initializeTimeout` | 120 s | adapter answering `initialize` |
| `ProxyOptions.initializeNoticeAfter` | 10 s | one "Flutter is still starting" notice |
| `ProxyOptions.snapshotInterval` | 2 s | how often descendants are recorded while the adapter runs |
| `ProxyTimings.stoppingNoticeAfter` | 1 s | "Stopping the app..." notice after `terminate` |
| `ProxyTimings.drainWait` | 2 s | adapter's last messages after it exited |
| `ProxyTimings.snapshotWait` | 3 s | reading the adapter's process tree |
| `ProxyTimings.firstSnapshotDelay` | 300 ms | before the first periodic snapshot |
| `ProxyTimings.disconnectGrace` | 500 ms | adapter exit after it answered `disconnect` |
| `ProxyTimings.adapterExitGrace` | 800 ms | adapter exiting on its own once the app stopped |
| `ProxyTimings.sweepGrace` | 300 ms | pause before sweeping descendants that are already exiting |
| `ProxyTimings.hookWait` | 2 s | each owner hook and the client flush |
| `ProxyTimings.sweepWait` | 3 s | killing the process tree |
| `ProxyTimings.sweepWaitLate` | 1 s | the same, once the terminate deadline passed |

Outside the proxy: `DapCommand.attachWatchdog` 15 s, and the session-file write debounce 50 ms (`DapSessionHost`).

### 4.13 `DapMessage` and the raw pass-through rule
`DapMessage` is an extension type over the decoded map (`DapJson`): read-only getters (`seq`, `type`, `command`, `requestSeq`, `success`, `failed`, `event`, `arguments`, `body`, `isRequest`, `isResponse`, `isEvent`) that tolerate missing or wrongly typed fields. It copies nothing. Rule: **the proxy reads through the view but forwards `message.raw`**, so unknown fields, odd `seq` types and anything a newer Zed or adapter adds reach the other side unchanged. The only client messages it edits are `launch`/`attach` (a copy with `arguments` replaced by the rewriter's result). There is deliberately no full typed DAP model (ADR 0010).

Injected requests (`injected_requests.dart`) and their capability gate:

| Command | Flutter adapter | Dart adapter | Sent by |
|---|---|---|---|
| `hotReload` | yes | yes | `HotActions.reload` (task, control `reload`, reload on save) |
| `hotRestart` | yes | no | `HotActions.restart` (control `restart`) |
| `terminate`, `disconnect` | not gated | not gated | `ShutdownCoordinator` |

`supportedInjections` lists what each `DapKind` accepts for the gated commands (`gatedInjections` = `hotReload`, `hotRestart`); `injectionSupported(kind, command)` is false only for a gated command that kind lacks. `DapProxy.inject` and the restart path check it before anything is sent, so a Dart session answers `restart` with a refusal instead of a doomed request.

### 4.14 Attach validation
`LaunchRewriter._attachProblem` runs for `attach` and returns a rejection, which the proxy turns into a failed response with a user-visible message:

| Case | Result |
|---|---|
| `vmServiceUri` contains `PORT/TOKEN` (the placeholder `flutter_run init` writes; `attachUriPlaceholder` in `init/templates.dart`, copied as a constant because `dap/` cannot import `init/`) | rejected, with the steps to paste the real URI |
| a non-blank `vmServiceUri` or `vmServiceInfoFile` | accepted |
| neither, Dart adapter | rejected: Dart attach needs an address |
| neither, Flutter adapter | accepted: `flutter attach` may wait for the app; after 15 s without `flutter.appStarted` the attach watchdog prints the "Still waiting" notice (3.5) |

The extension schema agrees: `vmServiceUri` is required only for Dart attach (test `attach_requires_a_vm_service_address`).

### 4.15 Extension modules (`extension/src`)
- `lib.rs`: the Zed trait glue only. `get_dap_binary`, `dap_request_kind`, `dap_config_to_scenario`, `dap_locator_create_scenario` call pure functions; the I/O (`cached_binary`, `download_and_install`, `resolve_command`) is thin. It also holds the schema tests (every key the extension reads is in the schema, every property has `x-support`, `extension.toml` matches the constants).
- `install.rs`: the **install planner**. `plan_install(PlanInput { user, which_exe, which_plain, os, download, cached })` returns an `InstallPlan` without touching the disk: `UseCommand(path)` (setting or PATH), `UseCached { make_executable }`, `Download { expected }` or `Fail(InstallError)`. Inputs are `DownloadSupport` (`Unsupported`, `NoPins`, `NotPinned`, `Pinned(sha)`) and `CachedBinary` (`Missing`, `Corrupt`, `Verified`, `VerifiedThisSession`). Order: user setting, then PATH (Windows prefers `.exe`, skips `.bat`/`.cmd`), then download or cache if a checksum is pinned, else a typed error. `InstallError` (`NotFound`, `NoPinnedChecksum`, `BatchShim`, `UnsupportedPlatform`, `DownloadFailed`, `ChecksumMismatch`, `Io`) becomes text only at the Zed API boundary (`String::from`). Also: asset naming, stale install directory and leftover `.part-<n>` file cleanup, `sha256_hex`, `verify_sha256`.
- `checksums.rs`: the pinned SHA-256 table (empty in dev builds).
- `proxy_args.rs`: parses the scenario (`parse_config`), builds the proxy argv and env, `request_kind`, `config_to_scenario`. `READ_KEYS` lists the keys the extension reads; a test checks each is in the schema.
- `locator.rs`: the **debug locator** ([ADR 0009](decisions/0009-debug-locator.md)). `[debug_locators.FlutterRun]` in `extension.toml`; `scenario_config(&TaskInput)` maps a Zed task (`flutter run`, `fvm flutter run`, `puro flutter run`, `dart run file.dart`, `dart file.dart`) to scenario JSON, and returns `None` for everything else (`flutter build`, `flutter test`, `dart pub get`). Only the pair `FlutterRun`/`FlutterRun` is served, so the official Dart extension's locator is untouched. The scenario is returned with `build: None`, so `run_dap_locator` is never needed. Zed only calls a locator when the active language's `debuggers` setting lists `FlutterRun` (ADR 0009 context).

## 5. Contracts

### 5.1 Control protocol v1 (`cli/lib/src/control/control_protocol.dart`, `control_server.dart`, `control_client.dart`)

Transport: TCP `127.0.0.1:<port>` (`port` from the session file), one connection per request. The client sends exactly one line of UTF-8 JSON ended by `\n` (at most 65,536 bytes before the newline, sent within 3 s) and reads one reply line. The server answers and half-closes (2 s grace).

Request:

```json
{"v": 1, "token": "<token from the session file>", "id": 1, "command": "reload", "args": {"reason": "manual"}}
```

| Field | Type | Rules |
|---|---|---|
| `v` | int | must equal 1, else `unsupported_version` |
| `token` | string | must equal the session token (constant-time), else `unauthorized` |
| `id` | int, string or null | echoed back; any other type is `bad_request` |
| `command` | string | one of `ping`, `reload`, `restart`, else `unknown_command` |
| `args` | object, optional | `reload` reads `reason` (string, default `"manual"`; the watcher uses `"save"`); others ignore it |

Success reply: `{"v":1,"id":1,"ok":true,"result":{...}}`. Failure reply: `{"v":1,"id":1,"ok":false,"error":{"code":"<code>","message":"<text>"}}`.

| Command | `result` fields |
|---|---|
| `ping` | `pid` (int), `version` (string, `packageVersion`), `protocol` (int, 1) |
| `reload` | `durationMs` (int), `coalesced` (bool; true when it joined a reload already running) |
| `restart` | `durationMs` (int) |

Error codes (`ControlErrorCode.wire`): `bad_request`, `unsupported_version`, `unauthorized`, `payload_too_large`, `unknown_command`, `app_not_started`, `busy` (also sent with `id: null` when the server has too many connections), `adapter_error`, `timeout`, `session_ended`, `internal`.

There is no control `status` command; `flutter_run status` reads the session files and uses `ping` only to prune stale ones.

### 5.2 Session file v1 (`cli/lib/src/control/session_info.dart`)

Path: `<state>/sessions/<pid>.json`, rewritten atomically. Created when the proxy starts, updated when launch/attach is rewritten, when the device or VM service becomes known (debounced 50 ms) and immediately at `flutter.appStarted`. Deleted as the first step of shutdown. Unknown keys are ignored by readers; another `version` makes the file invisible.

```json
{
  "version": 1,
  "pid": 12345,
  "port": 40123,
  "token": "<base64url, 43 chars, 32 random bytes>",
  "projectRoot": "/tmp/rdf-sample",
  "cwd": "/tmp/rdf-sample",
  "kind": "flutter",
  "request": "launch",
  "startedAt": "2026-11-03T12:00:00.000Z",
  "deviceId": "linux",
  "mode": "debug",
  "vmServiceUri": "ws://127.0.0.1:33171/xzgCOabbXpo=/ws",
  "appStarted": true
}
```

Required: `version, pid, port, token, projectRoot, cwd, kind` (`flutter` or `dart`), `request` (`launch` or `attach`), `startedAt` (ISO 8601 UTC). Optional: `deviceId, mode, vmServiceUri` (omitted when unknown), `appStarted` (bool, written always, false at first).

### 5.3 Saved device file (`devices/device_store.dart`)

`<state>/devices/<first 16 hex of sha256(project root)>.json`: `{"version":1,"projectRoot":..,"deviceId":..,"name":..,"platform":..,"savedAt":..}`. Ignored when the version or project root does not match.

### 5.4 Environment variables

`FLUTTER_RUN_FLUTTER_SDK` (SDK root), `FLUTTER_RUN_DEVICE` (device id), `FLUTTER_RUN_LOG` (log file), `FLUTTER_RUN_LOG_LEVEL` (`error|warn|info|debug|trace`), `FLUTTER_RUN_STATE_DIR` (state base directory), `NO_COLOR` (CLI output only). `FLUTTER_RUN_TEST_EXE` is used by the integration tests.

### 5.5 Scenario keys (`extension/debug_adapter_schemas/FlutterRun.json`)

Own keys (stripped before the adapter sees them): `flutterSdkPath, useFvm, deviceId, flutterMode, reloadOnSave, reloadOnSaveGlobs, reloadOnSaveDebounceMs, openDevTools, logFile, platform, adapter, label`. `type` (`flutter` default, `dart`), `request` (`launch` default, `attach`), `cwd`, `env` and `logFile`/`flutterSdkPath`/`useFvm` are also read by the extension to build the proxy argv. Everything else (`program, args, toolArgs, vmServiceUri, vmServiceInfoFile, stopOnEntry, noDebug, debugSdkLibraries, ...`) passes to the Dart/Flutter adapter.

## 6. State locations

| OS | State base directory (`flutter_run`) | Contents |
|---|---|---|
| Linux | `$XDG_STATE_HOME/flutter_run`, else `~/.local/state/flutter_run` | `sessions/<pid>.json`, `devices/<hash>.json` |
| macOS | `~/Library/Application Support/flutter_run` | same |
| Windows | `%LOCALAPPDATA%\flutter_run`, else `<home>\AppData\Local\flutter_run` | same |
| any | `$FLUTTER_RUN_STATE_DIR` overrides all of the above | same |

Other places: the project's `.zed/debug.json` and `.zed/tasks.json` (written by `init`, usually committed); the user's Zed keymap (never written, `init` prints a snippet); the extension's download directory, Zed's per-extension work dir, `.../extensions/work/flutter-run-debugger/flutter_run-0.1.0/flutter_run[.exe]` (only used when a checksum is pinned); the optional log file from `logFile` / `--log-file` / `FLUTTER_RUN_LOG`. Nothing is written to the project except `.zed/*` by `init`.

## 7. Security model

- The control server binds `127.0.0.1` only, on a random port. The only credential is a 256-bit random token in the session file. The sessions directory is mode 0700 on POSIX (no per-file chmod, ADR 0006 D4) and lives in the per-user profile on Windows, so other users cannot read it. A process of the same user could read it anyway; nothing further is defended against.
- The command set is a fixed enum (`ping`, `reload`, `restart`); nothing from a request is executed or interpolated. Requests are limited to 64 KiB, 64 connections, 16 connections without a full line, 3 s to send the line.
- Child processes are started without a shell. On Windows `.bat`/`.cmd` targets get argument validation; emulator ids are checked against a safe pattern before `--launch`, and a device id must be one `flutter devices` listed.
- DevTools URLs are only opened when they point at the local machine (`isSafeBrowserUrl`).
- The extension downloads the proxy only from `github.com/sawongam/zed-flutter-run/releases/download/v<version>/<asset>` and only after verifying a SHA-256 pinned in the extension source (`download_file` itself does no hash check). With no pin (all dev builds) it refuses to download. The manifest declares the `download_file` capability for `github.com/sawongam/zed-flutter-run/**`.
- Logs may contain full DAP traffic (paths, variable values). They are only written when `logFile` / `--log-file` / `FLUTTER_RUN_LOG` is set.
- `logFile` rules (ADR 0007 P3, decided): a project's `debug.json` must not turn the proxy into a write primitive (`~/.bashrc`, `authorized_keys`). So the path must end in `.log`, its parent directory must already exist (no `mkdir -p`), the file is opened with owner-only permissions (0600 on POSIX) and control characters are escaped in every logged line. `FLUTTER_RUN_LOG` follows the same rules.
- Project-controlled execution (ADR 0007 P4): `flutterSdkPath`, `.fvm/flutter_sdk` and the scenario `env` choose which binaries run, like Zed tasks and the official Dart extension. Open only projects you trust.

## 8. What Zed shows

Zed's debugger UI only displays DAP `output` events (Console tab) plus the standard stopped/variables/threads views. It ignores custom events, `progress*` events and `showUser`. Therefore:

- All proxy feedback (device in use, reload on save, DevTools URL, "Stopping the app...", PATH and version warnings, startup failures) is sent as `output` events with the `[flutter_run]` prefix. Startup failures also fail the first request so Zed shows something other than "adapter exited".
- Results of `reload`/`restart` appear in the terminal tab of the task that ran them (the tab hides on success, stays on failure) and, for the reload itself, in the Console as the adapter's own `Reloaded N libraries ...` output.
- Zed's keys: F4 opens the debug picker, F5 reruns the last scenario or continues, Shift-F5 stops. `ctrl-f5` and `ctrl-shift-f5` are our keymap bindings and only work while a session runs.

## 9. Known limits

- Never run in a real Zed by the authors (R14). Open questions are listed in [MANUAL_ZED_TEST.md](MANUAL_ZED_TEST.md), notably whether Zed's rerun/restart sends DAP `restart` and whether `capabilities` events enable it.
- The debug locator (ADR 0009) only runs when Zed's `languages.Dart.debuggers` (or the matching language setting) lists `FlutterRun`; without it, "Run" buttons next to `main()` do not use FlutterRun. `.vscode/launch.json` entries of type `dart`/`flutter` are not picked up by Zed for any adapter.
- No Zed UI of our own: no status-bar item, no device picker, no toolbar buttons. Everything goes through tasks, keybindings and the Console.
- A reload while the app is paused at a breakpoint waits until it is resumed. The adapter reports `success: true` for hot actions even when nothing is attached, so the proxy only injects them after `flutter.appStarted`.
- Reload on save watches `lib/` (plus `bin/` for Dart programs and glob folders) only. Zed autosave makes every autosave reload. Hot restart on save does not exist.
- Attach needs `toolArgs: ["-d", "<id>"]` (or a saved device); `vmServiceInfoFile` in the format written by `flutter run --vmservice-out-file` does not work.
- Hot Reload / Hot Restart tasks use `"save": "all"` (ADR 0007 P5), so reload sees what is on screen; with reload on save this can produce two reloads that the coalescer merges.
- Dart programs (ADR 0007 P5, decided): hot restart is refused (`dart debug_adapter` supports `hotReload` but not `hotRestart`); the session counts as "started" at the first `dart.debuggerUris`; `devtools` is refused with a hint because that DDS does not serve DevTools. The ignored folders `build/`, `.dart_tool/`, `.git/`, `node_modules/` apply only at the project's top level; hidden segments are ignored at any depth.
- Dart console programs (`type: dart`): the `reload`/`restart` tasks skip them ("it is a Dart console session, not a Flutter app"). The reload-on-save watcher is still armed for them (it watches `lib/` and `bin/`) and injects `hotReload`, but whether `dart debug_adapter` accepts that was not verified; treat it as untested.
- Windows: no POSIX signals are used; the control channel is the same TCP design. `.bat` wrappers for `flutter_run` are rejected by the extension. Windows ARM uses the x64 binary under emulation. 32-bit systems are unsupported.
- Release binaries are unsigned (macOS ad hoc signature from `dart compile exe`, no notarization; Windows no Authenticode). See [RELEASE.md](RELEASE.md).
- The extension is a debug-adapter-only extension; it does not provide the Dart language or LSP. The user keeps the official Dart extension for that ([coexistence research](research/coexistence-with-dart-extension.md)).
