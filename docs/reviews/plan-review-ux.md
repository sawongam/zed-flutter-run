# UX review of docs/IMPLEMENTATION_PLAN.md

Reviewer: independent UX reviewer (did not write the plan). Date: 2026-11-03.
Method: walked the plan twice as a first-time user, then compared with `research/feature-parity-vscode.md`, `research/zed-recent-changes-and-picker-ux.md`, `research/zed-dap-client-behaviour.md` and the Zed keymaps in the research clone (`assets/keymaps/default-{linux,macos,windows}.json`).

- Persona A: Windows 11, Android emulator + Chrome, Flutter from zip, maybe fvm, new to Zed's debugger.
- Persona B: macOS, iPhone simulator, fvm or Homebrew Flutter, coming from VS Code + Dart-Code.

Verified Zed facts used below (all from the default keymaps / research docs):
- `f4` = `debugger::Start` (opens the New Session modal, global).
- `f5` in `Workspace` = `debugger::Rerun` (re-runs the last scenario). `f5` in `debugger_running` is unbound. `f5` in `debugger_stopped` = `debugger::Continue`.
- `shift-f5` = Stop, `f6` = Pause (both only in `debugger_session`). `ctrl-shift-f5` (macOS `shift-cmd-f5`) = `debugger::RerunSession`.
- `ctrl-f5` / `cmd-f5` are unbound. On Windows `ctrl-alt-shift-d` is bound to the dev-only `dev::ResetFrameOverlayStats`.
- Only DAP `output` events render in the debugger console. Zed shows no progress, no `showUser`, no toasts. Adapter stderr is visible only in `dev: open debug adapter logs`.

## Summary

| Severity | Count |
|---|---|
| blocker | 2 |
| major | 9 |
| minor | 10 |
| nit | 4 |

## Blockers and majors (one line each)

- U1 blocker: "extension only" install gives no usable hot reload, and `init`/tasks cannot run (the downloaded binary is not on PATH).
- U2 blocker: the only documented install path (`dart pub global activate flutter_rd`) does not exist at 0.1.0 (publishing is forbidden) and the download is refused without pinned checksums.
- U3 major: Hot Reload/Restart tasks use `reveal: never`, so every failure ("no session", "app not started", "reload failed") is invisible.
- U4 major: no device selected and several devices attached (the normal Windows case) has no handled path; the user gets a raw Flutter error.
- U5 major: `flutter_rd` is not on PATH after `dart pub global activate` on Windows and macOS (pub-cache bin), and Zed started from the Dock/Start menu has no login-shell PATH for tasks.
- U6 major: F4/F5 semantics are not explained; first F5 with no previous scenario and F5 while running do nothing visible.
- U7 major: ctrl-f5 is "run without debugging" in VS Code and a hot-reload key only in Dart-Code during a session; the plan leaves ctrl-f5 dead when idle and never says so. macOS keys differ.
- U8 major: reload-on-save fires on any file write (autosave, git checkout, codegen), the default is "on" while Dart-Code's is "manual", and nothing tells the user it is on or how to turn it off.
- U9 major: simulator/emulator not running means "no devices"; no launch-emulator task, and the zero-device message is not defined.
- U10 major: compile errors / "needs restart" results of reload appear only in the debug console panel, which the user may not have open; no pointer is given.
- U11 major: `Flutter: Select Device` is a terminal prompt that is lost on `flutter clean` (state in `.dart_tool`) and gives no feedback in the debugger.

## Walkthrough findings

