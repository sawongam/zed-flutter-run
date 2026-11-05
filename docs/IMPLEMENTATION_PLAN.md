# Implementation plan: Flutter Run & Debug in Zed

- **Date:** 2026-11-03 (cloud container clock)
- **Status:** Revision 2 - plan reviews (docs/reviews/*) resolved per [ADR 0006](decisions/0006-plan-review-resolutions.md); every finding is mapped in §11. Parallel implementation agents build from THIS file.
- **Author:** planning engineer. Orchestrator decisions are written in as given; where I found a real problem the decision is kept and a **Planner concern:** note is added (all collected in §10). Where a review and ADR 0006 differ, ADR 0006 wins.
- **Inputs read:** HANDOFF, ADR 0002-0005, risk register, coexistence research (Q4-Q6, recommendations), Zed DAP client behaviour, Zed recent changes + picker UX, extension registry (§4), Flutter tooling protocols, conversation 007, `spike/**`, the Zed / Dart-extension / `zed_extension_api 0.7.0` sources (research clones), and two quick probes run by the planner (§4.7 DevTools, §4.11 `flutterMode`/`platform`).

How to read this document: §1-§3 are shared context. §4 is the **specification** (behaviour). §5 has the sequence diagrams. §6 has the **work packages** with exact public interfaces. §7 is the test plan. Every WP agent reads §1-§5, then its own WP in §6, and nothing else is required.

---

## 1. Architecture

```
                           Zed (GUI, can't be run in the cloud)
   .zed/debug.json  .zed/tasks.json  keymap.json       Debugger panel / console
        │                 │                                  ▲        │ DAP (stdio, Content-Length)
        │ task::Spawn     │ (terminal task, real PTY)        │        ▼
        │                 ▼                                  │   ┌─────────────────────────────┐
        │        ┌──────────────────┐                        │   │ Rust WASM extension          │
        │        │ flutter_run <cmd> │                        │   │ flutter-run-debugger          │
        │        │ reload|restart|  │                        │   │  get_dap_binary ─┐           │
        │        │ status|devtools| │                        │   │  dap_request_kind│           │
        │        │ devices|select-  │                        │   │  dap_config_to_scenario      │
        │        │ device|init|...  │                        │   │  (no locator in 0.1.0)       │
        │        └───────┬──────────┘                        │   └──────────────────┬──────────┘
        │                │ TCP 127.0.0.1:<port> + token      │      spawns          │ command=flutter_run
        │                │ (newline-delimited JSON)          │                      ▼ args=dap --cwd ...
        │                │   ┌───────────────────────────────┴──────────────────────────────────┐
        │                │   │ flutter_run dap   (Dart, one process per debug session)            │
        │                └──▶│  ControlServer ◀── session file (per-user state dir, 0700)        │
        │                    │  DapProxy: framing, seq renumbering, launch/attach rewriting,     │
        │                    │            injected hotReload/hotRestart, shutdown + tree kill    │
        │                    │  ReloadOnSaveWatcher (package:watcher) ─▶ HotActions(reason:save) │
        │                    │  DevTools opener (openDevTools: <page>)                            │
        │                    └───────────────────────────────┬───────────────────────────────────┘
        │                                                    │ DAP over stdio (child process)
        │  reads/writes <state dir>/devices/            ▼
        │  <hash>.json (per-user state dir)        flutter debug_adapter | dart debug_adapter
        └─────────────────────────────────────────           │ (resolved SDK: fvm/puro/PATH/...)
                                                             ▼
                                                   flutter run --machine ──▶ app on device
                                                   (DDS serves DevTools at <vmservice>/devtools/)
```

Components:

| Component | Language | Where | Job |
|---|---|---|---|
| Zed extension `flutter-run-debugger` | Rust → `wasm32-wasip2` | `extension/` | Find/download the proxy, build its argv/env, pass the user's scenario through, schema. No logic beyond that. |
| Proxy `flutter_run dap` | Dart | `cli/lib/src/{dap,control,watch,devtools,...}` | Everything that touches a debug session. |
| CLI `flutter_run <cmd>` | Dart (same executable) | `cli/lib/src/{control,devices,devtools,init,cli}` | Commands run from Zed tasks or a terminal. |

---

## 2. Names and constants (ADR 0005)

| Thing | Value |
|---|---|
| Dart package / executable | `flutter_run` |
| Zed extension id / display name | `flutter-run-debugger` / "Flutter Run & Debug" (extension.toml `name`; must not contain "Zed"/"extension") |
| Debug adapter name (`"adapter"` in debug.json) | `FlutterRun` |
| Rust crate | `flutter_run_debugger` (cdylib; wasm file becomes `flutter_run_debugger.wasm`) |
| Env prefix | `FLUTTER_RUN_` |
| GitHub repo (release source) | `sawongam/zed-flutter-run` |
| Proxy version (initial) | `0.1.0`; tag `v0.1.0`; the extension crate version, `extension.toml` version and `PROXY_VERSION` in Rust move together. |
| Release asset names | `flutter_run-v<ver>-<os>-<arch>[.exe]`, `<os>` ∈ `linux|macos|windows`, `<arch>` ∈ `x64|arm64`. Uncompressed executables. Plus `SHA256SUMS` (`<hex>  <asset>` lines). |

Environment variables (all optional):

| Variable | Used by | Meaning |
|---|---|---|
| `FLUTTER_RUN_FLUTTER_SDK` | SDK resolution | Flutter SDK root (step 2). |
| `FLUTTER_RUN_DEVICE` | proxy launch rewrite | Device id (precedence step 2). |
| `FLUTTER_RUN_LOG` | proxy, CLI | Path of a log file. Full DAP traffic + debug log. Same as `--log-file`. |
| `FLUTTER_RUN_LOG_LEVEL` | all | `error|warn|info|debug|trace` (default `info`; `--verbose` = `debug`). |
| `FLUTTER_RUN_STATE_DIR` | session + device stores | Overrides the per-user base dir (`<dir>/sessions`, `<dir>/devices`). Mainly for tests. |
| `FLUTTER_RUN_TEST_EXE` | integration tests | Path to a prebuilt `flutter_run` executable. |
| `NO_COLOR` | CLI | Disables ANSI in CLI output (never in DAP `output` events). |

---

## 3. Repo layout and file ownership

```
extension/
  Cargo.toml  extension.toml  LICENSE (BSD-3-Clause, unmodified standard text)
  debug_adapter_schemas/FlutterRun.json
  src/lib.rs  src/proxy_args.rs  src/install.rs  src/checksums.rs
cli/
  pubspec.yaml  pubspec.lock (committed)  analysis_options.yaml  dart_test.yaml  LICENSE
  bin/flutter_run.dart
  lib/flutter_run.dart                        (barrel, WP10a)
  lib/src/common/    logger.dart errors.dart version.dart console.dart host_environment.dart
                     paths.dart files.dart json_types.dart global_options.dart
  lib/src/dap/       framing.dart messages.dart channel.dart injected_requests.dart launch_rewriter.dart
                     proxy.dart proxy_state.dart hot_actions.dart notices.dart device_hints.dart
  lib/src/control/   session_info.dart session_paths.dart session_store.dart control_protocol.dart
                     control_server.dart control_client.dart session_matcher.dart
                     hot_command.dart reload_command.dart restart_command.dart status_command.dart find_sessions.dart (as built)
  lib/src/sdk/       sdk_resolver.dart sdk_steps.dart process_spec.dart managed_process.dart process_tree.dart
  lib/src/devices/   flutter_device.dart device_store.dart device_lister.dart picker.dart emulators.dart
                     commands/{devices,select_device,emulators}_command.dart
  lib/src/watch/     reload_config.dart path_filter.dart coalescer.dart content_hash.dart reload_on_save_watcher.dart
  lib/src/devtools/  pages.dart url_builder.dart browser_opener.dart devtools_opener.dart
                     commands/devtools_command.dart
  lib/src/init/      project_detect.dart templates.dart json_merge.dart keymap.dart commands/init_command.dart
  lib/src/cli/       runner.dart dap_command.dart doctor_command.dart version_command.dart wiring.dart path_notice.dart
  test/unit/<module>/**      (mirrors lib/src/<module>; owned by that module's WP)
  test/unit/schema_test.dart  test/unit/cli/**   (WP10a)
  test/integration/**                             (WP10b)
fixtures/sample_app          (exists; DO NOT edit; integration tests copy it)
fixtures/dart_console        (new, WP0)
.github/workflows/{ci,release}.yml  .github/scripts/*   (WP9)
.gitignore  LICENSE          (WP0)
spike/                       (historical, not built by CI, never edited)
```
Not owned by any WP (written by the orchestrator in Phase 7): root `README.md`, `CHANGELOG.md`, `docs/MANUAL_ZED_TEST.md`, `docs/RELEASE.md`, `docs/STATUS.md`.

**Ownership matrix (disjoint; every file above has exactly one owner):**

| WP | Owns (create/edit) |
|---|---|
| WP0 | `cli/pubspec.yaml`, `cli/pubspec.lock`, `cli/analysis_options.yaml`, `cli/dart_test.yaml`, `cli/LICENSE`, `LICENSE`, root `.gitignore` (`.dart_tool/`, `build/`, `target/`, `*.log`, `cli/.dart_tool/flutter_run_test/`), `cli/lib/src/common/**`, `cli/test/unit/common/**`, `fixtures/dart_console/**` |
| WP1 | `cli/lib/src/dap/**`, `cli/test/unit/dap/**` |
| WP2 | `cli/lib/src/control/**`, `cli/test/unit/control/**` |
| WP3 | `cli/lib/src/sdk/**`, `cli/test/unit/sdk/**` |
| WP4 | `cli/lib/src/devices/**`, `cli/test/unit/devices/**` |
| WP5 | `cli/lib/src/watch/**`, `cli/test/unit/watch/**` |
| WP6 | `cli/lib/src/devtools/**`, `cli/test/unit/devtools/**` |
| WP7 | `cli/lib/src/init/**`, `cli/test/unit/init/**` |
| WP8 | `extension/**` |
| WP9 | `.github/**` |
| WP10a | `cli/bin/**`, `cli/lib/flutter_run.dart`, `cli/lib/src/cli/**`, `cli/test/unit/cli/**`, `cli/test/unit/schema_test.dart` |
| WP10b | `cli/test/integration/**` |

**Rules for every WP:**
1. Only edit files you own. If you need a new dependency, a change in `common/`, or a change to another WP's interface: don't. Write the need into your final report; the orchestrator resolves it.
2. `lib/src/<module>/` files may import `package:*`, `dart:*`, `lib/src/common/**` and files of the **same** module only. **Never import another module** (WP10a is the only place where modules are wired together).
3. No `print` in `lib/`. Output goes through `Console` (CLI) or `Logger` (diagnostics). Nothing may write to `stdout` in the proxy except the DAP channel.
4. User-facing text lives next to the code that uses it (`static const` / small functions; no per-module strings files and no shared message table, ADR 0006 D4). Message style rules (apply to every user-visible string): whole sentences that say what to do next; placeholders only via function parameters (no fragment concatenation, so word order can vary later); no pluralisation by appending `s`; no hard-coded key names for shortcuts except in `init`/README output that is explicitly about Zed's defaults; ASCII `...` never the Unicode ellipsis; exit-code names never appear in text; no jargon such as "appStarted". Prefix for console notices is `[flutter_run]`. Notices of level warning/error carry the words `Warning:` / `Error:` (colour is never the only signal).
5. Everything with I/O takes its collaborators as constructor arguments (`HostEnvironment`, `Console`, `Logger`, process-runner functions) so it is unit-testable. Time-dependent code uses `Timer`/`Future.delayed` only (so `package:fake_async` works).
6. `dart format` applied, `dart analyze --fatal-infos` clean for your files, tests pass with `dart test --exclude-tags integration test/unit/<module>`. LF line endings.
7. Every `Command<int>` subclass: `name` fixed by this plan; constructor takes its dependencies; `run()` returns the exit code (`ExitCodes.*`); throws `FlutterRunException` subclasses for expected failures. Each command's constructor calls `GlobalOptions.addTo(argParser)` (do not declare `--verbose`, `--project` or `--flutter-sdk` yourself).

---

## 4. Specification

### 4.1 CLI surface and exit codes

`flutter_run [global flags] <command> [command flags]`. Global flags are registered on the runner **and** on every command: `--verbose/-v`, `--project <dir>`, `--flutter-sdk <dir>`, `--help/-h`. No command redeclares them.

| Command | Module | Flags (besides global) | Purpose |
|---|---|---|---|
| `dap` | WP10a | `--cwd <dir>` (required), `--kind dart\|flutter` (default flutter), `--request launch\|attach` (default launch; attach spawns the adapter with `--no-dds`, §4.2a), `--use-fvm`, `--log-file <path>`, `--client-version <x.y.z>` | DAP stdio proxy (spawned by Zed). SDK path comes from the global `--flutter-sdk`. |
| `reload` | WP2 | `--timeout <seconds>` (default 120) | Hot reload on all eligible matching sessions. |
| `restart` | WP2 | `--timeout <seconds>` (default 120) | Hot restart on all eligible matching sessions. |
| `status` | WP2 | `--json` | List running sessions from the session files (+ liveness ping); marks those matching cwd/`--project`. |
| `devices` | WP4 | `--json` | `flutter devices --machine` of the resolved SDK; marks the saved device. |
| `select-device` | WP4 | `--device <id>`, `--clear` | Interactive numbered picker (`r` rescans), or non-interactive with `--device`. |
| `emulators` | WP4 (MVP) | `--launch <id>`, `--json` | No flags + interactive: pick an emulator and launch it; no flags + non-interactive: list; `--launch <id>`: launch. |
| `devtools [page]` | WP6 | `--print` | Open DevTools for the running session. Pages: `inspector` (default), `performance`, `cpu-profiler`, `memory`, `network`, `logging`. |
| `init` | WP7 | `--force`, `--dry-run` | Write `.zed/debug.json` + `.zed/tasks.json`, print keymap snippet and key table. |
| `doctor` | WP10a | | Environment report. |
| `version` | WP10a | | Print `flutter_run <version>`. |
| `help` | runner | | args' built-in. |

**Exit codes** (`ExitCodes` in `common/errors.dart`; documented in `--help`):

| Code | Name | Meaning |
|---|---|---|
| 0 | `ok` | Success. |
| 1 | `internal` | Unexpected error (bug). Message + "Run with --verbose for details." |
| 2 | `usage` | Bad flags/arguments; also "no terminal and no `--device`". |
| 3 | `noSession` | No Flutter debug session found for the directory. |
| 4 | `sessionError` | Sessions exist but none could act, or one failed (reload failed, app still starting, busy, adapter error, unresponsive). |
| 5 | `timeout` | A session did not answer within `--timeout`. |
| 6 | `sdkNotFound` | Flutter/Dart SDK could not be resolved. The trace of tried locations is printed. |
| 7 | `deviceError` | No devices / unknown `--device` id. |
| 8 | `projectNotFound` | No `pubspec.yaml` at/above the directory and no `--project`. |
| 9 | `manualActionRequired` | `init` could not safely edit a file (JSONC / invalid JSON); snippet printed, "Done with 1 manual step." |
| 10 | `externalToolFailed` | `flutter`/`dart`/browser subprocess failed. |
| 130 | `interrupted` | Ctrl-C while waiting. |

`dap` exit code: the adapter's exit code if it exited on its own; `0` after a clean client stop; `6` if the SDK cannot be resolved; `1` for proxy bugs.

Top-level handler (runner): `FlutterRunException` → `error: <message>` (+ `hint: <full sentence>`) on stderr, exit its code; `UsageException` → message + usage, exit 2; anything else → `error: unexpected failure: <e>` + `Run with --verbose for details.`, exit 1; with `--verbose` the stack trace is printed. Raw stack traces are never shown otherwise.

### 4.2 DAP proxy (`flutter_run dap`)

**Startup.** `dap_command` (WP10a): (1) parse flags; (2) build `Logger` (stderr + `--log-file`/`FLUTTER_RUN_LOG`); (3) install a `Zone` that redirects `print` to stderr; (4) resolve the SDK (WP3) with `explicit = --flutter-sdk`, `projectDir = --cwd`, `kind`, `strictFvm = --use-fvm`; (5) spawn `<flutter|dart> debug_adapter` (cwd = `--cwd`, env inherited) via `ManagedProcess`; drain its **stderr** continuously into the `Logger`; (6) `projectRoot = findProjectRoot(cwd) ?? cwd`, canonicalised; (7) start `ControlServer`, write the session file (`appStarted:false`); (8) run `DapProxy`; (9) emit start notices (see "Start notices").

**Start notices** (each at most once per session, only when relevant): PATH notice (D1, below); device source (`Using device <id> (saved selection).` / `(environment variable FLUTTER_RUN_DEVICE)`; silent when from config or toolArgs; when no device source applies: `No device was chosen, so Flutter will pick one. If it cannot, run the task "Flutter: Select Device".`); reload-on-save armed (§4.6); version mismatch (`--client-version`): `The Zed extension is version 0.2 but the flutter_run command is 0.1. Update flutter_run to match (see the README install section).`

**PATH notice (ADR 0006 D1).** Zed tasks run commands from the shell PATH; the extension's download directory is not on it. If `findExecutableOnPath('flutter_run', env)` finds nothing (or finds a different file than `Platform.resolvedExecutable` and the resolved executable is the compiled exe, not `dart`), print once: `Warning: the flutter_run command is not on your PATH, so the tasks "Flutter: Hot Reload", "Hot Restart", "Select Device" and "Open DevTools" cannot run. This debug session is using <resolvedExecutable>. Add <its folder> to your PATH (<per-OS how-to>) and see the README section "Install". Hot restart with Zed's own Rerun Session key still works.` Per-OS how-to lines are pure text in `cli/path_notice.dart` (Linux/macOS: `export PATH="<dir>:$PATH"` in your shell profile; Windows: Settings > System > About > Advanced system settings > Environment Variables > Path). When `resolvedExecutable` is `dart`/`dart.exe` (running from source) skip the path hint and just say the command isn't installed. Messages never tell the user to run a command that doesn't exist yet: until 0.1.0 is published, install instructions refer to the README, which documents GitHub-release binaries, `dart pub global activate --source git https://github.com/sawongam/zed-flutter-run --git-path cli`, and building from source.

**Startup failure** (SDK not found, spawn failure, or no `initialize` response from the adapter within 10 s): the proxy answers the client's first request with `{"type":"response","success":false,"message":"<friendly text incl. tried locations / last adapter stderr line>"}`, sends an `output` event (category `stderr`) with the same text, then exits (`6` for SDK, else `1`). Zed otherwise only sees "adapter exited".

**Framing.** `Content-Length: N\r\n\r\n<N bytes UTF-8 JSON>`. Decoder is incremental (partial headers/bodies, many messages per chunk), tolerant of extra headers and header case, throws `DapFramingException` on a missing/invalid length (the proxy logs, notifies via `output`, and shuts down). Encoder always emits a valid frame (a malformed frame kills the Zed session). Synthetic events always include a `body` object. Before `exit()` the proxy flushes stdout.

**Sequence numbers (ADR 0006 D3: no renumbering).** Client→adapter messages pass through **untouched**. Injected requests (`hotReload`, `hotRestart`, `terminate` mitigation) take `seq` from a separate counter starting at `1_000_000_000`. Responses whose `request_seq` is in the injected-pending set are swallowed (not forwarded), including late ones after a timeout (the seq stays in a bounded "late" set of 64). If a client request ever arrives with `seq >= 1_000_000_000` the proxy logs an error and emits an `Error:` notice (it would collide). Adapter→client events, responses and reverse requests pass through unchanged; client→adapter responses to reverse requests (`runInTerminal`, `startDebugging`) likewise. Synthetic client-bound messages (our `output` events) use `seq` from a counter starting at `1_000_000_000` (Zed ignores adapter `seq`).

**Launch/attach rewrite** (`LaunchRewriter.rewrite(request, arguments)`):
1. Own keys are removed and returned in `RewriteResult.ownConfig`: `flutterSdkPath`, `deviceId`, `reloadOnSave`, `reloadOnSaveGlobs`, `reloadOnSaveDebounceMs`, `openDevTools`, `logFile`, `useFvm`, `adapter`, `label`, **plus** `flutterMode` and `platform` (interpreted here, then removed; the Flutter adapter reads neither, §4.11). `LaunchRewriter.ownKeys` contains all twelve and is the single source of truth (WP10a's schema test reads it).
2. `flutterMode` (`debug|profile|release`, kind flutter, launch only): `profile` → append `--profile`, `release` → append `--release` to `toolArgs`, unless `toolArgs` already contains `--debug`, `--profile`, `--release` or `--debug-*`/`--profile-*` variants (toolArgs wins, logged).
3. Device (kind flutter only). Not injected if `toolArgs` already contains `-d`, `--device-id`, an element starting with `--device-id=`, or `-d<id>`. Otherwise the first available: (a) `ownConfig.deviceId`, (b) env `FLUTTER_RUN_DEVICE`, (c) saved per-project selection (callback `savedDevice()`), (d) none. When chosen: append `-d`, `<id>`. Same precedence for `attach` (§4.2a item 5). `RewriteResult.deviceSource` ∈ `toolArgs|config|env|saved|none`.
4. Defaults: `cwd` missing → `--cwd`; kind flutter + launch + `program` missing → `lib/main.dart`.
5. Everything else (`type`, `request`, `env`, `args`, `toolArgs`, `noDebug`, `stopOnEntry`, `vmServiceUri`, `vmServiceInfoFile`, `debug*`, `evaluate*`, `sendLogsToClient`, unknown keys) passes through untouched.

**Device failure hints (ADR 0006 D7).** `device_hints.dart` inspects adapter `output` events and a failed `launch` response for Flutter's phrases (`More than one device connected`, `No supported devices connected`, `No devices found`, `no connected devices`); on the first match it emits one notice: `Several devices are available (or none is). Run the task "Flutter: Select Device", or add "deviceId" to this launch entry.` / for none: `No devices found. Start an emulator or simulator (task "Flutter: Launch Emulator"), connect a phone, or enable Chrome/desktop with "flutter config --enable-<platform>-desktop". A simulator can take a few seconds to appear.` The adapter's own text is still forwarded unchanged.

**State capture** (events are forwarded unchanged AND observed): `dart.debuggerUris{vmServiceUri}` → `state.vmServiceUri`; `flutter.appStart{appId,deviceId,mode,...}` → `appId/deviceId/mode`; `flutter.appStarted` → `appStarted = true`; `terminated`/`exited` → `ended`. Each change emits a `ProxyEvent`; WP10a rewrites the session file. `DebuggerUris` carries `isFirst` (true for the first occurrence this session) for `openDevToolsOnce`.

**Injected requests.** `HotActions.reload({reason})` sends `hotReload {reason}`, `restart` sends `hotRestart {reason}`. Rules:
- If `!appStarted`: no request; result `HotError.notStarted` (notice `Hot reload skipped: the app is still starting. Try again in a moment.`).
- At most one hot action in flight. A `reload` while a `reload` is in flight **joins** it (same result, `coalesced: true`) - this is how a manual reload never makes a save-triggered one fail and vice versa (ADR 0006 D5). A `reload` with `reason: 'save'` while a **restart** is in flight waits for the restart to finish and then runs (a save during a restart runs after it); a manual `reload` during a restart → `HotError.busy`; `restart` during anything → `busy`. A client-originated DAP `restart` (Zed's Rerun Session) marks the restart flag from the request until its response, so injected reloads queue behind it (`DapProxy` tells `HotActions` via `noteClientRestart(started)`).
- Timeout 120 s. On timeout the result is `HotError.timeout`, but the action stays counted as in flight until its late response arrives (or 10 min), so the next call does not overlap. A breakpoint hit during reload delays the response until the user resumes (spike finding 4): after 3 s without a response a one-time notice `Reload is waiting for the debugger to resume.` is emitted.
- The adapter prints "Reloaded N libraries…" itself; the proxy adds a notice only for failures, save-triggered reloads, and skips. A failure notice is `Error: Hot reload failed: <adapter message>. Try the task "Flutter: Hot Restart".`; if the message contains "not supported" (web) the hint is `Hot reload is not supported here. Try the task "Flutter: Hot Restart" instead.`

**User-visible status.** `DapProxy.notice(text, level)` emits `{"type":"event","event":"output","body":{"category":"console","output":"<ANSI>[flutter_run] [Warning: |Error: ]text<RESET>\n"}}`. Colours: info cyan `\x1b[36m`, warn yellow, error red; multi-line text prefixes each line. Every notice ends with exactly one `\n`. No custom events (Zed ignores them).

**Shutdown (ADR 0006 D2: follows Zed's real stop path).** Zed's `Session::shutdown` (`crates/project/src/debugger/session.rs:2249-2299`) sends `terminate` (when the adapter advertises `supportsTerminateRequest`, which the Dart/Flutter adapters do) else `disconnect`, and **kills the adapter process (our proxy) as soon as that response arrives**. So anything not done before relaying that response may never run.
- **Common path - client `terminate`:** (1) immediately delete the session file and stop accepting control requests (a SIGKILL right after the relay must leave nothing stale); (2) snapshot adapter descendants; (3) forward the `terminate` request unchanged; (4) when the adapter's response arrives, **hold it** (do not relay) until the `terminated` event was seen (forwarded to the client when it arrives) or 5 s since receipt of `terminate`, then: stop the watcher, close the control server, sweep surviving snapshot pids (`AdapterConnection.terminateTree()` over survivors, bounded 3 s); (5) only then relay the held response (a bounded 5 s total from step 3, never longer). If the adapter dies without answering, synthesize a success response. If `terminate` takes more than 1 s emit `Stopping the app...`.
- **`disconnect` without a prior `terminate`** (launch mode): inject `terminate` (seq from the injected counter), wait ≤5 s for its response or a `terminated` event, then forward `disconnect`; in *attach* mode forward `disconnect` straight away (the app must keep running). After forwarding, wait ≤5 s for the adapter to exit, then the same cleanup as above, then relay the `disconnect` response.
- **stdin EOF** (Zed killed / window closed; also a `.bat` wrapper killed by Zed so only `cmd.exe` died): same cleanup as a `terminate` without a client response, then exit. **Adapter exit** (crash): drain/forward remaining output, emit `output` (category `stderr`) with the last ~20 stderr lines and an `Error:` notice, send a `terminated` event, flush, clean up, exit with the adapter's code.
- `terminateTree` is the last resort: POSIX - before signalling each snapshot pid re-read the process table and signal only pids that are still descendants of the snapshotted adapter or were its descendants and now have ppid 1 and the same start time (guard against PID reuse); SIGTERM, 2 s grace, SIGKILL. Windows - `snapshotDescendants` is the adapter pid only and `terminateTree` runs `taskkill /PID <pid> /T /F` while the adapter is alive.
- Idempotent; signals are never used for control, only in this last-resort sweep of processes we spawned.

### 4.2a Attach (probe result)

Source: [research/attach-probe.md](research/attach-probe.md) (D9 probe, Flutter 3.47.9, `flutter-tester`, 2026-11-03). Binding for WP1, WP8, WP10a, WP10b.

1. **App-started signal:** `flutter.appStarted` (arrives about 2 s after the `attach` request; order: `initialized`, `capabilities`, `flutter.appStart{launchMode:"attach"}`, `dart.debuggerUris`, `thread`, `flutter.appStarted`, `dart.serviceRegistered`, `breakpoint(verified)`). Same signal as launch; no special case. No `stopped(entry)` on attach (it does appear after a hot restart, then auto-`continued`).
2. **DDS:** attaching works without flags, but the adapter then starts a *second* DDS that is orphaned (ppid 1) after every stop. So **for `request: attach` the proxy spawns `flutter debug_adapter --no-dds`.** The proxy must know this before the first DAP message, so the extension passes **`--request attach|launch`** in the `dap` argv (from the scenario's `request`, default `launch`), and `dap` gets a new flag `--request` (WP8 + WP10a). The descendant sweep still runs as a safety net (in attach mode the app is not our descendant, so it is never killed).
3. **URI form:** both `ws://H:P/T=/ws` and `http://H:P/T=/` work; with `--no-dds` the ws form logs a harmless `/ws/ws`. The proxy passes `vmServiceUri` through unchanged. `init`'s attach scenario documents `vmServiceUri` as "the `http://127.0.0.1:…/…=/` URL that `flutter run` prints".
4. **`vmServiceInfoFile`:** must contain JSON `{"uri":"…"}`. `flutter run --vmservice-out-file` writes a *bare string*, which makes the adapter wait forever. The proxy does **not** rewrite files; README/troubleshooting says so. Attach with no URI also waits silently (device discovery), so: **attach watchdog** — if `flutter.appStarted` hasn't arrived 15 s after the `attach` request, the proxy emits one notice: `Still waiting for the app. Start it with "flutter run", or set "vmServiceUri" in .zed/debug.json.` (no abort).
5. **Device:** `flutter attach` needs `-d` when more than one device is connected (else `More than one device connected`, `Exited (1)`). So **device injection uses the normal precedence for attach too** (config → env → saved → none); this replaces the earlier "only (a) applies for attach" rule in §4.2 step 3. The failure gets the same device hint as launch (`deviceHintFor`).
6. **Stop:** `terminate`, `disconnect`, `disconnect{terminateDebuggee:true}` all just detach ("Detached"); the app keeps running. So in attach mode the proxy never injects `terminate`; the held-`terminate`-response path (§4.2 Shutdown) still applies because Zed sends `terminate`.
7. **Reload/restart** work in attach mode, including breakpoint hits in `bump()`. Caveat: `hotReload`/`hotRestart` answer `success:true` even when nothing is attached, so the proxy refuses hot actions until `flutter.appStarted` (already the rule).

### 4.3 Control channel and session files

**Server (WP2).** `ServerSocket.bind(InternetAddress.loopbackIPv4, 0)` (loopback only; no separate remote-address check); a connection must deliver its request line within **10 s** or is closed; max request line **64 KiB** (`payload_too_large` then close); one request per connection. Token: 32 random bytes (`Random.secure()`), base64url without padding, compared in constant time. The handler may take long; the idle timeout does not apply after the line was read.

**Request:** `{"v":1,"token":"…","id":1,"command":"reload"|"restart"|"ping","args":{…}}\n`
**Response (ok):** `{"v":1,"id":1,"ok":true,"result":{…}}\n`
**Response (error):** `{"v":1,"id":1,"ok":false,"error":{"code":"<enum>","message":"…"}}\n`

Error codes (`ControlErrorCode`): `bad_request`, `unsupported_version`, `unauthorized`, `payload_too_large`, `unknown_command`, `app_not_started`, `busy`, `adapter_error`, `timeout`, `session_ended`, `internal`. The token check happens before the command lookup. There is **no control `status` command** (ADR 0006 D4): `status` and `devtools` read the session files and use `ping` only to check liveness.

Commands and results:
- `ping` → `{"pid":123,"version":"0.1.0","protocol":1}`
- `reload` args `{"reason":"manual"}` → `{"durationMs":593,"coalesced":false}`
- `restart` args `{}` → `{"durationMs":320}`

**Session file (schema version 1)**:
```json
{ "version": 1, "pid": 12345, "port": 51789, "token": "base64url…",
  "projectRoot": "/home/me/app", "cwd": "/home/me/app", "kind": "flutter", "request": "launch",
  "startedAt": "2026-11-03T12:00:00.000Z", "deviceId": "linux", "mode": "debug",
  "vmServiceUri": "ws://127.0.0.1:35233/abc=/ws", "appStarted": true }
```
`deviceId`, `mode`, `vmServiceUri` are omitted until known. `projectRoot` is canonical (`canonicalDirectory`). Readers ignore unknown keys and skip (debug log, no delete) files with `version != 1`.
- **Location:** base = `stateBaseDirectory(env)` (WP0): `$FLUTTER_RUN_STATE_DIR` if set, else Linux `$XDG_STATE_HOME/flutter_run` (default `~/.local/state/flutter_run`), macOS `~/Library/Application Support/flutter_run`, Windows `%LOCALAPPDATA%\flutter_run`; sessions in `<base>/sessions/`.
- **Protection:** the sessions directory is created `0700` (POSIX; one `chmod` of the directory, nothing per file). Windows relies on the per-user profile ACL.
- **File name:** `<pid>.json`. **Atomic update:** write `<pid>.json.tmp-<random>` in the same directory and `rename` over the target (retry 10 × 50 ms for Windows sharing violations). Rewritten whenever state changes. Deleted as the first step of shutdown (§4.2) and on normal exit; hard crashes leave a file that the next CLI call prunes.
- **Listing/pruning (CLI side):** read all `*.json`, ping **all concurrently** (2 s). Connect refused, connect timeout, reset or a non-protocol reply → stale → delete the file, skip. Connected but no protocol reply within the timeout → keep, mark `unresponsive`.
- **Matching** (`matchSessions`): a session matches directory `D` when `isWithin(session.projectRoot, D)` or `isWithin(D, session.projectRoot)` (D inside the project, or D a parent such as a monorepo worktree root); `D` = `--project` or cwd, canonicalised; comparisons use `pathKey` (case-insensitive on Windows and macOS). **Planner concern 2.** In a monorepo a parent directory therefore reloads every app below it (stated in the command's output).
- **Eligibility and CLI behaviour (ADR 0006 D5):** `reload`/`restart` act on matching sessions that are **alive, `kind == flutter` and `appStarted`**, concurrently (like VS Code). Skipped with a one-line note: other kinds (`Skipped pid N: it is a Dart console session, not a Flutter app.`), unresponsive (`Skipped pid N: it did not answer. If Zed is hung, stop that debug session.`), not started (`pid N: the app is still starting.`). Outcome: exit 3 only when **no matching session exists** (message: `No running Flutter app found for <dir>. Start one from the debugger first (F4 opens the debug picker in Zed). Sessions started with the "Dart" adapter cannot be reloaded by this tool; use a scenario that uses the "FlutterRun" adapter.`); exit 0 if at least one session succeeded (skips are warnings); exit 4 if sessions matched but none succeeded or one failed; exit 5 on timeout. One result line per session: `Hot reload: <device> <project name> ok in 0.6 s` / `Hot reload: <device> <project name> failed: <message>` (words `ok`/`failed`, not colour only; CLI colour honours `NO_COLOR`). After **3 s** without a reply the CLI prints once `Waiting... the app may be paused at a breakpoint (Ctrl+C to stop waiting).`

### 4.4 SDK resolution (`lib/src/sdk`)

`SdkResolver.resolve(...)` walks these steps in order; the first hit wins; **every step is recorded** (`ResolutionStep{id, description, outcome, detail}`) for `doctor` and for error messages.

| # | Step id | Source | Notes |
|---|---|---|---|
| 1 | `explicit` | `--flutter-sdk` / config `flutterSdkPath` | Must contain `bin/flutter` (`.bat` on Windows). Invalid explicit path is an **error**, not a fall-through. |
| 2 | `env` | `FLUTTER_RUN_FLUTTER_SDK` | Same validation; invalid → recorded `invalid`, fall through. |
| 3 | `fvm-link` | `.fvm/flutter_sdk` in the project dir or any ancestor | Symlink or Windows junction; `resolveSymbolicLinksSync`, fall back to `Link(path).target`. |
| 4 | `fvmrc` | `.fvmrc` (`{"flutter":"<version-or-channel>"}`) | Project dir or ancestor → version for step 5. |
| 4b | `fvm-legacy` | `.fvm/fvm_config.json` (`{"flutterSdkVersion":"<v>"}`) | Same. |
| 5 | `fvm-cache` | `$FVM_CACHE_PATH/versions/<v>`, else `$FVM_HOME/versions/<v>`, else `~/fvm/versions/<v>` (Windows `%USERPROFILE%\fvm\versions\<v>`, also `%LOCALAPPDATA%\fvm\versions\<v>`) | Only if 4/4b produced a version. |
| 6 | `puro` | `.puro.json` (`{"env":"<name>"}`) in project dir or ancestor | → `$PURO_ROOT` else `~/.puro` + `/envs/<name>/flutter`. |
| 7 | `flutter-root` | env `FLUTTER_ROOT` | validated. |
| 8 | `path` | `flutter` (`flutter.bat` on Windows) on `PATH` via `findExecutableOnPath` | Resolve symlinks to the SDK root. If the real file is not inside `<root>/bin` (a shim, e.g. asdf/mise) use the command **as found**; `FlutterSdk.root` may be `null`. |
| – | error | | `SdkNotFoundException` listing all tried steps + three fixes (set `flutterSdkPath`, set `FLUTTER_RUN_FLUTTER_SDK`, put `flutter` on PATH). |

`useFvm`/`--use-fvm` (**strictFvm**): steps 3-5 must succeed, otherwise error; steps 6-8 are not tried. `fvm` itself is never invoked.

Kind `dart`: try steps 1-8 non-fatally; if a Flutter SDK is found use `<root>/bin/cache/dart-sdk/bin/dart[.exe]` if present; else `$DART_SDK/bin/dart`; else `dart` on PATH; else error. Versions for `doctor` come from `<root>/version` and `<root>/bin/cache/dart-sdk/version` (file reads).

**Windows process launching.** Dart's `Process.start` on a `.bat` goes through `CreateProcess`, which implicitly starts `cmd.exe` (argument-injection hazards). Approach (`process_spec.dart`, pure, unit-tested): `buildProcessSpec(executable, args, env)` returns `ProcessSpec{executable, arguments, workingDirectory}` and always starts the target directly (`runInShell` is never used). For `.bat`/`.cmd` targets every argument must pass `validateBatchArgument` (reject `\n \r " % ^ & | < > !` and a trailing backslash; our own argv is a fixed vocabulary - `debug_adapter`, `devices`, `--machine`, `emulators`, `--launch <id>`, `--version` - plus device/emulator ids validated against `safeIdPattern` = `^[A-Za-z0-9._:\-@]+$`). The executable is the absolute path to `flutter.bat` (Dart quotes it when it has spaces). No `cmd /c` string is assembled from user data.

### 4.5 Device selection and emulators

- `devices [--json]`: runs `<flutter> devices --machine` (cwd = project dir; timeout 60 s) → JSON array; robust parser (skips noise before the first `[`). Table output marks the saved device with `*`. `--json` prints the list plus `"saved": <id|null>`. If the command times out the message mentions that another running `flutter` command may be holding the startup lock.
- `select-device [--device <id>] [--clear]`: with `--device` non-interactive (validated against the current list; unknown → exit 7 listing ids). `--clear` removes the saved selection. Interactive requires `Console.isInteractive` (stdin **and** stdout are terminals; else exit 2: `select-device needs a terminal; use --device <id>.`): numbered list, accepts a number or an exact id; `r` rescans (simulators take seconds to appear); empty line or `q` cancels (exit 0, nothing changed); invalid input re-prompts up to 3 times then exit 2. Zero devices → exit 7 with the "No devices found" text from §4.2. On success print exactly: `Saved device: <name> (<id>). It is used the next time you start the app. The running app keeps its device.` and `Start the app from the debugger (F4 opens the picker in Zed).`
- **State (ADR 0006 D7):** `<base>/devices/<projectRootHash>.json` (`base` = `stateBaseDirectory`, hash = first 16 hex of sha256(`pathKey(projectRoot)`)) = `{"version":1,"projectRoot":"…","deviceId":"…","name":"…","platform":"…","savedAt":"<iso>"}` - survives `flutter clean`, never pollutes the repo. `projectRoot` = `findProjectRoot(--project ?? cwd)`; none → exit 8. Unknown version or malformed file → "no selection" (debug log; never breaks launch). The proxy reads it via `DeviceStore.readSync`.
- `emulators` (MVP): no flags & interactive → list `flutter emulators` (text table, tolerant regex `^(\S+)\s+•\s+(.+?)\s+•\s+(.+?)\s+•\s+(.+)$`, unparsable lines ignored; zero emulators → the "No devices found" text) and launch the chosen one with `flutter emulators --launch <id>`; `--launch <id>` launches directly (id validated by `safeIdPattern`); non-interactive without flags lists; `--json` prints the parsed list.

### 4.6 Reload on save (`lib/src/watch`)

Config comes from the stripped launch keys: `reloadOnSave` ∈ `"changed"` (default) | `"always"` | `"off"` (`true`→changed, `false`→off); `reloadOnSaveGlobs: string[]` (package:glob, matched against the path **relative to projectRoot** with `/` separators; Windows paths converted); `reloadOnSaveDebounceMs` (default 200, clamp 10-5000).

- **Armed** when the app has started and `mode` is not `profile|release|jit_release`; otherwise one notice `Reload on save is off because the app runs in profile mode (hot reload needs debug mode).` and no watcher. Works for launch and attach. On arming print once: `Reload on save is on for lib/ (changed files only). Set "reloadOnSave": "off" in .zed/debug.json to turn it off. With Zed autosave enabled, every autosave reloads.` (names the actual watched directories).
- **Allow-list watching (ADR 0006 D6):** watch `<projectRoot>/lib` and, for kind `dart`, `<projectRoot>/bin`, plus the static directory prefix of every `reloadOnSaveGlobs` entry (`assets/**.json` → `assets/`; a pattern with no directory prefix such as `**.json` is rejected with a warning notice), each only if it exists at arm time. One `DirectoryWatcher` per directory. Never `ios/Pods`, `android/.gradle`, `build/`, `.dart_tool/`, `.git/`, `node_modules/`; no rescan - directories created later and sibling path packages outside the project (monorepo/pub workspace edits, finding A21) are out of scope for 0.1.0.
- **Which files trigger:** extension `.dart`, or matching a glob, inside a watched directory. Always ignored: a path whose *first* segment relative to `projectRoot` is `.dart_tool`, `build`, `.git` or `node_modules`; any segment starting with `.` at any depth; anything outside `projectRoot` (code review B13: `lib/build/x.dart` does trigger). Ignore rules beat globs.
- **Mode `changed`:** per-file SHA-256 (package:crypto) of the content, **no baseline scan** (ADR 0006 D4): the first event for a file counts as changed; later events reload only if the hash differs from the last seen. Files > 2 MiB are treated as changed. Deleted files count as changed once. **Mode `always`:** every matching event. **Mode `off`:** no watcher.
- **Debounce + coalescing** (`ReloadCoalescer`): trailing-edge debounce (`Timer`) restarting on each accepted change; when it fires and nothing is in flight call `reload()`; changes arriving while one is in flight set `pendingAfter`, and exactly **one** more reload runs afterwards. Never two concurrently. A `busy` outcome (a restart/manual action in flight) is **not an error**: it sets `pendingAfter` and retries after the in-flight action completes. Real failures do not stop the watcher.
- Sends `HotActions.reload(reason: 'save')`; the notice `Hot reload on save: <first changed relative path>[ (+N more)]` precedes it.

### 4.7 DevTools

**Probe result (planner, Flutter 3.47.9, `flutter run --machine -d flutter-tester`):** the machine stream carries `app.devTools{uri:"http://127.0.0.1:P/TOKEN=/devtools/?uri=ws://127.0.0.1:P/TOKEN=/ws"}`: DDS itself serves DevTools under the VM-service path. A GET of `…/TOKEN=/devtools/?uri=<enc>`, `…/devtools/inspector?uri=<enc>`, `…/devtools/performance?uri=<enc>` and `…/devtools/?uri=<enc>&page=inspector` all return 200 with the same 941-byte SPA index (contains `flutter_bootstrap.js`); routing is client-side, so HTTP cannot tell page forms apart. The adapter does not forward `app.devTools` over DAP.

`devtools [page]` (ADR 0006 D4: one URL style, no probe, no fallback server):
1. Find the session from the session files: most recent `startedAt` among matching, live sessions with a `vmServiceUri`. None → exit 3; no URI yet → exit 4 `The app is still starting. Try again in a moment.`
2. Build `http://H:P/TOKEN=/devtools/<page>?uri=<percent-encoded ws URI>` (input forms `ws://H:P/TOKEN=/ws`, `http://H:P/TOKEN=/`, `…/TOKEN=` normalised).
3. Always print `Opening DevTools: <url>` (so the user can copy it), then open it without a shell: Linux `xdg-open <url>`, macOS `open <url>`, Windows `rundll32 url.dll,FileProtocolHandler <url>`; URL must be http(s) to loopback only. `--print` prints and does not open. Browser launch failure → URL stays printed, exit 10. If the page does not load, the message in the README says DevTools needs the Dart Development Service (default; `--no-dds` in `toolArgs` turns it off).
- Auto-open: launch key `openDevTools: "never"|"<page>"` (default `never`); the proxy opens that page **once** on the first `dart.debuggerUris` (failure → notice with the URL).

### 4.8 `init`

`flutter_run init [--project <dir>] [--force] [--dry-run]` (ADR 0006 D4: no `--worktree`; `.zed/` is written in the project directory).
- Detect (`detectProject`): needs `pubspec.yaml` (else exit 8). Flutter project if `dependencies.flutter` (sdk: flutter) or a `flutter:` section / `environment.flutter` exists; else Dart package. `fvm` presence is reported only. Dart entry: `bin/<name>.dart` if it exists, else `bin/main.dart`, else the first file in `bin/`, else `lib/main.dart`.
- **Per file** (`debug.json`, `tasks.json`): absent → create (2-space JSON, LF, trailing newline). Present and valid **strict JSON array** → add our entries whose `label` isn't present (existing entries and order kept; report `Added N entries, kept M that were already there.`). Present but **not strict JSON** (comments, trailing commas, invalid) → untouched; print `Could not safely edit .zed/debug.json (it has comments or trailing commas). Nothing was changed. Paste these entries into the file:` + snippet; the run ends with `Done with 1 manual step.` and exit 9. `--force` on such a file → `Backed up to debug.json.bak` (numbered if it exists), then a fresh file. `--dry-run` prints what would happen and the resulting files, writes nothing. A strict-JSON file whose root is not an array counts as invalid.
- **Always prints** (after writing): (1) **key table** `F4 start/choose a debug scenario (first time) | F5 re-run the last scenario, Continue when paused | Shift+F5 stop | Ctrl+F5 hot reload | Ctrl+Shift+F5 hot restart` with: "F5 does nothing while the app runs; Ctrl+F5/Ctrl+Shift+F5 only work while a debug session is running; Zed has no key for 'run without debugging' - pick 'Flutter: Run (no debug)' with F4"; (2) the **keymap snippet** for the current OS with the exact steps `Open the command palette, run "zed: open keymap file", and paste the snippet.` and a second optional snippet that omits the `ctrl-shift-f5` entry ("keep Zed's default restart key"); on macOS a note about the `fn` key / "Use F1, F2 etc. as standard function keys" and a possible system shortcut conflict; (3) `Output and reload results appear in the Console tab of the Debug panel.`; (4) a **PATH check**: `flutter_run on PATH: yes (<path>)` or `no` with the per-OS fix (same helper as the proxy notice); (5) a note that `.zed/` is usually committed and the tasks fail for teammates without `flutter_run` (they see `Flutter: Doctor`). No settings/locator snippet (locator deferred).
- **Scenarios (`debug.json`)** - Flutter project:

```json
[
  { "label": "Flutter: Debug", "adapter": "FlutterRun", "request": "launch", "type": "flutter",
    "program": "lib/main.dart", "cwd": "$ZED_WORKTREE_ROOT", "reloadOnSave": "changed" },
  { "label": "Flutter: Run (no debug)", "adapter": "FlutterRun", "request": "launch", "type": "flutter",
    "program": "lib/main.dart", "cwd": "$ZED_WORKTREE_ROOT", "noDebug": true, "reloadOnSave": "changed" },
  { "label": "Flutter: Profile", "adapter": "FlutterRun", "request": "launch", "type": "flutter",
    "program": "lib/main.dart", "cwd": "$ZED_WORKTREE_ROOT", "toolArgs": ["--profile"] },
  { "label": "Flutter: Attach", "adapter": "FlutterRun", "request": "attach", "type": "flutter",
    "cwd": "$ZED_WORKTREE_ROOT", "reloadOnSave": "changed" }
]
```
Dart package: one scenario `{"label":"Dart: Debug bin/<name>.dart","adapter":"FlutterRun","request":"launch","type":"dart","program":"bin/<name>.dart","cwd":"$ZED_WORKTREE_ROOT"}`.

- **Tasks (`tasks.json`)**, all `"command":"flutter_run"`, `"cwd":"$ZED_WORKTREE_ROOT"`; all keys exist in Zed's `TaskTemplate`:

| label | args | extra keys |
|---|---|---|
| Flutter: Hot Reload | `["reload"]` | `use_new_terminal:true, allow_concurrent_runs:true, reveal:"no_focus", hide:"on_success", show_summary:false, show_command:false` |
| Flutter: Hot Restart | `["restart"]` | same |
| Flutter: Select Device | `["select-device"]` | `use_new_terminal:true, allow_concurrent_runs:false, reveal:"always", hide:"never"` |
| Flutter: Launch Emulator | `["emulators"]` | same as Select Device |
| Flutter: Devices | `["devices"]` | `use_new_terminal:false, allow_concurrent_runs:true, reveal:"always", hide:"never"` |
| Flutter: Open DevTools | `["devtools"]` | `use_new_terminal:true, allow_concurrent_runs:true, reveal:"no_focus", hide:"on_success"` |
| Flutter: DevTools Inspector / Performance | `["devtools","inspector"]`, `["devtools","performance"]` | same as Open DevTools (other pages: `flutter_run devtools <page>`) |
| Flutter: Doctor | `["doctor"]` | `use_new_terminal:false, reveal:"always", hide:"never"` |

  `reveal:"no_focus"` + `hide:"on_success"` (ADR 0006 D8) shows the tab while the command runs and keeps it visible on failure. For a plain **Dart package** only `Flutter: Doctor` is written (console apps have no hot reload).
- **Keymap snippet** (printed, never written). Keys verified against `default-{linux,macos,windows}.json` in the cloned Zed (`ctrl-f5` and `ctrl-alt-shift-d` unbound on Linux/macOS; on Windows `ctrl-alt-shift-d` is the dev-only `dev::ResetFrameOverlayStats`):

```json
[
  { "context": "Workspace && debugger_session",
    "bindings": {
      "ctrl-f5": ["task::Spawn", { "task_name": "Flutter: Hot Reload" }],
      "ctrl-shift-f5": ["task::Spawn", { "task_name": "Flutter: Hot Restart" }],
      "ctrl-alt-shift-d": ["task::Spawn", { "task_name": "Flutter: Open DevTools" }]
    } }
]
```
  macOS variant: Hot Restart on `"shift-cmd-f5"` (Zed's default `RerunSession` key there). On Linux/Windows `ctrl-shift-f5` is by default `debugger::RerunSession`, which also hot-restarts via DAP `restart`; binding the task makes it deterministic.

### 4.9 Logging and error policy

- **No telemetry**, no network except localhost control and the extension's GitHub download.
- `Logger` levels `error|warn|info|debug|trace`; format `HH:MM:SS.mmm LEVEL message`; sinks: stderr (default `info`; CLI results go through `Console`, not the logger) and optional file (`--log-file` / `FLUTTER_RUN_LOG`): the file always receives `debug` and above plus the full DAP traffic as `trace` lines (`C>A`, `A>C`, `INJ`, `SYN`). Never stdout.
- Adapter stderr is drained into the logger and mirrored to the client as `output` (category `stderr`) until `launch` completes, and for the last ~20 lines on unexpected exit.
- Expected failures are `FlutterRunException`s with a user message and optional `hint`; runtime failures in the proxy become an `Error:` notice when the client channel is alive, plus a stderr/file log.

### 4.10 Zed extension (WP8) behaviour

`get_dap_binary(adapter_name, config, user_provided_debug_adapter_path, worktree)`:
1. Parse `config.config` (JSON string, `$ZED_*` already substituted) with `serde_json`. Invalid JSON → error.
2. `cwd` = config `cwd` (string) else `worktree.root_path()`.
3. **Command resolution (ADR 0006 D1):** (a) `user_provided_debug_adapter_path` (`dap.FlutterRun.binary`) if `Some`; (b) on Windows `worktree.which("flutter_run.exe")`, then `worktree.which("flutter_run")` **ignoring results ending in `.bat`/`.cmd`** (a `dart pub global` shim means Zed would kill only `cmd.exe` and orphan the real proxy; pure fn `pick_command(user, which_exe, which_plain, os)` unit-tested); on other OSes `worktree.which("flutter_run")`; (c) pinned-checksum download; (d) error. The CLI on PATH is also required for tasks, so the supported install is two steps (extension + `flutter_run` on PATH); the download keeps *debugging* working without it, and the proxy prints the PATH notice (§4.2).
4. **Download (only if a checksum is pinned for the asset):** `asset = flutter_run-v<PROXY_VERSION>-<os>-<arch>[.exe]` from `current_platform()`; `(Windows, Aarch64)` → the `windows-x64` asset (runs under emulation); other `Aarch64`/`X8664` pairs map directly; 32-bit `X86` → error. URL is deterministic: `https://github.com/sawongam/zed-flutter-run/releases/download/v<ver>/<asset>` (no GitHub API call; a missing/draft release gives the download error below). Install dir `flutter_run-<ver>/` built with `std::path::Path`. If `<dir>/flutter_run[.exe]` exists and its SHA-256 equals the pinned value, call `make_file_executable` (always) and use it (hash verified once per extension instance). Else download to `<dir>/flutter_run[.exe].part-<n>` via `download_file(url, path, DownloadedFileType::Uncompressed)`, read with `std::fs::read`, hash (`sha2`, lower-case hex written by hand), compare; mismatch → delete, error with expected and actual; match → `std::fs::rename` into place (two Zed windows racing is safe), `make_file_executable`, delete other `flutter_run-*` dirs **ignoring errors** (Windows: binary in use), return the absolute path (`std::env::current_dir()?` joined with the `Path`). Download failure message: `Could not download flutter_run v<ver> from GitHub (<error>). Download the file for your system from https://github.com/sawongam/zed-flutter-run/releases and put it on your PATH, or set "dap": {"FlutterRun": {"binary": "<path>"}} in Zed settings.`
5. **No pinned checksum (dev builds) / nothing found:** error `flutter_run was not found. Install it from the README section "Install" (release binary on your PATH${if PUBLISHED_ON_PUB: , or "dart pub global activate flutter_run"}), or set "dap": {"FlutterRun": {"binary": "<path>"}} in Zed settings.` `PUBLISHED_ON_PUB` is a `const bool = false` in `install.rs`; it is flipped by the release steps, so the message never recommends a command that fails.
6. **Arguments:** `["dap","--cwd",<cwd>]`, `"--kind","dart|flutter"` (config `type`; missing/empty → `flutter`; other → error), `"--flutter-sdk",<path>` if `flutterSdkPath` is a non-empty string, `"--use-fvm"` if `useFvm == true`, `"--log-file",<path>` if `logFile` is a non-empty string, `"--client-version",PROXY_VERSION`.
7. **envs:** `worktree.shell_env()` merged with config `env` (object; config wins on identical keys). Non-string scalars are stringified; objects/arrays → error.
8. `cwd: Some(cwd)`, `connection: None` (stdio), `request_args = StartDebuggingRequestArguments { configuration: config.config (verbatim), request }` with `request` from config `request` (default launch).

`dap_request_kind`: `"attach"` → Attach; `"launch"` or missing → Launch (lenient); else `Err`.

`dap_config_to_scenario(DebugConfig{label,adapter,request,stop_on_entry})` (New Session custom tab): `DebugScenario{label, adapter:"FlutterRun", build:None, tcp_connection:None, config}` with launch → `{"request":"launch","type":"flutter","program":…,"cwd":…?,"args":[…],"env":{…},"stopOnEntry":…?}`; attach → `{"request":"attach","type":"flutter","stopOnEntry":…?}` (`process_id` ignored). `type` is always `flutter`.

**No locator in 0.1.0** (ADR 0006 D4): no `[debug_locators]` entry, no `run_dap_locator`/`dap_locator_create_scenario` override (the locator only works when the user sets `languages.Dart.debuggers`, and cannot be tested here). Deferred to 0.2; finding A15's tokenising note is recorded for then.

**Crate shape (A14, verified by the reviewer: `cargo test` works on the host with `crate-type = ["cdylib"]` and an unguarded `register_extension!`).** Four files: `lib.rs` (trait impl + `register_extension!`), `proxy_args.rs` (config parsing, argv, env merge, request kind, scenario), `install.rs` (asset naming, paths, `pick_command`, sha256 + hex, pin lookup, error texts, `PROXY_VERSION`, `PUBLISHED_ON_PUB`), `checksums.rs` (generated pin table, empty in dev builds). Unit tests live in each module (`#[cfg(test)]`). No `cfg(target_os = "wasi")` split, no `rlib`.

### 4.11 Schema `extension/debug_adapter_schemas/FlutterRun.json`

JSON Schema draft-07, `"type":"object"`, `"additionalProperties": true`, structure like Dart's `Dart.json` (`properties.adapter.enum = ["FlutterRun"]`, …). Properties (type · default · note):

| Key | Type | Note |
|---|---|---|
| `adapter` | enum `["FlutterRun"]` | |
| `label` | string | |
| `request` | enum `launch|attach` | default `launch` |
| `type` | enum `flutter|dart` | default `flutter` |
| `program` | string | default `lib/main.dart` |
| `cwd` | string | |
| `args` | string[] | app args |
| `toolArgs` | string[] | args for `flutter run/attach` |
| `env` | object of strings | |
| `flutterMode` | enum `debug|profile|release` | **translated by the proxy** to `--profile`/`--release` in `toolArgs` (launch). |
| `deviceId` | string | `-d` injected by the proxy |
| `platform` | string | accepted for copy-paste compatibility with the Dart extension; **ignored** |
| `vmServiceUri` | string | attach |
| `vmServiceInfoFile` | string | attach |
| `stopOnEntry`, `noDebug` | boolean | |
| `debugSdkLibraries`, `debugExternalPackageLibraries`, `evaluateGettersInDebugViews`, `evaluateToStringInDebugViews`, `sendLogsToClient` | boolean | passed through |
| `useFvm` | boolean | strict fvm SDK resolution |
| `flutterSdkPath` | string | step 1 of SDK resolution |
| `reloadOnSave` | enum `changed|always|off` | default `changed` |
| `reloadOnSaveGlobs` | string[] | must start with a directory |
| `reloadOnSaveDebounceMs` | integer 10-5000 | default 200 |
| `openDevTools` | enum `never|inspector|performance|cpu-profiler|memory|network|logging` | default `never` |
| `logFile` | string | |

**`flutterMode` / `platform` (planner research):** Zed's `dart` extension (`dart@fba74df src/dart.rs`) defaults `flutterMode` to `"debug"` and `platform` to `"web"` and forwards both. The Flutter debug adapter (`flutter_tools/lib/src/debug_adapters/*`, Flutter 3.47.9; grepped: no occurrence of either key) reads neither. In VS Code, Dart-Code translates `flutterMode` into `--profile`/`--release`. So with the Dart extension `flutterMode: "profile"` silently does nothing; `FlutterRun` implements the Dart-Code behaviour (§4.2). `platform` has no `flutter run` equivalent; we accept and ignore it.

### 4.12 Cross-platform notes

- **Paths:** compare with `pathKey` (lower-case on Windows **and** macOS; case-sensitive on Linux); the session file stores native-separator canonical paths; the device-store hash uses `pathKey`. UNC and 8.3 names are not normalised (documented limitation). `canonicalDirectory` resolves symlinks (macOS `/tmp` → `/private/tmp`, Windows junctions).
- **Line endings:** generated files LF; readers accept CRLF.
- **`.bat`:** §4.4. `flutter.bat` first on Windows; `PATHEXT` honoured by `findExecutableOnPath`.
- **Windows `$ZED_WORKTREE_ROOT`** with spaces works since Zed commit 01448f56.
- **Control channel:** loopback TCP everywhere; no Unix sockets, named pipes or signals.
- **Process trees:** POSIX `ps -A -o pid=,ppid=` (+ start time for the PID-reuse guard; Linux falls back to `/proc/*/stat`); Windows `taskkill /PID n /T /F` on the adapter pid only.
- **Home/state dirs:** `HOME` / `USERPROFILE`; Linux honours `XDG_STATE_HOME`.
- **GUI-launched Zed has no login-shell PATH:** the extension passes `worktree.shell_env()` to the proxy; tasks need `flutter_run` on the shell PATH (D1). `doctor` prints PATH findings and the per-OS fix.
- **macOS Gatekeeper:** files fetched by Zed's HTTP client are not quarantined; a browser-downloaded release binary is: README documents `xattr -d com.apple.quarantine <file>`. CI copies the compiled exe and runs it, plus `codesign -dv` (unverified on arm64 until the first run).
- **Terminal colour:** CLI uses ANSI only when stdout is a TTY and `NO_COLOR` is unset; DAP notices always use ANSI.
- **Ctrl-C:** interactive commands handle `ProcessSignal.sigint` (works on Windows too) and exit 130; this is user interaction, not control signalling.

---

## 5. Sequence diagrams

### 5.1 Launch

```
User      Zed                 Extension (wasm)       flutter_run dap            flutter debug_adapter       App
 │ F4      │                          │                    │                          │                    │
 ├────────▶│ resolve scenario         │                    │                          │                    │
 │         ├─dap_request_kind────────▶│ launch             │                          │                    │
 │         ├─get_dap_binary──────────▶│ user path/PATH/download                       │                    │
 │         │◀─cmd=flutter_run dap ...──┤ + env + req args   │                          │                    │
 │         ├─spawn (stdio)────────────────────────────────▶│ resolve SDK, spawn ─────▶│ (waits for client) │
 │         │                                               │ ControlServer + session file(appStarted=false)│
 │         │◀─output: PATH notice (if flutter_run not on PATH), device source ───────────┤                    │
 │         ├─initialize───────────────────────────────────▶│ pass through ───────────▶│                    │
 │         │◀─response / initialized event────────────────┤◀─────────────────────────┤                    │
 │         ├─launch{program,toolArgs,deviceId,reloadOnSave..}▶ rewrite: strip own keys,│                    │
 │         │                                               │ inject -d <id> ─────────▶│ flutter run --machine ─▶ build
 │         ├─setBreakpoints / configurationDone───────────▶│ ─────────────────────────▶│                    │
 │         │◀─events: flutter.appStart, dart.debuggerUris──┤ capture mode/device/uri ◀┤                    │
 │         │                                               │ rewrite session file     │                    │
 │         │◀─flutter.appStarted───────────────────────────┤ appStarted=true → arm ReloadOnSaveWatcher    │
 │         │                                               │ (lib/ etc.), openDevTools page (once) if set │
```

### 5.2 Reload from a task

```
User  Zed(keymap ctrl-f5)  flutter_run reload (task terminal)   session files / ControlServer     DapProxy        adapter
 ├────▶│ task::Spawn "Flutter: Hot Reload"                     │                                  │               │
 │     ├─spawn────────────▶│ list <state>/sessions/*.json, ping all concurrently, prune stale, matchSessions(cwd),
 │     │                   │ keep eligible (alive, flutter, appStarted)
 │     │                   ├─TCP 127.0.0.1:port {"v":1,"token",cmd:"reload"}────▶│ constant-time token check
 │     │                   │                                    ├─HotActions.reload('manual')──▶│ inject hotReload (seq ≥1e9)
 │     │                   │ (after 3 s: "Waiting... paused at a breakpoint?")   │               ├──────────────▶│
 │     │◀ output "Reloaded 1 of 754 libraries…" (adapter's own output event) ◀───────────────────┤◀──────────────┤
 │     │                   │                                    │◀──response swallowed (request_seq ≥1e9)─┤
 │     │                   │◀─{"ok":true,"result":{"durationMs":593}}┤
 │     │   prints "Hot reload: linux sample_app ok in 0.6 s", exit 0 (tab hides on success; stays on failure)
```

### 5.3 Reload on save

```
Editor saves lib/a.dart → OS fs event → package:watcher (lib/, globs' dirs only) → PathFilter → hash changed?
   → ReloadCoalescer.notifyChange() ──(debounce 200 ms)──▶ [nothing in flight] ──▶ notice "[flutter_run] Hot reload on save: lib/a.dart"
   → HotActions.reload('save') → inject hotReload{reason:"save"} → adapter prints "Reloaded …" (Zed console)
   changes during the reload, or a manual restart in flight → pendingAfter=true → exactly one more reload afterwards
   response success:false → notice "Error: Hot reload failed: <message>. Try the task "Flutter: Hot Restart"."
```

### 5.4 Stop (Zed's real path)

```
Zed Stop button / window close
   ├─terminate─────────────────────────▶ DapProxy: delete session file, stop control accepts, snapshot descendants,
   │                                      forward terminate ──▶ adapter ──▶ app.stop ──▶ flutter_tester exits
   │                                      adapter response arrives: HOLD it; forward `terminated` event when it comes
   │                                      stop watcher, close control server, sweep survivors (terminateTree) [≤5 s total]
   │◀─terminate response (now relayed)───┤
   ├─Zed kills the proxy process (SIGKILL / TerminateProcess)          ← nothing needed to run after this point
   │
 Variant: `disconnect` without terminate → inject terminate (≤5 s) → forward disconnect → wait adapter exit → same cleanup.
 Variant: stdin EOF / adapter crash → same cleanup without a client response (crash adds output + `terminated`).
```

---
## 6. Work packages

Order: **WP0 first** (everything depends on `common/`). Then **WP1-WP9 in parallel** (9 agents). Then **WP10a** (composition) and **WP10b** (integration tests; may start in parallel with WP10a against the CLI contract in §4 and finishes after WP10a merges; §4.2a must be filled in before WP10b test 4 is finalised). Model/effort for all agents per CLAUDE.md: Sonnet / medium. Reviewers are never the authors.

Common acceptance for every WP (not repeated): `dart format --set-exit-if-changed` on owned files; `dart analyze --fatal-infos` clean for owned files; `dart test --exclude-tags integration test/unit/<module>` green; no imports across modules; no stdout writes; the final report lists files created, the public API actually exposed (any deviation from this plan), and tests run with real output.

### WP0 - Scaffold and `common/` (blocks everything)

**Owner:** agent "scaffold". **Depends on:** none. **May read:** this plan, `spike/`.

Files: see matrix. `cli/pubspec.yaml` (versions verified on pub.dev on 2026-11-03; `dart pub get` resolved them together under Dart 3.13.7 in a scratch project):

```yaml
name: flutter_run
description: Flutter Run & Debug in Zed - DAP proxy and CLI (hot reload, reload on save, devices, DevTools).
version: 0.1.0
repository: https://github.com/sawongam/zed-flutter-run
issue_tracker: https://github.com/sawongam/zed-flutter-run/issues
environment:
  sdk: ^3.8.0          # runtime deps need >=3.5; dev deps (test 1.33) need 3.11 - fine for `pub global activate`
executables:
  flutter_run:
dependencies:
  args: ^2.7.0
  async: ^2.13.1
  collection: ^1.19.1
  crypto: ^3.0.8
  glob: ^2.2.0
  meta: ^1.19.0
  path: ^1.9.1
  watcher: ^1.2.1
  yaml: ^3.1.4
dev_dependencies:
  fake_async: ^1.3.3
  json_schema: ^5.2.2      # draft-07 validation in tests (exists on pub.dev, 5.2.2)
  lints: ^6.1.0
  test: ^1.33.0
```
Commit `pubspec.lock`. `analysis_options.yaml`: `include: package:lints/recommended.yaml`, strict-casts/strict-inference/strict-raw-types, extra lints `prefer_final_locals`, `avoid_print`, `unawaited_futures`, `always_declare_return_types`, `prefer_single_quotes`, `directives_ordering`. `dart_test.yaml`:

```yaml
tags:
  integration:          # flutter-tester suite (Linux CI)
    timeout: 5m
  integration-dart:     # dart debug_adapter suite + no-Flutter CLI e2e (Linux, macOS, Windows CI)
    timeout: 5m
```
`fixtures/dart_console/` - `pubspec.yaml` (`name: dart_console_fixture`, `sdk: ^3.8.0`, no deps), `bin/main.dart` (~30 lines): `int square(int n)`, `computeTotal(List<int>)` with locals `total`, `i` and a line marked `// BREAKPOINT_TARGET` (integration tests scan for the marker; no hard-coded line numbers), a call `square(n)` on the line after the marker, prints `TOTAL: <n>`, exits 0; plus `README.md` stating the contract.

**Public interface (`cli/lib/src/common`):**

```dart
// json_types.dart
typedef Json = Map<String, Object?>;

// version.dart
const String packageVersion = '0.1.0';          // test asserts == pubspec.yaml version
const int controlProtocolVersion = 1;
const int sessionFileVersion = 1;
const String adapterName = 'FlutterRun';
const String toolName = 'flutter_run';
const String envPrefix = 'FLUTTER_RUN_';
const String stateDirEnv = 'FLUTTER_RUN_STATE_DIR';

// errors.dart
abstract final class ExitCodes {
  static const ok = 0, internal = 1, usage = 2, noSession = 3, sessionError = 4, timeout = 5,
      sdkNotFound = 6, deviceError = 7, projectNotFound = 8, manualActionRequired = 9,
      externalToolFailed = 10, interrupted = 130;
}
class FlutterRunException implements Exception {
  const FlutterRunException(this.message, {this.exitCode = ExitCodes.internal, this.hint, this.cause});
  final String message; final int exitCode; final String? hint; final Object? cause;
  @override String toString() => message;
}
class UsageError extends FlutterRunException { const UsageError(String message, {String? hint}); }                 // 2
class NoSessionException extends FlutterRunException { const NoSessionException(String message, {String? hint}); }   // 3
class SessionRequestException extends FlutterRunException { const SessionRequestException(String message, {String? hint}); } // 4
class RequestTimeoutException extends FlutterRunException { const RequestTimeoutException(String message, {String? hint}); } // 5
class SdkNotFoundException extends FlutterRunException { const SdkNotFoundException(String message, {this.tried = const [], String? hint}); final List<String> tried; } // 6
class DeviceException extends FlutterRunException { const DeviceException(String message, {String? hint}); }         // 7
class ProjectNotFoundException extends FlutterRunException { const ProjectNotFoundException(String message, {String? hint}); } // 8
class ManualActionRequired extends FlutterRunException { const ManualActionRequired(String message, {String? hint}); } // 9
class ExternalToolException extends FlutterRunException { const ExternalToolException(String message, {String? hint, Object? cause}); } // 10

// logger.dart
enum LogLevel { error, warn, info, debug, trace }
class Logger {
  Logger({LogLevel level = LogLevel.info, IOSink? stderrSink, String? logFilePath, DateTime Function()? clock});
  factory Logger.silent();
  factory Logger.capturing(List<String> sink, {LogLevel level = LogLevel.trace});   // for tests
  LogLevel get level;
  void error(String m, [Object? error, StackTrace? st]);  void warn(String m);  void info(String m);
  void debug(String m);  void trace(String m);
  void dap(String direction, Object? message);       // file-only; 'C>A','A>C','INJ','SYN'
  Future<void> close();
  static LogLevel levelFromName(String? name, {LogLevel fallback = LogLevel.info});
}

// host_environment.dart
enum HostOs { linux, macos, windows }
class HostEnvironment {
  HostEnvironment({required this.os, required Map<String, String> environment,
      required this.currentDirectory, String? homeOverride});
  factory HostEnvironment.system();
  final HostOs os; final Map<String, String> environment; final String currentDirectory;
  bool get isWindows;  bool get pathsCaseInsensitive;      // windows || macos
  String? env(String name);                                 // case-insensitive on Windows
  String? get home;                                         // HOME / USERPROFILE
  path.Context get pathContext;                             // posix or windows style by `os`
  HostEnvironment copyWith({HostOs? os, Map<String, String>? environment, String? currentDirectory});
}

// console.dart
abstract interface class Console {
  void out(String line);  void err(String line);
  bool get isInteractive;      // stdin AND stdout are terminals
  bool get useColor;           // stdout is a TTY and NO_COLOR unset
  Future<String?> readLine();  // null at EOF
}
class SystemConsole implements Console { SystemConsole({bool? color}); ... }
class MemoryConsole implements Console {
  MemoryConsole({List<String> input = const [], bool interactive = false});
  final List<String> outLines = [], errLines = [];
}

// paths.dart  (all take HostEnvironment so Windows rules are testable on Linux)
String canonicalDirectory(String path, HostEnvironment env);
String pathKey(String path, HostEnvironment env);
bool pathsEqual(String a, String b, HostEnvironment env);
bool isWithin(String parent, String child, HostEnvironment env);   // equal => true
String? findProjectRoot(String startDir, HostEnvironment env);     // nearest ancestor (inclusive) with pubspec.yaml
String? findUpwards(String startDir, String relativePath, HostEnvironment env);
String projectRootHash(String projectRoot, HostEnvironment env);   // first 16 hex of sha256(pathKey)
String? findExecutableOnPath(String name, HostEnvironment env);   // PATH scan; PATHEXT on Windows (.exe .bat .cmd); returns first hit
String stateBaseDirectory(HostEnvironment env);                    // $FLUTTER_RUN_STATE_DIR | XDG | Library/Application Support | %LOCALAPPDATA%

// files.dart
Future<void> atomicWriteString(String path, String content, {HostEnvironment? env});   // temp + rename, retry 10x50ms
Future<void> ensureOwnerOnlyDirectory(String path, HostEnvironment env);               // mkdir -p + chmod 700 (POSIX)

// global_options.dart
class GlobalOptions {
  const GlobalOptions({this.verbose = false, this.project, this.flutterSdk});
  final bool verbose; final String? project; final String? flutterSdk;
  static void addTo(ArgParser parser);                   // --verbose/-v, --project, --flutter-sdk
  factory GlobalOptions.of(Command<Object?> command);    // merges runner's globalResults and the command's own results (command wins)
}
```
(There is no shared message table; text lives next to the code, §3 rule 4.)

**Acceptance (WP0):** `cd cli && dart pub get && dart analyze && dart test test/unit/common` pass; tests cover exit-code values, `Logger` level filtering and file sink (no stdout), Windows case-insensitive env lookup, `paths.dart` with a fake Windows env (`C:\Users\Me\App` vs `c:\users\me\app`, trailing separators, `..`), `isWithin` edge cases (`/a/b` vs `/a/bc`), `findProjectRoot` with temp dirs, `findExecutableOnPath` (POSIX temp dir + fake Windows PATHEXT order), `stateBaseDirectory` for all three OSes and the override, `atomicWriteString` (no partial file visible), directory mode 0700 on POSIX, `version.dart == pubspec.yaml`; `cd fixtures/dart_console && dart pub get && dart run bin/main.dart` prints `TOTAL:` and exits 0. The orchestrator re-runs everything and then releases WP1-WP9.

---

### WP1 - DAP framing + proxy core (`cli/lib/src/dap/**`)

**Owner:** agent "dap". **Depends on:** WP0. **May read:** `spike/lib/framing.dart`, `spike/bin/proxy.dart`, `docs/research/zed-dap-client-behaviour.md`, `docs/research/flutter-tooling-protocols.md` §1, ADR 0006 D2/D3.

```dart
// messages.dart
typedef DapJson = Map<String, Object?>;
bool isRequest(DapJson m);  bool isResponse(DapJson m);  bool isEvent(DapJson m);
DapJson makeResponse({required int requestSeq, required String command, required bool success, String? message, Json? body, required int seq});
DapJson makeOutputEvent(String text, {String category = 'console', required int seq});   // always has body

// framing.dart
class DapFramingException implements Exception { DapFramingException(this.message); final String message; }
class DapFrameDecoder { List<DapJson> add(List<int> chunk); }            // incremental; throws DapFramingException
List<int> encodeDapMessage(DapJson message);                              // 'Content-Length: N\r\n\r\n' + utf8 json

// channel.dart
abstract interface class DapChannel {
  Stream<DapJson> get messages;          // ends when input closes; errors => DapFramingException
  void send(DapJson message);
  Future<void> flush();  Future<void> close();
}
class StreamDapChannel implements DapChannel {
  StreamDapChannel(Stream<List<int>> input, StreamSink<List<int>> output, {Logger? logger, String label = ''});
}
/// What the proxy needs from the adapter child process. WP10a adapts WP3's ManagedProcess to this.
abstract interface class AdapterConnection {
  DapChannel get channel;  int get pid;  Future<int> get exitCode;
  Stream<String> get stderrLines;                       // already decoded; proxy mirrors/logs them
  Future<Set<int>> snapshotDescendants();               // POSIX: descendants; Windows: {pid}
  Future<void> terminateTree({Set<int> extraPids = const {}});
}

// injected_requests.dart  (replaces renumbering; ADR 0006 D3)
class InjectedRequests {
  InjectedRequests({int firstSeq = 1000000000});
  InjectedRequest create(String command, Json? arguments);   // allocates seq; .message to send; .response future
  /// null => not ours, forward unchanged; otherwise the response was consumed (swallowed).
  bool consumeResponse(DapJson adapterResponse);             // completes the future; also swallows late responses
  void markTimedOut(int seq);                                // keeps seq in a bounded late set (64)
  bool clientSeqCollides(DapJson clientRequest);             // seq >= firstSeq
  int nextSyntheticSeq();                                    // client-bound counter, starts at firstSeq
}
class InjectedRequest { final int seq; final DapJson message; final Future<DapJson> response; }

// launch_rewriter.dart
enum DapKind { flutter, dart }
enum DeviceSource { toolArgs, config, env, saved, none }
class RewriteResult {
  final Json arguments;            // what goes to the adapter
  final Json ownConfig;            // stripped own keys (values as given)
  final String? deviceId;  final DeviceSource deviceSource;  final List<String> notes;
}
class LaunchRewriter {
  LaunchRewriter({required DapKind kind, required String cwd, required Map<String, String> environment,
      required String? Function() savedDevice, Logger? logger});
  RewriteResult rewrite(String request /* 'launch' | 'attach' */, Json arguments);
  /// Single source of truth (12 keys): flutterSdkPath, deviceId, reloadOnSave, reloadOnSaveGlobs,
  /// reloadOnSaveDebounceMs, openDevTools, logFile, useFvm, adapter, label, flutterMode, platform.
  static const ownKeys = {...};
}

