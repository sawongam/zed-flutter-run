# Zed changes Aug-Nov 2026, task/keymap/debugger surface, and device-picker UX

Date: 2026-11-03. Researcher: subagent "research-d".

## Method
- Shallow clone of zed-industries/zed (`--shallow-since=2026-08-01`), main HEAD b61f33f8 (2026-11-03), crate version 1.28.0 (nightly line) [verified-source: crates/zed/Cargo.toml:5].
- `git log --since=2026-08-01` on extension_api, extension_host/wasm_host, dap, dap_adapters, debugger_ui, task, tasks_ui, project/debugger, task_inventory, keymaps; source reads of keymaps, task, tasks_ui, zed_actions, workspace key_context.
- `git ls-remote --tags` + shallow tag fetches for the stable version.
- Cloned dea6cat/zed-flutter (HEAD 2026-10-15) and onepub-dev/zed-dart-extension (HEAD 2026-04-13) to read their picker approach.
- NOT possible: `gh api` on zed-industries/zed (403, repo not attached for API; git reads only) and zed.dev (DNS blocked; zed.dev would need allowing). So GitHub release notes / zed.dev/releases were not read. One web search only.

## 1. Current stable version, extension API
- Stable: **v1.26.2** (latest non-`-pre` tag on the highest v1.2x line; commit dated 2026-10-28). Preview: v1.27.0-pre (same date). Main/nightly: 1.28.0. Tags seen: v1.24.4, v1.25.3, v1.26.2 stable; v1.27.0-pre, v1.26.2-pre preview. [verified-source: `git ls-remote --tags`, `git log -1 v1.26.2`]. Caveat: inferred from tags, not from the release page [unverified against zed.dev].
- Extension API: `crates/extension_api/Cargo.toml` version **0.8.0**; WIT dirs unchanged: since_v0.0.1 ... since_v0.6.0, since_v0.8.0 (latest, `use since_v0_8_0 as latest` in crates/extension_host/src/wasm_host/wit.rs:24). No new WIT directory and no new host functions since 2026-08-01. The only commits touching crates/extension_api since Aug 1 are dependency/shear/build churn (21f16f7b, 282f47a5, aec7395e, d544470d). Related: 4ca90055 bumped wasmtime to 48 / tree-sitter 0.27 (Aug 25); 7eec8920 restored project LSP settings for old-API extensions (Aug 22). [verified-source]
- Debugger-related exports in since_v0.8.0/extension.wit:173-178: `get-dap-binary`, `dap-request-kind`, `dap-config-to-scenario`, `dap-locator-create-scenario`, `run-dap-locator`. No custom-request / custom-action export. [verified-source]
- Our crate should keep targeting zed_extension_api 0.8.0 (or whatever it currently pins); nothing newer exists.