### U1 [blocker] - "Only installed the extension" (§4.10 step 3-4, §4.8, §4.1)
Scenario (A and B): user installs "Flutter Run & Debug" from Zed's Extensions page, as for any other extension. F4 works because `get_dap_binary` downloads `flutter_rd` into the extension's work directory. Then ctrl-f5 runs task `flutter_rd reload` in a terminal and prints "command not found". `flutter_rd init` cannot be run either (no binary on PATH), so `.zed/tasks.json` does not exist. The user concludes hot reload is broken.
Fix:
1. README quick start must be a two-step install ("1 install extension, 2 install CLI") with the CLI step first for hot reload, and say so in the extension description.
2. In the proxy (`dap`), when `flutter_rd` is not resolvable on PATH (check `Platform.environment['PATH']`, same as the task shell would), emit one console notice at session start: `Hot reload keys need the flutter_rd command on your PATH. Run it once: <own absolute path> init` plus the PATH line to add. The proxy knows `Platform.resolvedExecutable`, so the notice is copy-pasteable and works with only the extension installed.
3. Let `flutter_rd init` write tasks that tolerate this: the notice above is the cheap fix; a stretch is `init` placing/copying itself to a PATH directory with consent.
4. Add `docs/MANUAL_ZED_TEST.md` case "extension only, no PATH".

### U2 [blocker] - Install path does not exist at release (§4.10 step 4, §9 Q9, HANDOFF safety rules)
Scenario: error text says `Install it with "dart pub global activate flutter_rd"`. The project may not publish to pub.dev; dev builds have no pinned checksum, so no download either. A first-time user following the message hits a dead end ("could not find package flutter_rd").
Fix: until published, the message must name what works today: `Download flutter_rd-v0.1.0-<os>-<arch> from https://github.com/saadbtch/run-and-debug-flutter/releases and put it on PATH` and the exact `dap.FlutterRD.binary` setting. Make the text depend on a build-time flag (`PUBLISHED_ON_PUB`) so it never tells users to run a command that fails. Record in README "Status: pre-release, install from GitHub releases".

### U3 [major] - Silent failures of Hot Reload / Hot Restart tasks (§4.8 tasks table, §4.3)
Scenario: user presses ctrl-f5 before the app has started, or after stopping, or while the Dart (not FlutterRD) adapter is in use. The CLI exits 3 or 4 with a good message (`No running Flutter debug session found ... F4/F5`), but the task has `reveal:"never"`, `hide:"on_success"`. Failure keeps the tab but never shows it. Nothing happens; user presses again. Same for "Waiting... paused at a breakpoint" (3 s hint is never seen) and for `reload failed`.
Verified: `reveal` and `hide` are TaskTemplate keys (research §4); `never` does not focus or show the terminal panel.
Fix:
- Use `reveal: "no_focus"` with `hide: "on_success"` for Hot Reload/Restart (shows only while running or on failure, closes on success). Resolve open question Q3 in favour of visibility; a brief flash is better than silence.
- Alternatively have the CLI, when a session exists, mirror its failure as a DAP notice (the plan lists this in zed-dap-client-behaviour recommendation 2, but §4.3 never implements it). Add control command `notify {text, level}` so the CLI can post "no app running" is impossible (no session), but "reload skipped: app not started yet" and "busy" can be mirrored.
- Message for exit 3 must not hard-code F4/F5: `No running Flutter app found for <dir>. Start one first (Run > Start Debugging, or F4).`

### U4 [major] - Multiple devices, none chosen (§4.2 step 3, §4.5)
Scenario A: Windows 11 with Android emulator, Chrome, Edge and Windows (desktop) available. User presses F4/F5 without ever running Select Device. Rule (d) is "none", so `flutter run --machine` is started without `-d`; with more than one device Flutter fails ("More than one device connected"). The adapter's error reaches the console as raw tool output (or only the debug-adapter log).
Fix: when no device source applies and kind is flutter, the proxy runs `flutter devices --machine` (cached 2 s; reuse WP4 parser by wiring in WP10a), then:
- exactly one device: proceed (note `device: <name>`),
- zero: error notice with the U9 text,
- more than one: do not launch; answer `launch` with `success:false` plus console notice: `Several devices are available (Pixel_7 [emulator-5554], Chrome, Windows). Choose one: run the task "Flutter: Select Device", or add "deviceId" to this launch entry.` List the ids. Timebox 5 s and fall through to plain launch on failure.
Dart-Code behaviour for comparison: status-bar picker + auto-select when only one (`flutterSelectDeviceWhenConnected`).

