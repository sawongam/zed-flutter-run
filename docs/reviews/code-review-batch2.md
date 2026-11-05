# Code review, batch 2: WP1 (dap), WP2 (control), WP3 (sdk)

Reviewer: independent (wrote none of it). Scope: `cli/lib/src/{dap,control,sdk}/**` and their unit tests. `cli/lib/src/cli` (WP10a) not reviewed.
Baseline: `dart test test/unit/dap test/unit/control test/unit/sdk` passes (282 tests) on Linux. Proxy tests use fake_async, so they are deterministic.
Scratch programs: `/tmp/claude-0/-home-user-run-and-debug-flutter/32cd234d-2bba-5c41-b10d-b540117c3393/scratchpad/review2/epipe*.dart`.

Status: CONFIRMED = reproduced or proven from code; PLAUSIBLE = follows from code but not reproduced.

Summary: 0 blocker, 2 major, 9 minor, 6 nit.

## Major

### C1 (major, CONFIRMED) `client.flush()` can hang forever, which stalls `_finish` and skips cleanup
- `cli/lib/src/dap/proxy.dart:590` (`_finishTerminate`) and `:747` (`_finish`); `cli/lib/src/dap/channel.dart:234-242` (`flush`).
- Problem: `StreamDapChannel.flush()` awaits `IOSink.flush()` on stdout. Once a previous write has hit EPIPE (Zed died or closed the pipe), the sink is in an error state and `flush()` never completes. It does not throw. `_finish` awaits it before `_cleanup()`, so the session file is not deleted, the adapter tree is not swept, `_done` never completes, and `run()` never returns. `_finishTerminate` has the same problem, so a held `terminate` response is never released and `_terminateDone` never completes. `shutdown()` and `_handleDisconnect` then wait on it too.
- Evidence: `review2/epipe3.dart` (`dart epipe3.dart | true`) printed `UNCAUGHT: FileSystemException: writeFrom failed ... Broken pipe`, then `FLUSH HUNG` (the 2 s guard timer fired), then `flush returned`. Without a guard timer the Dart VM simply exits with code 0 when the event loop empties, so the adapter and its descendants are orphaned.
- Realistic path: Zed is SIGKILLed or crashes while the adapter is still emitting `output` events. A write fails with EPIPE, then stdin EOF arrives, then `shutdown`, then `_finish`, then `flush` hangs. `_clientGone` only suppresses writes made after the EOF.
- Fix:
  1. Bound every flush: `await _client.flush().timeout(const Duration(seconds: 2), onTimeout: () {})` inside `StreamDapChannel.flush()`, so all callers benefit.
  2. In the `StreamDapChannel` constructor, `if (output is IOSink) output.done.then((_) => _outputClosed = true, onError: (e) { _outputClosed = true; ... })`. Then `flush()` returns immediately and `send` stops writing.
  3. Move `_cleanup()` before `_client.flush()` in `_finish`. The flush only matters for delivering the last messages.
  4. Add a channel test with a sink whose `flush()` never completes, and a `proxy_test` case where `client.flush()` hangs and shutdown still finishes.

### C2 (major, PLAUSIBLE) A throwing `onShutdownStarted`, `onShutdownCleanup`, `inject` or rewriter step leaves a client request unanswered
- `cli/lib/src/dap/proxy.dart:226-232` (`_onClientMessage`), `:293-301` (`_rewriteLaunch`), `:279`.
- Problem: any exception in `_handleClient` is only logged (`catchError`). For `launch` or `attach`, if `_rewriter.rewrite` throws (for example the injected `savedDevice()` callback throws on a corrupt device file or an I/O error, or a non-Map `toolArgs` edge case), the request is dropped. Zed waits for a `launch` response indefinitely and the user's F5 hangs with no message.
- Evidence: code reading. The only protection is the queue-level `catchError`, which has no access to the request.
- Fix: in `_handleClient`, wrap the request path in try/catch. For `launch` and `attach`, on a rewrite error log it, send a `success:false` response (`makeResponse`) with a readable `message` plus a notice, or forward the original message unchanged. A generic fallback: any request whose handler throws before forwarding gets an error response. Add a test with a throwing `savedDevice`.

## Minor

### C3 (minor, CONFIRMED) Unhandled async EPIPE on stdout is only caught by the outer zone
- `cli/lib/src/dap/channel.dart:168-190`, `:222-231`.
- Problem: `send()` wraps `_output.add` in try/catch, but IOSink reports the broken pipe asynchronously through the `done` future, which nobody listens to. `epipe3.dart` shows `UNCAUGHT: FileSystemException` in the zone. `dap_command.dart:153` has `runZonedGuarded`, so today it is logged, not fatal. The channel itself is unsafe when used outside that zone.
- Fix: same as C1 step 2, listen to `output.done` and swallow or log it.

