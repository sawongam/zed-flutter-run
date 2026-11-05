# Phase 6 correctness review (whole system as wired)

Reviewer: independent correctness pass over `cli/lib/src/{cli,dap,control,watch,devices,sdk}` and the extension's argv builder. No code was changed. Unit suite: `dart test --exclude-tags integration --exclude-tags integration-dart` = 726 passed. Flutter integration suite not run (another job may be using it); evidence below comes from scratch drivers in `/tmp/claude-0/-home-user-run-and-debug-flutter/32cd234d-2bba-5c41-b10d-b540117c3393/scratchpad/p6-correctness/` (`drv/drv.dart`, `drv/attach.dart`, `drv/fail.dart`) that speak DAP to the compiled `flutter_rd dap` against a real `dart debug_adapter` / `flutter debug_adapter`.

Counts: 0 blocker, 4 major, 8 minor, 4 nit. Previously fixed batch1/batch2 items were not re-reported.

Verified OK (no finding): Zed terminate then SIGKILL (Dart launch: response arrives, tree gone, no session file); disconnect-only; stdin EOF (launch and attach); adapter crash; SDK not found and bad `--flutter-sdk` (first request answered `success:false`, console text, exit 6, also when the client sends nothing); attach never kills the app on terminate, disconnect, disconnect `terminateDebuggee:true` and EOF (Dart kind, measured); Flutter launch failure then terminate (adapter and proxy gone); device precedence matches README/plan; `--no-dds` only for Flutter attach; Dart restart refusal; seq ranges disjoint and client seqs never rewritten; control server limits and token check; session file delete-before-cleanup ordering.

---

## Major

### R1 (major, CONFIRMED) Adapter is left running after Zed's terminate then kill when the descendant snapshot is empty (Dart attach)
- `cli/lib/src/dap/proxy.dart:816-825` (`_sweep`), esp. `:818`.
- `adapterAlive = snapshot.contains(_adapter.pid) && !_adapterExited`. On POSIX `snapshotDescendants()` never contains the adapter's own pid (only on Windows it is `{pid}`), so `adapterAlive` is always false on POSIX. With no descendants in the snapshot, `_sweep` returns without touching the adapter. The adapter is then supposed to exit by itself after `terminate`, which `dart debug_adapter` does not do in attach mode.
- Evidence (`drv/attach.dart terminate`, Dart kind, `--request attach` to a hand-started `dart` app): `terminate` answered `success:true`; 6 s later `proxy alive=true adapter alive=true`; after Zed-style SIGKILL of the proxy the `dart debug_adapter` is still running, reparented to pid 1 (killed by the driver). Target app survived (correct). The Flutter adapter does exit by itself (`drv/fail.dart`: adapter and proxy gone ≤4 s), so this hits Dart attach, and any Dart/Flutter launch whose snapshot saw no descendant (program exited before the 300 ms first snapshot).
- Impact: every stopped Dart attach session leaks one adapter process (tens of MB) until reboot.
- Fix: `adapterAlive = !_adapterExited`. After the held terminate response, wait up to ~0.5-1 s for `_adapterExit`, then `terminateTree` (adapter included) before relaying the response, since Zed SIGKILLs the proxy right after. Add a Dart-attach case to `stop_paths_test.dart`/a new attach test for Dart kind.