// device_hints.dart (pure)
String? deviceHintFor(String adapterText);     // null unless it matches Flutter's "more than one device" / "no devices" phrases; returns the full notice sentence

// proxy_state.dart
class ProxyState {   // immutable snapshot + copyWith
  final String request; final DapKind kind; final String cwd;
  final String? deviceId, mode, appId, vmServiceUri; final bool appStarted, ended;
}
sealed class ProxyEvent {}
class LaunchRewritten extends ProxyEvent { LaunchRewritten(this.request, this.result); final String request; final RewriteResult result; }
class StateChanged extends ProxyEvent { StateChanged(this.state); final ProxyState state; }
class DebuggerUris extends ProxyEvent { DebuggerUris(this.vmServiceUri, {required this.isFirst}); final String vmServiceUri; final bool isFirst; }
class AppStarted extends ProxyEvent {}
class SessionEnded extends ProxyEvent {}

// notices.dart
enum NoticeLevel { info, warn, error }
String formatNotice(String text, NoticeLevel level);   // '\x1b[36m[flutter_run] text\x1b[0m\n'; warn/error add 'Warning: ' / 'Error: ' after the prefix; multi-line prefixes each line

// hot_actions.dart
/// Contract: inject() returns the adapter's response map INCLUDING success:false responses; it throws only
/// TimeoutException (no response in time) and StateError (session closed). HotActions maps both to HotResult.
abstract interface class RequestInjector {
  Future<DapJson> inject(String command, [Json? arguments, Duration? timeout]);
  bool get appStarted;
  void notice(String text, [NoticeLevel level = NoticeLevel.info]);
}
enum HotError { notStarted, busy, adapterError, timeout, sessionEnded }
class HotResult { final bool ok; final HotError? error; final String? message; final Duration duration; final bool coalesced; }
class HotActions {
  HotActions(RequestInjector injector, {Duration timeout = const Duration(seconds: 120),
      Duration waitingNoticeAfter = const Duration(seconds: 3)});
  Future<HotResult> reload({String reason = 'manual'});   // never throws
  Future<HotResult> restart({String reason = 'manual'});
  void noteClientRestart({required bool started});        // DapProxy calls on client `restart` request/response
  bool get busy;
}

