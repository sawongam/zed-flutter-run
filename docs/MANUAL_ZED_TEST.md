# Manual test in real Zed

Nothing in this project has been run in a real Zed yet (the cloud container has no GUI; risk R14 in [risk-register](research/risk-register.md)). This checklist is for you, on your machine (Zed 1.26.x, Arch Linux, Flutter via fvm, official Dart extension installed). It should take 60 to 90 minutes. Expected behaviour is described in [ARCHITECTURE.md](ARCHITECTURE.md).

How to use it: tick each box, and where a step fails run the "if it fails, capture" line before moving on. At the end fill the results table (section 16) and paste it into `docs/conversations/<date>-NNN-manual-zed-test.md`. Several steps record an observation ("record which") because the answer is not known yet; those are the most valuable results.

Terms: "Console" is the Console tab of Zed's Debug panel. "Zed log" is the output of `zed: open log` (file `~/.local/share/zed/logs/Zed.log` on Linux). "Adapter logs" is `dev: open debug adapter logs` from the command palette (action `dev::OpenDebugAdapterLogs`, verified in Zed source `crates/debugger_tools/src/dap_log.rs:950-956`; it lists the DAP traffic Zed saw). "logFile" is the proxy's own log: add `"logFile": "/tmp/rdf-proxy.log"` to a scenario in `.zed/debug.json` (full DAP traffic, both directions).

Helper commands used below (Linux/macOS):

```sh
# leftovers check
pgrep -af 'flutter_tester|sample_app|flutter_run|development-service|frontend_server|debug_adapter' || echo "none"
# session files
ls "${XDG_STATE_HOME:-$HOME/.local/state}/flutter_run/sessions" 2>/dev/null || echo "no session dir"
```

---

## 0. Prerequisites

- [ ] **0.1 Rust toolchain with the `wasm32-wasip2` target** (Zed compiles the dev extension itself: it runs `cargo` from its own environment, then checks `rustc --print target-libdir --target wasm32-wasip2`; only if that target is missing does it need `rustup` to run `rustup target add`. rustup is the easy path; any toolchain that already has the target works).
  Action: `cargo --version && rustup --version && rustup target list --installed`. If missing: install rustup (on Arch: `pacman -S rustup && rustup default stable`; without sudo, use the user-local installer: `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y -t wasm32-wasip2`, then `source ~/.cargo/env`). **Start Zed from the shell (`zed .`) for step 1 too**, so that Zed's process sees `cargo` (`~/.cargo/bin`) on its PATH; a launcher-started Zed may not, the same trap as `flutter_run` in 0.3.
  Expected: a stable toolchain is listed. Zed adds the wasm target itself on first build.
  If it fails, capture: output of `which -a cargo rustc`, `rustup show`.
- [ ] **0.2 Build `flutter_run`**.
  Action:
  ```sh
  git clone https://github.com/sawongam/zed-flutter-run.git ~/src/zed-flutter-run
  cd ~/src/zed-flutter-run && git checkout build/mvp    # the code is on build/mvp (draft PR #1), not master
  cd cli && dart pub get
  mkdir -p ~/.local/bin
  dart compile exe bin/flutter_run.dart -o ~/.local/bin/flutter_run
  ```
  If you use fvm, run these with the Dart from your Flutter SDK (`fvm dart pub get`, `fvm dart compile exe ...`).
  Expected: the file `~/.local/bin/flutter_run` exists and is executable.
  If it fails, capture: the full compiler output, `dart --version`.
- [ ] **0.3 On the PATH of the Zed process, not only your shell.** Zed started from a launcher may not see your shell's PATH. Action: `command -v flutter_run && flutter_run version`; then start Zed from the same shell (`zed .`) for the first run, and later also test starting it from the launcher (step 13.2 depends on the difference).
  Expected: prints the path and `flutter_run 0.1.0`.
  If it fails, capture: `echo $PATH`, `flutter_run doctor` output.