### R2 (major, CONFIRMED by simulation) The sweep kills long-lived shared daemons that were once descendants of the adapter
- `cli/lib/src/dap/proxy.dart:782-793` (`_refreshSnapshot`, `_known.addAll` at `:790`), `:816-825`; `cli/lib/src/sdk/process_tree.dart:195-200`; `cli/lib/src/sdk/managed_process.dart:68-72`.
- `_known` is cumulative: every pid seen under the adapter by the 2 s poll stays in it. At shutdown, `killTree` also signals snapshot pids that were reparented to init with an unchanged start time. That is the right rule for orphaned build helpers, but it also matches intentionally daemonised helpers that the Flutter tool starts: Gradle daemon, Kotlin compile daemon, `adb` server, `xcodebuild`/`simctl` helpers, `dart devtools`/analysis servers started by tools. They are shared with other projects/IDEs. SIGTERM (then SIGKILL after 2 s) breaks the user's other builds.
- Evidence (`drv/drv.dart terminate`): debuggee spawns `bash -c 'sleep 604 & ... sleep N'`, so the `sleep` is reparented to init after N s. N=3 s (seen by a poll): after `terminate` the `sleep` is gone (killed by the proxy sweep; the adapter only stops the debuggee). N=0.05 s (never seen): the `sleep` survives. Same code path, so the sweep killed it.
- Fix: restrict the sweep to pids that are still descendants of the adapter at shutdown, or reparented ones that also share the adapter's process group / session id (`ps -o pgid`), or remove reparented-by-snapshot kills and keep only "still in the tree". Alternatively record only processes whose parent is the adapter or the `flutter`/`dart` tool processes, and exclude well-known daemons (`adb`, `gradle`, `java ... GradleDaemon`, `kotlin-compiler`). Whatever is chosen, document it in ARCHITECTURE and add a test with a daemonised child.

### R3 (major, CONFIRMED for Dart adapter) SIGTERM/SIGHUP/SIGINT to the proxy skip all cleanup; SIGKILL before any terminate orphans the adapter and the app
- `cli/lib/src/cli/runner.dart:150-160` (SIGINT watched for non-`dap` commands only), no `ProcessSignal.sigterm|sighup` handler anywhere in `cli/lib` or `cli/bin/flutter_rd.dart`.
- Dart's default action for SIGTERM/SIGHUP/SIGINT is immediate termination: no `shutdown()`, no session file delete, no sweep. The adapter does not exit on stdin EOF (it only did in our EOF test because the proxy itself ran `disconnect`/sweep).
- Evidence (`drv/drv.dart sigterm` and `sigkill`, Dart launch, 12 s wait): proxy exits -15 / -9; `dart debug_adapter` (ppid 1), the `dartvm` debuggee and its `sleep` child all still running; `sessions/<pid>.json` left behind. (`eof`, `disconnect`, `terminate` leave nothing.)
- When it happens in practice: Zed's `Session::shutdown` while still `Booting` (kills adapter without any request), Zed quitting/crashing mid-boot, the OS or a user sending SIGTERM/SIGHUP (terminal close, `kill`, package-manager stop), the proxy being OOM-killed, Windows `.bat` wrapper edge cases (D1).
- Fix: on POSIX register `sigterm` and `sighup` (and `sigint` for `dap`) handlers that call `proxy.shutdown(reason: 'signal')` and let `exit()` follow `_finish`. For the uncatchable SIGKILL case, add defence in depth: spawn the adapter so that it dies with the proxy, for example a tiny watchdog (`flutter_rd __reap <proxyPid> <adapterPid>` started detached, polling the proxy pid and killing the tree when it vanishes), or `setsid`+process-group kill by the watchdog. At minimum, document the SIGKILL gap in ARCHITECTURE.

### R4 (major, PLAUSIBLE) 10 s `initialize` timeout kills a first-run / post-upgrade `flutter debug_adapter` in a loop
- `cli/lib/src/dap/proxy.dart:21` (`initializeTimeout`), `:345-392` (`_failStartup` then `_finish(1)`, tree killed).
- After `flutter upgrade`, on a fresh SDK, or while another `flutter` command holds the startup lock, the first `flutter debug_adapter` rebuilds the tool/downloads the Dart SDK for 20 s to minutes. The proxy kills it at 10 s, so the next attempt starts the same rebuild and is killed again until the user happens to run `flutter` in a terminal. The error text does say to run `flutter debug_adapter` in a terminal, which is the only way out. Not reproduced (would require touching the SDK stamp).
- Fix: raise the default (e.g. 60-90 s), and show a console notice at ~5 s ("Flutter is still starting; the first run after an upgrade can take a minute") instead of failing; fail only when the adapter process exits or stderr shows no progress.

---

## Minor