### U5 [major] - PATH for tasks (§4.12 "GUI-launched Zed", §4.8)
Scenario A: `dart pub global activate` prints a warning that `%LOCALAPPDATA%\Pub\Cache\bin` is not on PATH; most users ignore it. Scenario B: `~/.pub-cache/bin` not on PATH, and Zed launched from the Dock does not read `.zshrc`. Tasks run in Zed's terminal, which is a login/interactive shell in most setups but not guaranteed. The plan covers only the DAP side (`worktree.shell_env()`), not tasks.
Fix: (1) README: per-OS "add to PATH" lines and a one-line check (`flutter_rd version`). (2) `flutter_rd doctor` must print "flutter_rd on PATH: yes/no, location" and the exact PATH fix for the current OS. (3) `init` ends with a check: `Is flutter_rd on your PATH? <yes/no>` and, if no, the fix. (4) On Windows with fvm, `flutter` often is not on PATH either; doctor must show that SDK resolution found it via `.fvm` (already in §4.4), so the message "Flutter SDK: found via .fvm/flutter_sdk" is reassuring.

### U6 [major] - F4 vs F5 vs F6 are not explained (§4.8 closing note, §5.1 "F4/F5")
Scenario B: VS Code user presses F5 on a fresh project. In Zed `f5` = `debugger::Rerun`: with no previous scenario in this workspace nothing useful happens (exact behaviour unverified; likely opens nothing or the modal). `F4` opens the New Session picker. While the app is running `F5` is unbound; user presses it expecting continue/reload. When paused, `F5` = continue (fine). `F6` = pause, `F10/F11` stepping match VS Code.
Fix: README + `init` output + MANUAL_ZED_TEST: a 5-line table: `F4` choose and start (first time), `F5` re-run last (and Continue when paused), `Shift+F5` stop, `Ctrl+F5` hot reload (while running), `Ctrl+Shift+F5` hot restart. State that F5 does nothing while the app runs, and that this is Zed behaviour. Name the scenario that should be picked ("Flutter: Debug"). Add a verification item for "F5 on a never-run workspace".

### U7 [major] - ctrl-f5 / ctrl-shift-f5 expectations (§4.8 keymap)
Scenario B: in VS Code `Ctrl+F5` is Start Without Debugging; Dart-Code rebinds it to Hot Reload only while a session runs (feature-parity §1, §2). In the plan `ctrl-f5` is bound in `Workspace && debugger_session` only, so when idle it is dead (the VS Code user wanted "run without debugging"; the scenario `Flutter: Run (no debug)` exists but has no key). On macOS Dart-Code uses `cmd+...`; the plan uses `ctrl-f5` on macOS (the printed reasoning only checked it is unbound in Zed). Macs also need `fn` for F-keys unless "Use F1, F2 etc. as standard function keys" is on, and `ctrl-f5` may be captured by macOS ("Move focus to the toolbar"/accessibility shortcuts) on some setups (unverified, flag in MANUAL_ZED_TEST). `ctrl-shift-f5` replaces the stock RerunSession which also hot-restarts via DAP `restart` (plan §4.8, §9 Q2): two ways, one deterministic.
Fix: (1) Document that Zed has no key for "run without debugging"; point to `F4` then `Flutter: Run (no debug)`. (2) Keep the `Workspace && debugger_session` context, but print that the bindings are only active during a session. (3) macOS: print a note about the `fn` key and the system shortcut check, and offer `cmd-f5`-style alternatives only after MANUAL_ZED_TEST confirms Dart-Code's mac keys. (4) Make `init` offer a second optional snippet "Keep Zed's default restart key" that omits the ctrl-shift-f5 entry.
Surprise to call out: hot reload keys do nothing in the terminal panel or editor outside a session; this is by design.