### C4 (minor, CONFIRMED) `send()` marks the output permanently closed on any exception
- `cli/lib/src/dap/channel.dart:226-230`.
- Problem: `jsonEncode`/`encodeDapMessage` failure (for example a non-encodable value in an injected or rewritten message) sets `_outputClosed = true`, and every later message to that side is dropped silently. One bad message kills the whole session's output.
- Fix: separate encoding from writing. Catch encoding errors per message (log and drop that message). Only mark closed on write or sink errors.

### C5 (minor, PLAUSIBLE) Terminate forwarded after its own deadline already fired
- `cli/lib/src/dap/proxy.dart:547-559`.
- Problem: `_terminateTimer` is armed before `await _startShutdown()`, which can take up to 3 s for the snapshot plus an unbounded `onShutdownStarted`. If the timer fires first, `_finishTerminate` sends the synthesized success. The handler then still forwards the real `terminate` to the adapter afterwards (`_sendToAdapter(message)` at line 559).
- Fix: after the `await`, `if (_terminateFinishing || _finishing) return;`. Also bound `onShutdownStarted` and `onShutdownCleanup` with a timeout (2 s) like the snapshot.

### C6 (minor, PLAUSIBLE) `_terminateDone` never completes if `_finish` runs first
- `cli/lib/src/dap/proxy.dart:737-745`, `:607-608`, `:660-661`.
- Problem: `_finish` cancels `_terminateTimer`. If `_finish` is entered through `_failStartup` or `_handleCrash` while a terminate is pending (`_terminateReceived && !_terminateFinishing`), nothing completes `_terminateDone`. Any later `shutdown()` or queued `disconnect` handler awaits it forever.
- Fix: in `_finish`, complete `_terminateDone` if it is not complete (and set `_terminateFinished`), or do not await `_terminateDone` when `_finishing`.

### C7 (minor, PLAUSIBLE) `adapter.exitCode.then(_onAdapterExit)` and the `unawaited(_finish...)` calls have no error sink
- `cli/lib/src/dap/proxy.dart:168-174`, `:549`, `:252`, `:627`.
- Problem: `_onAdapterExit`, `_finishTerminate` (try/finally with no catch) and `_finishDisconnect` return futures that are dropped. Any exception inside them (a bug, or `_cleanup` throwing) becomes an uncaught async error. In a zone without a handler that kills the proxy, and with it Zed's session. `_cleanupFuture ??= ...` also caches a failed future, so a second caller rethrows.
- Fix: add a small `_guard(Future<void> Function() body, String what)` helper. It catches, logs and still drives `_finish`. Use it at the call sites above.

### C8 (minor, PLAUSIBLE) Disconnect response is held until the adapter exits or 5 s pass, even when the adapter answered
- `cli/lib/src/dap/proxy.dart:390-393`, `:625-628`.
- Problem: `_heldDisconnectResponse` is stored on arrival, but nothing finishes the disconnect until adapter exit or the `exitWait` timer. If the adapter acknowledges `disconnect` but lingers (a Windows `.bat` parent that outlives `dart`, or a slow flutter tool), Zed waits the full 5 s before the response. Zed kills the proxy as soon as that response arrives, so the delay is user visible on every stop of an attach session.
- Fix: when the held response is stored, start a short grace timer (~500 ms) instead of waiting for `exitWait`. Then `_finishDisconnect` cleans up and sweeps. Add a test where the adapter answers but never exits.

### C9 (minor, CONFIRMED) Stale-session pruning deletes live sessions on transient protocol errors
- `cli/lib/src/control/control_client.dart:98-119`, `:208-216`; `cli/lib/src/control/session_store.dart:119-122`; locked in by `test/unit/control/session_store_test.dart:174`, `:203`.
- Problem: `ping` maps every `ControlClientException` that is not a timeout to `stale`, which deletes the file. That includes "closed without a reply" and reset. A live proxy closes the socket without a reply when it is at `maxConnections` (64, `control_server.dart:87`) or in `close()`. A slow connect that exceeds the 2 s connect timeout also becomes `stale` rather than `unresponsive`. The deleted file is only restored when the proxy next calls `update` (state change), so `reload` and `restart` report "no running app" until then. Pruning also races with PID reuse: `_deleteFile(c.$1)` deletes by path without checking that the file still holds the same token.
- Fix: prune only when it is certain: `ECONNREFUSED` (SocketException with osError code), `unauthorized` or a pid mismatch (already handled). Treat all other transport errors (connect timeout, reset, protocol, premature close) as `unresponsive` and keep the file. Before deleting, re-read the file and compare the token, or the pid plus `startedAt`. Update the two tests.

