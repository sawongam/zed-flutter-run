# Architecture (as built, v0.1.0)

This describes the code that exists in `cli/lib/src/**` and `extension/src/**` on branch `build/mvp`. Where the plan ([IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md)) and the code differ, the code is described and the difference is called out. Nothing here has been run in a real Zed yet; see [MANUAL_ZED_TEST.md](MANUAL_ZED_TEST.md) for what still has to be confirmed.

Decisions behind this design: [0002](decisions/0002-architecture-dap-proxy.md) (shape), [0003](decisions/0003-languages-rust-extension-dart-proxy.md) (languages), [0004](decisions/0004-architecture-accepted-with-amendments.md) (amendments), [0005](decisions/0005-project-names.md) (names), [0006](decisions/0006-plan-review-resolutions.md) (install model, shutdown, seq range; wins over 0004 where they differ), [0007](decisions/0007-phase6-review-resolutions.md) (process-kill policy, log file rules, initialize timeout). Risks: [risk-register](research/risk-register.md).

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
   (no locator in 0.1.0)                                                   | DAP over stdio
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
 |-terminate-------------> DapProxy._handleTerminate
 |                           1. onShutdownStarted: ControlSession.markEnding (reload/restart now answer session_ended),
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

Variants (dap/proxy.dart):
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
- Attaching with neither URI nor info file waits silently; the proxy watchdog prints "Still waiting for the app. Start it with "flutter run", or set "vmServiceUri" in .zed/debug.json." after 15 s.
- No `stopped(entry)` on attach; `flutter.appStarted` arrives about 2 s after `attach`, which arms reload on save and unlocks `reload`/`restart`.
- Stop detaches; the original `flutter run` and the app keep running.

## 4. Module map (`cli/lib/src`)

Rule from the plan: a module imports `package:*`, `dart:*`, `common/` and itself only. `cli/` is the only place where modules are wired together (`cli/wiring.dart`, `cli/dap_command.dart`).

### 4.1 `common/`
`version.dart` holds `packageVersion` (`0.1.0`), `controlProtocolVersion = 1`, `sessionFileVersion = 1`, `adapterName = 'FlutterRun'`, `toolName`, `envPrefix`. `errors.dart` defines `FlutterRunException` and subclasses, each with an exit code (`ExitCodes`: 0 ok, 1 internal, 2 usage, 3 no session, 4 session error, 5 timeout, 6 SDK not found, 7 device error, 8 no project, 9 manual action required, 10 external tool failed, 130 interrupted). `paths.dart` has canonical/case-aware path comparison, `findProjectRoot` (nearest `pubspec.yaml`), `findExecutableOnPath` (PATHEXT on Windows), `projectRootHash` (first 16 hex of SHA-256) and `stateBaseDirectory` (see section 6). `files.dart` writes files atomically (temp file plus rename, 10 retries for Windows sharing violations, keeps symlinks intact) and creates owner-only directories. `logger.dart` logs to stderr and optionally a file (`--log-file`, `FLUTTER_RUN_LOG`), never to stdout; the file also receives all DAP traffic. `console.dart` is the CLI's stdout/stderr with `NO_COLOR` handling. `host_environment.dart` abstracts OS, env vars, cwd and path style so Windows logic is testable anywhere. `global_options.dart` registers `--verbose/-v`, `--project`, `--flutter-sdk`.

### 4.2 `dap/` (proxy core)
`framing.dart` is the incremental `Content-Length` decoder/encoder (8 KiB header limit, 64 MiB body limit (ADR 0007, S7), tolerant of split UTF-8). `channel.dart` wraps a byte stream pair as a DAP message channel with flush. `messages.dart` has request/response/event predicates and builders for synthetic messages. `injected_requests.dart` allocates seq numbers from 1,000,000,000, completes the matching future on the adapter's response, and swallows late responses of timed-out requests (bounded set of 64). `launch_rewriter.dart` rewrites `launch`/`attach` arguments: it strips the keys this tool owns (`flutterSdkPath, deviceId, reloadOnSave, reloadOnSaveGlobs, reloadOnSaveDebounceMs, openDevTools, logFile, useFvm, adapter, label, flutterMode, platform`), turns `flutterMode` `profile`/`release` into `--profile`/`--release` in `toolArgs` (unless a mode flag is already there), injects `-d <id>` and defaults `cwd` and (Flutter launch) `program: lib/main.dart`. `proxy.dart` is the `DapProxy`: message routing, the terminate/disconnect/EOF/crash flows of 3.4, an `initialize` watchdog (ADR 0007 P2: 120 s, with one notice after 10 s, "Flutter is still starting. The first run after an upgrade, or another flutter command holding the startup lock, can take a while."; on timeout the failure becomes a failed `initialize` response plus a stderr-category output event), event capture (`dart.debuggerUris`, `flutter.appStart`, `flutter.appStarted`, `terminated`, `exited`), and the device hint on Flutter's "more than one device" / "no devices" errors. `proxy_state.dart` is the immutable state snapshot (request, kind, cwd, deviceId, mode, appId, vmServiceUri, appStarted, ended) that feeds the session file. `hot_actions.dart` is the reload/restart coordinator of 3.2. `notices.dart` formats console notices (cyan `[flutter_run] ...`; warnings prefixed `Warning:`, errors `Error:`; ANSI is fine because Zed sends `supportsANSIStyling`). `device_hints.dart` maps Flutter's error texts to the hint sentences.

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
`runner.dart` registers all commands, maps exceptions to exit codes and prints the exit-code table. `wiring.dart` builds the shared objects (SDK resolver, stores, control client, browser opener) and the adapters between modules: `ManagedAdapterConnection` (process to DAP channel), `ProxySessionControl` (control requests to `HotActions`), `reloadForSave`. `dap_command.dart` is `flutter_run dap`: resolves the SDK, starts the adapter, builds the `DapProxy`, control server, session file and watcher, and turns startup failures into a failed first response plus a stderr console message (because Zed only says "adapter exited" otherwise). `path_notice.dart` builds the "flutter_run is not on your PATH" notice and per-OS PATH hints. `doctor_command.dart` prints version, OS, executable, project, the SDK trace, PATH status, sessions, `.zed` files and env overrides. `version_command.dart` prints the version.

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
- No debug locator in 0.1.0 (ADR 0006 D4); "Run" buttons next to `main()` do not use FlutterRun. `.vscode/launch.json` entries of type `dart`/`flutter` are not picked up by Zed for any adapter.
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
