# 2026-11-03-010: Phase 5 tests and Gate 5

## What was tested
- **Unit** (`cli/test/unit/**`, 726 tests): framing (1-byte chunks, several messages per chunk, split UTF-8, bad headers), injected-request seq range and swallowed responses (incl. late), launch rewriting and device precedence, hot-action coalescing/busy/timeouts (fake_async), Zed-style shutdown paths with fakes, control-channel auth/limits on real loopback sockets, session files, SDK resolution matrix (incl. Windows layouts via a fake host), `.bat` argument validation, process-tree kill with real processes, watcher filters/debounce/coalescing with real file-system save styles, DevTools URL building and browser launching, `init` merge cases, the schema check (every generated scenario validates against `FlutterRD.json`).
- **Integration** (`cli/test/integration/**`): a fake DAP client sends Zed's exact `initialize` and drives the **compiled** `flutter_rd dap` with the same argv the Zed extension builds, against the real `dart debug_adapter` (`fixtures/dart_console`) and the real `flutter debug_adapter` (a temp copy of `fixtures/sample_app` on `flutter-tester`). Each test asserts no leftover processes and no stale session file.
- **Rust** (`extension/`): 30 host tests, clippy (host + wasm32-wasip2), wasm release build.

## Gate 5 run (orchestrator, independent of the agents' own runs)
Command (from `cli/`): `dart format --output=none --set-exit-if-changed . ; dart analyze --fatal-infos ; dart test --exclude-tags integration --exclude-tags integration-dart ; dart test -t integration-dart -j 1 ; dart test -t integration -j 1`

```
Formatted 130 files (0 changed) in 0.34 seconds.
No issues found!
00:16 +726: All tests passed!
UNIT EXIT 0
00:19 +15: All tests passed!
IDART EXIT 0
04:46 +21: All tests passed!
IFLUTTER EXIT 0
```

Integration tests in that run (time, passed-so-far, name):
```
00:00 +0 cli_e2e_test.dart: without a debug session init writes valid debug.json and tasks.json, and is idempotent
00:00 +1 cli_e2e_test.dart: without a debug session init leaves a tasks.json with comments alone and exits 9
00:00 +2 cli_e2e_test.dart: without a debug session status with no sessions exits 0
00:00 +3 cli_e2e_test.dart: without a debug session reload and restart with no session exit 3 with guidance
00:00 +4 cli_e2e_test.dart: without a debug session doctor exits 0 and names the SDK
00:00 +5 cli_e2e_test.dart: without a debug session version prints the package version
00:00 +6 cli_e2e_test.dart: without a debug session status prunes a session file whose proxy is gone
00:00 +7 dart_console_test.dart: breakpoint, variables, step, stepIn, evaluate, run to the end
00:01 +8 dart_console_test.dart: session file describes the Dart session
00:02 +9 dart_console_test.dart: Zed's stop path: terminate, then the proxy is killed at once
00:03 +10 dart_console_test.dart: disconnect only (no terminate) leaves nothing behind
00:05 +11 stop_paths_test.dart: Dart adapter adapter crash: Error notice, terminated, proxy exits, no session file
00:06 +12 stop_paths_test.dart: Dart adapter adapter crash: the debuggee does not outlive the proxy
00:07 +13 stop_paths_test.dart: Dart adapter stdin EOF: the proxy cleans up and exits within 20 s
00:13 +14 stop_paths_test.dart: Dart adapter a killed proxy leaves a stale session file that status prunes
00:00 +0 flutter_attach_test.dart: attach by vmServiceUri: reload, reload on save, stop keeps the app
00:14 +1 flutter_attach_test.dart: disconnect-only stop in attach mode also leaves the app running
00:29 +2 cli_e2e_test.dart: with the Flutter tool devices --json is non-interactive and lists devices
00:29 +3 cli_e2e_test.dart: with the Flutter tool select-device rejects an id that is not connected (exit 7)
00:29 +4 cli_e2e_test.dart: with the Flutter tool select-device without a terminal exits 2
00:29 +5 cli_e2e_test.dart: with the Flutter tool a saved device is injected as -d on the next launch
00:44 +6 flutter_launch_test.dart: launch, breakpoint, status, reload, restart, DevTools, then no orphans
01:00 +7 flutter_launch_test.dart: deviceId in the launch entry is injected as -d
01:14 +8 flutter_launch_test.dart: reload that hits a breakpoint finishes once the user resumes
01:28 +9 flutter_launch_test.dart: reload before the app has started says it is still starting
01:46 +10 flutter_launch_test.dart: one reload from a parent folder reloads every Flutter app below it
02:13 +11 stop_paths_test.dart: Flutter adapter adapter crash: processes the adapter started are swept
02:26 +12 stop_paths_test.dart: Flutter adapter stdin EOF: the proxy stops the app and exits within 20 s
02:41 +13 flutter_reload_save_test.dart: a changed file reloads on save; identical content does not
02:58 +14 flutter_reload_save_test.dart: reloadOnSave "always" reloads identical content too
03:11 +15 flutter_reload_save_test.dart: reloadOnSave "off" never watches or reloads
03:26 +16 flutter_reload_save_test.dart: build, .dart_tool, ios and dot folders never reload
03:42 +17 flutter_reload_save_test.dart: two edits 10 ms apart cause exactly one reload
03:58 +18 flutter_reload_save_test.dart: a burst of 200 writes causes one reload (plus at most one)
04:13 +19 flutter_reload_save_test.dart: reloadOnSaveGlobs makes assets/*.json trigger a reload
04:27 +20 flutter_reload_save_test.dart: a save during a restart reloads after the restart
```

The Flutter tests prove the Definition-of-Done items headlessly through the proxy: breakpoint hit (`main.dart:7`), CLI hot reload (new string in the output, breakpoint hit again via `reassemble`), CLI hot restart (`main()` re-runs), reload on save (`reason: "save"`, injected seq ≥ 1e9, identical content ignored, ignored folders, debounce, 200-write burst), attach by `vmServiceUri` with `--no-dds` (app survives stop), DevTools URL answers HTTP 200, and Zed's stop path (`terminate` then kill) leaves nothing behind.

## History of this gate
- WP10b's own three full runs: 41/43 green. The 2 reds were a **real product bug** (after the adapter is SIGKILLed, its children were orphaned because descendants were only snapshotted at shutdown). The tests were kept red, not skipped. Fixed in `proxy.dart` (snapshots at start, on app/thread events and every 2 s on POSIX). One flaky check in the test harness itself was fixed by WP10b.
- Also fixed before this run: `dart debug_adapter` supports `hotReload` (dds 5.4.0 `adapters/dart.dart:951`) but never sends `flutter.appStarted`; Dart programs are now "started" on `dart.debuggerUris`, and `restart` is refused for them with a clear message (the Dart adapter has no hot restart).

## Not covered here
- macOS and Windows: only through CI (unit + `integration-dart` on all three OSes; Flutter suite on Linux). CI has not run yet (the draft PR will trigger it).
- Real Zed, real devices (Android/iOS/desktop window), web: see [MANUAL_ZED_TEST.md](../MANUAL_ZED_TEST.md).
- No integration test yet for hot reload of a long-running Dart program (unit-tested only).

## Gate 5: passed