### C10 (minor, PLAUSIBLE) Rewrite failure paths and malformed `launch` arguments are silent
- `cli/lib/src/dap/launch_rewriter.dart:121`, `:72-76`.
- Problem: a `toolArgs` that is not a list (for example a string) is replaced by a new list containing only the injected device. The user's value is lost with no note. `_nonBlank` trims, but `_deviceInToolArgs` does not, so `-d " emulator-5554"` is treated as an existing device.
- Fix: add a note ("toolArgs must be a list; it was ignored") and surface it with the other notes. Low priority.

### C11 (minor, PLAUSIBLE) Session file and control port are reachable for token brute force and DoS by other local users
- `cli/lib/src/control/control_server.dart:37-38`, `:86-89`, `:125-129`.
- Problem: any local process can open 64 idle connections for 10 s each (`requestLineTimeout`) and block `reload`, `restart` and `ping` for everyone. This needs no token. The token itself (256 bits) cannot be guessed. The version check, JSON parse and `id` checks run before the token check, so an unauthenticated caller learns the supported protocol version. This is harmless but contradicts "no info leak on bad token".
- Fix: check the token first (parse JSON, then require `token`, then everything else). Use a shorter pre-auth timeout (2 s) and a per-connection cap of unauthenticated sockets lower than the total (for example 16 unauthenticated).

## Nits

### C12 (nit, CONFIRMED) `DapFrameDecoder` never shrinks its buffer
- `cli/lib/src/dap/framing.dart:63-91`. After one large message (up to 256 MiB cap) `_buf` stays at that capacity for the life of the session. `_compact` only moves data. Fix: shrink to 4096 when empty and capacity is greater than 1 MiB. `_findHeaderEnd` rescans the whole header on every chunk, which is quadratic only for pathological 8 KiB headers; start from `max(_start, _end - chunkLen - 3)`.

### C13 (nit, PLAUSIBLE) `inject` without a timeout and per-inject closures
- `cli/lib/src/dap/proxy.dart:183-212`. `HotActions._run` calls `inject(command, args)` with no timeout, so `_pending` keeps the entry until the session closes. A response that arrives late is swallowed (good), but entries and `_closed.future.then` closures accumulate for the session. Over a long session with hundreds of save-triggered reloads and an unresponsive adapter this is a small leak. Fix: pass a long timeout (for example `timeout + 30 s`) so `markTimedOut` moves it to the bounded late set.

### C14 (nit, PLAUSIBLE) Sweep has no grace between `terminated` and SIGTERM
- `cli/lib/src/dap/proxy.dart:719-724`, `cli/lib/src/sdk/process_tree.dart:416-420`. The doc comment says "only when processes may have survived", but the sweep runs as soon as the response and `terminated` are in. Any descendant still mid-exit gets SIGTERM immediately. Harmless for the flutter tool, but it can cut short an `adb`/`xcrun` child that was exiting normally. Fix: wait up to ~300 ms for the snapshot pids to disappear before signalling.

### C15 (nit, PLAUSIBLE) `.bat` argument validation hardening
- `cli/lib/src/sdk/process_spec.dart:20-47`. Rejected set: `\n \r " % ^ & | < > ! NUL` and a trailing backslash. Not rejected: `( ) , ; =` and non-ASCII (full-width look-alikes). `, ; =` act as batch parameter delimiters, so an argument containing them is split by `flutter.bat` into several parameters (argument smuggling, not command injection). `( )` can end a parenthesised block if the batch file expands `%*` inside one. The executable path itself (SDK path from user config) is never validated, so `%` in a path is expanded. No injection path to a new command was found for the vocabulary that is accepted. Fix: reject `( ) , ; =` for `.bat`/`.cmd` unless the value matches `safeIdPattern`, reject non-ASCII control chars, and validate the executable path for `%`, `!` and `^`. Add tests.