// proxy.dart
class ProxyOptions { const ProxyOptions({required this.kind, required this.cwd,
    this.terminateTimeout = const Duration(seconds: 5), this.exitWait = const Duration(seconds: 5),
    this.initializeTimeout = const Duration(seconds: 10)}); ... }
class DapProxy implements RequestInjector {
  DapProxy({required DapChannel client, required AdapterConnection adapter, required ProxyOptions options,
      required LaunchRewriter rewriter, Future<void> Function()? onShutdownStarted /* WP10a: deletes session file */,
      Future<void> Function()? onShutdownCleanup /* stop watcher + control server */, Logger? logger});
  Stream<ProxyEvent> get events;  ProxyState get state;
  Future<int> run();                       // completes with the exit code once fully shut down
  Future<void> shutdown({String reason = 'requested'});
  @override Future<DapJson> inject(String command, [Json? arguments, Duration? timeout]);
  @override void notice(String text, [NoticeLevel level = NoticeLevel.info]);
}
```
**Behaviour:** exactly §4.2 (framing, no renumbering, injected range, rewrite, device hints, state capture, injected requests, notices, shutdown per D2). `DapProxy` must run against in-memory fake `DapChannel`/`AdapterConnection`.

**Acceptance (tests in `cli/test/unit/dap`):** framing (1-byte chunks; 3 messages in one chunk; multi-byte UTF-8 split across chunks; extra headers; invalid length; non-ASCII round trip); `InjectedRequests` (seqs ≥ 1e9, responses swallowed, client responses untouched, late response swallowed after `markTimedOut`, client seq ≥ 1e9 flagged); `LaunchRewriter` tables (every own key stripped incl. `flutterMode`/`platform`; device precedence config > env > saved > none; `-d`, `--device-id`, `--device-id=x`, `-dx` suppress; attach with `vmServiceUri` ignores env/saved; kind dart never injects; `flutterMode` → flag without duplication; defaults; unknown keys untouched); `deviceHintFor` on real Flutter phrases and non-matches; `HotActions` (not started, join-on-reload, busy for restart-during-anything and manual-reload-during-restart, save-reload waits for a restart, client restart flag, timeout keeps busy until the late response, waiting notice at 3 s, "not supported" hint; fake_async); `DapProxy` with fakes: pass-through of events/reverse requests, state capture and events, **terminate path** (forward, hold response until `terminated` or 5 s, `onShutdownStarted` before forwarding, cleanup before relaying, response synthesized when the adapter dies), `disconnect`-without-terminate (inject terminate in launch mode, not in attach mode, not if the client already sent `terminate`), `Stopping the app...` notice after 1 s, EOF path, adapter-crash path (stderr tail `output`, `terminated`, flush), no `initialize` response in 10 s → notice, startup-failure responder helper if placed here, `terminateTree` only as last resort, well-formed notices with `body`, idempotent shutdown. **Must not touch:** process spawning (no `dart:io Process` in this module).

---

### WP2 - Control channel, session files, `reload`/`restart`/`status` (`cli/lib/src/control/**`)

**Owner:** agent "control". **Depends on:** WP0. **May read:** `spike/bin/proxy.dart`, `spike/bin/reload.dart`.

```dart
// session_info.dart
class SessionInfo {
  const SessionInfo({required this.pid, required this.port, required this.token, required this.projectRoot,
      required this.cwd, required this.kind, required this.request, required this.startedAt,
      this.deviceId, this.mode, this.vmServiceUri, this.appStarted = false});
  final int pid, port; final String token, projectRoot, cwd, kind, request; final DateTime startedAt;
  final String? deviceId, mode, vmServiceUri; final bool appStarted;
  Json toJson();  factory SessionInfo.fromJson(Json json);   // FormatException on bad/unsupported version
  SessionInfo copyWith({...});
}

// session_paths.dart (pure)
String sessionsDirectory(HostEnvironment env);               // <stateBaseDirectory>/sessions
String sessionFileName(int pid);                             // '<pid>.json'

// control_protocol.dart
enum ControlErrorCode { badRequest, unsupportedVersion, unauthorized, payloadTooLarge, unknownCommand,
    appNotStarted, busy, adapterError, timeout, sessionEnded, internal;  String get wire; }
class ControlException implements Exception { const ControlException(this.code, this.message); final ControlErrorCode code; final String message; }
const int maxControlLineBytes = 64 * 1024;
/// Implemented by WP10a on top of DapProxy/HotActions.
abstract interface class SessionControl {
  Future<Json> reload(Json args);          // throws ControlException
  Future<Json> restart(Json args);
  Json ping();
}

// control_server.dart
class ControlServer {
  static Future<ControlServer> start({required SessionControl control, Logger? logger,
      Duration requestLineTimeout = const Duration(seconds: 10), String? tokenOverrideForTests});
  int get port;  String get token;
  Future<void> close();
}
bool constantTimeEquals(String a, String b);

// session_store.dart
class SessionHandle { Future<void> update(SessionInfo info); Future<void> delete(); String get path; }
class SessionRecord { final SessionInfo info; final bool unresponsive; final String path; }
class SessionStore {
  SessionStore(HostEnvironment env, {Logger? logger, ControlClient? probe});
  Future<SessionHandle> create(SessionInfo info);                      // dir 0700, atomic file
  Future<List<SessionRecord>> list({bool prune = true});               // concurrent ping; deletes stale
}

// control_client.dart
class ControlResponse { final bool ok; final Json? result; final ControlErrorCode? errorCode; final String? errorMessage; }
class ControlClient {
  ControlClient({Duration connectTimeout = const Duration(seconds: 2)});
  Future<ControlResponse> send(SessionInfo session, String command, {Json args = const {}, Duration timeout = const Duration(seconds: 120)});
  Future<PingOutcome> ping(SessionInfo s, {Duration timeout = const Duration(seconds: 2)});   // alive | stale | unresponsive
}
enum PingOutcome { alive, stale, unresponsive }

// session_matcher.dart (pure)
List<T> matchSessions<T>(List<T> sessions, String Function(T) projectRootOf, String directory, HostEnvironment env);

// commands (names fixed)
class ReloadCommand extends Command<int> {   // 'reload'
  ReloadCommand({required SessionStore store, required ControlClient client, required HostEnvironment env,
      required Console console, Duration waitingNoticeAfter = const Duration(seconds: 3)});
}
class RestartCommand extends Command<int> { /* 'restart', same ctor */ }
class StatusCommand extends Command<int> { /* 'status' [--json], ctor: store, env, console; reads session files + ping */ }
/// Shared helper for WP10a (DevTools wiring): live matching sessions for a directory.
Future<List<SessionRecord>> findSessionsFor(SessionStore store, String directory, HostEnvironment env);
```
**Acceptance:** `SessionInfo` round trip and version-2 rejection; `<pid>.json` naming; atomic update (concurrent reader loop sees old or new, never partial; no `*.tmp-*` left); directory mode 0700 (skip on Windows); server auth: wrong token → `unauthorized`, 70 KiB line → `payload_too_large`, non-JSON → `bad_request`, unknown command with valid token → `unknown_command`, `v:2` → `unsupported_version`, request line never completed → closed after the (test-short) timeout, `constantTimeEquals`; client↔server round trip with a fake `SessionControl` incl. a slow handler; pruning: closed port deleted (connect refused **and** connect timeout both count as stale), connected-but-silent server kept as `unresponsive`, N stale files pinged concurrently (fake_async elapsed ≈ one timeout); `matchSessions` matrix (equal, child, parent, sibling `/a/b` vs `/a/bc`, Windows case); commands: no matching session → exit 3 with the §4.3 text; Dart-kind session skipped with note; unresponsive skipped with hint; not-started sessions skipped; two Flutter sessions both reloaded with one line each; one failing → exit 4 while the other is still reported; all skipped → exit 4; timeout → exit 5; waiting notice once after the delay; result-line format `Hot reload: <device> <project> ok in 0.6 s`; `status --json` shape. **Must not touch:** `dap/**`.

---

### WP3 - SDK discovery + process launching + tree kill (`cli/lib/src/sdk/**`)

**Owner:** agent "sdk". **Depends on:** WP0. **May read:** §4.4, `docs/research/flutter-tooling-protocols.md` §6.

```dart
// sdk_steps.dart / sdk_resolver.dart
enum StepOutcome { skipped, notFound, invalid, found }
class ResolutionStep { const ResolutionStep(this.id, this.description, this.outcome, [this.detail]); final String id, description; final StepOutcome outcome; final String? detail; }
enum SdkKind { flutter, dart }
class FlutterSdk {
  final String? root;                 // null for non-resolvable shims
  final String flutterExecutable;     // absolute path to bin/flutter(.bat) or the shim as found
  final String? bundledDartExecutable;
  final String sourceStep;            // ResolutionStep.id
  String? get flutterVersion;  String? get dartVersion;    // from <root>/version files, no subprocess
}
class SdkResolution {
  final FlutterSdk? flutter;  final String? dartExecutable;   // set for SdkKind.dart
  final List<ResolutionStep> trace;
  String describeTrace();
}
class SdkResolver {
  SdkResolver(HostEnvironment env, {Logger? logger});
  Future<SdkResolution> resolve({required String projectDir, SdkKind kind = SdkKind.flutter,
      String? explicitSdkPath, bool strictFvm = false});     // never throws for "not found"
  Future<SdkResolution> resolveOrThrow({...same});            // SdkNotFoundException with tried list + hint
}

// process_spec.dart (pure)
class ProcessSpec { const ProcessSpec(this.executable, this.arguments, {this.workingDirectory}); final String executable; final List<String> arguments; final String? workingDirectory; }
ProcessSpec buildProcessSpec(String executable, List<String> args, HostEnvironment env);   // validates args for .bat/.cmd; never uses a shell
bool isBatchFile(String path);
void validateBatchArgument(String arg);                      // throws ArgumentError
final RegExp safeIdPattern;                                  // ^[A-Za-z0-9._:\-@]+$

// managed_process.dart
class ManagedProcess {
  static Future<ManagedProcess> start(ProcessSpec spec, {Map<String, String>? environment, Logger? logger});
  int get pid;  Stream<List<int>> get stdout;  Stream<List<int>> get stderr;  IOSink get stdin;
  Future<int> get exitCode;
  Future<Set<int>> snapshotDescendants();       // POSIX: descendants; Windows: {pid}
  Future<void> terminateTree({Set<int> extraPids = const {}, Duration grace = const Duration(seconds: 2)});
}
Future<ToolOutput> runTool(ProcessSpec spec, {Map<String, String>? environment, Duration timeout = const Duration(seconds: 60), Logger? logger});
class ToolOutput { const ToolOutput(this.exitCode, this.stdout, this.stderr); final int exitCode; final String stdout, stderr; }

// process_tree.dart
Map<int, List<int>> parsePsOutput(String psOutput);          // 'pid ppid [start]' lines
Set<int> collectDescendants(Map<int, List<int>> childrenOf, int root);
Future<ProcessTable> readProcessTable(HostEnvironment env);   // ps -A -o pid=,ppid=,lstart=; Linux /proc fallback
Future<void> killTree(int rootPid, Set<int> snapshot, HostEnvironment env, {Duration grace});   // PID-reuse guard, SIGTERM -> grace -> SIGKILL; Windows: taskkill /PID n /T /F
```
**Acceptance:** SDK matrix with temp dirs (fake SDK trees): every step 1-8 alone and in precedence order; `.fvm/flutter_sdk` from a subdirectory/ancestor; legacy `fvm_config.json`; `FVM_CACHE_PATH`; `.puro.json` + `PURO_ROOT`; PATH symlink resolved; PATH shim used as-is; strictFvm failure; invalid explicit path is an error; kind dart variants; error lists every tried step. **Windows (pure, fake `HostEnvironment(os: windows)`):** `flutter.bat` selection, `PATHEXT` order, fvm/puro cache paths, `buildProcessSpec` accepts normal args and rejects `& | % ^ " < > !`/newline for `.bat`, `safeIdPattern`. Process: `parsePsOutput`/`collectDescendants` golden tests; **a cross-platform real-process test that runs on Linux, macOS and Windows CI** (spawn `dart` running a tiny script that spawns a long-running child; `snapshotDescendants`, `terminateTree` kills the tree; on Windows asserts `taskkill /T` semantics); POSIX-only extras (SIGKILL escalation for a `trap '' TERM` child; PID-reuse guard with a fake process table); `runTool` timeout kills the child. **Must not touch:** `common/**`; no imports from `dap/**`.

---

### WP4 - Devices and emulators (`cli/lib/src/devices/**`)

**Owner:** agent "devices". **Depends on:** WP0. **May read:** §4.5, `docs/research/flutter-tooling-protocols.md` §2.

```dart
// flutter_device.dart
class FlutterDevice {
  const FlutterDevice({required this.id, required this.name, required this.platform, this.category, this.emulator = false, this.sdk, this.isSupported = true});
  final String id, name, platform; final String? category, sdk; final bool emulator, isSupported;
  factory FlutterDevice.fromMachineJson(Json j);  Json toJson();
}
List<FlutterDevice> parseDevicesMachineOutput(String stdout);   // skips noise before first '['; ExternalToolException on garbage

// device_lister.dart
typedef FlutterRunner = Future<FlutterToolResult> Function(List<String> flutterArgs, {String? workingDirectory, Duration? timeout});
class FlutterToolResult { const FlutterToolResult(this.exitCode, this.stdout, this.stderr); final int exitCode; final String stdout, stderr; }
typedef FlutterRunnerFactory = Future<FlutterRunner> Function({String? projectDir, String? explicitSdk});   // WP10a: SDK resolution + runTool
Future<List<FlutterDevice>> listDevices(FlutterRunner run, {String? workingDirectory});

// emulators.dart
class Emulator { const Emulator({required this.id, required this.name, required this.manufacturer, required this.platform}); ... }
List<Emulator> parseEmulatorsOutput(String text);              // tolerant regex, unparsable lines ignored
Future<List<Emulator>> listEmulators(FlutterRunner run, {String? workingDirectory});
Future<void> launchEmulator(FlutterRunner run, String id, {String? workingDirectory});   // validates id (safe-id regex, local copy)

// device_store.dart  (per-user state dir, ADR 0006 D7)
class SavedDevice { const SavedDevice({required this.deviceId, required this.name, required this.platform, required this.savedAt}); ...; Json toJson(); factory SavedDevice.fromJson(Json j); }
class DeviceStore {
  DeviceStore(HostEnvironment env, {Logger? logger});
  String filePath(String projectRoot);                  // <stateBaseDirectory>/devices/<projectRootHash>.json
  SavedDevice? readSync(String projectRoot);            // null on missing/invalid/unknown version (debug log)
  Future<void> write(String projectRoot, SavedDevice d);  // atomic; stores projectRoot too
  Future<bool> clear(String projectRoot);
}

// picker.dart
Future<T?> pickFromList<T>(List<T> items, String Function(T) label, Console console,
    {String? savedId, String Function(T)? idOf, Future<List<T>> Function()? rescan, int maxAttempts = 3});   // number | id | r | q

// commands (names fixed)
class DevicesCommand extends Command<int> {          // 'devices' [--json]
  DevicesCommand({required FlutterRunnerFactory runnerFor, required DeviceStore store, required HostEnvironment env, required Console console});
}
class SelectDeviceCommand extends Command<int> { /* 'select-device' [--device] [--clear]; same ctor */ }
class EmulatorsCommand extends Command<int> { /* 'emulators' [--launch <id>] [--json]; same ctor */ }
```
**Acceptance:** `parseDevicesMachineOutput` on real captured `flutter devices --machine` output (agent captures one into a test string; also with leading noise and the root-user warning), empty list, invalid JSON; `DeviceStore` round trip in a temp `FLUTTER_RUN_STATE_DIR`, same project via different case on a Windows fake env maps to one file, unknown version → null, clear; picker: number, id, `r` rescan, `q`, empty, three invalid → exit 2; commands with a fake `FlutterRunner` and `MemoryConsole`: `--device` valid/unknown (exit 7 lists ids), non-interactive without `--device` (exit 2), zero devices (exit 7 with the §4.2 text), no project (exit 8), `--clear`, saved-device confirmation wording, `devices --json` shape, flutter exit non-zero → exit 10, timeout message mentions the startup lock; emulators: parse sample output, `--launch` args, interactive pick, zero emulators message, id validation. **Must not touch:** `sdk/**` (use only the `FlutterRunner` typedef).

---

### WP5 - Reload-on-save watcher (`cli/lib/src/watch/**`)

**Owner:** agent "watch". **Depends on:** WP0. **May read:** §4.6, `docs/research/flutter-tooling-protocols.md` §5.

```dart
// reload_config.dart
enum ReloadOnSaveMode { changed, always, off }
class ReloadOnSaveConfig {
  const ReloadOnSaveConfig({this.mode = ReloadOnSaveMode.changed, this.globs = const [], this.debounce = const Duration(milliseconds: 200), this.warnings = const []});
  factory ReloadOnSaveConfig.fromOwnConfig(Json ownConfig);   // tolerant; bad values -> defaults + warnings
  final ReloadOnSaveMode mode; final List<String> globs; final Duration debounce; final List<String> warnings;
}

// path_filter.dart
class PathFilter {
  PathFilter({required String projectRoot, required HostEnvironment env, List<String> globs = const []});
  bool shouldTrigger(String absolutePath);      // .dart or glob; ignore rules beat globs; outside root => false
  bool isIgnored(String absolutePath);
  /// Allow-list: lib (+ bin for dart) + static prefixes of globs; existing dirs only is the watcher's job.
  static List<String> watchDirectories({required String projectRoot, required bool isDartProgram, required List<String> globs, required HostEnvironment env, List<String>? rejectedGlobs});
}

// content_hash.dart
class ContentHashTracker {
  ContentHashTracker({Future<List<int>?> Function(String path)? readFile, int maxBytes = 2 * 1024 * 1024});
  Future<bool> hasChanged(String path);          // first sight => true; updates stored hash; deleted => true once; >maxBytes => true
}

// coalescer.dart
enum ReloadResult { done, busy }
class ReloadCoalescer {
  ReloadCoalescer({required Duration debounce, required Future<ReloadResult> Function() reload, void Function(Object, StackTrace)? onError});
  void notifyChange();         // trailing debounce; one in flight; one follow-up; `busy` => retry after the in-flight action
  bool get inFlight;  Future<void> dispose();
}

// reload_on_save_watcher.dart
class ReloadOutcome { const ReloadOutcome({required this.ok, this.busy = false, this.message}); final bool ok, busy; final String? message; }
class ReloadOnSaveWatcher {
  ReloadOnSaveWatcher({required String projectRoot, required bool isDartProgram, required ReloadOnSaveConfig config, required HostEnvironment env,
      required Future<ReloadOutcome> Function() reload,                 // WP10a: HotActions.reload(reason:'save')
      required void Function(String text, {required bool isError}) notice,   // WP10a: DapProxy.notice
      Logger? logger, Stream<WatchEvent> Function(String directory)? watcherFactory});
  Future<void> start();     // no-op for mode off; prints the armed notice once
  Future<void> stop();
  bool get running;  List<String> get watchedDirectories;
}
```
**Acceptance:** `PathFilter` table (`.dart` yes, `a.g.dart` yes, `.dart_tool/x.dart`, `build/x.dart`, `.git/…`, hidden segments no, outside root no, glob `assets/**.json` yes but `build/assets/a.json` no, Windows separators/case); `watchDirectories` (lib; bin only for Dart; glob prefixes; `**.json` rejected; nonexistent dirs left to `start`; never `ios`, `android`, `build`); `ContentHashTracker` (first sight true, identical rewrite false, change true, delete true once, big file true); `ReloadCoalescer` with `fake_async` (burst → 1; event during run → exactly one more; never overlap; `busy` result retries after in-flight completes, no error; throwing reload doesn't wedge; dispose cancels); `ReloadOnSaveWatcher` with a fake `watcherFactory`: `changed` skips identical rewrite after first event, `always` reloads both, `off` starts nothing, only allow-listed directories get watchers (assert factory calls), armed notice names the directories, notice format `Hot reload on save: lib/a.dart` / `(+2 more)`, failure outcome → error notice and the watcher keeps running. One real-FS test (all OSes) with a temp dir and the real `DirectoryWatcher`, event-driven wait (completer + 10 s timeout, no fixed sleeps). **Must not touch:** `dap/**`.

---

### WP6 - DevTools (`cli/lib/src/devtools/**`)

**Owner:** agent "devtools". **Depends on:** WP0. **May read:** §4.7, `docs/research/flutter-tooling-protocols.md` §4.

```dart
// pages.dart
enum DevToolsPage { inspector('inspector'), performance('performance'), cpuProfiler('cpu-profiler'),
    memory('memory'), network('network'), logging('logging');
  const DevToolsPage(this.route);  final String route;
  static DevToolsPage? parse(String name); }       // accepts 'cpu-profiler', 'cpu_profiler', 'cpuprofiler'

// url_builder.dart (pure; one style)
Uri buildDdsDevToolsUrl(String vmServiceUri, DevToolsPage page);   // http://H:P/TOKEN=/devtools/<route>?uri=<enc ws>
String normalizeWsUri(String vmServiceUri);                         // accepts ws://…/ws, http://…/, …/TOKEN=
bool isSafeBrowserUrl(Uri url);                                     // http(s) to 127.0.0.1/localhost/[::1] only

// browser_opener.dart
class BrowserCommand { const BrowserCommand(this.executable, this.arguments); final String executable; final List<String> arguments; }
BrowserCommand browserCommandFor(HostOs os, String url);   // xdg-open | open | rundll32 url.dll,FileProtocolHandler
abstract interface class BrowserOpener { Future<void> open(Uri url); }     // throws ExternalToolException
class SystemBrowserOpener implements BrowserOpener { SystemBrowserOpener(HostEnvironment env, {Logger? logger}); }

// devtools_opener.dart
/// Used by the proxy for `openDevTools: <page>`.
Future<Uri> openDevToolsOnce(String vmServiceUri, DevToolsPage page, BrowserOpener opener, {Logger? logger});   // returns the URL even if opening failed (throws after carrying the URL in the exception)

// commands/devtools_command.dart
class VmServiceTarget { const VmServiceTarget({required this.vmServiceUri, this.deviceId, required this.sessionPid}); ... }
/// WP10a wires this to WP2 (session files; most recent startedAt with a vmServiceUri). Throws NoSessionException / SessionRequestException.
typedef VmServiceTargetResolver = Future<VmServiceTarget> Function({required String directory});
class DevToolsCommand extends Command<int> {            // 'devtools' [page] [--print]
  DevToolsCommand({required VmServiceTargetResolver resolveTarget, required BrowserOpener opener,
      required HostEnvironment env, required Console console});
}
```
**Acceptance:** URL builder golden tests for the three input forms, token containing `=`, `-`, `_`, IPv6 loopback `[::1]`, all pages; `isSafeBrowserUrl` rejects `file:`, `javascript:`, remote hosts; `browserCommandFor` per OS with a URL containing `&` and `=` (single argument, no shell); command with fakes: `--print` prints just the URL and opens nothing; default prints `Opening DevTools: <url>` then opens; browser failure → URL still printed, exit 10; no session → exit 3; no URI yet → exit 4 with the "still starting" text; unknown page → exit 2. The real-DDS GET check lives in WP10b. **Must not touch:** `control/**`, `sdk/**`.

---

### WP7 - `init` + templates (`cli/lib/src/init/**`)

**Owner:** agent "init". **Depends on:** WP0. **May read:** §4.8, `docs/research/zed-recent-changes-and-picker-ux.md` §6, the Zed default keymaps in the research clone.

```dart
// project_detect.dart
enum ProjectKind { flutter, dart }
class ProjectInfo { final String root, name; final ProjectKind kind; final bool usesFvm; final String dartEntry; }
ProjectInfo detectProject(String projectDir, HostEnvironment env);   // ProjectNotFoundException (exit 8) when no pubspec

// templates.dart  (pure; LF; deterministic order)
List<Json> debugScenarios(ProjectInfo p);
List<Json> zedTasks(ProjectInfo p);

// keymap.dart
String keymapSnippet(HostOs os, {bool keepZedRestartKey = false});   // JSON array text from §4.8
String keyTable();                                                    // F4/F5/Shift+F5/Ctrl+F5/Ctrl+Shift+F5 text from §4.8
String macosKeyNote();

// json_merge.dart
sealed class MergeResult {}
class MergeCreated extends MergeResult { final String content; }
class MergeUpdated extends MergeResult { final String content; final int added, kept; }
class MergeNeedsManual extends MergeResult { final String reason; final String snippet; }
MergeResult mergeLabeledArray(String? existingText, List<Json> additions);   // strict JSON only; key = 'label'
bool isStrictJson(String text);

// commands/init_command.dart
class InitCommand extends Command<int> {           // 'init' [--force] [--dry-run]
  InitCommand({required HostEnvironment env, required Console console, required String? Function() findFlutterRunOnPath /* WP10a: findExecutableOnPath */, required String pathFixHint /* WP10a: per-OS text */});
}
```
**Acceptance:** `detectProject` on temp pubspecs (flutter sdk dependency, `flutter:` section only, plain Dart, missing pubspec → exit 8, fvm markers); templates: keys per §4.8, labels unique, `adapter == "FlutterRun"`, `reloadOnSave` present on Debug/Run/Attach, tasks use only Zed `TaskTemplate` keys (allow-list copied from Zed source into the test), `reveal:"no_focus"`/`hide:"on_success"` on reload/restart, `$ZED_WORKTREE_ROOT` for cwd, Dart package gets one scenario and only the Doctor task; everything valid JSON; keymap snippets per OS parse and use only `task::Spawn`; `keepZedRestartKey` omits `ctrl-shift-f5`; `mergeLabeledArray`: absent → created; strict JSON with existing labels → only missing appended, order preserved, counts right; JSONC with `//`, trailing comma, empty file, root-object file → `MergeNeedsManual`; `InitCommand` end to end in a temp project: creates both files, second run adds 0, `--dry-run` writes nothing, JSONC file untouched + exit 9 + `Done with 1 manual step.`, `--force` writes `.bak` (numbered) then overwrites, key table and PATH check lines printed, PATH-missing hint shown. Validation of the generated JSON against `FlutterRun.json` is WP10a's `schema_test.dart` (this WP must not read `extension/`). **Must not touch:** `extension/**`.

