# Spike: DAP proxy + control channel for Flutter in Zed

Proof of concept, ugly on purpose. Pure Dart (no Flutter dependency), headless.

## Layout
- `bin/proxy.dart` DAP proxy over stdio. Spawns `flutter debug_adapter`, forwards both ways (Content-Length framing in `lib/framing.dart`, handles partial and multiple messages per chunk), logs all traffic (`--log`), captures `dart.debuggerUris`, runs a control server on 127.0.0.1:0 with a random token and writes `{port, token, pid, vmServiceUri}` to `--session-file`. Control commands `reload`, `restart`, `status` are injected as DAP `hotReload` / `hotRestart` (`{"reason":"manual"}`) with seq >= 1000000000; the adapter's response is swallowed, not forwarded to the client.
- `bin/reload.dart --session-file <p> [reload|restart|status]` control client; prints the result JSON.
- `bin/fake_client.dart` fake Zed driving everything end to end (see below).
- `../fixtures/sample_app` Flutter counter app. **Breakpoint target: `lib/main.dart` line 7** (`final y = x + 1;` inside `bump`). `bump` is called from `main()` (startup, and again after every hot restart) and from `State.reassemble()` (on every hot reload). `kGreeting` is printed from `main()` and `build()` as `GREETING: ...`. `flutter test` passes.

## Run
```
cd spike && dart pub get
dart run bin/fake_client.dart [--out <dir>] [--with-type] [--terminate-first] [--no-mitigation]
```
Needs `flutter` on PATH and the `flutter-tester` device (passed with `--show-test-device`). Writes proxy log + session file to `--out` (default `$TMP/spike_out`). The fake client rewrites `kGreeting` to `Hello v2` and ALWAYS restores `main.dart` (finally block). Exit 0 = pass. Every wait has a timeout (60-90s).

## What each step proves
1. `initialize` with Zed's exact args, `launch` (not awaited, like Zed), `initialized`, `setBreakpoints`, `configurationDone`, wait `stopped(breakpoint)`, `stackTrace` top frame = `lib/main.dart:7`, `continue`: **(a)** breakpoints work through the proxy.
2. Rewrite `Hello v1` to `Hello v2`, `reload.dart reload`: proxy injects `hotReload`; app prints `GREETING: Hello v2`: **(b)** control-channel hot reload works.
3. During that reload `reassemble()` calls `bump()` and the breakpoint fires: **(c)** breakpoints work after a reload (the Dart VM keeps them across the reload).
4. `reload.dart restart`: `hotRestart`; `main()` re-runs, prints `Hello v2`, hits the breakpoint again.
5. `disconnect`: proxy exits, `flutter_tester`, DDS, frontend_server are gone (checked via the process tree captured before disconnect; polls /proc up to 10s).

## Actual output of a passing run (trimmed)
```
[     0ms] initialize
[   561ms] launch (not awaited, like Zed)
[   564ms] got initialized
[   573ms] setBreakpoints -> [{"id":100000,"message":"Breakpoint has not yet been resolved","reason":"pending","verified":false}]
    out>   /
    out> Launching lib/main.dart on Flutter test device in debug mode...
    out> Connecting to VM Service at ws://127.0.0.1:37881/97E5NNAIeIU=/ws
    out> Connected to the VM Service.
    out> GREETING: Hello v1
[ 12458ms] (a) initial: top frame bump /home/user/zed-flutter-run/fixtures/sample_app/lib/main.dart:7
[ 12468ms] launch response success=true
[ 12470ms] (a) PASS: breakpoint hit through proxy; app started with Hello v1
[ 12473ms] event kinds seen: [initialized, output, capabilities, flutter.appStart, dart.debuggerUris, thread, stopped, flutter.appStarted, dart.serviceRegistered, breakpoint, continued]
[ 12474ms] session file keys: [port, token, pid, vmServiceUri]
    out> BUMP: 2
    out> GREETING: Hello v1
[ 12811ms] proxy captured vmServiceUri: ws://127.0.0.1:37881/97E5NNAIeIU=/ws
[ 12811ms] rewriting kGreeting -> Hello v2
[ 13456ms] (c) after reload: top frame bump /home/user/zed-flutter-run/fixtures/sample_app/lib/main.dart:7
    out> REASSEMBLE: 1
    out> GREETING: Hello v2
    out> Reloaded 1 of 754 libraries in 359ms (compile: 44 ms, reload: 135 ms, reassemble: 156 ms).
[ 13577ms] (b) PASS: reload produced Hello v2 in app output
[ 13577ms] (c) PASS: breakpoint hit again after reload
    out> Restarted application in 262ms.
    out> GREETING: Hello v2
[ 14272ms] restart: top frame bump /home/user/zed-flutter-run/fixtures/sample_app/lib/main.dart:7
[ 14278ms] restart control result: {"ok":true,"durationMs":320,"response":{"seq":111,"type":"response","command":"hotRestart","request_seq":1000000001,"success":true}}
[ 14279ms] restart PASS: main() re-ran (Hello v2 printed) and breakpoint hit again
[ 14282ms] no injected-request responses forwarded to client: OK
    out> BUMP: 2
[ 14353ms] process tree before disconnect: proxy=7222 descendants={7256: /opt/sdk/flutter/bin/cache/dart-sdk/bin/dartvm --resolved_executable_name=/opt/sdk/flutter/bin/cache/dart-sdk/bin/dart --executable_name=/opt/sdk/flutter/bin
    out> Application finished.
    out> 
Exited.
[ 14991ms] proxy exited with 0
[ 14995ms] cleanup PASS: proxy + 4 descendants gone
[ 14996ms] timings: {launch_to_stopped_ms: 11863, reload_total_ms: 763, reload_proxy_reported_ms: 425, restart_total_ms: 700}
[ 14996ms] RESULT: PASS
```
All 3 consecutive runs (plus one with `--with-type`) passed; launch-to-stopped 11.7-12.5 s, reload 0.75 s end to end (adapter reports "Reloaded ... in ~400ms"), restart 0.7 s.

