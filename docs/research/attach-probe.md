# Attach probe: `flutter debug_adapter` in attach mode

Date: 2026-11-03. Flutter 3.47.9 (`/opt/sdk/flutter`), device `flutter-tester`, Linux container, running as root.

Question: how does DAP `attach` behave through `flutter debug_adapter` when the app was started separately by `flutter run --machine`? Everything below was measured. Probe code and raw logs live in the session scratchpad (`.../scratchpad/attach-probe/`: `probe/bin/probe.dart`, `r*.log`), not in the repo. `fixtures/` and `spike/` were not modified (the app was a temp copy).

## Method

1. Copy `fixtures/sample_app` to a scratch dir and start the app by hand:
   ```
   cd <scratch>/app
   tail -f /dev/null | flutter run --machine -d flutter-tester --show-test-device \
       --vmservice-out-file=<scratch>/vmservice.txt > run.log
   ```
2. `probe.dart` (adapted from `spike/bin/fake_client.dart` + `spike/lib/framing.dart`) spawns `flutter debug_adapter [--no-dds]` directly (no proxy), sends Zed's exact `initialize`, then `attach` with `{cwd, vmServiceUri | vmServiceInfoFile, [toolArgs]}`. Then it sends `setBreakpoints` (lib/main.dart:7) + `configurationDone` as soon as `initialized` arrives, and optionally `hotReload`, `hotRestart`, and one of `terminate` / `disconnect`. Breakpoint stops are continued by the probe.

## The running app: what `flutter run --machine` gives us

```
{"event":"app.debugPort","params":{"appId":"77a2c9be-...","port":33171,"wsUri":"ws://127.0.0.1:33171/xzgCOabbXpo=/ws","baseUri":"file:///tmp/appXNZAAU/app/"}}
{"event":"app.devTools", ... "uri":"http://127.0.0.1:33171/xzgCOabbXpo=/devtools/?uri=ws://127.0.0.1:33171/xzgCOabbXpo=/ws"}
{"event":"app.dtd", ... "uri":"ws://127.0.0.1:36717/zda5X4cuw0U="}
{"event":"app.started","params":{"appId":"77a2c9be-..."}}
```

- `app.debugPort.wsUri` is the **DDS** URI (port 33171). The real VM service listens on another port (39721), which is only visible on the `dart development-service --vm-service-uri=http://127.0.0.1:39721/...` command line. `flutter run` starts DDS itself.
- `--vmservice-out-file` content: **a bare string, no newline, no JSON**: `ws://127.0.0.1:33171/xzgCOabbXpo=/ws` (same value as `wsUri`).

## Results table

"Default" = adapter started as plain `flutter debug_adapter`, so adapter DDS enabled.

