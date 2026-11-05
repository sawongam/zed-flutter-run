# Zed integration surface for a standalone Flutter Run & Debug tool

Date: 2026-11-04. Local env: Zed 1.26.2 (Linux), zed-extensions/dart v0.4.1 (extension.toml, lib kind Rust, API 0.7.0).

## 1. Debugger configuration

| Topic | Finding | Source |
|---|---|---|
| `.zed/debug.json` | Array of objects. `adapter` and `label` required. Optional: `build` (object `{command,args}` or string naming a task), `request` (`launch`/`attach`), `program`, `cwd` (default `$ZED_WORKTREE_ROOT`), `tcp_connection`. Global file at `$XDG_CONFIG_HOME/zed/debug.json`. Falls back to `.vscode/launch.json` if empty. Other keys are adapter-defined. | https://zed.dev/docs/debugger |
| Binary override | `dap.$ADAPTER.binary` and `dap.$ADAPTER.args` in settings. Zed reads `binary`, `args`, `env` and passes them to the adapter's `get_binary`. | https://zed.dev/docs/debugger ; https://raw.githubusercontent.com/zed-industries/zed/main/crates/project/src/debugger/dap_store.rs |
| Built-in adapters | Only CodeLLDB, Python (debugpy), JS, Go, GDB. **No generic/"Custom" adapter that takes an arbitrary command.** Any other adapter must come from an extension. | https://raw.githubusercontent.com/zed-industries/zed/main/crates/dap_adapters/src/dap_adapters.rs |
| `tcp_connection` | `{host, port, timeout}` on a scenario. Doc comment in `dap/src/adapters.rs`: connect to the adapter instead of spawning it. The user docs mention the field but do not document its sub-keys. Whether an extension adapter honors it depends on the extension (Dart sets `connection: None`). | https://raw.githubusercontent.com/zed-industries/zed/main/crates/dap/src/adapters.rs |
| Extension adapter API | `get_dap_binary(adapter_name, config, user_installed_path, worktree)` returns `DebugAdapterBinary {command, arguments, envs, cwd, connection: Option<tcp>, request_args}`. Also `dap_request_kind`, `dap_config_to_scenario`, locators (`dap_locator_create_scenario`, `run_dap_locator`). The extension host forwards only `user_installed_path`, never user args/env. | https://zed.dev/docs/extensions/debugger-extensions ; https://raw.githubusercontent.com/zed-industries/zed/main/crates/extension_api/wit/since_v0.8.0/dap.wit ; https://raw.githubusercontent.com/zed-industries/zed/main/crates/extension_host/src/wasm_host/wit.rs |
| Locators | Extension-defined (`[debug_locators.name]`), turn a task into a debug scenario. Built-in automatic scenarios cover Rust/Go/Python/JS/TS only. | https://zed.dev/docs/extensions/debugger-extensions ; https://zed.dev/docs/debugger |

### How the Dart extension launches the adapter (v0.4.x)

Source: https://raw.githubusercontent.com/zed-extensions/dart/main/src/dart.rs (read via fetch summary) and the installed `debug_adapter_schemas/Dart.json`.

- Resolves `flutter` (`flutter.bat` on Windows) or `dart` via `worktree.which(tool)`. With `useFvm: true` it resolves `fvm` and runs `fvm flutter debug_adapter`. Otherwise `flutter debug_adapter` (underscore, `dart debug_adapter` for Dart).
- `connection: None`, so DAP runs over stdio.
- `env` from the debug config is passed as process envs. `args` and `toolArgs` go into the DAP launch JSON, not the process argv.
- The launch JSON has `type, program, cwd, args, toolArgs, flutterMode, platform, stopOnEntry, sendLogsToClient: true`. `deviceId` is turned into `-d <id>` in `toolArgs` (v0.4.1 schema has `deviceId`).
- **The extension ignores `user_provided_debug_adapter_path`** (the parameter is named `_user_provided_debug_adapter_path`). So `dap.Dart.binary` does NOT redirect the Dart adapter. `dap.Dart.args` is never delivered to extensions.
- The schema has `additionalProperties: false` and the JSON is built from a fixed key list. Flutter's own `customTool` / `customToolReplacesArgs` launch args (a built-in way to substitute the `flutter` binary, per https://raw.githubusercontent.com/flutter/flutter/master/packages/flutter_tools/lib/src/debug_adapters/README.md) cannot be reached through the Dart extension.
- Dart-ext schema keys: adapter, type (dart|flutter), label, program, cwd, useFvm, args, toolArgs, env, flutterMode, deviceId, platform, request, vmServiceUri, stopOnEntry.

## 2. Upstream status (custom debug actions)