## 2. Debugger changes since 2026-08-01 (relevant subset)
All [verified-source], commit hashes in zed repo:
- 391a66a5 (Aug 24) Separate `debugger::Continue` (all threads) and new `debugger::ContinueThread`.
- 32a0e813 (Aug 20, #58729) Keymaps synced to VS Code: f10 StepOver, f11 StepInto, shift-f11 StepOut (in `Workspace && debugger_stopped`), f11 fullscreen moved to Workspace.
- f8b0d52b (Sep 28) Fix "rerun last debug scenario" ordering (#64856).
- 00b86477 (Nov 2) configurable default debug panel size; afff3d26 (Oct 19) hover tree UI; cb73ee1d (Oct 7) search in debugger terminal; 7aec07cc python envFile; 2214d0a9 Delve auto-update; 1e477708 CodeLLDB schema fix.
- 01448f56 (Sep 19) fix Windows worktree-variable paths with spaces in tasks.
- 1274a5dc (Aug 18) VS Code npm tasks `path` property.
- No change to the debug.json schema keys, locators API, or DAP client request surface relevant to us.
- Actions in `debugger::` namespace now (crates/debugger_ui/src/debugger_ui.rs:~35-85): Start, Continue, ContinueThread, Detach, Pause, Restart, RerunSession, StepInto/Over/Out/Back, Stop, ToggleIgnoreBreakpoints, ClearAllBreakpoints, Focus{Console,Variables,BreakpointList,Frames,Modules,LoadedSources,Terminal}, ToggleThreadPicker, ToggleSessionPicker, Rerun (deprecated alias `debugger::RerunLastSession`), ToggleExpandItem, ToggleUserFrames, ToggleDataBreakpoint. None sends custom DAP.
  - `debugger::Restart` ("Restarts the current debugging session") exists; it maps to the DAP `restart` request / relaunch, not a Flutter hot restart [unverified exact semantics; not read in depth].

## 3. Q2: custom DAP request / reload action / successor to #51873
- Source search for `request_raw`, `custom_request`, `custom_action`, `get_dap_custom_actions` across crates/*.rs and *.wit: no hits in extension/debugger code (only unrelated lsp.rs / open_ai tests). [verified-source]
- No new debugger action that reloads/restarts the debuggee app. No successor PR/issue could be confirmed: GitHub API on zed was blocked, and the web search returned nothing newer than the known closure (PR 51873 closed unmerged 2026-08-19, see docs/research/zed-integration-surface.md). A search snippet claimed dart#72 "still open"; the earlier doc says closed 2026-08-19. Trust the earlier doc; [unverified] either way. Successor/reopen: [unverified].
- So custom DAP requests must still originate from our own proxy (file watcher, CLI over a socket/pid file/stdin).

## 4. Q3: task::Spawn, task keys, contexts, default F-keys
### task::Spawn (crates/zed_actions/src/lib.rs:~725-760) [verified-source]
Untagged enum, three forms, each with optional `reveal_target`: `{task_name, reveal_target?}`, `{task_tag, reveal_target?}`, `{reveal_target?}` (opens the modal). `reveal_target` is `"center"` | `"dock"` (default dock).
- `"use_new_terminal"` and `"allow_concurrent_runs"` are NOT Spawn args. They are `task::Rerun` args (`reevaluate_context`, `allow_concurrent_runs`, `use_new_terminal`; same file ~767-785) and also TaskTemplate keys.
- `hide` (`never|always|on_success`) is a TaskTemplate key (crates/task/src/task_template.rs:44-60), not a Spawn arg.
- TaskTemplate keys (task_template.rs:24-81): label, command, args, env, cwd, use_new_terminal, allow_concurrent_runs, reveal (always|no_focus|never), reveal_target (dock|center), hide, tags, shell, show_summary, show_command, save (all|current|none, default none), **hooks** (set of TaskHook; only variant `create_worktree`, alias `create_git_worktree`).
- **No on-save hook** for tasks. Reload-on-save stays in our proxy's file watcher. [verified-source]
- `task_tag` spawn runs tasks that declare `tags`; tagged tasks are hidden from the modal ("removes this task from other UI").

### Keybinding contexts for the debugger [verified-source: crates/workspace/src/workspace.rs:8218-8243, assets/keymaps/default-linux.json]
- `debugger_running`: active thread Running or Stepping (program executing).
- `debugger_stopped`: active thread Stopped (paused).
- `debugger_session`: coarse, any of running/stepping/stopped (live session). This is the right gate for "only while debugging". Exists on stable v1.26.2 too (checked: `git show v1.26.2:assets/keymaps/default-linux.json` has `Workspace && debugger_session` and workspace.rs:8038). Not checked how old; may be missing in older stable versions [unverified].
- Others: `DebugPanel`, `DebugConsole > Editor`, `Editor && DebuggerHover`, `DebuggerHoverMenu`.
- A session whose thread has Exited/Ended sets none of the three.
- Hot reload/restart tasks can be bound with `task::Spawn {task_name}` in `Workspace && debugger_session` (action is generic; context gating is just keymap contexts).
- Caveat: the DAP thread state is of the *active* session/thread; with Flutter the thread state is usually Running while the app runs (verified by context code only; [unverified] empirically for Flutter).

### Default F-keys (identical logic on linux, macOS, windows) [verified-source]
| Key | Context | Action |
|---|---|---|
| f4 | global (Workspace) | `debugger::Start` (linux:36, mac:6, win:35) |
| f5 | Workspace | `debugger::Rerun` (linux:740) |
| f5 | `Workspace && debugger_running` | unbound (null) (linux:778-783) |
| f5 | `Workspace && debugger_stopped` | `debugger::Continue` |
| f6 | `Workspace && debugger_session` | `debugger::Pause` (plain f6 = workspace::FocusNextPart otherwise) |
| shift-f5 | `Workspace && debugger_session` | `debugger::Stop` |
| ctrl-shift-f5 (mac: shift-cmd-f5) | `Workspace && debugger_session` | `debugger::RerunSession` |
| f10 / f7 | debugger_stopped | StepOver |
| f11 / ctrl-f11 | debugger_stopped | StepInto |
| shift-f11 | debugger_stopped | StepOut |
| ctrl-shift-d (mac cmd-shift-d) | Workspace | `debug_panel::ToggleFocus` |
Task keys (linux): ctrl-shift-r task::Rerun{reevaluate_context:false}, ctrl-alt-r task::Rerun, alt-t task::Rerun, alt-shift-t task::Spawn, alt-shift-r task::Spawn{reveal_target:center}. Mac: cmd-shift-r task::Spawn, cmd-alt-r Rerun, ctrl-alt-shift-r Spawn center. Windows: alt-t Rerun, shift-alt-t Spawn, shift-alt-r Spawn center, ctrl-shift-r Rerun.
Notes: `shift-f5`/`f6` only exist in debugger_session, so they are free when idle. f5 while running is unbound at default, so user bindings for f5 in `debugger_running` (e.g. hot reload) do not fight defaults. Earlier-vs-later precedence: later entries in the same-depth contexts win; user keymap loads after defaults.

## 5. Q4: device-picker UX
Facts:
- Zed has NO picker/prompt API for tasks or extensions. Task resolution only substitutes variables (`$ZED_FILE, $ZED_FILENAME, $ZED_RELATIVE_FILE, $ZED_RELATIVE_DIR, $ZED_DIRNAME, $ZED_STEM, $ZED_WORKTREE_ROOT, $ZED_SYMBOL, $ZED_RUNNABLE_SYMBOL, $ZED_ROW, $ZED_COLUMN, $ZED_SELECTED_TEXT, $ZED_LANGUAGE, $ZED_MAIN_GIT_WORKTREE, $ZED_GIT_SHA(_SHORT), $ZED_GIT_REPOSITORY_NAME/PATH, $ZED_GIT_REF, $ZED_CUSTOM_*`) [verified-source: crates/task/src/task.rs:154-250]. Defaults via `${ZED_X:default}` are supported (task_template.rs:397-430). No "ask user" variable for tasks. `PickProcessId` exists only for debug configs (attach), not devices.
- Terminal tasks run in a real PTY (alacritty_terminal `tty::Pty`, crates/terminal/src/alacritty.rs:49,170) [verified-source]. The task tab accepts keyboard input when focused (reveal: always focuses it). So both numbered prompts and arrow-key TUI pickers work in principle; dea6cat relies on `stdin.readLineSync()` there. A raw-mode arrow-key TUI is [unverified] empirically in Zed (alacritty PTY makes it very likely; test it).
- Task templates with variants: just multiple tasks, e.g. one per device — static, cannot be generated by us at runtime unless the CLI rewrites `.zed/tasks.json`.
- debug.json: all JSON string values (recursive, including args/env/toolArgs) have `$ZED_*` task variables substituted; non-ZED vars like `$HOME` / `$FLUTTER_DEVICE` are left literally (unknown, non-ZED vars intentionally untouched); unknown `$ZED_*` without default makes substitution fail (`substitute_variables_in_str` returns None, so the string is left unsubstituted). `program` and `cwd` additionally get path resolution. Source: crates/debugger_ui/src/session/running.rs:743-775, 800-835; task_template.rs:375-430. [verified-source]. So `${ZED_CUSTOM_DEVICE}` would only work if something provides `ZED_CUSTOM_DEVICE`: extensions can provide custom task variables via language `ContextProvider`, not available to wasm extensions as far as the WIT shows [unverified]. Env vars of the user shell are NOT expanded in debug.json. Reading a file the CLI wrote: NOT supported by Zed itself.
- Consequences: the device must reach the adapter either (a) by CLI rewriting `.zed/debug.json` `deviceId` (what dea6cat does, `.zed/flutter_device` + sync), or (b) by our proxy reading a state file itself (e.g. `.zed/flutter_device`/XDG state) at launch when `deviceId` absent. (b) is best: debug.json stays static, no rewrite races, scenario `"deviceId": null/omitted` means "use saved selection".
- Prior art:
  - dea6cat/zed-flutter: task `Flutter: select device` runs `dart tool/flutter_zed.dart device`, prints numbered `flutter devices --machine` list, reads a number from stdin, writes `.zed/flutter_device`, then re-syncs debug.json; reload/restart via pid-file signal tasks; README suggests f5 hot reload, f6 restart. Uses `use_new_terminal: true`, `allow_concurrent_runs: true`, `reveal: no_focus`, `hide: on_success` for reload. Source: https://github.com/dea6cat/zed-flutter (README, tool/flutter_zed.dart:45-70, languages/dart/tasks.json:131-). Extensions can ship `languages/<lang>/tasks.json` (dea6cat does) [verified in their repo; Zed loading side not re-verified].
  - onepub-dev/zed-dart-extension: `/flutter-devices`, `/flutter-devtools`, `/flutter-hot-reload` etc. are extension slash commands (extension.toml `[slash_commands.*]`); these only live in Zed's assistant/agent text thread, not a picker, and its README calls its hot reload a "temporary shell-backed workaround". https://github.com/onepub-dev/zed-dart-extension
  - Zed's `ZED_SELECTED_TEXT`: a hack (type the device id in the editor, select it, run task) - poor UX.

### Recommendation for MVP
1. Primary: task `Flutter: Select Device` -> runs our CLI `select-device` in a terminal tab (`reveal: always`, `use_new_terminal: true`, `allow_concurrent_runs: false`, `hide: on_success`). The CLI lists `flutter devices --machine`, shows a numbered list (works with plain stdin; add raw-mode arrow keys only if tested in Zed), writes the choice to a state file in the workspace (`.zed/rdf-device.json` or similar; add to .gitignore).
2. The proxy reads that file at launch if the scenario has no explicit `deviceId`; also expose `Flutter: Current Device` task (prints it) and allow `RDF_DEVICE` env override. Explicit `deviceId` in debug.json always wins.
3. Fallback with zero state: scenarios per device generated by `Flutter: Generate Device Scenarios` (CLI writes debug.json entries `Flutter (<device>)`); then Zed's own scenario picker (debugger::Start modal / NewProcessModal) is the picker. Optional, post-MVP.
4. Defer slash-command/agent surfaces.
Reload/restart/devtools: tasks that talk to the proxy via a local control channel (pid file or unix socket) - no DAP request from Zed required.

## 6. Ready-to-adapt snippets (only verified keys/actions)
`rdf` is a placeholder for our CLI binary.

`.zed/tasks.json` (or global tasks.json):
```json
[
  {
    "label": "Flutter: Select Device",
    "command": "rdf",
    "args": ["select-device"],
    "cwd": "$ZED_WORKTREE_ROOT",
    "use_new_terminal": true,
    "allow_concurrent_runs": false,
    "reveal": "always",
    "hide": "on_success",
    "show_summary": false
  },
  {
    "label": "Flutter: Current Device",
    "command": "rdf",
    "args": ["device"],
    "cwd": "$ZED_WORKTREE_ROOT",
    "use_new_terminal": true,
    "allow_concurrent_runs": true,
    "reveal": "no_focus",
    "hide": "never"
  },
  {
    "label": "Flutter: Hot Reload",
    "command": "rdf",
    "args": ["reload"],
    "cwd": "$ZED_WORKTREE_ROOT",
    "use_new_terminal": true,
    "allow_concurrent_runs": true,
    "reveal": "never",
    "hide": "on_success",
    "show_summary": false,
    "show_command": false
  },
  {
    "label": "Flutter: Hot Restart",
    "command": "rdf",
    "args": ["restart"],
    "cwd": "$ZED_WORKTREE_ROOT",
    "use_new_terminal": true,
    "allow_concurrent_runs": true,
    "reveal": "never",
    "hide": "on_success",
    "show_summary": false,
    "show_command": false
  },
  {
    "label": "Flutter: Open DevTools",
    "command": "rdf",
    "args": ["devtools"],
    "cwd": "$ZED_WORKTREE_ROOT",
    "use_new_terminal": true,
    "allow_concurrent_runs": true,
    "reveal": "no_focus",
    "hide": "on_success"
  }
]
```
Caveat: `reveal: "never"` in the terminal still adds a tab per use with `use_new_terminal`; with `hide: on_success` it closes itself on exit 0. [unverified: whether a tab flickers]. All keys above exist in TaskTemplate [verified-source].

`keymap.json`:
```json
[
  {
    "context": "Workspace && debugger_running",
    "bindings": {
      "f5": ["task::Spawn", { "task_name": "Flutter: Hot Reload", "reveal_target": "dock" }]
    }
  },
  {
    "context": "Workspace && debugger_session",
    "bindings": {
      "ctrl-shift-f5": ["task::Spawn", { "task_name": "Flutter: Hot Restart" }],
      "ctrl-alt-d": ["task::Spawn", { "task_name": "Flutter: Open DevTools" }]
    }
  },
  {
    "context": "Workspace",
    "bindings": {
      "ctrl-alt-shift-d": ["task::Spawn", { "task_name": "Flutter: Select Device" }]
    }
  }
]
```
Notes: `ctrl-shift-f5` here deliberately overrides the default `debugger::RerunSession` while a session is live (VS Code Flutter convention is hot restart); users who want the stock behavior should pick another key. `ctrl-alt-d` / `ctrl-alt-shift-d` collisions with user/OS bindings not checked [unverified]. On macOS use `cmd-`/`shift-cmd-f5` variants (default RerunSession is `shift-cmd-f5`). `debugger_running` excludes paused state; to also reload while paused at a breakpoint, add `debugger_stopped` entry for f5 (but that shadows `debugger::Continue`, so use another key).

## 7. Unverified / open
- Release notes (zed.dev) and GitHub releases unread (blocked); stable = v1.26.2 inferred from tags.
- Whether any successor to zed#51873 exists; PR 51873/dart#72 states conflict between a search snippet ("open") and the earlier doc ("closed 2026-08-19").
- Exact semantics of `debugger::Restart` vs Flutter.
- Raw-mode arrow-key TUI in Zed task terminals (PTY exists; no live test).
- `debugger_session` availability on older stable builds; Flutter DAP thread state mapping to running/stopped.
- Whether wasm extensions can supply `ZED_CUSTOM_*` task variables (no WIT surface seen).
- Flicker/tab behavior of `reveal: never` + `use_new_terminal`.