---

### WP8 - Rust extension (`extension/**`)

**Owner:** agent "rust". **Depends on:** none (reads §4.10-§4.11; may read the research clones under `/tmp/claude-0/…/scratchpad/research-a/{c070,dart,zed}` for exact API types). Toolchain present: rustc 1.97, target `wasm32-wasip2`.

`Cargo.toml`:
```toml
[package]
name = "flutter_run_debugger"
version = "0.1.0"
edition = "2024"
publish = false
license = "BSD-3-Clause"
[lib]
path = "src/lib.rs"
crate-type = ["cdylib"]
[dependencies]
zed_extension_api = "0.7.0"
serde_json = "1"
sha2 = "0.11"        # 0.11.1 verified to build for wasm32-wasip2 (reviewer); NOTE: `format!("{:x}", digest)` does not compile with 0.11 - hex-encode by hand
```
`extension.toml`:
```toml
id = "flutter-run-debugger"
name = "Flutter Run & Debug"
version = "0.1.0"
schema_version = 1
authors = ["Flutter Run & Debug contributors"]
description = "Flutter Run & Debug: hot reload, reload on save, device picker and DevTools for Zed."
repository = "https://github.com/sawongam/zed-flutter-run"

[debug_adapters.FlutterRun]
# schema: debug_adapter_schemas/FlutterRun.json (default path)

[[capabilities]]            # documentation of intent only; the grant comes from the user's Zed settings
kind = "download_file"
host = "github.com"
path = ["sawongam", "zed-flutter-run", "**"]
```
No `[debug_locators]`. `LICENSE`: unmodified standard BSD-3-Clause text, `Copyright (c) 2026, the Flutter Run & Debug contributors`.