### C16 (nit, PLAUSIBLE) SDK resolution details
- `cli/lib/src/sdk/sdk_resolver.dart:96`, `:529-541`, `:497-502`, `:530`.
  1. `_versionPattern` accepts `.` and `..`, so `.fvmrc` `{"flutter": ".."}` or `.puro.json` `{"env": ".."}` resolves `versions/..` or `envs/../flutter`. Exploitation is limited because `bin/flutter` must exist there, but reject names that are `.`, `..` or start with `.`.
  2. `_fromRoot` only checks `bin/flutter` is a file, not that it is an SDK (for example `bin/internal/engine.version`). A wrapper script at `/usr/local/bin/flutter` is reported as SDK root `/usr/local` (PATH step, binDir named `bin`). `FlutterSdk.root` is then wrong, which affects `flutterVersion` and `FLUTTER_ROOT` use. Fix: require `bin/internal/engine.version` or `packages/flutter` to treat it as a root, otherwise treat as a launcher.
  3. A relative `flutterSdkPath` is made absolute against the process cwd (`_ctx.absolute`), not `projectDir`.
  4. `LocalSdkFileSystem.isExecutableFile` accepts any exec bit (`0x49`), not the caller's.

### C17 (nit, PLAUSIBLE) Housekeeping
- `*.tmp-*` files left by a crash in the sessions directory are never cleaned (`session_store.dart:107-109` only reads `*.json`). `atomicWriteString` temp files are created with the default umask inside the 0700 directory, which is fine by D4, but `FLUTTER_RD_STATE_DIR` on Windows pointing at a shared folder has no ACL protection. Document it.
- `ManagedProcess.terminateTree` on Windows only knows the adapter pid, so if the adapter has already exited its children are not found (accepted by plan section 4.4 and A12; keep in the doctor/docs known limitations).

## Checked, no problem found

- Framing: partial headers and bodies, many messages per chunk, split UTF-8, extra headers, header-name case, `Content-Length` limits (10 digits, 256 MiB), zero-length body (`FormatException` mapped to `DapFramingException`), header block limit.
- Seq: injected and synthetic seqs start at 1e9 (disjoint from Zed's counter). Responses to injected requests are swallowed, pending or late (bounded set of 64). Client messages are never renumbered. A client seq at or above 1e9 produces a notice and still passes through. Reverse requests (`runInTerminal`) and their responses pass untouched.
- Terminate path: response held until `terminated` seen plus adapter response, bounded by `terminateTimeout`, with synthesized success if the adapter never answers or dies. Cleanup runs before the response is sent, which matches Zed's `session.rs:2249-2299` (kill on response). Disconnect without terminate injects `terminate` for launch only, bounded. EOF, crash and idempotent `shutdown` are covered by tests.
- Control channel: `127.0.0.1` only, `Random.secure` 32-byte token, constant-time compare, 64 KiB line limit, request-line idle timeout that does not apply to slow handlers, one request per connection, token never logged or put in exception messages, session directory 0700, atomic writes with rename retry, deletion serialised after updates so a late update cannot resurrect the file.
- Process handling: process table re-read before each signal round, PID reuse guarded by start time, pids 0/1 and zombies skipped, reparented descendants only killed on identical start time, SIGTERM then SIGKILL with grace, no shell (`runInShell: false`), `runTool` kills the whole tree on timeout.
- SDK precedence matches plan section 4.4 (explicit, env, fvm link, `.fvmrc`, legacy, fvm cache, puro, `FLUTTER_ROOT`, PATH). An invalid explicit Flutter path is an error. `useFvm` strictness works. PATHEXT is honoured. A junction is treated as a link.

## Test gaps

- T1: no test for a client or adapter sink whose `flush()` never completes (C1), or an EPIPE after a write (C3).
- T2: no proxy test where `savedDevice` or the rewriter throws (C2), nor client seq at or above 1e9 followed by a response (swallow collision).
- T3: no test for `maxConnections` (64) in `control_server_test.dart`, nor for pruning when a live server drops a connection (the opposite is asserted today, see C9).
- T4: no test for adapter answering `disconnect` but not exiting (C8), nor `_finish` entered while a terminate is pending (C6).
- T5: Windows-only behaviour (`taskkill`) is only covered with a fake runner. Mark in CI which tests actually run on the Windows runner. `sdk_windows_test` and `process_spec_test` run on all OSes, which is good.
- T6: timing-sensitive real-socket tests that may be flaky on slow macOS or Windows CI runners:
  - `control_server_test.dart:153`, `:162`: 200-300 ms idle timers against an 800 ms handler. Use at least 1 s and 3x margins.
  - `session_store_test.dart:24`, `:230`: 250 ms ping timeout and a 400 ms concurrency bound. A refused loopback connect on Windows can take about 2 s, so the "connection refused" cases there are timing dependent.
  - `managed_process_test.dart` and `process_tree_test.dart` real-process kill tests use 200 ms to 2 s graces with 10 to 30 s guards. They are fine, but assert on outcomes, not elapsed time.
