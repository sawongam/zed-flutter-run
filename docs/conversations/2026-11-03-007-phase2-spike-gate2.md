# 2026-11-03-007: Phase 2 spike and Gate 2

## What was built
`spike/` (Dart, throwaway): a stdio DAP proxy around `flutter debug_adapter`, a localhost TCP + token control channel, a reload/restart client, and a fake DAP client that sends Zed's exact `initialize` arguments. `fixtures/sample_app/`: a counter app with a breakpoint target at `lib/main.dart:7` (`bump()`), called from `main()` and from `reassemble()`, and `GREETING: $kGreeting` prints. Details and findings: [spike/README.md](../../spike/README.md).

## Gate 2 result: passed
The spike agent ran it 3× (plus once with `type: "flutter"`); the orchestrator re-ran it independently:

```
$ cd spike && dart run bin/fake_client.dart
...
[ 14809ms] (c) after reload: top frame bump .../fixtures/sample_app/lib/main.dart:7
    out> GREETING: Hello v2
    out> Reloaded 1 of 754 libraries in 523ms (compile: 48 ms, reload: 237 ms, reassemble: 198 ms).
[ 14932ms] reload control result: {"ok":true,"durationMs":593,"response":{...,"command":"hotReload","request_seq":1000000000,"success":true}}
[ 14934ms] (b) PASS: reload produced Hello v2 in app output
[ 14934ms] (c) PASS: breakpoint hit again after reload
    out> Restarted application in 292ms.
[ 15700ms] restart PASS: main() re-ran (Hello v2 printed) and breakpoint hit again
[ 15704ms] no injected-request responses forwarded to client: OK
[ 16439ms] cleanup PASS: proxy + 4 descendants gone
[ 16440ms] timings: {launch_to_stopped_ms: 12993, reload_total_ms: 913, reload_proxy_reported_ms: 593, restart_total_ms: 766}
[ 16440ms] RESULT: PASS
```
Afterwards `ps` showed no `flutter_tester`, DDS, `frontend_server` or proxy processes.

(a) breakpoint through the proxy ✔, (b) control-channel reload ✔, (c) breakpoint after reload ✔, hot restart ✔, cleanup ✔.

## Findings that change the design
1. **`disconnect` alone orphans the app.** With `disconnect` (even `terminateDebuggee: true`) the adapter exits but `flutter_tester` and DDS keep running (ppid 1). Sending `terminate` first cleans up. → The proxy owns shutdown: on a client `disconnect` without a prior `terminate`, it injects `terminate`, waits (bounded) for `terminated`, then forwards `disconnect`; as a last resort it kills the adapter's process tree. (Checked on `flutter-tester` only.)
2. **`capabilities {supportsRestartRequest: true}` arrives ~0.7 s after launch** (confirmed in the proxy log). So Zed's `debugger::RerunSession` should send DAP `restart`, which the Flutter adapter maps to hot restart. Needs the real-Zed check.
3. **Transient `stopped(reason: entry)`** at launch and after each hot restart; the adapter resumes by itself. A client that sends `continue` for it can lose the real breakpoint stop. Zed doesn't auto-continue, so the effect in Zed is probably a short "paused" flicker. Kept on the watch list; not filtered in the MVP (filtering could hide a real `stopOnEntry`).
4. **A breakpoint hit during reload delays the `hotReload` response** until the user resumes. Control requests need a long timeout and the CLI must say "waiting (app paused at a breakpoint?)".
5. The `hotReload` / `hotRestart` responses have no `body`; the human-readable result ("Reloaded 1 of 754 libraries in 523ms") arrives as normal `output` events, which Zed shows. The proxy only needs to add messages for failures and for save-triggered reloads.
6. No `type` needed in launch args; seq collisions didn't occur with a disjoint range, but ADR 0004's renumbering stays (robust if a client ever uses big seqs).
7. Timings on this container: launch→breakpoint ≈ 12–13 s (first compile), reload ≈ 0.6–0.9 s, restart ≈ 0.7 s.

## Housekeeping
Commit b229347 captured `fixtures/sample_app/lib/main.dart` mid-test with `Hello v2`; restored to `Hello v1` in the next commit. The real integration test must restore the fixture in a `finally` and work on a temp copy of the app instead of the checked-in fixture (decided for Phase 4).