- [ ] **0.4 Doctor.** Action: `flutter_run doctor` inside any Flutter project (or after step 2).
  Expected: shows version 0.1.0, your OS, the executable path, "How the Flutter SDK was looked for" with a `found` line (fvm link, fvm cache, PATH, ...), Flutter and Dart versions, `flutter_run on PATH: yes (...)`.
  If it fails, capture: the whole output. If the SDK is "not found" while `fvm flutter --version` works: note which fvm layout you use (`.fvm/flutter_sdk` link in the project, global fvm default only, ...) and set `FLUTTER_RUN_FLUTTER_SDK` or `"flutterSdkPath"` for now.
- [ ] **0.5 Flutter can run on Linux desktop.** Action: `flutter doctor` (or `fvm flutter doctor`) and `flutter devices`.
  Expected: a `Linux (desktop)` device. Arch needs `clang cmake ninja gtk3 pkgconf` for desktop builds.
  If it fails, capture: `flutter doctor -v`.

## 1. Install the dev extension

- [ ] **1.1 Install.** Action: open Zed, command palette (`ctrl-shift-p`), run `zed: install dev extension`, select the folder `<repo>/extension` (the one containing `extension.toml`, not the repo root).
  Expected: after a moment (first build downloads the wasm target and compiles, can take minutes) the extension "Flutter Run & Debug" appears in `zed: extensions` under "Installed" with a "Dev" marker. No error toast.
  If it fails, capture: `zed: open log` (search for `flutter-run-debugger`, `error`, `wasm32-wasip2`), `cargo --version`, `rustup target list --installed`.
- [ ] **1.2 Extension logs.** Action: `zed: open log`, look for lines mentioning `flutter-run-debugger`.
  Expected: loaded without errors. Keep this log open; every later failure in the extension (binary not found, bad scenario JSON) shows up here and as a message in the debug panel.
  If it fails, capture: the lines around the first `flutter-run-debugger` mention.
- [ ] **1.3 Version consistency.** Action: `cd <repo> && sh .github/scripts/check-versions.sh`.
  Expected: `OK: all versions match (0.1.0)`.

## 2. Sample app

- [ ] **2.1 Copy and initialise.**
  ```sh
  cp -r <repo>/fixtures/sample_app /tmp/rdf-sample
  cd /tmp/rdf-sample
  # with fvm: fvm use <your flutter version> first, so .fvm/flutter_sdk exists
  flutter pub get          # or: fvm flutter pub get
  flutter_run init
  ```
  Expected: `Flutter app "sample_app" in /tmp/rdf-sample`, `Created .zed/debug.json with 4 entries.`, `Created .zed/tasks.json with 9 entries.`, a key table, a keymap snippet, `flutter_run on PATH: yes (...)`. Exit code 0 (`echo $?`).
  If it fails, capture: full output and exit code.
- [ ] **2.2 Open in Zed.** Action: `zed /tmp/rdf-sample`, open `lib/main.dart`.
  Expected: the Dart extension highlights the file. `.zed/debug.json` has scenarios labelled `Flutter: Debug`, `Flutter: Run (no debug)`, `Flutter: Profile`, `Flutter: Attach`, all with `"adapter": "FlutterRun"`.
- [ ] **2.3 Optional but recommended: proxy log.** Add `"logFile": "/tmp/rdf-proxy.log"` to the `Flutter: Debug` scenario.

## 3. Coexistence with the Dart extension

- [ ] **3.1 Both adapters listed.** Action: press `F4` (or `debugger: start`), go to the "New Process"/Debug tab, open the adapter dropdown or the custom-scenario tab.
  Expected: both `Dart` and `FlutterRun` are offered as adapters. The scenarios from `.zed/debug.json` are listed (FlutterRun ones).
  If it fails, capture: screenshot, Zed log, `zed: extensions` list (both installed?).
- [ ] **3.2 Dart language server still works.** Action: in `lib/main.dart` hover over `MaterialApp`, trigger completion, introduce a type error.
  Expected: hover, completion and diagnostics work exactly as before installing our extension.
  If it fails, capture: Zed log (LSP lines).
- [ ] **3.3 Dart extension's own adapter still starts** (optional): create a scenario with `"adapter": "Dart"` and start it.
  Expected: unaffected by our extension.

## 4. Select a device