### U8 [major] - Reload on save defaults and discoverability (§4.6, §4.11)
Scenarios:
- Dart-Code `flutterHotReloadOnSave` defaults to `manual` (feature-parity §2: reload on explicit save, not autosave). The plan's default `changed` reloads on every file write seen by the OS watcher, including Zed autosave (`autosave: after_delay` users reload while typing), git checkout/pull, `build_runner` output, and `dart fix --apply`.
- A user who never configured anything sees reloads they did not ask for and has no hint that `reloadOnSave` exists (keys are only in the schema, i.e. visible only in JSON autocomplete).
- Reload on save while paused at a breakpoint blocks until resume (§4.2) with no on-save notice about it.
Fix:
- On session start print once: `Reload on save is on (changed files only). Turn it off with "reloadOnSave": "off" in .zed/debug.json.` The text mentions the file name, not a setting jargon.
- Keep the default "changed" but add `"reloadOnSave"` explicitly to the generated `Flutter: Debug` scenario so the option is visible in the file: `"reloadOnSave": "changed"`. (Cheap, makes the feature discoverable.)
- Doc note: with Zed `autosave` on, every autosave reloads.
- On-save reload while paused: after 3 s without a response print `Reload is waiting for the debugger to resume.`
- Consider an option value `"manual"` (explicit save only) later; Zed gives no hook to distinguish, so say so in the docs rather than promise it.

### U9 [major] - No emulator/simulator running; `emulators` only "should" (§4.5, §4.1)
Scenario B: iPhone simulator not started; `flutter devices` lists only macOS/Chrome. Scenario A: Android emulator not started. Dart-Code has `Flutter: Launch Emulator` (feature-parity §2, "Should", v1). The plan implements `emulators` as "if time" and has no task for it.
Fix: promote to MVP-lite: `flutter_rd emulators --launch <id>` plus task `Flutter: Launch Emulator` (a numbered pick if no `--launch`, using the same picker as devices). Define the zero-device message (see U4) as: `No devices found. Start an emulator or simulator (task "Flutter: Launch Emulator"), connect a phone, or enable Chrome/desktop with "flutter config --enable-<platform>-desktop".` Mention that a simulator needs a few seconds to appear; `Select Device` should have a `r` rescan key.

### U10 [major] - Where compile and reload errors show (§4.2 "Injected requests", §5.3)
Scenario: user saves a file with a syntax error. Reload on save fails; the notice and the adapter's error text go to the debug console. In Zed the debugger panel's Console is one of several tabs; "new output" is only an indicator (`console.rs:153-155`); no toast. Editor diagnostics (LSP) give some feedback, but a type-valid change that fails hot reload (e.g. "Hot reload rejected: change requires a restart") is only in the console.
Fix: (1) Say in README "errors appear in the Console tab of the Debug panel". (2) `init`/first-launch notice: `Output and reload results appear in the Console tab.` (3) For reload failures that need restart, append an actionable hint to the notice: `Run "Flutter: Hot Restart" (ctrl-shift-f5) to apply it.` Do not hard-code the key; read nothing, say task name only. (4) Keep multi-line compile errors as separate `output` events, one per line, each with the prefix (plan already prefixes each line).

### U11 [major] - Select Device flow and state location (§4.5, §4.8 tasks)
Scenario: user runs the task, a terminal asks for a number; picks 2. Nothing in the debugger changes; the next F5 uses it (the plan prints `device: <id> (from saved selection)` only on launch). Later `flutter clean` deletes `.dart_tool/` including `flutter_rd/device.json`; the next launch silently falls back to "no device" and U4 error appears. Also the selection is per-project, not per-window, and a running session is not affected ("the CLI says so") but no wording is given.
Fix: (1) Store the selection outside `.dart_tool` (for example `.zed/flutter_rd.json`, with `init` adding it to `.gitignore` or `.git/info/exclude`) or document that `flutter clean` resets it. (2) Exact CLI wording: `Saved device: Pixel 7 (emulator-5554). It is used the next time you start the app. The running app keeps its device.` (3) Print `Press F4/F5 to start` hint.