**Public interface (Rust):**
```rust
// proxy_args.rs
pub enum Kind { Flutter, Dart }   pub enum Request { Launch, Attach }
pub struct ProxyConfig { pub cwd: Option<String>, pub kind: Kind, pub flutter_sdk_path: Option<String>,
    pub use_fvm: bool, pub log_file: Option<String>, pub env: Vec<(String,String)>, pub request: Request }
pub fn parse_config(config_json: &str) -> Result<ProxyConfig, String>;        // lenient defaults per §4.10; errors for bad `type`/env types
pub fn request_kind(config: &serde_json::Value) -> Result<Request, String>;    // dap_request_kind
pub fn build_proxy_args(cfg: &ProxyConfig, cwd: &str, client_version: &str) -> Vec<String>;   // ["dap","--cwd",cwd,"--kind",…]
pub fn merge_env(shell_env: &[(String,String)], config_env: &[(String,String)]) -> Vec<(String,String)>;
pub struct ScenarioSpec { pub label: String, pub adapter: String, pub config: serde_json::Value }
pub fn config_to_scenario(label: &str, launch: Option<LaunchSpec>, stop_on_entry: Option<bool>) -> ScenarioSpec;
pub struct LaunchSpec<'a> { pub program: &'a str, pub cwd: Option<&'a str>, pub args: &'a [String], pub envs: &'a [(String,String)] }

// install.rs
pub const PROXY_VERSION: &str = "0.1.0";   pub const REPO: &str = "sawongam/zed-flutter-run";
pub const PUBLISHED_ON_PUB: bool = false;
pub enum Os { Mac, Linux, Windows }   pub enum Arch { Aarch64, X8664, X86 }
pub fn asset_name(version: &str, os: Os, arch: Arch) -> Result<String, String>;   // (Windows, Aarch64) -> windows-x64 asset; X86 -> Err
pub fn download_url(version: &str, asset: &str) -> String;                          // https://github.com/<REPO>/releases/download/v<ver>/<asset>
pub fn install_dir(version: &str) -> String;                                         // "flutter_run-0.1.0"
pub fn binary_path(version: &str, os: Os) -> std::path::PathBuf;                     // Path-based, flutter_run[.exe]
pub fn is_stale_install_dir(name: &str, current_version: &str) -> bool;
pub fn pick_command(user: Option<String>, which_exe: Option<String>, which_plain: Option<String>, os: Os) -> Option<String>;  // ignores .bat/.cmd on Windows
pub fn sha256_hex(bytes: &[u8]) -> String;                                           // hand-written hex
pub fn verify_sha256(bytes: &[u8], expected_hex: &str) -> Result<(), String>;        // case-insensitive; message has expected+actual
pub fn not_found_message() -> String;  pub fn download_failed_message(version: &str, err: &str) -> String;

// checksums.rs  (generated at release time by .github/scripts/pin-checksums.sh; EMPTY in dev builds)
pub const PINNED_SHA256: &[(&str, &str)] = &[];
pub fn pinned_sha256(asset: &str) -> Option<&'static str>;
```
`lib.rs` implements `zed::Extension` for `FlutterRunExtension { verified: Option<String> }` (`get_dap_binary`, `dap_request_kind`, `dap_config_to_scenario`) using `zed::{download_file, make_file_executable, current_platform, DownloadedFileType}`, `std::fs`, and `zed::register_extension!(FlutterRunExtension);` (unguarded). Schema file per §4.11 (draft-07, `$schema`, `title`, a `description` per property, `additionalProperties: true`).

