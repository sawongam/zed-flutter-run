# 0009: Debug locator for `flutter run` and `dart run` tasks

- **Date:** 2026-11-08
- **Status:** Accepted (implementation work on branch `improve/world-class`). Supersedes the "Locator deferred" bullet of [0006](0006-plan-review-resolutions.md) D4.
- **Inputs:** [zed-integration-surface](../research/zed-integration-surface.md), [coexistence-with-dart-extension](../research/coexistence-with-dart-extension.md) Q3, Zed docs <https://zed.dev/docs/extensions/debugger-extensions>, the Ruby extension (`extension.toml` has `[debug_locators.ruby]`; `src/ruby.rs` implements `dap_locator_create_scenario` and returns a scenario with `build: None`), and `zed_extension_api` 0.7.0 (`src/extension_api.rs`, `wit/since_v0.6.0/dap.wit`).

## Context
ADR 0006 D4 deferred the locator because it "only works when the user sets `languages.Dart.debuggers`, and can't be tested here". Both facts are still true (Zed only calls locators with the adapter of the active buffer's language; with no `debuggers` setting no locator runs at all). But a locator is the only way to get a debug entry from the tasks users already have (`flutter run -d linux`), and its cost is small: one pure function and one manifest line. The 0.7.0 API gives us `dap_locator_create_scenario(locator_name, build_task, resolved_label, debug_adapter_name) -> Option<DebugScenario>`, where `build_task` carries only `label, command, args, env, cwd` (no task tags). A scenario returned without `build` skips the second phase, so `run_dap_locator` is not needed.

## Options
1. **No locator** (status quo). Zero risk, but users must hand-write `.zed/debug.json` for every task.
2. **Broad locator** that claims every `flutter ...` / `dart ...` task. Would hijack `flutter build`, `flutter test`, `dart pub get`.
3. **Narrow locator** that claims only tasks that start an app: `flutter run`, `fvm flutter run`, `puro flutter run`, `dart run <file>.dart`, `dart <file>.dart`. Everything else returns `None`. **Chosen.**
4. **Locator with a build step** (`build: Some(..)` plus `run_dap_locator`). Needed for compiled languages that must find an artifact; Flutter and Dart run from source, so it only adds a second phase that can fail.

## Decision
- `extension.toml` declares `[debug_locators.FlutterRun]`. The locator is only used for a `(locator_name, debug_adapter_name)` pair of `FlutterRun`/`FlutterRun`; any other adapter (for example the official Dart extension's `Dart`) gets `None`, so coexistence is unchanged.
- Parsing lives in the pure module `extension/src/locator.rs`; `lib.rs` only forwards the call.
- Mapping for `flutter run` (also `fvm flutter run`, `puro flutter run`; a path or `.exe`/`.bat` suffix on the command is accepted):

  | Task argument | Scenario key |
  |---|---|
  | `-d X`, `--device-id X`, `--device-id=X`, `-dX` | `deviceId` |
  | `--profile`, `--release`, `--debug` | `flutterMode` |
  | `-t X`, `--target X`, `--target=X`, `-tX` | `program` |
  | anything else (`--flavor dev`, `--dart-define=A=1`, `-v`) | `toolArgs`, in order |
  | after a bare `--` | `args` (for the app) |
  | `fvm` prefix | `useFvm: true` |
  | task `env`, `cwd` | `env`, `cwd` |

  Not matched (return `None`): other subcommands, global flags before `run`, `flutter run --machine` (it owns stdout), flags missing their value.
- `dart run <file>.dart [args]` and `dart <file>.dart [args]` give `type: "dart"` with `program` and `args`; flags before the file go to `toolArgs`. `dart run <package>`, `dart test`, `dart pub ...` return `None`.
- A command that contains spaces is split on whitespace only if there are no separate args and no quotes. Otherwise it is treated as a path and not matched.
- The scenario has `build: None` and the task's resolved label.

Related change in the same batch: the modal `dap_config_to_scenario` now picks `type: "dart"` for a `.dart` program whose first `lib`/`bin`/`test` folder is not `lib` (or that has none), rejects an empty launch program with a clear error, and documents that a modal attach scenario still needs `vmServiceUri`. The JSON schema now requires `vmServiceUri` or `vmServiceInfoFile` for `request: attach`.

## Consequences
- Users who set `"languages": {"Dart": {"debuggers": ["FlutterRun"]}}` see a debug entry next to their `flutter run` tasks. Without that setting nothing changes.
- Task matching is by command line only, so a task that wraps `flutter run` in a shell script is not matched. That is deliberate.
- `puro flutter run` is mapped like plain `flutter run`; the proxy cannot select a puro environment, so the `flutter` found by the normal SDK resolution is used.
- **Unverified in real Zed.** Unit tests cover the parser and the manifest/name constants, but the locator was never run inside Zed (no Zed available to the implementing agent), so how the picker shows these entries and whether `$ZED_*` variables in `cwd` are substituted for locator scenarios must be checked by hand before release.
- Risk register: if two locators claimed the same task, Zed picks one arbitrarily (hash-map order). Ours is narrow, and the Dart extension has none.