### U12 [minor] - Adapter name `FlutterRD` and duplicated labels (§2, §4.8)
Scenario B: New Session shows adapters `Dart` and `FlutterRD`; scenarios in debug.json are labelled `Flutter: Debug` (the Zed Dart extension adds its own entries). Users do not know which to pick and the wrong one silently has no hot reload keys.
Fix: README one-liner "Pick `FlutterRD`, not `Dart`". In the CLI, when exit 3 happens and process listing is cheap, mention it: `Sessions started with the "Dart" adapter cannot be reloaded by this tool. Start "Flutter: Debug" (adapter FlutterRD).` (Heuristic only; always include in the hint.) Keep display name "Flutter Run & Debug" in extension.toml (ok).

### U13 [minor] - First debug.json: init before open, and the "which window" (§4.8)
`init` is run in a terminal before or after opening Zed; both fine, but the plan never says Zed must be restarted or the keymap added. The keymap is printed, never written, so the user has to find `keymap.json` (Zed: `zed: open keymap file`) and paste. Surprising for Windows A.
Fix: print the exact steps and the Zed command names: `Open the command palette, run "zed: open keymap file", paste the snippet.` Offer `--write-keymap` (backup + merge only when file is strict JSON; Zed keymap is JSONC so this needs care; otherwise skip) as a v1 item. Same for settings snippet (`zed: open settings`).

### U14 [minor] - JSONC debug.json that init cannot edit (§4.8)
Zed's own `.zed/debug.json` and `tasks.json` are routinely JSONC (comments, trailing commas) because Zed generates templated files with comments (unverified for debug.json, true for settings). `init` prints a snippet and exits 9 with `--force` creating `.bak`. Exit code 9 plus red error for a normal situation is alarming; also "added N, skipped M" has no wording.
Fix: print `Could not safely edit .zed/debug.json (it has comments or trailing commas). Nothing was changed. Paste these entries into the file: ...` and exit 0 with a warning, or keep 9 but print `Done with 1 manual step.` Offer to write the snippet to `.zed/flutter_rd.snippets.json` for copy. Specify `--force` wording: `Backed up to debug.json.bak`.

### U15 [minor] - Two Zed windows / multiple sessions (§4.3)
Scenario: two windows with two Flutter projects: matching by directory works. Two windows with the same project, or a monorepo root matching two apps: reload acts on all matches ("like VS Code") and prints one line per session; fine, but the line format is unspecified.
Fix: define `Hot reload: <device> <project name> ok in 0.6 s` per session so the user sees which device was hit. Add the `--device` filter flag later.

### U16 [minor] - Zero-config start: "Flutter: Debug" with `program` default and pubspec detection (§4.8)
Fine, but `lib/main.dart` hard-coded for Flutter; flavored apps need `toolArgs`. Dart-Code parity "Should": flavors, dart-define (feature-parity §5 row).
Fix: add a commented example in docs (not in file, since JSON) for `toolArgs: ["--flavor","dev","--dart-define=ENV=dev"]`; generate no extra scenarios. Add to MANUAL_ZED_TEST.

### U17 [minor] - Web (Chrome) users (Persona A) (§4.5, §4.6)
Chrome is an attached device in `flutter devices`; hot reload works, but `flutter run -d chrome` hot restart behaviour and "web hot reload experimental" are not mentioned. Source: feature-parity §3, last bullet. Users will hit "Hot reload is not supported on web" style errors from the adapter.
Fix: docs note; pass the adapter's message through unchanged and add `Try "Flutter: Hot Restart" instead.` when the message contains "not supported".

### U18 [minor] - DevTools discoverability and failure texts (§4.7)
Scenario: user wants DevTools; there is no UI. Task `Flutter: Open DevTools` exists, ctrl-alt-shift-d bound (colliding with a dev-only Windows action, harmless but unverified against OS shortcuts). The fallback server mode prints "press Ctrl+C or close this terminal", which holds a terminal tab. Wrong page route (§9 Q7) might open the default tab silently.
Fix: print the URL in the terminal always (not only `--print`): `Opening DevTools: http://127.0.0.1:...` so the user can copy it if the browser launch fails (plan prints only on failure). In Dart-Code the setting `dart.openDevTools` defaults `never`, so the `openDevTools: never` default matches. Add the DevTools task names to the README table.