**Acceptance:** `cd extension && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test` (host) green; `cargo clippy --target wasm32-wasip2 -- -D warnings` and `cargo build --release --target wasm32-wasip2` succeed (record the `.wasm` size); tests: config parsing defaults/edges (missing `type` → flutter, bad `type` → error, env stringification, non-object env → error, cwd default), arg building (full matrix, stable order, paths with spaces remain single args), env merge (config wins), asset naming for the supported pairs incl. (Windows, Aarch64) and X86 error, `.exe` only on Windows, `download_url`, `binary_path`, stale-dir detection, `pick_command` (user wins; Windows ignores `.bat`/`.cmd`; prefers `.exe`; POSIX plain), sha256 known vectors (empty, `abc`) through the hand-written hex, mismatch message, uppercase hex accepted, `pinned_sha256` empty in dev, error texts contain the README/`binary` setting hints and mention pub only when `PUBLISHED_ON_PUB`, `request_kind` (launch/attach/missing/invalid), `config_to_scenario` launch/attach; the schema parses as JSON (`include_str!`). **Must not touch:** `cli/**`. Must not publish or submit anything.

---

### WP9 - CI (`.github/**`)

**Owner:** agent "ci". **Depends on:** none. Cannot run workflows; validate with `actionlint` if installable, else YAML parse, and run every non-OS-specific command locally.