### R5 (minor, CONFIRMED) `/ws/ws` breaks the DevTools URL and the stored VM service address in attach mode with `--no-dds`
- `cli/lib/src/devtools/url_builder.dart:26`, `:49-63`; value comes from `dart.debuggerUris` in `cli/lib/src/dap/proxy.dart:466-483`.
- With `vmServiceUri` given in `ws://.../ws` form and the adapter started with `--no-dds`, the adapter reports `.../ws/ws` (attach-probe case 7). `normalizeWsUri` removes one trailing `ws` segment and adds one back, so the doubled segment survives. Measured: `buildDdsDevToolsUrl('ws://127.0.0.1:1234/AAA=/ws/ws', inspector)` gives `http://127.0.0.1:1234/AAA=/ws/devtools/inspector?uri=ws%3A...%2Fws%2Fws` (wrong). Affects `openDevTools` and `flutter_rd devtools`. The README documents the `http://.../TOKEN=/` form, which is fine, but the ws form is accepted and silently breaks.
- Fix: strip all trailing `ws` segments in `normalizeWsUri`, and/or normalise the URI in `_onAdapterEvent` before storing. Add a unit test for `.../ws/ws`.

### R6 (minor, CONFIRMED) Dart kind: `openDevTools` / `flutter_rd devtools` open a 404 page
- `cli/lib/src/cli/dap_command.dart:579-607`, `cli/lib/src/cli/wiring.dart:vmServiceTargetResolver`, `cli/lib/src/devtools/devtools_opener.dart`.
- The URL is always `<dds>/devtools/<page>?uri=...`. The Dart adapter's DDS does not serve DevTools: measured `GET .../devtools/inspector?...` = 404 and `.../devtools/` = 404 (root = 302) for a `type: dart` session; the proxy still prints "Opened DevTools: <url>".
- Fix: for `kind == dart` print a notice ("DevTools is not served for Dart console sessions; run `dart devtools` and paste the VM service address: ...") and have the resolver skip or flag Dart sessions.

### R7 (minor, PLAUSIBLE) A save that lands during an in-flight reload is reported as done but not applied
- `cli/lib/src/dap/hot_actions.dart:122-127`, `cli/lib/src/watch/reload_on_save_watcher.dart:_runReload`.
- A save-triggered `reload` that finds a reload already in flight (typically a manual task started earlier) joins it and returns `ok` (`coalesced`). If the file was written after the first reload had already compiled, the change is never applied; the watcher marks the path done and the content hash prevents a retry.
- Fix: when joining, only report coalesced if the flight started after the file event; otherwise queue exactly one follow-up reload (the watcher coalescer already supports "one follow-up").

### R8 (minor, PLAUSIBLE) Save-reload while paused at a breakpoint reports failure after 120 s although the reload is still pending
- `cli/lib/src/dap/hot_actions.dart:171-185`, `:101-103`.
- The flight times out for callers at 120 s ("Hot reload failed ... Try Hot Restart"), `forgetBatch` re-arms the hash, but the adapter request stays pending (10 min late limit) and finishes the reload when the user resumes. Between the two, every reload/restart returns "busy". The message steers the user to Hot Restart, which will also be "busy".
- Fix: for `reason == 'save'` do not time out (the waiting notice at 3 s is enough), or on timeout say "still waiting for the debugger to resume" and keep the batch queued.

### R9 (minor, PLAUSIBLE) Hot actions and the file watcher stay live between receipt of `terminate` and cleanup
- `cli/lib/src/dap/proxy.dart:602-623`, `cli/lib/src/cli/dap_command.dart:_onShutdownStarted` (marks only `ProxySessionControl`), `reloadForSave` in `cli/lib/src/cli/wiring.dart`.
- The control path is refused after `markEnding`, but save-triggered reloads call `proxy.hotActions` directly and `inject` only checks `_closed`/`_finishing`. A save in the up-to-5 s stop window sends `hotReload` to a terminating adapter and may print "Hot reload failed".
- Fix: make `inject` refuse hot commands once `_startFuture != null`, or stop the watcher in `_onShutdownStarted`.