| # | Config | Outcome |
|---|---|---|
| 1 | `vmServiceUri` = `ws://.../ws` (from `app.debugPort`), toolArgs `-d flutter-tester --show-test-device`, default adapter | Works. No DDS conflict. Breakpoint hit, hotReload, hotRestart all work. |
| 2 | `vmServiceUri` = `http://127.0.0.1:PORT/TOKEN/` (same app), same toolArgs | Works identically. Adapter normalises it to `ws://.../ws` (see `dart.debuggerUris`). |
| 3 | `vmServiceUri` ws or http, **no toolArgs** | Attach response is `success:true`, then the adapter prints `More than one device connected; please specify a device with the '-d <deviceId>' flag` plus the device list, `Exited (1).`, `terminated`. **toolArgs `-d <device>` is mandatory** (with `flutter-tester`, also `--show-test-device`). |
| 4 | `vmServiceInfoFile` = the file written by `flutter run --vmservice-out-file` (bare string) + toolArgs | **Hangs silently**: attach response never arrives, no events beyond `initialized`, no error output (killed after 40 s). A later `hotReload`/`hotRestart` request even returns `success:true` although nothing is attached. |
| 5 | `vmServiceInfoFile` = JSON `{"uri":"ws://.../ws"}` + toolArgs | Works like #1. So the adapter wants the Dart-VM style info file (`{"uri": ...}`), not Flutter's out-file format. |
| 6 | neither `vmServiceUri` nor `vmServiceInfoFile`, toolArgs `-d flutter-tester ...` | Attach `success:true`, `capabilities` + `flutter.appStart` arrive, then nothing (the adapter waits to discover an app on its own). No error. Would need a timeout on our side. |
| 7 | ws URI + toolArgs + adapter started with `flutter debug_adapter --no-dds` | Works; breakpoint, hotReload, hotRestart all pass. Adapter reports `ws://.../ws/ws` (appends `/ws` to a URI that already ends in `/ws`, cosmetic; it still connects). Pass the **http** form with `--no-dds` to get a clean URI. |
| 8 | `hotReload {"reason":"manual"}` in attach mode (#1, #2, #5, #7) | Works. Response `success:true` with no body; output event `Reloaded 0 libraries in 339ms (compile: 11 ms, reload: 0 ms, reassemble: 149 ms).` (sample_app unchanged, so 0 libraries). `reassemble()` calls `bump()` and the breakpoint fires during reload. The response only arrives after the breakpoint is resumed. |
| 9 | `hotRestart {"reason":"manual"}` in attach mode | Works. Events: `thread exited(1)`, `output "Restarted application in 900ms."`, response `success:true`, `thread started(2)`, `stopped(entry)` immediately followed by adapter's own `continued`, then `stopped(breakpoint)` from `main()` -> `bump()`. Same entry-stop quirk as in launch mode. |
| 10 | `disconnect {"terminateDebuggee": false}` | `success:true`, output `Detached.`, `terminated` event, adapter exits 0 after ~0.5 s. **App (flutter_tester), the original `flutter run` and its DDS keep running** and kept answering later attaches. |
| 11 | `terminate` | Same as disconnect: `success:true`, `Detached.`, `terminated`, adapter exits 0. App keeps running. |
| 12 | `disconnect {"terminateDebuggee": true}` | Same: only `Detached.`; app keeps running. In attach mode the adapter never kills the app. |
| 13 | Disconnect while stopped at a breakpoint inside a reload (not continued) | `disconnect` succeeds; the next attach worked normally and the reload completed. No stuck state seen from this path. |

## Event order on attach (case #1, trimmed)

```
[   182ms] <- EVENT initialized {}                      (sent right after initialize response, before attach is processed)
[   182ms] -> attach {"cwd":"...","vmServiceUri":"ws://127.0.0.1:33171/xzgCOabbXpo=/ws","toolArgs":["-d","flutter-tester","--show-test-device"]}
[   184ms] -> setBreakpoints ... -> verified:false, "Breakpoint has not yet been resolved"
[   198ms] <- RESPONSE configurationDone success
[   208ms] <- RESPONSE attach success=true             (immediately, long before the app is attached)
[   231ms] <- EVENT output stderr (root warning x4)
[   462ms] <- EVENT capabilities {"capabilities":{"supportsRestartRequest":true}}
[   463ms] <- EVENT flutter.appStart {"appId":"66de67d8-...","deviceId":"flutter-tester","directory":null,"supportsRestart":true,"launchMode":"attach","mode":"debug"}
[  1967ms] <- EVENT output "Connecting to VM Service at ws://127.0.0.1:33171/xzgCOabbXpo=/ws"
[  1986ms] <- EVENT output "Connected to the VM Service."
[  2002ms] <- EVENT dart.debuggerUris {"vmServiceUri":"ws://127.0.0.1:33171/xzgCOabbXpo=/ws"}
[  2018ms] <- EVENT output stdout "GREETING: Hello v1"      (app's backlog output is replayed)
[  2058ms] <- EVENT thread {"reason":"started","threadId":1}
[  2138ms] <- EVENT flutter.appStarted {}
[  2139ms] <- EVENT dart.serviceRegistered x10 (reloadSources, hotRestart, flutterVersion, compileExpression, flutterMemoryInfo; once under s1.* and once under s3.*)
[  2140ms] <- EVENT flutter.serviceExtensionStateChanged (activeDevToolsServerAddress, connectedVmServiceUri)
[  2141ms] <- EVENT breakpoint {"breakpoint":{"column":11,"id":100000,"line":7,"verified":true},"reason":"changed"}
```

Observations:
- Same events as launch mode (`capabilities`, `flutter.appStart`, `dart.debuggerUris`, `thread`, `flutter.appStarted`, `dart.serviceRegistered`), but `flutter.appStart.launchMode` is `"attach"` and `directory` is `null`.
- **No `stopped(entry)` on attach** (the app is already running). The `stopped(entry)` only appears after `hotRestart`.
- Attach takes about 2.0-2.1 s from `attach` request to `flutter.appStarted` (vs about 12 s for a launch).
- A breakpoint set before the VM connection is "pending" and is verified through the `breakpoint(changed)` event when the connection completes.
- Reload sequence trimmed:
  ```
  -> hotReload {"reason":"manual"}
  <- EVENT stopped {"reason":"breakpoint","threadId":1}      (reassemble -> bump)
  -> stackTrace -> top frame bump .../lib/main.dart:7
  -> continue
  <- EVENT output "REASSEMBLE: 1" / "GREETING: Hello v1"
  <- EVENT output "Reloaded 0 libraries in 339ms (compile: 11 ms, reload: 0 ms, reassemble: 149 ms)."
  <- RESPONSE hotReload success=true
  ```

## The extra DDS (important)

Attaching to the DDS URI that `flutter run` already runs does **not** fail. The adapter starts its **own second DDS** on top of the first one, visible in `ps`:

```
dart development-service --vm-service-uri=http://127.0.0.1:39721/YTN-mI3NVKc=/ ...        <- from flutter run
dart development-service --vm-service-uri=http://127.0.0.1:33171/xzgCOabbXpo=/ws/ ...     <- started by the adapter (chained on the first DDS)
```

That second DDS is **orphaned (ppid 1) after every disconnect and every terminate**, in every attach run without `--no-dds` (same orphan bug the spike recorded for launch mode). With `flutter debug_adapter --no-dds` no second DDS is started and nothing is left behind (verified with `ps` after the run). Conclusion: `--no-dds` is not needed for correctness but it is the right thing for attach because the app already has a DDS.

Caveat: `--no-dds` also disables DDS for **launch** mode, so a launch session would then have no DDS (breakpoints etc. were not re-verified in launch mode with `--no-dds`). Apply it per session type (attach only), or test launch separately first.

## Other incidental observations

- The `flutter run` process and the app are unaffected by attach/detach cycles (several attach + reload + restart + disconnect cycles against the same app; app output keeps flowing in `run.log`).
- One probe run crashed while the app was in a `stopped(entry)` state after a hot restart, and the next attach showed `Reloaded 0 libraries in 138ms.` with no `reassemble` and no breakpoint hit until the app was restarted. Probably the isolate was left paused at the entry; not conclusively confirmed. Not reproduced by a clean disconnect.
- `hotReload` / `hotRestart` return `success:true` even when the adapter is not attached (cases 4 and 6, and after `terminated`). The proxy must not treat `success` as proof that a reload happened; wait for the `Reloaded ...` output or check state.
- The "Woah, running as root" banner arrives as 4 stderr `output` events (container artefact).

## Recommendation

**Attach config (init template / proxy):**
```json
{
  "request": "attach",
  "cwd": "${ZED_WORKTREE_ROOT}",
  "vmServiceUri": "<http or ws form from flutter run>",
  "toolArgs": ["-d", "<deviceId>"]
}
```
- `toolArgs` with `-d <deviceId>` is **mandatory** (without it the adapter dies with "More than one device connected"). Add `--show-test-device` for `flutter-tester`.
- Prefer the **`http://127.0.0.1:PORT/TOKEN/`** form (or the `ws://.../ws` form). Both work; with `--no-dds` http avoids the doubled `/ws/ws`.
- Do **not** use `vmServiceInfoFile` with the file written by `flutter run --vmservice-out-file`: it hangs silently. If a file is wanted, the proxy/template must write JSON `{"uri": "<ws uri>"}` itself. A simpler route: the proxy reads the bare-string out-file (or `app.debugPort.wsUri`) and puts the value into `vmServiceUri`.
- Do not send an attach without a URI/info file (silent wait).
- Add a watchdog in the proxy: if no `flutter.appStarted` arrives within about 15 s after `attach` (normal is about 2 s), treat it as a failed attach and show an error. This covers the silent-hang cases (#4, #6) and the missing-device failure, which shows up as `terminated` without any `flutter.appStart*`.

**Detecting "app started" in attach mode (for reload-on-save):** use the same signal as launch mode. `flutter.appStarted` (preceded by `dart.debuggerUris`) is emitted in attach mode too, about 2 s after `attach`. Use `flutter.appStart.launchMode == "attach"` to tell the modes apart. Reload-on-save should be enabled only after `flutter.appStarted`. Do not wait for `stopped(entry)` (not emitted on attach). Optionally also wait for the `dart.serviceRegistered` of `reloadSources`/`hotRestart`. Do not use the attach/launch response as the signal: attach returns `success:true` after about 25 ms, before anything is connected.

**Proxy adjustments for attach mode:**
1. Start the adapter with `--no-dds` for attach sessions (avoids the second DDS and its orphan). Not required for functionality.
2. If the adapter is started without `--no-dds`, the proxy must, after the adapter exits, kill the orphaned `development-service` whose `--vm-service-uri` is the attach URI (the spike's "inject `terminate` before `disconnect`" mitigation does **not** help here: terminate and disconnect behave identically in attach mode and both leave the orphan).
3. In attach mode the spike's "inject `terminate` before client `disconnect`" step is unnecessary (it does no harm: the app survives), but it must not be mistaken for "stop the app". If the product wants a "Stop" in attach mode to leave the app running, plain `disconnect` is right; stopping the app itself has to be done through the `flutter run` that owns it (not through the adapter).
4. Keep filtering `stopped(entry)` / matching `continued` after `hotRestart` (same as launch mode).
5. Do not rely on `hotReload` / `hotRestart` response `success` alone (see above); only inject them once `flutter.appStarted` was seen.
6. `terminate` and `disconnect` (with either `terminateDebuggee` value) never kill the app in attach mode, so no extra safeguard is needed to keep it running.

## Cleanup

All processes started for the probe (flutter run, flutter_tester, frontend_server, DDS processes, adapters, orphaned adapter-DDS) were killed by PID and verified gone with `ps`.