Files: `.github/workflows/ci.yml`, `.github/workflows/release.yml`, `.github/scripts/pin-checksums.sh` (reads `SHA256SUMS`, prints the body of `extension/src/checksums.rs`; POSIX sh with `sha256sum`/`shasum` fallback), `.github/scripts/check-versions.sh` (fails if the version differs between `cli/pubspec.yaml`, `cli/lib/src/common/version.dart`, `extension/Cargo.toml`, `extension/extension.toml`, `extension/src/install.rs` `PROXY_VERSION`), `.github/dependabot.yml` (pub, cargo, github-actions; weekly).

`ci.yml` (on `push` to `master`/`build/**`, and `pull_request`): `concurrency` cancel-in-progress; permissions `contents: read`; third-party actions pinned to major tags (SHA pinning is a follow-up).
- Job `dart` - matrix `ubuntu-latest, macos-latest, windows-latest`; `dart-lang/setup-dart@v1` (`sdk: stable`); `check-versions.sh` (ubuntu); in `cli`: `dart pub get --enforce-lockfile`, `dart format --output=none --set-exit-if-changed .`, `dart analyze --fatal-infos`, `dart test --exclude-tags integration --exclude-tags integration-dart`, **`dart test -t integration-dart -j 1`** (the `dart debug_adapter` suite and the no-Flutter CLI e2e subset run on all three OSes, ADR 0006 D10), `dart compile exe bin/flutter_run.dart -o build/flutter_run` (`.exe` on Windows), smoke `build/flutter_run version` and `--help`, copy the exe elsewhere and run it again (+ `codesign -dv` on macOS); upload the exe (7 days).
- Job `rust` - matrix ubuntu/macos/windows: host `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test`; ubuntu additionally `rustup target add wasm32-wasip2`, `cargo clippy --target wasm32-wasip2 -- -D warnings`, `cargo build --release --target wasm32-wasip2`, upload the `.wasm`. `dtolnay/rust-toolchain@stable`, `Swatinem/rust-cache@v2`.
- Job `integration` - ubuntu only, `needs: [dart]`: `subosito/flutter-action@v2` (`channel: stable`, `cache: true`), `flutter precache --linux`, `flutter doctor -v`, then in `cli`: `dart pub get`, `dart test -t integration -j 1 --reporter expanded`; upload `cli/.dart_tool/flutter_run_test/**` logs on failure; `timeout-minutes: 30`. A comment notes that macOS/Windows jobs for this suite are added if it proves stable there.
`release.yml` (on `push` of tags `v*` and `workflow_dispatch`; **never triggered by agents**): matrix builds with `dart compile exe` natively on `ubuntu-latest` (linux-x64), `ubuntu-24.04-arm` (linux-arm64), `macos-latest` (macos-arm64), `macos-15-intel` (macos-x64), `windows-latest` (windows-x64; windows-arm64 not built, the extension maps it to x64); asset name `flutter_run-${GITHUB_REF_NAME}-<os>-<arch>[.exe]`; a final job downloads all, writes `SHA256SUMS`, creates a **draft** GitHub Release and uploads assets + `SHA256SUMS`. A header comment documents the flow: build assets at the tag → publish the draft → `pin-checksums.sh` → commit `extension/src/checksums.rs` (and flip `PUBLISHED_ON_PUB` only after pub.dev publication) → the registry/dev-extension commit is the *next* commit; until the release is published (still a draft or not yet created) the extension's download fails with the clear error from §4.10 step 4.

**Acceptance:** YAML parses; every referenced path/command exists in the §3 layout; local runs of `dart format/analyze/test` and `cargo …` once WP0/WP8 exist (else say so); `pin-checksums.sh` tested against a fabricated `SHA256SUMS` producing valid Rust; `check-versions.sh` passes on the scaffold and fails on a fabricated mismatch. **Must not touch:** anything outside `.github/**`.

---

### WP10a - Composition root and CLI (`cli/bin`, `cli/lib/src/cli`, schema test)

**Owner:** agent "compose". **Depends on:** WP0-WP9 merged. **May read:** everything.

- `cli/bin/flutter_run.dart`: `Future<void> main(List<String> args) async => exit(await FlutterRunRunner.create().runWithExit(args));` (flushes stdout/stderr first).
- `runner.dart`: `FlutterRunRunner extends CommandRunner<int>`; `GlobalOptions.addTo(argParser)`; registers every command (WP2: `reload`, `restart`, `status`; WP4: `devices`, `select-device`, `emulators`; WP6: `devtools`; WP7: `init`; own: `dap`, `doctor`, `version`); top-level error handler (§4.1); `--verbose` → `LogLevel.debug`; `FLUTTER_RUN_LOG_LEVEL`; SIGINT → 130.
- `wiring.dart`: builds shared objects once (`HostEnvironment.system()`, `SystemConsole`, `Logger`, `SdkResolver`, `SessionStore`, `ControlClient`, `DeviceStore`, `SystemBrowserOpener`) and the adapters between modules:
  - `FlutterRunnerFactory` = `SdkResolver.resolveOrThrow` + `runTool(buildProcessSpec(flutterExecutable, args, env))` → `FlutterToolResult`;
  - `VmServiceTargetResolver` = `findSessionsFor` → most recent `startedAt` with a `vmServiceUri` (else the exit-3/4 exceptions of §4.7);
  - `AdapterConnection` over `ManagedProcess` (`StreamDapChannel(process.stdout, process.stdin)`, `stderrLines` from `process.stderr`);
  - `SessionControl` over `DapProxy`/`HotActions` (`HotResult` → `ControlException`: notStarted→`appNotStarted`, busy→`busy`, adapterError→`adapterError`, timeout→`timeout`, sessionEnded→`sessionEnded`); `ping` returns `{pid, version, protocol}`;
  - watcher callbacks: `reload` = `HotActions.reload(reason:'save')` mapped to `ReloadOutcome` (`busy` → `busy: true`), `notice` = `DapProxy.notice`.
- `path_notice.dart`: pure `String pathNoticeText(HostEnvironment env, String resolvedExecutable, bool isCompiledExe)` and `String pathFixHint(HostOs, String dir)` (§4.2 PATH notice; reused by `init` and `doctor`).
- `dap_command.dart`: `DapCommand` (`dap`) - the startup/failure/shutdown choreography of §4.2: print-to-stderr zone; startup-failure responder; `ControlServer.start` + `SessionStore.create`; pass `onShutdownStarted` (delete session file) and `onShutdownCleanup` (stop watcher, close server) to `DapProxy`; `SessionHandle.update` on `StateChanged` (debounced 50 ms, never concurrent); start notices (PATH, device source, version mismatch, reload-on-save armed); arm `ReloadOnSaveWatcher` on `AppStarted` when `mode` is debug-like (config from `LaunchRewritten.result.ownConfig`; `isDartProgram = kind == dart`); device hints from adapter `output` events via `deviceHintFor`; `openDevToolsOnce` on the first `DebuggerUris` when `openDevTools != never`; saved-device callback = `DeviceStore.readSync(projectRoot)?.deviceId`; flush stdout before exit. **Attach follows §4.2a** (`--no-dds` spawn for `--request attach`, 15 s watchdog notice).
- `doctor_command.dart`: version, OS, SDK trace for cwd/`--project`, flutter + dart versions, `flutter_run on PATH: yes (<path>) | no` with `pathFixHint`, sessions dir + live/stale counts, `.zed/debug.json` / `.zed/tasks.json` presence and whether they contain our labels, `FLUTTER_RUN_*` overrides; exit 0 if the SDK resolved else 6. Plain text only (no `--json`). `version_command.dart`: `flutter_run <version>`. (Doctor/version/schema test can be done in parallel inside this WP; they do not depend on the DAP choreography.)
- `cli/lib/flutter_run.dart`: barrel exporting `FlutterRunRunner`.
- `cli/test/unit/schema_test.dart`: loads `extension/debug_adapter_schemas/FlutterRun.json`; checks it is a valid draft-07 schema (`JsonSchema.create`); validates the output of `debugScenarios(...)` for a Flutter and a Dart project; hand-written valid/invalid samples (`reloadOnSave: "sometimes"` invalid, `openDevTools: "foo"` invalid, unknown extra key valid); asserts every key in `LaunchRewriter.ownKeys` except `adapter` and `label` is declared in the schema (this includes `flutterMode` and `platform`).
- `cli/test/unit/cli/**`: runner tests (usage error → 2; unknown command → 2; exception → exit-code mapping; unexpected exception shows no stack trace unless `--verbose`); `SessionControl` adapter mapping; `DapCommand` startup-failure responder with fakes (SDK not found → failed response + `output` + exit 6); PATH-notice texts per OS; `doctor` against a temp project with an `.fvmrc`; no command declares `--flutter-sdk`/`--verbose`/`--project` twice (construct the full runner and call `.usage`).

**Acceptance:** `cd cli && dart analyze --fatal-infos && dart test --exclude-tags integration --exclude-tags integration-dart` green for all modules together; `dart compile exe bin/flutter_run.dart` works; `flutter_run version`, `help`, `doctor` run. **Must not touch:** module internals (a bug in a module is reported, not fixed here).

---

### WP10b - Integration tests (`cli/test/integration/**`)

**Owner:** agent "itest". **Depends on:** WP10a contract (can start earlier). **May read:** `spike/bin/fake_client.dart`, `spike/README.md`, fixtures. Tags: `integration-dart` for tests 1 and 5a (runs on Linux/macOS/Windows), `integration` for the rest (Linux; extend to macOS/Windows if stable). Run with `dart test -t integration -j 1` / `-t integration-dart -j 1`.

**Files:** `support/{fake_dap_client.dart, proxy_harness.dart, temp_project.dart, wait.dart, process_checks.dart, build_exe.dart}`, `dart_console_test.dart`, `flutter_launch_test.dart`, `flutter_reload_save_test.dart`, `flutter_attach_test.dart`, `stop_paths_test.dart`, `cli_e2e_test.dart`.

**Harness requirements:**
- `build_exe.dart`: compile `bin/flutter_run.dart` once per run into `cli/.dart_tool/flutter_run_test/flutter_run[.exe]` (cache by newest mtime of `lib/`+`bin/`; honour `FLUTTER_RUN_TEST_EXE`) so tests exercise the AOT binary.
- Each test gets its own `FLUTTER_RUN_STATE_DIR` (temp) and a **temp copy** of `fixtures/sample_app` (never the checked-in fixture; `.dart_tool`/`build` excluded, `flutter pub get` once per run into a prepared copy, copied per test).
- `FakeDapClient`: sends Zed's exact `initialize` arguments (zed-dap-client-behaviour Q3), numbers its seqs from 1, `request(...)`, `waitForEvent(predicate, timeout)`, collects events and `output` text, answers `runInTerminal` with an error; never sleeps - waits are completer/stream based with explicit timeouts and a failure message containing the last 50 DAP messages + proxy stderr. **Teardown mimics Zed's `Session::shutdown`**: send `terminate`, wait for its response, then hard-kill the proxy (SIGKILL / `Process.kill(ProcessSignal.sigkill)` or taskkill) and assert **no session file remains and no orphan processes** (snapshot descendants before; poll `ps` ≤15 s; zombies ignored; leftovers killed and the test fails). A second variant sends `disconnect` only.
- Breakpoint lines are found by scanning for `BREAKPOINT_TARGET`.