- [ ] **4.1 Task list.** Action: `task: spawn` (or `alt-shift-t`).
  Expected: tasks `Flutter: Hot Reload`, `Hot Restart`, `Select Device`, `Launch Emulator`, `Devices`, `Open DevTools`, `DevTools Inspector`, `DevTools Performance`, `Doctor`.
- [ ] **4.2 Select Device.** Action: run `Flutter: Select Device`, type the number of the Linux desktop entry, Enter.
  Expected: a terminal tab with a numbered list (`Name (id) - platform`), "Enter a number or an id", then `Saved device: Linux (linux) ... It is used the next time you start the app.` It stays open (reveal always, hide never).
  If it fails, capture: terminal contents. Check `flutter_run devices` in a normal terminal.
- [ ] **4.3 Saved file exists.** Action: `ls "${XDG_STATE_HOME:-$HOME/.local/state}/flutter_run/devices"`.
  Expected: one `<16 hex>.json` file containing `deviceId` `linux`.

## 5. Start debugging

- [ ] **5.1 Start.** Action: `F4`, choose `Flutter: Debug`, start (or `F5` next time).
  Expected, in the Console, within a few seconds (the first Linux build can take about a minute):
  - `[flutter_run] Using device linux (saved selection).`
  - no PATH warning and no version warning (if you see "the flutter_run command is not on your PATH", note it: Zed's PATH differs from your shell's)
  - flutter's build output, a Linux window with the counter app opens
  - `[flutter_run] Reload on save is on for lib/ (changed files only). Set "reloadOnSave": "off" in .zed/debug.json to turn it off. With Zed autosave enabled, every autosave reloads.`
  - `GREETING: Hello v1` and `BUMP: 2`
  If it fails, capture: Console text, Zed log, Adapter logs, `/tmp/rdf-proxy.log`, `flutter_run status`, and run by hand `cd /tmp/rdf-sample && flutter debug_adapter` to see whether the adapter starts at all.
- [ ] **5.2 Session is visible.** Action (second terminal): `flutter_run status --project /tmp/rdf-sample`.
  Expected: `* pid N  flutter  linux  rdf-sample  running  /tmp/rdf-sample`. A file `<pid>.json` exists in the sessions directory with `"appStarted": true`.
- [ ] **5.3 Panels.** Expected: Threads/Variables/Call stack/Console panels as for any Zed debug session; stop button, restart button visible.

## 6. Breakpoint, variables, step, continue

- [ ] **6.1 Set breakpoint.** Action: click the gutter at `lib/main.dart` line 7 (`final y = x + 1;`) (set it before F5, or while running).
  Expected: a red dot; after the app is running it stays verified (not greyed out).
- [ ] **6.2 Hit.** Action: stop (Shift-F5) and start again with the breakpoint set, or press the app's `+` button (which calls `bump`).
  Expected: execution pauses at line 7 in `bump`. The call stack shows `bump` above `main`. Variables show `x` (1 at startup, the counter value after a `+` press).
  If it fails, capture: screenshot of the gutter, Adapter logs (`setBreakpoints` response `verified`), proxy log.
- [ ] **6.3 Step.** Action: Step over (F10).
  Expected: moves to line 8; `y` is now visible and equals `x + 1`.
- [ ] **6.4 Continue.** Action: F5 (continue).
  Expected: the app resumes, the window appears.

## 7. Hot reload by keybinding

- [ ] **7.1 Paste the keymap.** Action: `zed: open keymap file`, paste the snippet that `flutter_run init` printed (the first one), save. Re-print it with `flutter_run init --dry-run` if you lost it.
  Expected: the snippet is a JSON array element with `"context": "Workspace && debugger_session"` and bindings `ctrl-f5` (hot reload), `ctrl-shift-f5` (hot restart), `ctrl-alt-shift-d` (DevTools).