### U19 [minor] - Stopping (§4.2 Shutdown, §5.4)
Stop is `shift-f5` (Zed). VS Code users know the same key; fine. The up to 5+5+2 s shutdown could look hung. Fix: emit a console notice `Stopping the app...` when a launch-mode `disconnect` arrives and the injected `terminate` takes longer than 1 s. Also define: closing the Zed window kills things the same way (stdin EOF); mention in docs.

### U20 [minor] - Message style (all `strings.dart`, §4.1 top-level handler, §4.2, §4.3)
Examples in the plan are mostly good (they say what to do) but:
- `reload skipped: app not started` and `reload on save disabled: app runs in profile mode` are lower case fragments and jargon-free but lack the next step. Proposed: `Hot reload skipped: the app is still starting. Try again in a moment.` and `Reload on save is off because the app runs in profile mode (hot reload needs debug mode).`
- Prefix `[flutter_rd]` is tool jargon in the Zed console; fine for tagging, but use the product name `[Flutter RD]` or `[flutter_rd]` consistently and document it in the README so users can search output.
- `error:` / `hint:` format is good; ensure hints are full sentences with a command to copy.
- `Waiting… the app may be paused at a breakpoint` uses the Unicode ellipsis; Windows consoles (legacy conhost / PowerShell 5) may show `?`. Use `...`.
- Exit-code names (`manualActionRequired`) must not appear in user text.
i18n: the plan's `XStrings` classes are a good base. Add rules: whole sentences only, no string concatenation of fragments, placeholders only via function parameters (so word order can vary), no pluralisation by appending `s` (use a helper), no embedded key names for shortcuts (keys differ per OS and are user-rebindable), UTF-8 only. Note Zed always sends locale `en-US`, so this is future-proofing only.

### U21 [minor] - Accessibility: colour-only signals (§4.2 "User-visible status")
Notices use cyan/yellow/red ANSI only. The text itself does not say info/warn/error, so with a colour-vision deficiency or a high-contrast theme that remaps ANSI colours, a failure looks like an info line.
Fix: add a textual level word for warn/error: `[flutter_rd] Error: Hot reload failed: ...`, `[flutter_rd] Warning: ...`, nothing for info. Never use colour as the only differentiator in CLI output either (the CLI already prefixes `error:`/`hint:`; add `ok`/`failed` words in the per-session reload lines instead of only green/red). Keep honouring `NO_COLOR`.

### U22 [nit] - Generated task labels and options (§4.8 tasks table)
Labels are discoverable (all start with `Flutter:`, so one prefix in the task picker). Options checked against research: `use_new_terminal`, `allow_concurrent_runs`, `reveal`, `hide`, `show_summary`, `show_command` all exist. Problems:
- `Flutter: DevTools Inspector / Performance / CPU Profiler / Memory / Network` is five tasks of noise in the picker for rarely used pages. Keep `Open DevTools` plus `Inspector` and `Performance` only; others via `flutter_rd devtools <page>`.
- `Flutter: Devices` and `Flutter: Doctor` use `hide: never` and stay open: fine, but `use_new_terminal:true` piles up tabs; consider `use_new_terminal:false` for these two.
- `Flutter: Select Device` has `hide:on_success`: after choosing, the terminal vanishes with no confirmation; use `hide: never` so the "Saved device" line stays visible.
- `show_summary:false` hides Zed's "Task finished" line; for reload failures keep the summary (`show_summary:true`) so the exit state is visible in the tab. Or accept U3's fix.
- Task `cwd:"$ZED_WORKTREE_ROOT"` + `--project` for monorepos: if the user opens a sub-folder of a monorepo, `$ZED_WORKTREE_ROOT` is that folder; ok.