## Findings
**Response shapes** (from the proxy log; no `body` in either):
```
-> {"seq":1000000000,"type":"request","command":"hotReload","arguments":{"reason":"manual"}}
<- {"seq":107,"type":"response","command":"hotReload","request_seq":1000000000,"success":true}
-> {"seq":1000000001,"type":"request","command":"hotRestart","arguments":{"reason":"manual"}}
<- {"seq":111,"type":"response","command":"hotRestart","request_seq":1000000001,"success":true}
```
Human-readable progress ("Reloaded 1 of 754 libraries in 380ms (compile: ..., reload: ..., reassemble: ...)", "Restarted application in 477ms.") arrives as ordinary `output` events (category stdout/console), not in the response. A failed reload was not exercised (not tested what `success:false` looks like).

**`type` in launch args:** not needed. Launch with only `program`, `cwd`, `toolArgs` works; adding `type:"flutter", request:"launch"` is also accepted (tested). Extra keys are ignored.

**Events seen** (in order): `initialized` (sent right after the `initialize` response, before `launch` is even handled), `output` (including the root-user warning as stderr), `capabilities {supportsRestartRequest:true}` (dynamic), `flutter.appStart {appId,deviceId,directory,supportsRestart,launchMode,mode}`, `dart.debuggerUris {vmServiceUri}`, `thread`, `stopped(entry)`, `flutter.appStarted {}`, `dart.serviceRegistered` (reloadSources, hotRestart, flutterVersion, compileExpression, flutterMemoryInfo), `breakpoint (changed, verified)`, `continued`, `terminated`. `launch` response arrives within ~25 ms, long before the app is running (12 s later); `setBreakpoints` returns `verified:false / pending` and is resolved later via a `breakpoint` event.

**Seq collisions:** not an issue. The adapter echoes `request_seq`; the proxy matches responses to its injected range (>= 1e9) and swallows them; the client's seqs are tiny. Adapter-originated seqs (event/response `seq`) are independent. Verified in the log that no response with an injected `request_seq` reaches the client.

**Surprises**
1. **Transient `stopped(reason: entry)`** after launch (the app is started `--start-paused`). The adapter then resumes by itself after `flutter.appStarted`. If the client sends `continue` for the entry stop, it races with the adapter's own resume and the real breakpoint hit is lost (we saw `stopped(breakpoint)` immediately followed by `continued`, then `stackTrace` failing "Thread 1 is not paused"). Zed will show a brief entry stop; the proxy could filter `stopped(entry)` + the matching `continued` events (untested) so Zed never offers a bogus pause. Hot restart also emits `stopped(entry)` again.
2. **A breakpoint inside `reassemble`/`main` blocks the reload/restart response** until the user resumes. The control client must not assume a fixed latency (we use long timeouts; the proxy's inject has 60 s).
3. **Plain `disconnect` (even with `terminateDebuggee:true`) leaves `flutter_tester` and the `dart development-service` (DDS) process running as orphans (ppid 1)**, while the adapter itself exits 0. Sending `terminate` first cleans everything. The proxy now injects `terminate` and waits for its response before forwarding a client `disconnect` (`--no-terminate-on-disconnect` / fake client `--no-mitigation` reproduces the orphans). frontend_server takes a second or two to exit. This is flutter-tester specific at least; recheck on a real device/desktop target.
4. `supportsProgressReporting:false` made no visible difference: the adapter emits no `progressStart` events at all in this flow (reload progress is plain `output`); `dart.progress*` custom events were not seen.
5. The "running as root" warning is forwarded as 4 stderr `output` events.
6. Defunct (zombie) frontend_server processes remain in this container because pid 1 does not reap; the checker treats zombies as dead.

**Decisions:** no deps (dart:io only); control protocol is newline-delimited JSON over TCP with the token in each request; session file deleted by the proxy on exit; proxy exits when the adapter exits, and kills the adapter 5 s after client stdin closes without disconnect.
