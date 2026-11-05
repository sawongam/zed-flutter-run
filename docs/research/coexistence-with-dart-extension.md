# Coexistence with the official Dart extension (two debug adapters for Dart/Flutter)

Date: 2026-11-03

Question: can our own Zed extension register a debug adapter ("Flutter", working name) next to the official `zed-extensions/dart` extension's "Dart" adapter, without conflict?

Tags: **[verified-source]** = read in the cloned source (cited); **[unverified]** = inference or not testable from source alone.

## Method

- Shallow clones in `/tmp/claude-0/-home-user-zed-flutter-run/32cd234d-2bba-5c41-b10d-b540117c3393/scratchpad/research-a/`:
  - `zed-industries/zed` at commit `b61f33f8b6bf811e640a9e83fede2cf4640ba061` (main, dated 2026-11-03). Cited below as `zed@b61f33f`.
  - `zed-extensions/dart` at commit `fba74dfa66de4d123206dff56bf0b1fa20e3505d` (2026-08-28), extension version 0.4.1. Cited as `dart@fba74df`.
- `zed_extension_api` 0.7.0 downloaded from `https://crates.io/api/v1/crates/zed_extension_api/0.7.0/download` and read (`src/extension_api.rs`, `wit/since_v0.6.0/*.wit`). Cited as `api-0.7.0`.
- Read: `crates/dap`, `crates/debug_adapter_extension`, `crates/debugger_ui`, `crates/project/src/debugger`, `crates/project/src/task_inventory.rs`, `crates/task`, `crates/extension`, `crates/extension_host`, `crates/extension_api`, `docs/src/extensions/debugger-extensions.md`.
- Nothing was run in a real Zed. All claims are from source reading only.

## Verdict (short)

**Conflict risk: low, provided we use a distinct adapter name and a distinct locator name.** [verified-source]