- [ ] **7.2 Turn off reload on save for this step.** Set `"reloadOnSave": "off"` in the `Flutter: Debug` scenario and restart the session (Shift-F5, F4). Expected: no "Reload on save is on" line.
- [ ] **7.3 Reload.** Action: edit `kGreeting` to `'Hello v2'` (line 4), save, then press `ctrl-f5` with the editor focused.
  Expected:
  - a task terminal tab opens without taking focus and hides again on success (`reveal: no_focus`, `hide: on_success`); on failure it stays open
  - Console: `Reloaded 1 of N libraries in X ms (compile: ..., reload: ..., reassemble: ...)`
  - `GREETING: Hello v2` printed (and `REASSEMBLE: ...`)
  - the breakpoint at line 7 is hit again through `reassemble()`; continue (F5) to let the reload finish
  - the app window title now reads `Hello v2`
  - `Flutter: Hot Reload` terminal output (check with `flutter_run reload` in a terminal): `Hot reload: linux rdf-sample ok in 0.6 s` (the project directory name, here `rdf-sample`, not the pubspec name)
  If it fails, capture: the task terminal output (reopen with `task: rerun`), Console, proxy log, `flutter_run reload -v` in a terminal, and whether the keybinding fired at all (command palette `task: spawn` → Hot Reload as a test; macOS: see 7.5).
- [ ] **7.4 Reload while paused.** Action: with the breakpoint set, `ctrl-f5` again.
  Expected: after about 3 s the task terminal prints `Waiting... the app may be paused at a breakpoint`; after continuing it completes. (The terminal tab does not auto-hide while waiting.)
- [ ] **7.4b Task saves first.** Action: change `'Hello v2'` to `'Hello v2b'` and do NOT save; press `ctrl-f5`. Expected: the task saves all files (`"save": "all"`), then one reload shows `Hello v2b`. With reload on save enabled the save may also trigger the watcher; the two reloads should merge (the terminal may say `joined a reload that was already running`). Record what you see.
- [ ] **7.5 (macOS only)** If a key does nothing check the fn key / "Use F1, F2 as standard function keys" and System Settings shortcut conflicts; hot restart is `shift-cmd-f5` there.

## 8. Reload on save

- [ ] **8.1 Enable.** Set `"reloadOnSave": "changed"` (or delete the key), restart the session. Expected: the "Reload on save is on for lib/" line again.
- [ ] **8.2 Save.** Action: change `'Hello v2'` to `'Hello v3'`, save (ctrl-s).
  Expected, within about half a second:
  - `[flutter_run] Hot reload on save: lib/main.dart`
  - `Reloaded 1 of N libraries ...`, `GREETING: Hello v3`
  - `[flutter_run] Hot reload after saving finished in N ms.`
  If it fails, capture: Console, proxy log lines mentioning `Reload on save`, whether the file is on a normal local file system (inotify limits: `cat /proc/sys/fs/inotify/max_user_watches`).
- [ ] **8.3 No change, no reload.** Action: save again without changing the text.
  Expected: nothing happens ("changed" mode compares file content).
- [ ] **8.4 Syntax error.** Action: save a file with a syntax error.
  Expected: `[flutter_run] Error: Hot reload failed: ... Try the task "Flutter: Hot Restart".` Fix the error and save: reload succeeds again.
- [ ] **8.5 Autosave** (optional): enable Zed autosave (`"autosave": "on_focus_change"` or `after_delay`), type; record whether every autosave reloads (documented as yes).

## 9. Hot restart

- [ ] **9.1 Our task.** Action: `ctrl-shift-f5`.
  Expected: Console shows `Restarted application in N ms.`; `GREETING: ...` and `BUMP: 2` printed again; the breakpoint at line 7 hits again from `main()`; the terminal prints `Hot restart: linux rdf-sample ok in ...`. Note: our keymap overrides Zed's default `ctrl-shift-f5` (rerun session) inside a debug session. (The adapter may emit a stop at entry followed by its own `continued`; that is a known quirk.)
  If it fails, capture: task terminal, Console, proxy log.