### U23 [nit] - `.gitignore`, `.zed` commit advice (§4.8)
`.zed/` is usually committed; `tasks.json` would then fail on teammates who lack `flutter_rd`. Say so in the README, and include the PATH check task result (`Flutter: Doctor`). Also tell users `.zed/debug.json` entries may be committed safely (no paths of the user, only `$ZED_WORKTREE_ROOT`).

### U24 [nit] - `Flutter: Attach` with no VM service URI (§4.8 scenarios)
Attach without `vmServiceUri` relies on `flutter attach` discovery (device needed; U4 applies). Document the "app started elsewhere" workflow (`flutter run` in terminal, then Attach) and what message appears if nothing is found.

### U25 [nit] - Version mismatch notice (§4.10 step 5)
`--client-version` mismatch prints a notice when major.minor differs: wording undefined. Proposed: `The Zed extension is version 0.2 but the flutter_rd command on your PATH is 0.1. Update with <command>.`

## Parity check vs `feature-parity-vscode.md`

MVP/Must rows: hot reload, hot restart, device picker + remember, reload on save: all present. Missing or weaker than Dart-Code, cheap to add:
- Run without debugging key (Should, MVP/v1): scenario exists, no key; document (U7).
- Emulator launch (Should): promote (U9).
- Progress feedback for reload/restart (Should): Zed shows none; use the notice `Reloading...` before the adapter's `Reloaded N libraries` line only when the call takes >1 s. Cheap and fills the gap.
- Debug SDK / external packages toggles (Should): pass-through keys exist in the schema; add to the generated Debug scenario as commented docs only (JSON has no comments), so describe them in the README table.
- `dart.openDevTools` parity: present as `openDevTools`.
- Widget-error structured notification: not planned; fine for v1.
- Hot restart in multi-device: reload applies to all sessions, restart to all too (plan) while Dart-Code restarts only the active one; document the difference.

Dart-Code surprises for VS Code users that the README should list in a "Coming from VS Code" table: no status-bar device picker (task instead), no toolbar reload button (Zed's debug toolbar cannot be extended), no hot reload on manual-save-only mode, F5 does not hot reload, `ctrl-f5` only in sessions, console is a tab not a panel, DevTools opens in an external browser.

## Documentation needs

README (user-facing, short):
1. 60-second quick start per OS (install extension, install CLI, `flutter_rd init`, F4, pick "Flutter: Debug").
2. Key table (U6/U7) and "Coming from VS Code" table.
3. Where output appears (Console tab) and what the `[flutter_rd]` prefix means.
4. Troubleshooting by symptom (not found on PATH, no device, no SDK, nothing happens on ctrl-f5, wrong adapter). Link to `flutter_rd doctor`.
5. Settings reference for every launch key (`reloadOnSave`, `deviceId`, `flutterMode`, `openDevTools`, ...) with the Dart-Code equivalents.
6. Windows notes: PATH for pub-cache, `.bat` shim startup time (§9 Q7: steer to release binary), fvm.
7. macOS notes: fn keys, Homebrew/fvm SDK detection, simulator start.

MANUAL_ZED_TEST additions (beyond §7.5): extension-only install; F5 on a fresh workspace; F5 while running; ctrl-f5 on macOS with and without fn; tasks with `reveal: no_focus` flash/visibility; failure visibility of exit 3/4; multi-device error text; autosave `after_delay` + reload on save; reload while paused; JSONC debug.json; `flutter clean` then F5; high-contrast/ANSI themes; Windows PowerShell terminal for `select-device`; Chrome device.

## Defaults review

- `reloadOnSave: "changed"`: good default for correctness (skips identical content, avoids loops with formatters) but see U8 for visibility and autosave.
- Debounce 200 ms: appropriate for single saves and format-on-save (one write). With `build_runner` or git checkout bursts it coalesces to one extra reload at most, matching the plan's coalescer. Keep; allow 10-5000 (ok). Consider default 300 ms on Windows (Defender/indexer touches files, double events); unverified.
- `openDevTools: never`: matches Dart-Code.
- Task options: see U3 and U22.