| Item | Status | Source |
|---|---|---|
| zed-industries/zed#51873 "extension_api: Add custom debug actions for extensions" (author paulocagol, opened 2026-03-18) | **Closed unmerged 2026-08-19** by MrSubidubi: no progress for ~2 months, "cannot commit to a change to the API like this without proper context". Not a permanent no ("do NOT consider this the end of the road"). | https://github.com/zed-industries/zed/pull/51873 |
| What it proposed | `get_dap_custom_actions` (trigger Toolbar/OnSave/Both, icon), `DebugAdapterClient::request_raw()`, toolbar buttons, run-on-save during a debug session; extension API 0.8.0+. | same |
| Maintainer objections | Hardcoded icons, actions defined only in code not config, save-event hook is Flutter-specific; wants a design discussion covering other DAP clients, a seasoned contributor to steer, and a look at how VS Code does it. Team has plans for a "large effort" to improve the extension API (June 24 comment, no date). | same |
| zed-extensions/dart#72 "Add hot reload and hot restart custom actions" | Closed unmerged 2026-08-19 (was draft since 2026-05-27). Dart#86 (merged July 2026) forwards `deviceId` via `toolArgs`. | https://github.com/zed-extensions/dart/pull/72 |
| zed-industries/extensions#247 "Support for Flutter extension" | Open, linked from the closure. | via PR 51873 page |

ETA: none. The task brief said "blocked on #51873"; the state is now closed, with no replacement design. Treat first-class hot reload buttons in Zed as not arriving in the next several months.

## 3. Tasks

Source: https://zed.dev/docs/tasks

- Keys: `label, command, args, env, cwd, use_new_terminal, allow_concurrent_runs, reveal (always|no_focus|never), hide (never|always|on_success), shell, show_summary, show_command, tags, save (all|current|none)`.
- Variables: `ZED_FILE, ZED_FILENAME, ZED_DIRNAME, ZED_RELATIVE_FILE, ZED_RELATIVE_DIR, ZED_STEM, ZED_ROW, ZED_COLUMN, ZED_SYMBOL, ZED_SELECTED_TEXT, ZED_LANGUAGE, ZED_WORKTREE_ROOT, ZED_MAIN_GIT_WORKTREE`.
- Keybinding: `["task::Spawn", { "task_name": "..." }]`.
- Hooks: the only documented `hooks` event is `create_worktree`. **No on-save hook for tasks.** (`save` only saves buffers before a task runs.)
- Extension task templates: Languages ship `languages/<lang>/tasks.json` plus `runnables.scm` with tags (Dart ext does: `flutter run` tagged `flutter-main`, `flutter test`, `dart test ...`). Read locally from the installed extension.
- Tasks are one-shot shell commands in a terminal; they cannot address an existing debug session.

On-save options (none verified as working for this purpose): Zed's `format_on_save` with an external formatter or `code_actions_on_save` could in principle invoke a command per save, but this is abuse of formatting and unverified. A file watcher inside our own daemon is cleaner.

## 4. Extension API capabilities

| Capability | Status | Source |
|---|---|---|
| Extension types | Languages, debuggers, themes, icon themes, snippets, MCP servers | https://zed.dev/docs/extensions/developing-extensions |
| Rust-code extension points | Language servers, context servers (MCP), debug adapters/locators | same |
| Host imports (0.8.0) | kv insert, worktree read/which/shell_env, http fetch, node/npm, GitHub releases, `run_command`, `download_file`, `resolve_tcp_template`, settings get (language, lsp, context_servers). **No UI, notifications, or actions.** | https://raw.githubusercontent.com/zed-industries/zed/main/crates/extension_host/src/wasm_host/wit/since_v0_8_0.rs |
| Capabilities gating | `process:exec`, `download_file`, `npm:install`, user-restrictable via `granted_extension_capabilities` | https://zed.dev/docs/extensions/capabilities |
| Slash commands | Present in the WIT (`slash_command` interface) but the developing-extensions page does not list them; treat as legacy and unverified | wit.rs above |
| Custom panels, pickers, modals, toolbar buttons | **Not possible** today | developing-extensions page lists none; wit imports contain none |

## 5. Other ways to talk to a running Zed