- [ ] **9.2 Zed's own restart.** Action: click the restart button in the Debug panel toolbar, or run `debugger: rerun session` from the command palette (do not use `ctrl-shift-f5`, it is ours now; to test the Zed default key, use the second keymap snippet from `flutter_run init` which leaves it out).
  Expected (to be recorded, unknown today): either (a) a hot restart through DAP `restart` (same console lines as 9.1, the same window stays open, no new `[flutter_run] Using device` line), or (b) a full stop and new launch (a new window, `Using device` printed again).
  **Record which: ____________.** Also record whether Zed shows the restart button as enabled (it needs the adapter's `capabilities` event with `supportsRestartRequest`, which the proxy forwards).
  If it fails, capture: Adapter logs (look for a `restart` request and its response), proxy log.
- [ ] **9.3 Reload during client restart** (optional): save a file right after clicking restart. Expected: the save-triggered reload waits for the restart, then runs.

## 10. DevTools

- [ ] **10.1 Task.** Action: run `Flutter: Open DevTools` (or `ctrl-alt-shift-d`).
  Expected: your default browser opens `http://127.0.0.1:PORT/TOKEN=/devtools/inspector?uri=ws%3A%2F%2F...`; the DevTools inspector loads and shows the widget tree of the running app (connected, no "cannot connect" banner).
  If it fails, capture: `flutter_run devtools --print` output, the task terminal, browser screenshot. Try the printed URL by hand. Check `xdg-open --version`.
- [ ] **10.2 Other pages.** Action: tasks `DevTools Performance`, and `flutter_run devtools network --print`.
  Expected: URLs end in `/devtools/performance` and `/devtools/network`.
- [ ] **10.3 On start** (optional): add `"openDevTools": "inspector"` to the scenario and start. Expected: console line `[flutter_run] Opened DevTools: http://...` and the browser opens once per session.

## 11. Stop

- [ ] **11.1 Stop.** Action: Shift-F5 (or the stop button).
  Expected: the app window closes within a few seconds. If it takes longer than 1 s the console shows `[flutter_run] Stopping the app...` first. The session ends cleanly in the panel.
- [ ] **11.2 No session.** Action: `flutter_run status`.
  Expected: `No running debug sessions. ...`; the sessions directory is empty (`ls` command at the top).
- [ ] **11.3 No leftovers.** Action: the `pgrep` helper command, wait 5 s, run it again.
  Expected: `none` (no `flutter_tester`/`sample_app`, `development-service`, `frontend_server`, `flutter_run`, `debug_adapter`).
  If it fails, capture: `ps -eo pid,ppid,etime,cmd | grep -E 'dart|flutter|sample_app' | grep -v grep` before killing anything, the proxy log tail (which cleanup steps ran), Adapter logs (was `terminate` sent? was the response received?).
- [ ] **11.4 Stop via closing the window** (optional): start a session, close the Zed window. Expected: the same cleanup within seconds (stdin EOF path), no leftovers.
- [ ] **11.5 Reload after stop.** Action: `flutter_run reload`. Expected: `error: No running Flutter app found for ...`, exit code 3.

## 12. Attach

- [ ] **12.1 Start the app yourself.** Action: in a terminal `cd /tmp/rdf-sample && flutter run -d linux`; copy the `http://127.0.0.1:PORT/TOKEN=/` address from "A Dart VM Service on Linux is available at: ...".
- [ ] **12.2 Configure.** Edit the `Flutter: Attach` scenario: add `"vmServiceUri": "<that address>"` and `"toolArgs": ["-d", "linux"]` (the device is required even for attach).
- [ ] **12.3 Attach.** Action: F4, choose `Flutter: Attach`.
  Expected: within about 2 to 3 s the Console shows `Connecting to VM Service at ...`, `Connected to the VM Service.`, the app's earlier output may replay; the debug panel shows the thread. Breakpoint at line 7 works (press `+` in the app). If nothing happens for 15 s: `[flutter_run] Still waiting for the app. ...`.
  If it fails, capture: Console, proxy log, the adapter process line `pgrep -af debug_adapter` (it should contain `--no-dds`).
- [ ] **12.4 Reload works.** Action: change the greeting to a new value, save (reload on save) or `ctrl-f5`.
  Expected: `Reloaded ...` in the Zed Console; the `flutter run` terminal also reports the reload or at least the app changes.
- [ ] **12.5 Stop detaches.** Action: Shift-F5 in Zed.
  Expected: the Zed session ends; the Linux window and the `flutter run` terminal keep running; `flutter_run status` shows no session; `pgrep -af development-service` shows only the one that belongs to `flutter run` (no second, orphaned DDS).
  If it fails, capture: `pgrep -af development-service` before and after, proxy log.
- [ ] **12.6** Quit `flutter run` with `q` when done.

## 13. Error cases

- [ ] **13.1 No device selected, several devices.** Action: `flutter_run select-device --clear`; make sure at least two devices exist (`flutter devices`: Linux plus Chrome/web-server); start `Flutter: Debug`.
  Expected: Console `[flutter_run] No device was chosen, so Flutter will pick one. ...`; Flutter fails with "More than one device connected" and then `[flutter_run] Warning: Several devices are available (or none is). Run the task "Flutter: Select Device", or add "deviceId" to this launch entry.` (shown once).
  If it fails, capture: Console, proxy log.
- [ ] **13.2 `flutter_run` not on PATH, but known to Zed.** Action: copy the binary to `~/rdf-bin/flutter_run`; in Zed settings add `"dap": { "FlutterRun": { "binary": "/home/<you>/rdf-bin/flutter_run" } }`; move `~/.local/bin/flutter_run` away (`mv ~/.local/bin/flutter_run{,.off}`); restart Zed from the launcher; start `Flutter: Debug`.
  Expected: debugging works and the Console shows `[flutter_run] Warning: the flutter_run command is not on your PATH, so the tasks "Flutter: Hot Reload", ... cannot run. This debug session is using /home/<you>/rdf-bin/flutter_run. Add /home/<you>/rdf-bin to your PATH (...) and see the README section "Install". Hot restart with Zed's own Rerun Session key still works.` Running `Flutter: Hot Reload` fails in the task terminal (command not found). Restore afterwards (`mv ~/.local/bin/flutter_run{.off,}`, remove the setting).
  If it fails, capture: Console, Zed log.
- [ ] **13.3 Not found at all.** With the setting removed and the binary off the PATH, start a session.
  Expected: it does not start; a message `flutter_run was not found. Install it from the README section "Install" (release binary on your PATH), or set "dap": {"FlutterRun": {"binary": "<path>"}} in Zed settings.` (also covered by step 15).
- [ ] **13.4 JSONC `debug.json`.** Action: in a scratch copy of the project make `.zed/debug.json` contain a `// comment` line (Zed's own new-file template has comments), then run `flutter_run init; echo $?`.
  Expected: `Could not safely edit .zed/debug.json (... comments ...). Nothing was changed. Paste these entries into the file:` plus the JSON, a hint about template text, and exit code **9**. `flutter_run init --force` backs it up to `debug.json.bak` and writes a fresh file (exit 0).
- [ ] **13.5 Bad scenario.** Add `"reloadOnSave": "sometimes"` to a scenario and start. Expected: a warning line that it must be `changed`, `always` or `off`; using `changed`.
- [ ] **13.6 No Flutter SDK.** Start with `"flutterSdkPath": "/nonexistent"`. Expected: the session fails with a message listing where the SDK was looked for (explicit path invalid, then env, fvm, puro, PATH...), not just "adapter exited". Remove the key afterwards.

## 14. Pure Dart program

- [ ] **14.1 Set up.**
  ```sh
  cp -r <repo>/fixtures/dart_console /tmp/rdf-dart
  cd /tmp/rdf-dart && dart pub get   # or fvm dart pub get
  flutter_run init
  ```
  Expected: `Dart package "dart_console_fixture" in /tmp/rdf-dart`; `.zed/debug.json` with one scenario `Dart: Debug bin/main.dart` (`"type": "dart"`); tasks.json with only `Flutter: Doctor`.
- [ ] **14.2 Debug.** Open `bin/main.dart` in Zed, set a breakpoint on line 11 (`total += n;`), F4 → `Dart: Debug bin/main.dart`.
  Expected: stops at line 11 with `i == 0`, `n == 1`, `total == 0`; step; continue; the Console shows `TOTAL: 30` and the session ends by itself. `flutter_run status` while it is paused: `... dart ...  running`.
  If it fails, capture: Console, proxy log, `dart debug_adapter` run by hand.
- [ ] **14.3 Tasks skip it.** While paused run `flutter_run reload` in a terminal. Expected: `Skipped pid N: it is a Dart console session, not a Flutter app.`, exit code 4.

## 15. Extension download path (expected to fail in dev builds)

- [ ] **15.1** Remove the binary from the PATH and clear the `dap.FlutterRun.binary` setting (as in 13.3), start a session.
  Expected: **failure**, because `extension/src/checksums.rs` has no pinned checksums so the extension refuses to download: message `flutter_run was not found. Install it from the README section "Install" (release binary on your PATH), or set "dap": {"FlutterRun": {"binary": "<path>"}} in Zed settings.` No network access to GitHub is made. Zed log has the same text.
  If you see a download attempt or a different error, capture the Zed log and report it: it means a checksum got pinned or the code path changed.
- [ ] **15.2** Restore your setup (binary back on PATH).

## 16. Results template

Paste into `docs/conversations/<date>-NNN-manual-zed-test.md`. Result: PASS, FAIL, SKIP, or an observation.

```
# Manual Zed test, <date>

Zed version: ______   OS: ______   Flutter (fvm) version: ______   flutter_run: 0.1.0 (git <sha>)
Dart extension version: ______   Started Zed from: shell / launcher

| Step | Result | Notes / what was captured |
|------|--------|---------------------------|
| 0 prerequisites (rustup, build, PATH, doctor) |  |  |
| 1 dev extension installs, log clean |  |  |
| 2 sample app + init |  |  |
| 3.1 FlutterRun and Dart both in F4 picker |  |  |
| 3.2 Dart LSP still works |  |  |
| 4 Select Device task + saved file |  |  |
| 5 F4 Flutter: Debug, console notices |  |  |
| 6 breakpoint line 7, variables, step, continue |  |  |
| 7 ctrl-f5 hot reload (Hello v2, breakpoint again) |  |  |
| 7.4 reload while paused: "Waiting..." notice |  |  |
| 8 reload on save ("Hot reload on save: lib/main.dart") |  |  |
| 9.1 ctrl-shift-f5 hot restart (our task) |  |  |
| 9.2 Zed restart button / RerunSession: hot restart via DAP restart OR full relaunch? | (a) / (b) |  |
| 10 DevTools opens and connects |  |  |
| 11 stop: window closes, status empty, no leftovers |  |  |
| 12 attach, reload, stop detaches, app keeps running |  |  |
| 13.1 several devices hint |  |  |
| 13.2 PATH notice |  |  |
| 13.3 not-found message |  |  |
| 13.4 JSONC debug.json -> init exit 9 |  |  |
| 14 pure Dart debug |  |  |
| 15 download path fails with the install message |  |  |
| macOS (if available): keys, F-key/fn conflicts, reload, stop |  |  |
| Windows (if available): flutter_run.exe on PATH, debug, reload, stop, no leftovers (tasklist) |  |  |

Bugs / surprises:
-

Timings (optional): launch to first breakpoint ___ s; ctrl-f5 to "Reloaded" ___ s; stop to window closed ___ s.
```

## Notes for macOS and Windows (if you have them)

macOS: build with `dart compile exe` as above; put the binary on the PATH Zed sees (Zed started from the Dock does not read your shell profile; test both). Chrome or the macOS desktop device is available without extra setup. Check F-keys (needs fn unless "Use F1, F2, etc. keys as standard function keys" is on), that `shift-cmd-f5` reaches Zed (System Settings > Keyboard > Keyboard Shortcuts may grab it), Gatekeeper behaviour if you downloaded a binary with a browser (`xattr -d com.apple.quarantine <file>`), DevTools opens with `open`, stop leaves no processes (`pgrep -fl 'flutter|dart'`), state dir `~/Library/Application Support/flutter_run`.

Windows: use a `flutter_run.exe` on the PATH, never a `.bat` wrapper (the extension then reports "Zed cannot supervise a .bat wrapper"). Check `flutter_run doctor` from PowerShell, debug with the Windows desktop or Chrome device, reload and restart tasks (`ctrl-f5`), stop leaves no `dart.exe`/`flutter_tester.exe`/app processes (`tasklist | findstr /i "dart flutter"`), DevTools opens in the browser, state dir `%LOCALAPPDATA%\flutter_run`, SmartScreen prompt on the first run of a downloaded binary, and no Windows Firewall prompt for the loopback control port (none expected).
