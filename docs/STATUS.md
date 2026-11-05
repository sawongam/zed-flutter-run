# STATUS: Flutter Run & Debug in Zed (`flutter_run` 0.1.0, branch `build/mvp`)

- **Date:** 2026-11-03 (end of the autonomous cloud run)
- **Where:** branch [`build/mvp`](https://github.com/sawongam/zed-flutter-run/tree/build/mvp), draft PR [sawongam/zed-flutter-run#1](https://github.com/sawongam/zed-flutter-run/pull/1) against `master`. Nothing was pushed to `master`.
- **Published:** nothing. No pub.dev, crates.io, Homebrew, Scoop, Zed registry, GitHub release, tag, or issue post. The steps are in [RELEASE.md](RELEASE.md).

**Short version:** the proxy + CLI and the Zed extension are built, reviewed three times over, and proven **headlessly** against the real `flutter debug_adapter` and `dart debug_adapter`. Breakpoints, hot reload, hot restart, reload on save, attach, DevTools URL and clean stop all pass through the proxy on a real sample app. **Nothing has been run inside real Zed or on a real device yet**; that's your first job ([MANUAL_ZED_TEST.md](MANUAL_ZED_TEST.md)).

## 1. What works, and how it was checked

All checks ran in a Linux cloud container (Ubuntu 24.04, x86_64) with Flutter 3.47.9 / Dart 3.13.7 and Rust 1.97, by the orchestrator, independently of the agents that wrote the code. Final local run (Gate 6): format 0 changed, analyze clean, **762 unit**, **15 integration-dart**, **21 Flutter integration** tests passed, Rust 30 tests + wasm build ([log](conversations/2026-11-03-011-phase6-7-hardening-release-readiness.md)). Later CI fixes raised the unit count to 772 (all passing).

| Feature | Verified how | Evidence |
|---|---|---|
| DAP proxy between Zed and `flutter debug_adapter` (stdio, Content-Length framing) | A fake DAP client sends **exactly the `initialize` Zed sends** (read from Zed's source) to the **compiled** `flutter_run dap`, started with the **same argv the Zed extension builds** | `cli/test/integration/*`; [Gate 5 log](conversations/2026-11-03-010-phase5-tests-gate5.md) |
| Breakpoints through the proxy | Breakpoint at `lib/main.dart:7` hits on `flutter-tester`; stack trace, variables, step, continue | `flutter_launch_test`, `dart_console_test` |
| Hot reload (`flutter_run reload`, Zed task / keybinding) | Changing a string then `reload` shows the new string in the app output, and the breakpoint hits again via `reassemble()` | `flutter_launch_test` |
| Hot restart (`flutter_run restart`) | `main()` re-runs with the new code; breakpoint hits again | `flutter_launch_test` |
| Reload on save | Editing a file in the project triggers `hotReload {reason:"save"}` (seq ≥ 1e9, response swallowed); identical content doesn't; `always`/`off` modes; `build/`, `.dart_tool/`, `ios/`, dot-folders ignored; two edits 10 ms apart → one reload; 200-file burst → 1–2 reloads; `reloadOnSaveGlobs` (e.g. `assets/**.json`); a save during a restart reloads after it | `flutter_reload_save_test` |
| Device selection | `devices --json`, `select-device --device`, saved device injected as `-d`; `deviceId` in debug.json wins | `cli_e2e_test`, `flutter_launch_test`, unit tests |
| Attach | Attach by `vmServiceUri` to a `flutter run --machine` app (adapter started with `--no-dds`); reload and reload-on-save work; stop detaches and the app keeps running | `flutter_attach_test`; [attach probe](research/attach-probe.md) |
| DevTools | `flutter_run devtools --print` builds the DDS-served URL; an HTTP GET returns 200 with the DevTools page | `flutter_launch_test`; WP6 real check |
| Stop / cleanup | Zed's real stop path (**`terminate`, then the proxy is killed**, per Zed `session.rs:2249-2299`), `disconnect` only, stdin EOF, adapter crash (SIGKILL): no leftover `flutter_tester` / DDS / frontend_server / dartvm processes, no stale session file | `stop_paths_test`, `dart_console_test`, `flutter_launch_test` |
| Control channel | Loopback-only TCP + 32-byte token, checked first; size/idle/connection limits; stale-file pruning | unit tests on real sockets; security review |
| `init` | Writes `.zed/debug.json` + `.zed/tasks.json` that validate against the extension's JSON schema; idempotent; leaves JSONC files alone (exit 9) | `cli_e2e_test`, `schema_test`, unit tests |
| SDK discovery | explicit → `FLUTTER_RUN_FLUTTER_SDK` → `.fvm/flutter_sdk` → `.fvmrc`/legacy fvm config → fvm cache → puro → `FLUTTER_ROOT` → PATH; Windows `flutter.bat` layouts | unit tests with fake SDK trees; real SDK via PATH |
| Rust Zed extension | Builds for `wasm32-wasip2` against `zed_extension_api` 0.7.0 (what Zed's dev-extension builder runs); host unit tests for argv/env/cwd/checksum/asset logic | `cargo test` (30), clippy host + wasm, `cargo build --release --target wasm32-wasip2` (~289 KB) |

Code quality gates: `dart format` (0 changed), `dart analyze --fatal-infos` (no issues), `cargo fmt --check`, `cargo clippy -D warnings` (host and wasm).

Reviews done (all independent of the authors; findings and resolutions are in [docs/reviews/](reviews/) and ADRs [0006](decisions/0006-plan-review-resolutions.md), [0007](decisions/0007-phase6-review-resolutions.md)): 2 plan reviews, 2 per-batch code reviews, 3 Phase 6 reviews (correctness, security, architecture & docs) plus a verification pass by the same reviewers.

## 2. What is NOT tested (be careful here)

**Needs real Zed (couldn't run a GUI here):**
- The extension loading in Zed as a dev extension, the `FlutterRun` adapter appearing next to the official `Dart` adapter, and Zed launching our proxy. The Zed side was checked only by reading Zed's source (commit b61f33f8).
- Our keybindings (`ctrl-f5` reload, `ctrl-shift-f5` restart (`shift-cmd-f5` on macOS), `ctrl-alt-shift-d` DevTools, all in `Workspace && debugger_session`) and task options (`reveal`, `hide`, `save`) in a running Zed.
- What our console notices look like in Zed's Debug Console (ANSI colours).
- Zed's own restart button / `debugger::RerunSession` → DAP `restart` → hot restart (the adapter advertises `supportsRestartRequest`; Zed's handling is from source only).
- The `select-device` prompt inside a Zed task terminal.
- macOS: a Dock-launched Zed may not see your shell PATH; the `dap.FlutterRun.binary` setting is the fallback.

**Needs a real device / other platforms:**
- Android emulator, iOS simulator, physical phones, Linux/macOS/Windows desktop windows, Chrome/web. Only the headless `flutter-tester` device was used.
- **macOS** only through CI (unit tests, `integration-dart`, compile and Rust pass there); never run by hand. **Windows** only through CI: unit tests and the `integration-dart` suite (real `dart debug_adapter` through the compiled proxy, incl. Zed-style stop, adapter crash and EOF cleanup) pass on `windows-latest`; the Flutter suite (`flutter.bat` launching, hot reload on a Flutter app) has **not** run on Windows, and the `rundll32` browser launch is unit-tested only.
- Opening DevTools in a real browser (only the URL and an HTTP 200 were checked).

**CI:** GitHub Actions runs on every PR update: unit tests + `integration-dart` on Linux, macOS and Windows; the Flutter integration suite on Linux; `dart compile exe` per OS; Rust checks. **Latest run [41741647402](https://github.com/sawongam/zed-flutter-run/actions/runs/41741647402) (2026-11-03) was a failure, not green:** every job passed (Version consistency, Dart on ubuntu and **macOS**, Rust on all three OSes, Flutter integration on Linux) except **Dart (windows-latest)**, where one unit test, `session files update is atomic`, failed with `Access is denied` (errno 5) while renaming the session file. That is a Windows sharing-violation flake: the test's reader had the file open during the rename and the production retry budget (10 x 50 ms) was too short. The fix (rename retry now backs off over about 5 s; the test reader sleeps 2 ms between reads) is in the working tree and **has not been re-run on Windows CI yet**. The previous run, 41740646030, was **cancelled**, not green. CI earlier found and we fixed 28 Windows unit failures, a Windows orphan-process bug after an adapter crash, and a reload-on-save flake on slow runners (see conversation 011).

The Flutter integration suite has only run on Linux in CI; on Windows the `flutter.bat` launch path and hot reload on a Flutter app are untested.

**Local re-verification (Arch Linux, Flutter 3.47.0 / Dart 3.13.0, not the 3.47.9 / 3.13.7 of the original run):** `dart format` 0 changed, `dart analyze --fatal-infos` clean, 773 unit, 15 `integration-dart`, 21 Flutter (flutter-tester) integration tests passed; compiled binary prints `flutter_run 0.1.0` for `--version`, `-V` and `version`. For this the fixture `sdk:` constraint was lowered from `^3.13.7` to `^3.5.0` so the fixture resolves on older Dart.

**Release path:** the extension's download fallback has **no pinned checksums** (no release exists), so in this build it never downloads; it tells you to install `flutter_run` instead. That's expected until [RELEASE.md](RELEASE.md) is followed.

## 3. Known issues and limitations
1. **Zed has no API for buttons, a device picker or on-save hooks.** Hot reload/restart/devices/DevTools are tasks + keybindings; reload on save is our own file watcher. (Upstream zed#51873 was closed unmerged.)
2. **Two-step install:** the Zed extension **and** `flutter_run` on PATH (tasks can only run commands on PATH). The proxy prints a notice if `flutter_run` isn't on PATH.
3. **Registry submission needs a human**: the Zed extensions repo bans autonomous agents from contributing (`AI_POLICY.md`). Reviewers may also ask why it isn't part of the official Dart extension.
4. **If the proxy itself is SIGKILLed** (not Zed's normal stop, which we handle), the adapter and app can be left running and the session file stays until the next `flutter_run status`/`reload` prunes it. On Windows, process trees are read from `Win32_Process` via PowerShell (or `wmic`); if neither is available, cleanup falls back to `taskkill /T`, which can't reach children of an already-dead adapter.
5. A dead session whose port was later reused by a service that accepts connections but never replies is shown as "unresponsive" instead of being pruned. It doesn't block other sessions.
6. **Pure Dart programs:** breakpoints and hot reload work; hot restart and DevTools don't (the Dart adapter doesn't support them). Reload on save for Dart programs is unit-tested only.
7. `vmServiceInfoFile` must contain JSON `{"uri": "..."}`; the file `flutter run --vmservice-out-file` writes is a bare string and makes Flutter's adapter wait forever. Use `vmServiceUri`.
8. Flutter 3.47.9 answers a hot reload even while the app is paused at a breakpoint (after ~2 s), so the CLI's "app may be paused" message rarely shows.
9. Edits in sibling path packages (monorepo) don't trigger reload on save in 0.1.0 (only `lib/`, `bin/` for Dart, and `reloadOnSaveGlobs` folders are watched).
10. No "Run without debugging" key; use the "Flutter: Run (no debug)" scenario from the F4 picker.

## 4. Your next steps
1. **Run [MANUAL_ZED_TEST.md](MANUAL_ZED_TEST.md)** on your Arch machine (Zed 1.26.x, Flutter via fvm, official Dart extension installed). It takes about 30–45 minutes and has a results table to paste into `docs/conversations/`. Most important checks: the dev extension loads; F4 shows `FlutterRun` scenarios; a breakpoint hits; `ctrl-f5` hot reloads; saving reloads; stop leaves nothing running.
2. Push the Windows flake fix and confirm the Windows CI job goes green (macOS and Linux jobs passed on the latest run).
3. If you have them, repeat the key manual steps on macOS and Windows, and with an Android emulator / iOS simulator.
4. Read [docs.flutter.dev/brand](https://docs.flutter.dev/brand) once (it was blocked here) and re-check the names in [research/naming.md](research/naming.md) before publishing.
5. When happy: merge the PR, then follow [RELEASE.md](RELEASE.md) (tag, build binaries with the artifact-only release workflow, create the GitHub release yourself, pin checksums in `extension/src/checksums.rs`, `dart pub publish`, Homebrew/Scoop, and a **human-written** Zed registry PR).

## 5. Where to look
- How it works: [ARCHITECTURE.md](ARCHITECTURE.md). How it was planned: [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md). Why: [decisions/](decisions/). What happened, phase by phase: [conversations/](conversations/) 005–011.
- User docs: [../README.md](../README.md). Contributing: [../CONTRIBUTING.md](../CONTRIBUTING.md). Security model: [../SECURITY.md](../SECURITY.md).