### R10 (minor, PLAUSIBLE) Session file whose port is now used by another service is never pruned
- `cli/lib/src/control/control_client.dart:119-133`, `cli/lib/src/control/session_store.dart:list`.
- After a SIGKILL, if another local service takes the same port, the ping fails with a non-protocol reply (`protocol` failure), which maps to `unresponsive`, so the file is kept forever and `reload` prints "did not answer. If Zed is hung ...". The pid in the file is also dead.
- Fix: when the reply is not the protocol, also check that `info.pid` is alive (`kill -0` / `tasklist`) and prune if it is gone. Never send the token to a port whose pid is dead.

### R11 (minor, CONFIRMED by code) Every injected request leaves a closure on `_closed.future` for the whole session
- `cli/lib/src/dap/proxy.dart:208-213`.
- `_closed.future.then(...)` is registered per `inject()` and never removed, retaining the `result` completer and timer for each hot reload (reload-on-save with autosave means thousands per day). Small but unbounded growth.
- Fix: use a single `_closed.future.then` that fails a `Set` of pending injections, or complete via `Completer` held in `InjectedRequests._pending` and drain it on close.

### R12 (minor, PLAUSIBLE) The 2 s `ps` poll and the cumulative `_known` set never shrink
- `cli/lib/src/dap/proxy.dart:174-178`, `:782-793`; `cli/lib/src/sdk/managed_process.dart:57-73` (`_snapshot`, `_startTimes` also grow); `cli/lib/src/sdk/process_tree.dart:readProcessTable`.
- Every 2 s for the whole session, `ps -A -o pid=,ppid=,stat=,lstart=` is spawned and the whole table parsed (about 5 ms at 80 processes here, tens of ms on a busy macOS machine; roughly 1% of a core). Sets and maps of every seen descendant (including long-dead ones) grow for the session and are re-checked on every kill round. This is also what feeds R2.
- Fix: poll at 5-10 s or only on events (`thread`, `dart.debuggerUris`, `flutter.appStart` already trigger one); prune pids absent from the last two tables; skip while `_state.ended`.

---

## Nits

### R13 (nit, PLAUSIBLE) "Stopped unexpectedly" shown after an orderly end
- `cli/lib/src/dap/proxy.dart:557-598`. If the adapter exits by itself after it already sent `terminated` (exit code 0), `_handleCrash` still prints "The Flutter debug adapter stopped unexpectedly" as an error and synthesises a second `terminated`. Skip both when `_terminatedSeen.isCompleted && code == 0`.

### R14 (nit, PLAUSIBLE) Client EOF can race the client queue
- `cli/lib/src/dap/proxy.dart:240-267`. `_onClientEof` starts `shutdown()` immediately while earlier messages (a final `disconnect`) may still be in `_clientQueue`. Outcome is harmless (a second injected `terminate`/`disconnect`), but `_shutdownImpl` could first inspect `_disconnectReceived` too early. Chain the EOF handling onto `_clientQueue`.

### R15 (nit, CONFIRMED by code) `requestSeq == _initializeSeq` matches `null == null`
- `cli/lib/src/dap/proxy.dart:442`. A response without `request_seq` arriving before `initialize` was seen marks initialize answered and disarms the watchdog. Guard with `_initializeSeq != null`.

### R16 (nit, PLAUSIBLE) Unbounded log file and untracked timers
- `cli/lib/src/common/logger.dart:_log/dap` (every DAP message goes to `--log-file`/`FLUTTER_RD_LOG` with no cap or rotation); `cli/lib/src/dap/proxy.dart:174` (`Timer(300ms, _refreshSnapshot)` not stored); `cli/lib/src/cli/runner.dart:153` (`args.contains('dap')` also matches a value such as `--project dap`, disabling Ctrl+C handling for that command).

---

## Reproduction notes
- Compiled binary: `cli/.dart_tool/flutter_rd_test/flutter_rd`. Run, from the scratch dir: `dart run drv/drv.dart <exe> $PWD/app <sigkill|sigterm|eof|terminate|disconnect|devtools>`, `dart run drv/attach.dart <exe> $PWD/app <terminate|disconnect|disconnect-true|eof|sigkill>`, `dart run drv/fail.dart <exe> $PWD/sa`. Drivers only kill the processes they started.
- R2 control: change the debuggee's `sleep 3` to `sleep 0.05` and the daemon survives.