- Adapters live in one global `BTreeMap` keyed by exact, case-sensitive adapter name. They are not tied to a language. Different names coexist; the same name silently overwrites.
- The official Dart extension registers **no debug locator** and no language-level `debuggers` default. We do not clash with a locator; ours would be the only Dart-aware one.
- Three real risks, all manageable:
  1. A name collision (e.g. calling ours `Dart`) silently replaces one adapter, and uninstalling either extension removes the name for both.
  2. Locator-derived scenarios for Dart buffers only appear if the user sets `languages.Dart.debuggers` (Zed's default is empty), and only the first entry counts.
  3. `.vscode/launch.json` `type: dart` maps to adapter `dart` (lowercase), which exists in neither extension. Today those configs are hidden in the picker.

## Q1. How Zed keys debug adapters; duplicates; language tie

- Global registry state: `adapters: BTreeMap<DebugAdapterName, Arc<dyn DebugAdapter>>` and `locators: FxHashMap<SharedString, Arc<dyn DapLocator>>`. `zed@b61f33f crates/dap/src/registry.rs:35-36`. [verified-source]
- `add_adapter` does `adapters.insert(name, adapter)` and discards `_previous_value`. A second adapter with the same name silently replaces the first, with no warning. `registry.rs:49-52`. [verified-source]
- `DebugAdapterName` wraps a `SharedString`, with `Borrow<str>`. Lookup via `adapter(&str)` is exact string equality (`registry.rs:90`; `crates/dap/src/adapters.rs:54-82`). So `Dart`, `dart` and `DART` are three different adapters. [verified-source]
- Removal is by name only: `remove_adapter(name)` (`registry.rs:58`). When an extension is unloaded, `extension_host.rs:1417-1422` calls `unregister_debug_adapter` / `unregister_debug_locator` for each key in its manifest. If two extensions had registered the same name, unloading either would remove the name for both. [verified-source]
- An extension registers adapters from `[debug_adapters.<Name>]` and locators from `[debug_locators.<name>]` in `extension.toml`. `extension_host.rs:1715-1735` (load) and `crates/extension/src/extension_manifest.rs:121-124, 306-311` (manifest types). The entry has only one field, `schema_path` (optional; defaults to `debug_adapter_schemas/<Name>.json`, `extension_manifest.rs:216-228`). A schema file is mandatory (the loader reads it and fails if absent: `crates/debug_adapter_extension/src/extension_dap_adapter.rs:33-40`). [verified-source]
- Adapter-to-language tie: **none required for extension adapters.** `DebugAdapter::adapter_language_name()` defaults to `None` (`crates/dap/src/adapters.rs:366`), and `ExtensionDapAdapter` does not override it (`extension_dap_adapter.rs:79-121`). It is only used cosmetically by the picker: `debugger_ui/src/new_process_modal.rs:1105-1120`, which falls back to matching a language name in the scenario label. [verified-source]
- Language-to-adapter preference is the other direction: `debuggers` in the language config (`language_core/src/language_config.rs`) or in language settings (`language_settings.rs:176`, default `[]` at `assets/settings/default.json:1709`). Only `debuggers.first()` is used for locators (see Q3). The Dart extension's `languages/dart/config.toml` has **no** `debuggers` key (`dart@fba74df`). [verified-source]
- Settings are also keyed by adapter name: `dap.<Name>.binary/args/env` (`crates/project/src/project_settings.rs:60`, `dap_store.rs:257-272`). So `dap.Flutter.*` and `dap.Dart.*` are independent. [verified-source]

## Q2. How `.zed/debug.json` and `.vscode/launch.json` select an adapter

- `.zed/debug.json` is an array of `DebugScenario`: `adapter`, `label`, optional `build`, optional `tcp_connection`, and **everything else flattened into `config`** (`crates/task/src/debug_format.rs:262-282`, `#[serde(default, flatten)] pub config: serde_json::Value`). The `adapter` string is looked up verbatim in the registry (`debugger_ui/src/session/running.rs:1133-1138`, error `"{adapter}: is not a valid adapter name"`). [verified-source]
- The picker only lists scenarios whose adapter exists: `.filter(|(_, scenario)| valid_adapters.contains(&scenario.adapter))`. `new_process_modal.rs:1148, 1190`. A scenario naming an uninstalled adapter is silently absent. [verified-source]
- `.vscode/launch.json`: `crates/task/src/vscode_debug_format.rs:85-97`. `task_type_to_adapter_name` maps `node/pwa-node/chrome/...` to `JavaScript`, `go` to `Delve`, `php` to `Xdebug`, `cppdbg/lldb` to `CodeLLDB`, `debugpy` to `Debugpy`, `rdbg` to `rdbg`, and **anything else passes through unchanged**. So `type: "dart"` gives adapter `dart` and `type: "flutter"` gives adapter `flutter` (lowercase). [verified-source]
  - Consequence 1: neither "Dart" nor our "Flutter" matches. Those entries are filtered out of the picker as "invalid adapter" (`new_process_modal.rs:1190`). So VS Code Dart/Flutter launch configs currently do not work in Zed at all.
  - Consequence 2: `type` is **not** copied into `config` (only `JavaScript` keeps it: `vscode_debug_format.rs:26-33`). The Dart extension demands `type` (`dart.rs`: `"type is required and cannot be empty or null"`), so even a case-fixed name would fail there. [verified-source]
  - Opportunity: an extension may register an adapter literally named `dart` (or `flutter`) to catch launch.json imports. Names are case-sensitive, so this does not collide with `Dart`. Such an adapter would have to infer Flutter vs Dart from the config (no `type`, e.g. from `flutterMode`, `deviceId`, or by checking for `pubspec.yaml` with a flutter dependency via `worktree.read_text_file`). Not recommended for the MVP; see recommendations. [unverified: needs a spike]
- `.vscode` entries are hidden whenever `.zed` has any scenarios/tasks (`task_inventory.rs:90-103, 515-527`; `new_process_modal.rs:1161-1170`). [verified-source]
- VS Code variable replacement in launch.json: `${workspaceFolder}`, `${relativeFile}`, `${file}`, `${env:X}` and `${command:pickMyProcess}` only (`vscode_debug_format.rs:61-75`). [verified-source]

## Q3. Debug locators; matching; interaction with the Dart extension; picker behavior

### What a locator is

- Manifest: `[debug_locators.<name>]` (empty table; `DebugLocatorManifestEntry {}` at `extension_manifest.rs:311`). Docs: `docs/src/extensions/debugger-extensions.md:70-112`. Locators "can be provided even by extensions that don't provide a debug adapter" (`api-0.7.0 src/extension_api.rs:228`). [verified-source]
- Two phases: `dap_locator_create_scenario(locator_name, build_task, resolved_label, debug_adapter_name) -> Option<DebugScenario>` and, only if the returned scenario has a `build` with a locator name, `run_dap_locator(locator_name, resolved_build_task) -> Result<DebugRequest>` after the build task finishes. A scenario with no `build` skips phase two (`extension_api.rs:240-241`; `running.rs:1143-1228`). [verified-source]
- The `TaskTemplate` given to the locator has only `label, command, args, env, cwd` (`wit/since_v0.6.0/dap.wit` `task-template`). **Task `tags` are not passed.** So a locator cannot match on `flutter-main` and must match on `command`/`args` (e.g. `flutter run`, `fvm flutter run`). [verified-source]

### When and with what adapter name locators are called

- `TaskInventory::list_debug_scenarios` (`crates/project/src/task_inventory.rs:360-396`): the adapter name comes from the active buffer's `LanguageSettings.debuggers.first()`, falling back to the language config's `debuggers.first()`. **If neither is set, `adapter` is `None` and no locator is called at all.** For each available task, it loops `for locator in locators.values()` and takes the first `Some`. [verified-source]
- The same logic is used for the editor's code-action "debug" entries (`crates/editor/src/code_actions.rs:477-485`), the picker's "debug a task" action (`new_process_modal.rs:1340-1380`) and `debug_scenario_for_build_task` (`dap_store.rs:372-389`). [verified-source]
- `locators` is an `FxHashMap` (`registry.rs:36`), so iteration order is not defined. If two locators both returned `Some` for the same task, which one wins is arbitrary. [verified-source for the type; the nondeterminism follows from it]
- The adapter name is passed to every locator (`ExtensionLocatorAdapter::create_scenario` forwards `adapter.0` as `debug_adapter_name`: `extension_locator_adapter.rs:29-45`). Errors in the guest are swallowed (`.ok().flatten()`), so a failing locator just yields `None`. [verified-source]

### Interaction with the Dart extension

- The Dart extension (`dart@fba74df extension.toml`) declares only `[language_servers.dart]`, `[grammars.dart]` and `[debug_adapters.Dart]`. **No `[debug_locators.*]`**, and `src/dart.rs` implements neither `dap_locator_create_scenario` nor `run_dap_locator` (trait defaults give `None` / `Err`). [verified-source]
- It does ship Dart tasks with tags: `languages/dart/tasks.json` (`flutter run` / `fvm flutter run` tagged `flutter-main`; `flutter test $ZED_FILE` tagged `flutter-test-main`; `dart test ...`) and `runnables.scm`. The tags only drive the gutter "run" buttons. Nothing turns them into debug scenarios today. [verified-source]
- Built-in locator names: `rust-cargo-locator`, `go-debug-locator`, `Node`, `Python` (`crates/project/src/debugger/locators/*.rs`, registered at `dap_store.rs:123-126`). Each returns `None` for non-matching commands (cargo: `build_config.command != "cargo"` at `cargo.rs:68`). So a `flutter`-command locator of ours cannot clash with them. [verified-source]
- **Therefore we can add a locator that turns `flutter run` into a "Flutter" scenario without any clash**, provided:
  1. our locator name is unique (locator names are a global `FxHashMap` key too; `add_locator` overwrites silently, `registry.rs:54-56`);
  2. it returns `None` unless `debug_adapter_name == "Flutter"` (so it stays quiet if the user prefers `debuggers: ["Dart"]`);
  3. it returns `None` early for anything that is not `flutter run` / `fvm flutter run` (docs: "your locator **will be** called with tasks it's unlikely to accept", `debugger-extensions.md:112`).
- The real limitation: the user (or nobody) must set `"languages": { "Dart": { "debuggers": ["Flutter"] } }` in settings. We cannot set it from our extension, because language config belongs to the Dart extension's `languages/dart/config.toml`. [verified-source for the mechanism; the user-settings snippet is an inference]. Only the first entry is used, so `["Flutter", "Dart"]` makes "Flutter" the locator adapter, while the New Session dropdown still lists both (next bullet).

### Picker / New Session with two adapters

- **New Session modal adapter dropdown:** lists all registered adapters (`DapRegistry::enumerate_adapters`, `new_process_modal.rs:478`), sorted by the active buffer language's `config().debuggers` index (unlisted adapters get `usize::MAX`, stable sort, so the underlying `BTreeMap` order, i.e. alphabetical, applies: `Dart` before `Flutter`). The first becomes the default selection only if the buffer has a language (`new_process_modal.rs:482-496`). Note this reads the language *config* `debuggers`, not the user settings. [verified-source]
- **Scenario picker:** lists `debug.json` scenarios, `.vscode` scenarios (unless `.zed` has some), locator-derived scenarios, and recents, filtered to registered adapters (`new_process_modal.rs:1146-1195`). Entries are matched by label, so both a "Dart" and a "Flutter" scenario show up side by side. Whether the adapter name is displayed in the row is not established from source. [unverified UI detail]
- New Session "custom" tab: calls `config_from_zed_format` = extension `dap_config_to_scenario` for the chosen adapter. Dart does not implement it (default `Err`), so the custom tab fails for Dart; ours should implement it. [verified-source for the plumbing: `extension_dap_adapter.rs:109-111`]

## Q4. What reaches the extension (`config`), and `request_args`

Flow, all [verified-source]:

1. `debug.json` entry parses to `DebugScenario` where `adapter`, `label`, `build`, `tcp_connection` are consumed as named fields and **every other key, known or not, lands in `config` via `#[serde(flatten)]`** (`task/src/debug_format.rs:272-274`). So `deviceId`, `toolArgs`, `flutterMode`, `useFvm`, `env`, `args`, `program`, `cwd`, `request`, `stopOnEntry` and any unknown custom key all survive. `adapter` and `label` are NOT in `config`.
2. `resolve_scenario` (`debugger_ui/src/session/running.rs:1072-1106`): on `config` it runs `relativize_paths` (only string values under keys `program` and `cwd`: lines 804-832) and `substitute_variables_in_config` (Zed `$ZED_*` task variables across the config; `running.rs:1106`). Then `adapter.request_kind(&config)` (line 1133-1138). Then it builds `DebugTaskDefinition { label, adapter, config, tcp_connection }` (`running.rs:~1310`, struct at `crates/dap/src/adapters.rs:145-158`).
3. `dap_store.get_debug_adapter_binary` (`project/src/debugger/dap_store.rs:243-305`) looks up the adapter, reads `dap.<adapter>.binary` (becomes `user_installed_path`, resolved relative to the worktree, lines 264-270) and calls `ExtensionDapAdapter::get_binary` (`extension_dap_adapter.rs:88-107`), which calls the extension's `get_dap_binary(adapter_name, config, user_installed_path, worktree)`. The user's `dap.<name>.args` and `dap.<name>.env` are **dropped** (`extension_dap_adapter.rs:93-96`: `// TODO support user args/env in the extension API`). [verified-source]
4. In the WIT/Rust API the `config` is a **JSON string** of the whole flattened object (`DebugTaskDefinition.config: String`; host conversion `since_v0_8_0.rs:170-178`). The Dart extension confirms it by doing `serde_json::from_str(&config.config)` and reading `deviceId`, `toolArgs`, `useFvm` etc. from it (`dart@fba74df src/dart.rs`). [verified-source]
5. `dap_request_kind(adapter_name, config: serde_json::Value)` gets the same flattened JSON (host side `extension_dap_adapter.rs:113-120`; Rust trait `api-0.7.0 extension_api.rs:211-217`). It is called in step 2, before `get_dap_binary`, so it must work from the raw user keys. Dart's returns `Err` when `request` is missing. [verified-source]
6. `dap_config_to_scenario(DebugConfig { label, adapter, request: DebugRequest, stop_on_entry })` is the New Session modal path only, and also the second phase of a locator-with-build (`running.rs:~1255-1270`). [verified-source]

`DebugAdapterBinary.request_args` / `StartDebuggingRequestArguments`:

- Rust type (wit `dap.wit`): `start-debugging-request-arguments { configuration: string /* JSON */, request: launch | attach }`; `debug-adapter-binary { command: Option<String>, arguments: Vec<String>, envs, cwd: Option<String>, connection: Option<TcpArguments>, request_args }`. [verified-source]
- Whatever JSON string we put in `request_args.configuration` is parsed (`since_v0_8_0.rs` TryFrom, `serde_json::from_str(&value.configuration)?`: `extension_host/src/wasm_host/wit/since_v0_8_0.rs:104-110`) and later sent verbatim as the DAP `launch` or `attach` request body: `session.rs:424-433` builds `Launch { raw: raw.configuration }`, and `dap_command.rs:1599-1611` maps it to `dap::LaunchRequestArguments { raw }` (attach analogously at 1622-1634). Zed adds nothing to it. The Dart extension relies on exactly this to inject `toolArgs`. [verified-source]
- The Zed-side variable substitution happened earlier on the scenario `config`, not on what we return in `request_args`. The wit comment says "`configuration` will have it's Zed variable references substituted prior to being passed to the debug adapter" (`dap.wit`); in practice substitution is in `resolve_scenario` before `get_dap_binary`. If we construct new strings that contain `$ZED_*`, nothing will expand them. [verified-source for the code path; the wit comment is slightly misleading]
- Child sessions (DAP `startDebugging` reverse request) clone the parent's binary and overwrite only `request_args` (`debugger_ui/src/debugger_panel.rs:458-459`). A proxy would see a second spawn of the same command if the child uses a new process. Whether Flutter's debug adapter ever sends `startDebugging` is not established. [unverified]

## Q5. `zed_extension_api` version, WASI target, min Zed, trait signatures

- Latest on crates.io: **0.7.0** (published 2025-09-12; `max_version` = `max_stable_version` = 0.7.0; previous 0.6.0 on 2025-06-18). From `https://crates.io/api/v1/crates/zed_extension_api`. [verified-source]
- Zed `main` has `crates/extension_api/Cargo.toml` at version **0.8.0 with `publish = false`** ("Change back to `true` when we're ready to publish v0.8.0"). Only Dev/Nightly may load 0.8.0 extensions; Stable/Preview max is 0.7.0 (`crates/extension_host/src/wasm_host/wit.rs:60-70`: `Stable | Preview => since_v0_6_0::MAX_VERSION`, and `since_v0_6_0.rs:11-12` = 0.6.0..=0.7.0; `since_v0_8_0.rs:36-37` = 0.8.0). **We must depend on `zed_extension_api = "0.7.0"`** (what the Dart extension does: `dart@fba74df Cargo.toml`). The 0.8.0 dap.wit differs from the 0.6.0/0.7.0 one only in `tcp-arguments.host` using an `ip-address` variant instead of `u32` (diff run locally). [verified-source]
- WASI target: **`wasm32-wasip2`** (component model). `crates/extension/src/extension_builder.rs:26-27` (`const RUST_TARGET: &str = "wasm32-wasip2"`), `docs/src/extensions/developing-extensions.md:29`, `api-0.7.0 README.md:55`. Not wasip1. Output `.wasm` name replaces `-` with `_` (`extension_builder.rs:241`). Crate-type must be `cdylib`, path e.g. `src/lib.rs`, as in the Dart `Cargo.toml`. [verified-source]
- 0.7.0 is `edition = "2024"` (so rustc >= 1.85). [verified-source: `api-0.7.0 Cargo.toml`]
- Minimum Zed: the debug adapter / locator API appears at `since_v0.6.0` (`wit.rs:127`, and the older wit versions return "not available prior to v0.6.0": `wit.rs` `call_dap_locator_create_scenario`). The crate README table: `0.192.x` supports `zed_extension_api 0.0.1 - 0.6.0`; `0.205.x` supports through `0.7.0` (README of `api-0.7.0`). So the minimum Zed that can load an API-0.7.0 extension is roughly 0.205.x; one built against 0.6.0 would need 0.192.x. Use `0.7.0` and state "Zed >= 0.205" in our README. [verified-source via README table; exact first stable of 0.205 not checked]
- Rust trait method signatures in `zed_extension_api 0.7.0` (`src/extension_api.rs:197-262`), all on `trait Extension`; defaults are `Err("... not implemented")` / `None`: [verified-source]

```rust
fn get_dap_binary(
    &mut self,
    _adapter_name: String,
    _config: DebugTaskDefinition,                 // { label, adapter, config: String /*JSON*/, tcp_connection: Option<TcpArgumentsTemplate> }
    _user_provided_debug_adapter_path: Option<String>,
    _worktree: &Worktree,
) -> Result<DebugAdapterBinary, String>;

fn dap_request_kind(
    &mut self,
    _adapter_name: String,
    _config: serde_json::Value,
) -> Result<StartDebuggingRequestArgumentsRequest, String>;

fn dap_config_to_scenario(&mut self, _config: DebugConfig) -> Result<DebugScenario, String>;

fn dap_locator_create_scenario(
    &mut self,
    _locator_name: String,
    _build_task: TaskTemplate,                    // { label, command, args, env, cwd }
    _resolved_label: String,
    _debug_adapter_name: String,
) -> Option<DebugScenario>;

fn run_dap_locator(
    &mut self,
    _locator_name: String,
    _build_task: TaskTemplate,
) -> Result<DebugRequest, String>;
```

Related types (`wit/since_v0.6.0/dap.wit`): `DebugScenario { label, adapter, build: Option<BuildTaskDefinition>, config: String, tcp_connection: Option<TcpArgumentsTemplate> }`; `DebugConfig { label, adapter, request: DebugRequest, stop_on_entry: Option<bool> }`; `DebugRequest::{Launch(LaunchRequest{program,cwd,args,envs}), Attach(AttachRequest{process_id})}`; `DebugAdapterBinary { command: Option<String>, arguments: Vec<String>, envs: Vec<(String,String)>, cwd: Option<String>, connection: Option<TcpArguments>, request_args: StartDebuggingRequestArguments }`.

## Q6. How the official Dart extension declares things (`dart@fba74df`)

- `extension.toml` (id `dart`, version 0.4.1, `schema_version = 1`): `[language_servers.dart]`, `[grammars.dart]`, and
  ```toml
  [debug_adapters.Dart]
  # schema_path optional; default debug_adapter_schemas/Dart.json
  ```
  No `[debug_locators.*]`, no `[[capabilities]]` (it uses `worktree.which`, not `process:exec`). [verified-source]
- `Cargo.toml`: `crate-type = ["cdylib"]`, `path = "src/dart.rs"`, `zed_extension_api = "0.7.0"`. [verified-source]
- `src/dart.rs` `get_dap_binary` (what we must mirror/replace):
  - `type` (`dart`|`flutter`) is required; `program` default `lib/main.dart`; `args`, `toolArgs`, `env`, `useFvm`, `deviceId`, `platform` (default `web`), `cwd` (default `worktree.root_path()`), `request` (default `launch`), `vmServiceUri`, `stopOnEntry`, `flutterMode` (default `debug`).
  - Command: `worktree.which("flutter"|"dart")` (`.bat` on Windows) with args `["debug_adapter"]`; with `useFvm` it is `fvm <tool> debug_adapter`.
  - `deviceId` is appended to `toolArgs` as `-d <id>` unless `-d` / `--device-id*` is already there (only for `type == flutter`), and also kept as top-level `deviceId` in the launch JSON.
  - `connection: None` (stdio). `request_args.configuration` is `{type, request, program, cwd, args, flutterMode, platform, stopOnEntry, sendLogsToClient: true, [vmServiceUri], [deviceId], [toolArgs]}`.
  - Ignores `_user_provided_debug_adapter_path`, so `dap.Dart.binary` does nothing. `dap_request_kind` errors if `request` is missing or is not `launch`/`attach`. No `dap_config_to_scenario`, no locator functions.
  [verified-source]
- `debug_adapter_schemas/Dart.json`: draft-07 object, `properties.adapter.enum = ["Dart"]`, `type` enum `dart|flutter`, plus `label, program, cwd, useFvm, args, toolArgs, env, flutterMode, deviceId, platform, request, vmServiceUri, stopOnEntry`. The existing research note says `additionalProperties: false` (see `zed-integration-surface.md`); I did not re-verify that line here. The schema is used for editor completion/validation of `debug.json` (`registry.rs: adapters_schema`), one `oneOf` branch per adapter keyed on `adapter`, so a second schema with a different `adapter` enum does not collide. [verified-source for mechanism]
- Fields worth mirroring in our schema so users can copy configs between the two adapters: `type`, `program`, `cwd`, `args`, `toolArgs`, `env`, `useFvm`, `flutterMode`, `deviceId`, `platform`, `request`, `vmServiceUri`, `stopOnEntry`. Keep the same names and defaults.

## Recommendations for our extension

1. **Adapter name:** `Flutter` (case exactly; distinct from `Dart`, `dart`, `flutter`). Do not name it `Dart`. Optionally, later, reserve a second tiny adapter `dart`/`flutter` (lowercase) for launch.json import, after a spike.
2. **`extension.toml`:**
   ```toml
   id = "flutter-run-debug"          # unique id; not "dart"
   schema_version = 1
   [debug_adapters.Flutter]
   # schema_path defaults to debug_adapter_schemas/Flutter.json (the file is mandatory)
   [debug_locators.flutter-run-locator]   # unique; avoid: dart, flutter, Node, Python, rust-cargo-locator, go-debug-locator
   ```
   No `[language_servers]`, no `[grammars]`, no language dir, so we never touch the Dart extension's language config. Add `[[capabilities]]` only if we need `process:exec` or `download_file` (to fetch the proxy binary from GitHub releases).
3. **`Cargo.toml`:** `zed_extension_api = "0.7.0"`, `crate-type = ["cdylib"]`, target `wasm32-wasip2`. Do not use 0.8.0 (unpublished; Dev/Nightly only).
4. **Schema `debug_adapter_schemas/Flutter.json`:** `adapter.enum = ["Flutter"]`; same property names as Dart's (list in Q6) so configs are copy-paste compatible; add our extras (`hotReloadOnSave`, `reloadDebounceMs`, etc.), `additionalProperties: true` to be lenient.
5. **`get_dap_binary`:** parse `config.config` as JSON; resolve `flutter`/`fvm` like Dart does; return `command = <our proxy binary>` (prefer `user_provided_debug_adapter_path` when set, so `dap.Flutter.binary` works, which Dart's does not allow), with `arguments = ["dap", "--", "flutter", "debug_adapter"]` or the fvm form, `connection: None`, `envs` from the config's `env`, `cwd` as Dart does, and `request_args.configuration` built like Dart's (including the `deviceId` to `toolArgs -d` rewrite, since Flutter's DAP ignores the top-level `deviceId`). Pass everything unknown through untouched, since the flatten behavior guarantees it arrives. Remember `dap.Flutter.args/env` never reach us (TODO in Zed), so any user-tunable proxy options must be debug.json keys.
6. **`dap_request_kind`:** copy Dart's, but fall back to `launch` when `request` is missing (Dart errors; being lenient helps locator-produced configs).
7. **`dap_config_to_scenario`:** implement it (Dart does not), so the New Session custom tab works for Flutter and the locator two-phase path is safe.
8. **Locator:** implement `dap_locator_create_scenario` to return `None` unless `debug_adapter_name == "Flutter"` and `command` is `flutter` (or `fvm` with `args[0] == "flutter"`) with `args` containing `run`; return a scenario with **no `build`** (Flutter's DAP builds and launches itself), `adapter = "Flutter"`, `config` JSON with `request: "launch"`, `type: "flutter"`, `program` default, forwarding `cwd`, extra args after `run` into `toolArgs` (only the ones `flutter run` accepts), `-d` from the task's args into `deviceId`. Leave `run_dap_locator` unimplemented (single phase). Match on `command`/`args`, never tags (not passed).
9. **Docs for users:** explain `"languages": {"Dart": {"debuggers": ["Flutter"]}}` in `settings.json` as the opt-in for the "debug this task" and gutter integration, and that `.zed/debug.json` scenarios with `"adapter": "Flutter"` work without it. Also tell users they can keep the Dart extension for LSP and its "Dart" adapter for pure-Dart (non-Flutter) debugging.
10. **Init tooling:** `zflutter init` should write `.zed/debug.json` scenarios with `"adapter": "Flutter"`, and should not write `.vscode/launch.json` (it is hidden anyway once `.zed` has tasks).

## Still unverified: needs a spike or a manual Zed test

1. Both extensions installed in a real Zed (stable and nightly): confirm both adapters appear in the New Session dropdown, that `Flutter` and `Dart` scenarios in one `debug.json` each start with the right binary, and that uninstalling one leaves the other working.
2. Whether the picker row shows the adapter name, and what the default selected adapter is in New Session for a Dart buffer with and without `languages.Dart.debuggers`.
3. That `languages.Dart.debuggers: ["Flutter"]` in user settings actually drives locator calls (source says `LanguageSettings::for_buffer(...).debuggers.first()`; not exercised).
4. Locator end-to-end: does `flutter run` from the Dart extension's `tasks.json` produce a "Flutter" scenario in the picker and the gutter run/debug menu; does the scenario without `build` start correctly; label formatting.
5. `.vscode/launch.json` with `type: "dart"` today: confirm it is silently dropped; optional lowercase `dart` adapter experiment (config has no `type`).
6. Child sessions: does Flutter's `debug_adapter` ever send `startDebugging`; if so, how a second proxy spawn behaves.
7. `dap.Flutter.binary` override: confirm `user_installed_path` arrives as an absolute worktree-resolved path, including on Windows.
8. Exact first Zed stable release that loads API 0.7.0 extensions (README table says 0.205.x; not checked against release notes), and that Zed Preview/Stable rejects 0.8.0 as the source says.
9. Whether the Dart `Dart.json` schema uses `additionalProperties: false` (not re-read here), and how Zed's JSON-schema validation presents unknown keys when two schemas exist.
10. Publishing: zed-industries/extensions registry rules for a second debug-adapter extension that targets Flutter (naming review, id uniqueness).