- CLI flags only: `--wait, --new, --add, --reuse, --existing, --diff, --foreground, --user-data-dir, --zed`, plus `file:line:col`, `zed://`, `file://`, `ssh://` URLs. No documented command/action IPC. https://zed.dev/docs/reference/cli
- ACP: Zed is the ACP client for external agents (`agent_servers` with `type: custom`, `command`, `args`, `env`). Docs do not say agents can invoke Zed actions. https://zed.dev/docs/ai/external-agents
- Keybinding side: `workspace::SendKeystrokes` and `terminal::SendKeystroke` exist (https://zed.dev/docs/key-bindings). `terminal::SendText` was not found in docs (unverified, may exist in source).
- Debugger keybinding actions: docs list none beyond the `debugger_stopped` context key.

## 6. Evaluating a DAP proxy

Verdict: **feasible, but only through our own tiny Zed extension, not through settings overrides on the Dart adapter.**

What blocks the "no extension" route:
1. No generic adapter in `debug.json`, so an arbitrary command cannot be named.
2. `dap.Dart.binary` is ignored by the Dart extension (`_user_provided_debug_adapter_path`).
3. Dart's schema forbids extra keys, so `customTool` cannot be injected.
4. Partial hack: the Dart ext resolves `flutter`/`fvm` via `worktree.which`, i.e. the project environment PATH (direnv etc.). A shim named `flutter` earlier on PATH would be launched with `debug_adapter` args. Fragile and affects every use of `flutter`; unverified.

Recommended route:
- Ship a separate Zed debugger extension (e.g. `[debug_adapters.FlutterPlus]` with `schema_path`) whose `get_dap_binary` returns `command = <our proxy binary>`, `arguments = [..., "--", "flutter", "debug_adapter"]`, `envs` pass-through, `connection: None` (stdio). The proxy spawns the real `flutter debug_adapter` (or `fvm flutter debug_adapter`), forwards DAP both ways, and injects its own `hotReload` / `hotRestart` requests (Flutter DAP custom requests, optional `reason: "manual"|"save"`: https://raw.githubusercontent.com/flutter/flutter/master/packages/flutter_tools/lib/src/debug_adapters/README.md).
- Side channel: Unix socket (or `$XDG_RUNTIME_DIR/...`) per session, with a CLI such as `fdz reload`. Zed tasks bind to it: `{ "label": "Flutter: Hot Reload", "command": "fdz", "args": ["reload"], "reveal": "never", "hide": "always" }` plus a `task::Spawn` keybinding. Reload-on-save is done by the proxy's own file watcher on `lib/**/*.dart`, since Zed has no on-save hook.
- Locating the binary: `get_dap_binary` can use `worktree.which("fdz")` or download via `download_file`/GitHub releases (needs `download_file` capability). Zed passes the extension `user_installed_path`, so `dap.FlutterPlus.binary` can work in our own extension if we implement it.
- Costs: a Rust-to-WASM extension must be published to zed-industries/extensions (or installed as dev extension); a second adapter name next to the official "Dart" one; the user's `.zed/debug.json` uses `"adapter": "FlutterPlus"`. The extension must replicate Dart's launch-config construction (device, fvm, toolArgs).
- Device picker and DevTools: not possible as UI. Alternatives: `deviceId` in `debug.json`, a task or CLI that lists devices (`flutter devices --machine`) and rewrites `.zed/debug.json`, and DevTools opened with `xdg-open` from a task (URL from the `dart.debuggerUris` event, which the proxy sees).

Zero-extension fallback (no proxy), verified in part:
- `toolArgs: ["--pid-file", "/tmp/fdz.pid"]` in the Dart debug config (flag exists; checked locally with `flutter run -h`: "You can send SIGUSR1 to trigger a hot reload and SIGUSR2 to trigger a hot restart"). Whether the Dart DAP's inner `flutter run --machine` honors it and writes the pid is **unverified**. A watcher daemon plus `kill -USR1` tasks would then give reload and reload-on-save with no extension at all.
- Terminal-run alternative: `flutter run` in a task terminal and send `r`/`R` via keybinding (needs `terminal::SendText`, unverified), losing Zed debugger integration.

## Verified vs unverified

Verified (read directly): Dart extension schema, tasks.json and runnables.scm in the local install; `flutter run --pid-file` help text locally; Zed docs for debugger, tasks, CLI, extension pages; PR 51873 and dart#72 state (via fetch summaries); the Dart extension's ignoring of the user adapter path and the `debug_adapter` subcommand (via fetch summary of dart.rs, not read as raw text by me); dap.wit and wit.rs forwarding behavior (via fetch summaries).

Unverified: that `--pid-file` works inside the Flutter DAP; `terminal::SendText`; `tcp_connection` sub-key behavior for extension adapters; `format_on_save` abuse; PATH-shim behavior; whether slash command extension API is still supported; any 2026-09+ Zed changes to the extension API after the 51873 closure; exact spelling `debug_adapter` vs `debug-adapter` (Flutter README lists both).

## Implications for our tool

1. Do not wait for Zed: #51873 is closed, with no ETA, so toolbar buttons are not coming soon. UI is limited to tasks, keybindings and terminal output.
2. Primary architecture: a companion binary (daemon plus CLI) with a small Zed debugger extension that launches it as a DAP proxy around `flutter debug_adapter`. Zed tasks and keybindings call the CLI for reload, restart, device selection and DevTools.
3. Reload-on-save lives in the proxy (file watcher), because Zed exposes no save hook for tasks or debug sessions.
4. Ship a generated `tasks.json` and `keymap.json` snippet and a `debug.json` template. An installer subcommand can write them.
5. Ship a no-extension "lite mode" based on `--pid-file` plus signals (pending verification), so users can adopt it before installing the extension.
6. Device picker: CLI picker in a task terminal that writes `deviceId` to `.zed/debug.json`. No native picker is available.
7. Keep the design portable: if Zed later lands a custom debug actions API, the proxy's request logic can be reused and only the UI trigger changes.
