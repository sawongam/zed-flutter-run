# Contributing

Thanks for helping. By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Report security problems privately, see [SECURITY.md](SECURITY.md).

## Repository layout

| Path | What |
|---|---|
| `cli/` | The Dart package `flutter_run` (CLI and DAP proxy). `bin/` entry point, `lib/src/<module>/` modules, `test/unit/`, `test/integration/` |
| `cli/lib/src/` | `common`, `dap`, `control`, `sdk`, `devices`, `watch`, `devtools`, `init`, `cli` |
| `extension/` | The Rust Zed extension (`flutter-run-debugger`): `src/`, `extension.toml`, `debug_adapter_schemas/FlutterRun.json` |
| `fixtures/` | Sample projects used by tests (do not edit; tests copy them) |
| `docs/` | Project memory: plan, decisions, research, reviews, conversation logs |
| `spike/` | Historical, not built, never edited |
| `.github/` | CI and release workflows |

## Prerequisites

- Dart SDK 3.8 or newer (it comes with Flutter).
- Flutter SDK for the `integration` suite (it uses `flutter-tester`, no device needed).
- Rust (via rustup) with the `wasm32-wasip2` target for the extension.
- Zed, for manual testing (`zed: install dev extension`).

## Running checks

CLI, from `cli/`:

```sh
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test --exclude-tags integration --exclude-tags integration-dart   # unit tests
dart test -t integration-dart -j 1    # Dart debug adapter, no Flutter needed
dart test -t integration -j 1         # needs a Flutter SDK; uses flutter-tester
```

Extension, from `extension/`:

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
rustup target add wasm32-wasip2
cargo clippy --target wasm32-wasip2 -- -D warnings
cargo build --release --target wasm32-wasip2
```

## Code rules

(from [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) section 3)

1. **Module boundaries:** a module under `lib/src/<module>/` may import `package:*`, `dart:*`, `lib/src/common/**` and files of its own module only. Modules are wired together in `lib/src/cli/` (composition root).
2. **No `print` in `lib/`.** Output goes through `Console` (CLI results) or `Logger` (diagnostics). **Nothing may write to stdout in the proxy** except the DAP channel.
3. **Message style:** whole sentences that say what to do next; placeholders only through function parameters (no fragment concatenation, no pluralising by appending `s`); no hard-coded shortcut names except in `init`/README text about Zed's defaults; ASCII `...`; no exit-code names or jargon in text. Console notices start with `[flutter_run]`; warnings and errors carry `Warning:` / `Error:`. Keep text next to the code that uses it.
4. **Testability:** I/O classes take their collaborators (`HostEnvironment`, `Console`, `Logger`, process runners) as constructor arguments. Use `Timer` / `Future.delayed` for time so `fake_async` works.
5. Every `Command<int>` returns an exit code from `ExitCodes` and throws `FlutterRunException` subclasses for expected failures.
6. `dart format`, `dart analyze --fatal-infos` clean, LF line endings.
7. Never start processes through a shell string.

## Docs are the project memory

Read [docs/README.md](docs/README.md) before you start. After a milestone or a useful discussion:

- add a log to `docs/conversations/`;
- record decisions as ADRs in `docs/decisions/`;
- keep `docs/research/` correct (add a correction note rather than silently rewriting history);
- update the index in `docs/README.md`.

## Pull request checklist

- [ ] Format, analyze and unit tests pass; integration tests pass if you touched the proxy, control channel, watcher or SDK code.
- [ ] `cargo fmt`, `clippy` and `cargo test` pass if you touched `extension/`.
- [ ] If you changed a debug.json key, update `FlutterRun.json`, `init` templates, README and the schema test together.
- [ ] If you added or changed a command, flag, message or exit code, update the README and CHANGELOG (`## [Unreleased]`).
- [ ] No stdout writes in the proxy; no new `print`.
- [ ] Docs updated (conversation log, ADR if you decided something, research notes if facts changed).
- [ ] No secrets, no telemetry, no network calls beyond what SECURITY.md describes.
