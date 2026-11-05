# 0006: Plan-review resolutions (install model, shutdown, simplifications)

- **Date:** 2026-11-03
- **Status:** Accepted (orchestrator). Amends [0004](0004-architecture-accepted-with-amendments.md) §2 and §5.
- **Inputs:** [architecture review](../reviews/plan-review-architecture.md) (A1–A22), [UX review](../reviews/plan-review-ux.md) (U1–U25). A2 was re-checked by the orchestrator in Zed's source: `crates/project/src/debugger/session.rs:2249-2299` @ b61f33f8 sends `terminate` (when `supportsTerminateRequest`) else `disconnect`, and **kills the adapter process as soon as that response arrives**.

## Decisions

### D1. Install model: the CLI must be on PATH (A1, U1, U2, U5, A3)
Zed tasks can only run commands on the shell PATH, and the extension's download directory isn't on it. So the supported install is **two steps: the Zed extension + the `flutter_rd` CLI on PATH** (standalone release binary, Homebrew/Scoop later, or `dart pub global activate`).
- The extension resolves: `dap.FlutterRD.binary` → `flutter_rd` on the worktree PATH (prefer `flutter_rd.exe` over a `.bat` shim on Windows) → pinned-checksum download (so debugging still works) → clear error.
- When the proxy runs but `flutter_rd` is not on PATH, it prints **one** console notice: tasks won't work, here is my path, here is how to add it (per OS), see README.
- Messages never tell the user to run a command that doesn't work yet. Until 0.1.0 is published they point to the README install section (which documents `dart pub global activate --source git … --git-path cli` and building from source).
- On stdin EOF the proxy always shuts down, so a `.bat` wrapper killed by Zed (only `cmd.exe` dies) still lets the real proxy exit.

### D2. Shutdown follows Zed's real stop path (A2, A7, U19)
The proxy treats a client `terminate` as the start of shutdown: forward it, then **hold the `terminate` response** until the adapter has answered *and* cleanup is done (session file deleted, watcher stopped, surviving descendants swept), bounded at 5 s, then forward the response. `disconnect` without a prior `terminate` keeps the injected-`terminate` mitigation from the spike. stdin EOF and adapter exit trigger the same cleanup. Integration tests cover terminate→kill, disconnect, EOF and adapter crash.

### D3. Seq handling: disjoint range, no renumbering (A16; amends 0004 §2)
Renumbering every request breaks DAP `cancel` (`requestId`) unless rewritten too, for no gain: Zed's counter starts at 1 and never approaches 2³⁰. Injected requests use seq ≥ 1 000 000 000 from the proxy's counter; their responses are swallowed; everything else passes through untouched. Proven in the spike.

### D4. Simplifications (A15, A17, A18, A19, U-defaults)
- **Locator deferred** (post-MVP): it only works when the user sets `languages.Dart.debuggers`, and can't be tested here.
- **No DevTools fallback server** and one URL style (DDS-served `…/devtools/<page>?uri=…`). If DDS is off (`--no-dds`), say so.
- Session files: named `<pid>.json`, directory mode 0700 is the protection (no per-file chmod); no control `status` command (the CLI reads the session file, `ping` checks liveness).
- No `init --worktree`; no per-module `strings.dart` (messages live next to the code, kept in plain, translatable sentences); no hash baseline in the watcher (superseded: an arm-time baseline was added later, ADR 0007 P7).

### D5. Reload targeting (A4, A9)
`reload`/`restart` act on matching sessions that are alive and started; not-started sessions are reported and skipped, unresponsive ones are reported with a hint and don't block others. A save-triggered reload never fails because of a manual one: overlapping reloads coalesce. A save during a restart runs after it.

### D6. Watcher uses an allow-list (A5, A21, U8)
Watch `lib/` (and `bin/` for Dart programs) plus directories named by `reloadOnSaveGlobs`' static prefixes. Never `ios/Pods`, `android/.gradle`, `build/`, `.dart_tool/`. One console notice when armed ("Reload on save is on for lib/; set reloadOnSave to off to disable"). Generated scenarios set `reloadOnSave` explicitly so it's discoverable.

### D7. Devices (U4, U9, U11)
- Saved device lives in the **per-user state dir** keyed by project (survives `flutter clean`, never pollutes the repo).
- When no device is configured, the proxy says which device source it used, and adds a "run Flutter: Select Device" hint when the launch fails with Flutter's "more than one device" or "no devices" errors.
- `emulators` (list + `--launch`) is in the MVP, with a "Flutter: Launch Emulator" task.

### D8. Visibility of task results (U3, U10, U6, U7)
Reload/restart tasks use `reveal: "no_focus"`, `hide: "on_success"`, so failures stay visible. Reload failures add "try Hot Restart" to the console notice. README and `init` output explain Zed's keys (F4 picker, F5 rerun/continue, Shift-F5 stop) next to our ctrl-f5 / ctrl-shift-f5 bindings, and say these only work while a session runs.

### D9. Attach is probed before implementation (A6)
A short probe (attach `flutter debug_adapter` to a `flutter run --machine` app by `vmServiceUri`, then `hotReload`) runs before Phase 4; its result is written into the plan.

### D10. Test reach (A7)
CI runs the `dart debug_adapter` integration test on Linux, macOS and Windows; the `flutter-tester` integration suite runs on Linux (and on macOS/Windows if it proves stable there).

## Consequences
Fewer moving parts in the proxy and control channel; a clear, documented two-step install; Zed's real stop path is the tested path.