**Tests and timeouts** (per-test default 5 m; positive waits in brackets; no `sleep`):
1. `dart_console_test` (`integration-dart`, all OSes): proxy `dap --kind dart --cwd fixtures/dart_console` → `dart debug_adapter`: initialize, launch `bin/main.dart`, breakpoint at the marker, `stopped(breakpoint)` [60 s], top frame line == marker, `variables` shows `total`, `next` → `stopped(step)`, `stepIn` into `square`, `evaluate` `n * 2`, `continue`, exit with stdout `TOTAL:` [60 s]. Plus a `terminate` case (Zed's path: terminate → response → kill proxy → no orphans, no session file) and a `disconnect` case.
2. `flutter_launch_test` (flutter-tester via `toolArgs ["-d","flutter-tester","--show-test-device"]`, and a variant via `deviceId: "flutter-tester"` proving `-d` injection in the DAP log): launch, breakpoint, `stopped(breakpoint)` [180 s], `continue`; session file `<pid>.json` appears with `appStarted` true and `vmServiceUri` set; `flutter_run status --json` lists it; change `Hello v1` → `Hello v2` in the temp copy and run `flutter_run reload --project <tempcopy>` (CLI process): exit 0, line `Hot reload: … ok in …`, output contains `GREETING: Hello v2` and `Reloaded` [60 s]; breakpoint hit again (reassemble) → `continue`; `flutter_run restart`: exit 0, `Restarted application`, `GREETING` printed again [60 s]; reload while paused at a breakpoint: CLI prints the waiting line (event-driven on captured CLI stdout), resume via DAP `continue` → CLI exits 0; **reload before app start**: start the session but delay sending `configurationDone` (the app cannot finish starting while the client withholds it; assert via the session file that `appStarted` is false) → `flutter_run reload` exits 4 with `still starting`; two concurrent sessions in one project (second temp copy at a nested path) → one `reload` from the parent directory reloads both (two result lines); a `kind: dart` session in the same project is skipped with a note; **devtools:** `flutter_run devtools --print` prints a URL matching `^http://127\.0\.0\.1:\d+/[^/]+/devtools/inspector\?uri=ws%3A%2F%2F`; real `HttpClient` GET → 200 and body contains `flutter_bootstrap.js`; stop via Zed's path → no orphans (`flutter_tester`, `dart development-service`, `frontend_server`, proxy) and no session file.
3. `flutter_reload_save_test`: after `flutter.appStarted` modify `lib/main.dart` in the temp copy → wait for `output` containing `Hot reload on save` **and** `GREETING: Hello v3` [60 s]; DAP log shows the injected `hotReload` with `"reason":"save"` and seq ≥ 1e9; the armed notice appeared once; identical rewrite → no reload within a bounded quiet window (≤3 s, `waitForNo`); `reloadOnSave: "always"` reloads on identical rewrite; `"off"` never reloads (≤3 s window); writes under `build/` and `.dart_tool/` and `ios/` never reload; two quick edits 10 ms apart → exactly one `hotReload` (count in the DAP log after waiting for the first `Reloaded` plus a ≤2 s quiet window); a burst of ~200 file writes → one reload (+ at most one follow-up); `reloadOnSaveGlobs: ["assets/**.json"]` triggers on an `assets/x.json` edit; a save during a `restart` runs afterwards.
4. `flutter_attach_test`: steps and expectations per **§4.2a (placeholder; finalise from the D9 probe result)**: start `flutter run --machine -d flutter-tester --show-test-device` in a second temp copy (`Process.start`, read stdout until `app.debugPort` → `wsUri`, keep stdin open), drive the proxy with `request: "attach"` and the URI form/`toolArgs` fixed by §4.2a; assert the attach-started signal named in §4.2a [120 s], `flutter_run reload` → `Reloaded` appears, reload on save works, Zed-style stop (`terminate`/`disconnect` as §4.2a specifies) leaves the `flutter run` app alive (assert the machine process still runs), then `app.stop` over the machine stdin and assert everything exits.
5. `stop_paths_test`: (a) `integration-dart`: adapter crash (kill the `dart debug_adapter` mid-session) → client sees `Error:` notice + stderr output + `terminated`, proxy exits, no session file; stdin EOF → proxy cleans up and exits ≤20 s; proxy SIGKILL leaves a stale session file which `flutter_run status` prunes; (b) `integration`: the same crash/EOF cases for `flutter debug_adapter` with no orphan processes.
6. `cli_e2e_test` (`integration-dart`, no Flutter debug session): `flutter_run init` in a temp Flutter project (copy of sample_app's pubspec) → `.zed/debug.json` + `.zed/tasks.json` exist, strict JSON, debug.json validates against `FlutterRun.json` (json_schema), second `init` adds nothing; JSONC `tasks.json` untouched + exit 9; `status` with no sessions exits 0 ("No running…"); `reload` with no session exits 3 with the §4.3 text; `doctor` exits 0 and names the SDK; stale session file pruned by `status`. (`integration`, Linux): `devices --json` exits 0 with a JSON array; `select-device --device flutter-tester` is rejected (not in `devices`), so the test writes the saved device through `DeviceStore` into the temp state dir and asserts the next proxy launch without `deviceId` injects `-d flutter-tester` (DAP log) and prints the device-source notice; `select-device` without a terminal → exit 2.

**Flakiness policy:** no sleeps/fixed delays except the three bounded negative windows; every positive wait is event-driven with a timeout; unique temp dirs and random ports; `-j 1`; failures dump DAP transcript + proxy stderr + CLI output; no automatic retries; orphan checks in teardown; CI uploads logs.

**Acceptance:** all files pass 3 consecutive local runs (record commands and outputs in the report); `fixtures/` unchanged afterwards (`git status`); no stray processes. **Must not touch:** anything outside `cli/test/integration/**`.

---

## 7. Test plan summary

### 7.1 Unit tests (per module; Linux/macOS/Windows CI)
Framing (partial/multi), injected-request range and swallowing, launch-arg rewrite and device precedence, flutterMode translation, device hints, HotActions (join/busy/timeout/late response), proxy shutdown choreography (terminate hold, disconnect, EOF, crash; fake channels, fake_async), debounce/coalescing (fake_async), path filter and allow-list, content hash, SDK resolution matrix (temp dirs) and Windows pure functions, `.bat` argument validation, process-tree parsing/kill (real-process test on all OSes), session-file atomic write + directory mode, control protocol auth (bad token, oversize, unknown command, version), session matching and eligibility, DevTools URL building, browser command per OS, device store, init merge (absent / strict / JSONC / `--force`) and generated JSON validity, schema validity and template validation, CLI runner exit-code mapping, PATH-notice text. Rust: `cargo test` on the host.

### 7.2 Integration tests
`integration-dart` (Linux, macOS, Windows; ADR 0006 D10): `dart debug_adapter` on `fixtures/dart_console` incl. terminate/disconnect/crash/EOF paths, and the no-Flutter CLI e2e. `integration` (Linux CI): `flutter debug_adapter` on a temp copy of `fixtures/sample_app` with flutter-tester - launch, breakpoint, CLI reload/restart, reload on save, DevTools GET 200, Zed-style stop with no orphans and no stale session file, attach per §4.2a.

### 7.3 Things the integration suite decides (record results in docs/research)
Attach behaviour is **not** left to the suite any more: it comes from §4.2a (D9 probe). Remaining: whether `terminate` before `disconnect` is needed on desktop/web targets (flutter-tester only was checked); behaviour of `taskkill /T` and file watchers on Windows/macOS (unit-level real-FS and real-process tests there).

### 7.4 Timeouts and flakiness
Unit default 30 s/test; integration 5 min/test; waits: launch→first stop 180 s (13 s observed), reload/restart 60 s (0.6-0.9 s observed), shutdown 20 s, orphan polling 15 s. Event-driven waits only; three bounded negative windows. Isolated state dir, temp copies, random ports, `-j 1`. CI keeps logs on failure.

### 7.5 Manual (cannot run here)
`docs/MANUAL_ZED_TEST.md` (Phase 7) must cover: dev-extension install; **extension only, no PATH** (PATH notice appears, debugging works, tasks fail with the notice's guidance); both extensions coexisting (`Dart` + `FlutterRun` in New Session); F4 on a fresh workspace and F5 on a never-run workspace; breakpoint; `ctrl-f5`/`ctrl-shift-f5` (incl. macOS `fn`/system shortcut conflicts); save-reload (and Zed autosave); device pick and the "several devices" hint; emulator launch task; DevTools page route in a real browser (path form); locator-free New Session; stop leaves no processes (and no stale session file); `.zed` committed with teammates lacking `flutter_run`; flavors via `toolArgs`; attach workflow; a Windows run.

---

## 8. Decisions referenced

- [0001](decisions/0001-standalone-tool.md) · [0002](decisions/0002-architecture-dap-proxy.md) · [0003](decisions/0003-languages-rust-extension-dart-proxy.md) · [0004](decisions/0004-architecture-accepted-with-amendments.md) (its §2 seq renumbering and §5 are **amended by 0006 D3/D1**) · [0005 names](decisions/0005-project-names.md) · **[0006 plan-review resolutions](decisions/0006-plan-review-resolutions.md)** (D1 install model, D2 shutdown, D3 no renumbering, D4 cuts, D5 targeting, D6 allow-list watcher, D7 devices, D8 task visibility, D9 attach probe, D10 test reach).
- Research: [risk register](research/risk-register.md) R1-R14, [coexistence](research/coexistence-with-dart-extension.md) (adapter name there is `Flutter`; **here `FlutterRun` per ADR 0005**), [zed-dap-client-behaviour](research/zed-dap-client-behaviour.md), [zed-recent-changes-and-picker-ux](research/zed-recent-changes-and-picker-ux.md), [zed-extension-registry §4](research/zed-extension-registry.md), [flutter-tooling-protocols](research/flutter-tooling-protocols.md), [conversation 007](conversations/2026-11-03-007-phase2-spike-gate2.md), [spike/README.md](../spike/README.md), reviews [architecture](reviews/plan-review-architecture.md) and [UX](reviews/plan-review-ux.md).
- ADRs still to record when this plan is accepted: (a) control-session matching includes parent directories (monorepo), (b) allow-list watcher details, (c) `--client-version` / `--use-fvm` extension→proxy flags.

---

## 9. Open questions for reviewers

1. **Zed context for Flutter threads:** is `debugger_session` true for the whole life of a Flutter session so `ctrl-f5` works while running and paused? (source says yes; unverified.)
2. **Hot restart via `debugger::RerunSession`** and our task both end in hot restart; `init` prints an alternative snippet that keeps Zed's key. Enough?
3. **Task terminal noise:** `use_new_terminal` + `reveal: no_focus` + `hide: on_success` may flash a tab per reload; needs a real Zed.
4. **`type` default in `dap_config_to_scenario`** is always `flutter`.
5. **Windows ARM64:** mapped to the x64 asset (emulation); acceptable?
6. **Monorepos:** parent-directory session matching is my addition; sibling path packages outside the project do not trigger reload-on-save (A21, deferred).
7. **Pinned-checksum flow** (build assets at the tag → publish → pin → next commit) means the registry commit is not the tag commit.
8. **Transient `stopped(entry)`** after launch/restart is unfiltered; first follow-up if the manual test shows a flicker or lost breakpoint.
9. **Hold-the-terminate-response** (D2) adds up to 5 s to Stop; acceptable, or shorten to 3 s?

---

## 10. Planner concerns (decisions kept; flagged)

1. **Planner concern: one strings file vs disjoint ownership** (resolved by ADR 0006 D4: no strings files; messages next to the code, with the style rules in §3). The original orchestrator wording ("one strings file for future i18n") is therefore not met literally; a later extraction pass can collect the `static const` texts.
2. **Planner concern: session matching in monorepos.** "Equals or contains" misses the common case where Zed's worktree root is the monorepo root and the app is a subdirectory; matching is bidirectional and acts on all eligible matches (and says so).
3. **Planner concern: watching.** A recursive root watcher would watch `ios/Pods`, `android/.gradle`, `build/`…; ADR 0006 D6's allow-list (`lib/`, `bin/` for Dart, glob prefixes) replaces the deny-list. Cost: edits to sibling path packages and newly created top-level directories don't reload in 0.1.0.
4. **Planner concern: `flutterMode` / `platform` are dead keys in Zed's Dart extension.** We translate `flutterMode` and ignore `platform`; configs copied between adapters behave differently for `flutterMode: profile`.
5. **Planner concern: key bindings.** `ctrl-shift-f5` shadows Zed's `debugger::RerunSession` inside sessions (macOS `shift-cmd-f5`); `ctrl-alt-shift-d` collides with a dev-only Windows action; OS-level conflicts and macOS `fn` handling are unverified.
6. **Planner concern: the DevTools page-route form cannot be proven by HTTP** (all forms return the same SPA with 200). Path style is the single implemented style (D4); a manual browser check decides whether to revisit.
7. ~~Planner concern: attach details~~: resolved by §4.2a.
8. **Planner concern: stale-session detection without PID probes.** TCP ping only; a crashed proxy whose port was reused by another listener is deleted if it replies with something non-protocol, kept if it is silent.
9. **Planner concern: added extension→proxy flags** `--use-fvm` and `--client-version` (not in the orchestrator's list): the proxy must pick the SDK before it sees the launch arguments, and the version notice catches an extension/CLI mismatch.
10. **Planner concern: two-step install** (ADR 0006 D1): hot reload needs `flutter_run` on PATH; the extension download only keeps debugging working. Until publication, instructions point at the README (release binaries, `pub global activate --source git`, build from source).
11. **Planner concern: hold-the-terminate-response** keeps Stop responsive only because the adapter answers quickly; a hung adapter costs the full 5 s before Zed kills the proxy.
12. **Planner concern: package SDK constraint.** `sdk: ^3.8.0` is lower than the dev dependencies need (`test` needs 3.11); contributors need a current Dart, end users only 3.8. CI runs the stable channel only.

---

## 11. Review resolution log

Legend: **applied** / **applied-differently** (how) / **rejected** (why). ADR 0006 wins over reviews.

### Architecture review (A1-A22)

| Id | Result | Note |
|---|---|---|
| A1 | applied | D1: two-step install; PATH notice (§4.2); extension resolution order; README refs; `init`/`doctor` PATH check. Option (b)'s "write absolute path into tasks.json" rejected (D1 chose the notice; moving binaries between versions would break committed tasks). |
| A2 | applied | D2: `terminate` is the primary trigger; response held; session file deleted first; teardown/tests mimic Zed (§4.2, §5.4, WP1, WP10b). |
| A3 | applied | `pick_command` ignores `.bat`/`.cmd` on Windows and prefers `.exe` (§4.10, WP8); stdin-EOF shutdown always runs. |
| A4 | applied | D5 eligibility rules (§4.3, WP2); exit 3 only when nothing matches. |
| A5 | applied | D6 allow-list (§4.6, WP5); 5000-directory cap rejected (allow-list is small; bare-pattern globs are rejected instead). |
| A6 | applied-differently | D9: new placeholder §4.2a filled from the orchestrator's probe; hedge until then; test 4 rewritten against it. |
| A7 | applied | D10: `integration-dart` on three OSes, real-process test in WP3 on all OSes, Zed-style teardown, failure-mode cases, `flutter precache --linux` pinned (§7, WP3, WP9, WP10b). |
| A8.1 | applied | Moot after status-command removal; `HotResult.last` dropped. |
| A8.2 | applied | `ownKeys` has all 12 keys (single source of truth). |
| A8.3 | applied | `--flutter-sdk` only global; `dap` row fixed; test that no option is declared twice. |
| A8.4 | applied | `DebuggerUris(isFirst)`. |
| A8.5 | applied | `RequestInjector.inject` contract written out. |
| A8.6 | applied | Schema test uses `debugScenarios`. |
| A8.7 | applied | `ProcessSpec` prose matches the class (no `runInShell`). |
| A8.8 | applied | `Messages` dropped; `findExecutableOnPath`, `stateBaseDirectory` added to WP0; flush helper lives in WP10a. |
| A8.9 | applied | Layout/matrix aligned (barrel = WP10a); `.gitignore` to WP0; README/RELEASE/MANUAL/STATUS declared orchestrator-owned. |
| A9 | applied-differently | Busy/coalescing, late-response-keeps-in-flight, client restart flag, save-after-restart and the 3 s waiting notice applied; the `pausedThreads` deferral of save-reloads rejected (ADR 0006 D5 only asks for coalescing; a paused app already queues the reload in the adapter). |
| A10 | applied | stderr drained/mirrored, crash path emits output + `terminated`, 10 s initialize timeout, flush before exit. |
| A11 | applied | Concurrent pings, connect-timeout = stale. |
| A12 | applied | Windows = adapter pid + `taskkill /T`; POSIX PID-reuse guard. |
| A13 | applied | Items 1-6 applied (quarantine docs + codesign step, ARM64→x64, `.part` + rename, deterministic URL instead of the API, `Path` building, capabilities block described as documentation). |
| A14 | applied | No cfg split / `rlib`; 4 files; hand-written hex; no 0.10 hedge. |
| A15 | applied | D4: locator deferred. |
| A16 | applied | D3: no renumbering; injected range ≥ 1e9. |
| A17 | applied | `<pid>.json`, directory 0700 only, no remote-address check/connection cap, no control `status`, rename retry 10×50 ms. |
| A18 | applied | D4: DDS URL only; no probe/fallback/second style/`--session`/`--no-probe`. |
| A19 | applied-differently | Cut: `doctor --json`, `version --json`, `init --worktree`, strings files/`Messages`, hash baseline, `quoteWindowsArgument`/`windowsCommandLine`. **Kept (not cut):** `emulators` (D7 puts it in the MVP). **Rejected:** moving doctor/version/schema test into a new parallel WP - the instruction is to keep WP0/WP1-9/WP10a-b; they are marked as parallelizable inside WP10a. |
| A20 | applied | `.gitignore` owner, `check-versions.sh` in WP9, draft/absent-release behaviour stated (§4.10, WP9). |
| A21 | rejected | Deferred to post-0.1.0 (noted in §4.6/§9); D6 fixes the watch set. |
| A22 | applied | `isInteractive` = stdin and stdout terminals; startup-lock message; WP10b fragments rewritten. |

### UX review (U1-U25)

| Id | Result | Note |
|---|---|---|
| U1 | applied | D1 PATH notice, README two-step install, MANUAL_ZED_TEST case "extension only, no PATH". The "init copies itself to PATH" stretch rejected (surprising side effect). |
| U2 | applied | `PUBLISHED_ON_PUB` const; messages point at README/releases/`binary` setting. |
| U3 | applied-differently | D8 `reveal: no_focus` + `hide: on_success`; exit-3 text rewritten (no hard-coded F4/F5 claims beyond Zed's picker); the `notify` control command rejected (control protocol shrinks per D4). |
| U4 | applied-differently | D7: device-source notice and failure hints (`device_hints.dart`) instead of a pre-launch `flutter devices` probe. |
| U5 | applied | `doctor` and `init` print PATH status and per-OS fix; README. |
| U6 | applied | Key table printed by `init`; README; manual-test items. |
| U7 | applied | Documented absence of "run without debugging" key; session-only bindings stated; macOS `fn` note; optional snippet without `ctrl-shift-f5`. |
| U8 | applied | Armed notice, explicit `reloadOnSave` in generated scenarios, autosave note, 3 s waiting notice; a `"manual"` mode rejected (no Zed save hook). |
| U9 | applied | D7: `emulators` in MVP + "Flutter: Launch Emulator" task; zero-device text; `r` rescan in picker. |
| U10 | applied | Failure notices hint "Hot Restart"; "Console tab" text in `init`/README. |
| U11 | applied | D7: state in per-user state dir; exact "Saved device" wording; `hide: never`. |
| U12 | applied | Hint about the "Dart" adapter in the exit-3 message; README one-liner. |
| U13 | applied-differently | Exact Zed command names printed; `--write-keymap` rejected (keymap is JSONC; out of scope). |
| U14 | applied | Friendly wording, "Done with 1 manual step.", `.bak` message; exit 9 kept. Separate snippet file rejected (more files to explain). |
| U15 | applied | Per-session result-line format. `--device` filter deferred. |
| U16 | applied | Docs/manual-test note only (flavors via `toolArgs`). |
| U17 | applied | "not supported" hint in the failure notice. |
| U18 | applied | URL always printed; DevTools tasks trimmed. |
| U19 | applied | `Stopping the app...` notice after 1 s; window-close = EOF documented. |
| U20 | applied | Message style rules in §3 rule 4; ASCII `...`; whole sentences; version-mismatch wording. Per-module `XStrings` classes dropped by D4. |
| U21 | applied | `Warning:`/`Error:` words in notices; `ok`/`failed` words in CLI result lines. |
| U22 | applied | Task set trimmed (Inspector/Performance only), `use_new_terminal` per task, Select Device `hide: never`; `show_summary:false` kept on reload/restart because `no_focus` + `on_success` already keeps failures visible. |
| U23 | applied | `init` prints the commit/teammates note. |
| U24 | applied | Attach workflow documented in README/manual test; message when nothing is found comes from the adapter (§4.2a). |
| U25 | applied | Wording in §4.2 start notices. |