---

## Verification (after fixes)

Checked against commit c5ca0ce (build/mvp) by reading the code and re-running the scratch reproductions with a freshly compiled exe (`scratchpad/p6-correctness/frd2`). No Flutter integration suite was run.

| id | status | evidence |
|---|---|---|
| R1 | resolved | `drv/attach.dart terminate` (Dart attach): 6 s after the response `proxy alive=false adapter alive=false`, proxy exit 0, target app alive. Before: both alive. |
| R2 | resolved | Daemon simulation (`sleep 605` reparented, seen by the poll): survives `terminate` (`sleep 605` still running, then killed by me). Before: killed by the proxy. |
| R3 | partially (SIGKILL accepted by ADR 0007 P1) | SIGTERM: proxy exit 0, whole tree gone, no session file (handlers at `dap_command.dart:262-263`). SIGKILL without terminate still orphans adapter, debuggee and session file; documented known issue. |
| R4 | resolved | `proxy.dart:21` 120 s; notice at 10 s (`:386`). Not run against a real slow start. |
| R5 | resolved | `url_builder.dart:26` strips all trailing `ws` segments (`while`). |
| R6 | resolved | `devtools_opener.dart:38` refuses Dart sessions with a hint (read only). |
| R7 | not resolved | `hot_actions.dart:124-127` still joins an in-flight reload and returns `ok`/coalesced regardless of when the save happened. |
| R8 | resolved | `hot_actions.dart:168-170` save-triggered reloads have no timeout (read only). |
| R9 | resolved | `proxy.dart:225-232`: hot commands refused once shutdown started or terminate/disconnect received. |
| R10 | not resolved | `control_client.dart` / `session_store.dart` have no pid-liveness check; a dead session whose port is reused by a non-flutter_rd service is still kept as `unresponsive`. |
| R11 | resolved | `proxy.dart:69-75,118,235-239`: one `_closed` handler draining a `_pendingInjects` set. |
| R12 | resolved | Snapshot bounded to the last two polls (`proxy.dart:113`); poll interval still 2 s (cost accepted). |
| R13 | resolved | `proxy.dart:591` skips the crash notice after `terminated` with exit 0. |
| R14 | resolved | EOF handling chained on `_clientQueue` (`proxy.dart:296`). |
| R15 | resolved | `proxy.dart:485` guards `_initializeSeq != null`. |
| R16 | partially | First-snapshot timer now stored and cancelled; log-file rules from ADR P3. The `args.contains('dap')` heuristic in `runner.dart` was not changed (nit). |

New issues introduced by the fixes: none found in the paths exercised (terminate, SIGTERM, SIGKILL, Dart attach, daemon simulation).

### Orchestrator adjudication (2026-11-03)
- **R7: resolved at the watcher layer.** `hot_actions.dart` still joins an in-flight reload by design, but the result now carries `coalesced`, which `cli/lib/src/cli/wiring.dart:272` maps to `ReloadOutcome.joined`; `cli/lib/src/watch/reload_on_save_watcher.dart:249` then runs exactly one follow-up reload for the files saved during the joined reload. Covered by unit tests in `test/unit/watch` (joined case) and `test/unit/cli`.
- **R10: partially resolved, rest accepted as a known issue.** A port that now answers with anything that isn't our protocol is pruned (`ControlClientFailure.notProtocol`, `control_client.dart:55,136-156`). A dead session whose port was reused by a service that accepts the connection but never replies stays listed as "unresponsive" (it never blocks other sessions, ADR 0006 D5). A portable pid-liveness probe was rejected in the plan (no signals; `ps`/`tasklist` differences). Listed in STATUS.md known issues.
- **R3 (SIGKILL) and R16 (`args.contains('dap')` heuristic in `runner.dart`)**: accepted, see ADR 0007 P1 and STATUS.md known issues.
