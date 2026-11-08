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
| `tool/` | Contributor scripts (`bootstrap.sh`) |

## Quick start

```sh
sh tool/bootstrap.sh
```

The script checks for `dart`, `flutter` and `rustup`, adds the `wasm32-wasip2` target, runs `dart pub get` in `cli/` and `cargo fetch` in `extension/`. It is safe to run again and never uses `sudo`. A dev container is in `.devcontainer/` if you prefer one.

## Prerequisites

- Dart SDK 3.8 or newer (it comes with Flutter).
- Flutter SDK for the `integration` suite (it uses `flutter-tester`, no device needed). CI uses the version in `FLUTTER_VERSION` in `.github/workflows/ci.yml`.
- Rust (via rustup) with the `wasm32-wasip2` target for the extension.
- Zed, for manual testing (`zed: install dev extension`). See [docs/MANUAL_ZED_TEST.md](docs/MANUAL_ZED_TEST.md).

## Run CI locally

CLI, from `cli/`. Run `dart pub get` before `dart format`, because format needs the package config:

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

CI also runs `sh .github/scripts/check-versions.sh`, which checks that the version numbers agree.

## Architecture rules

- Every module under `cli/lib/src/<module>/` imports only `package:*`, `dart:*`, `lib/src/common/**` and its own files. Modules never import each other.
- Only `cli/lib/src/cli/` wires modules together (the composition root).
- A module defines the interfaces it needs, and `cli/` provides the real implementations.
- For a design change, write an ADR in `docs/decisions/` (`NNNN-title.md`: context, options, choice, consequences) and add it to the index in `docs/README.md`. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first.

## Commits and pull requests

Use [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `ci:`, `chore:`. Mark breaking changes with `!` or a `BREAKING CHANGE:` footer. Release automation (release-please) is being added and will build the changelog and version from these messages.

## Good first issues

Look for the [`good first issue`](https://github.com/sawongam/zed-flutter-run/labels/good%20first%20issue) label. Running [docs/MANUAL_ZED_TEST.md](docs/MANUAL_ZED_TEST.md) on your OS and reporting the results is also very welcome, since nothing has been tested in real Zed yet.

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
- [ ] If you changed a debug.json key, update `FlutterRun.json`, `init` templates, `docs/CONFIGURATION.md` and the schema test together.
- [ ] If you added or changed a command, flag, message or exit code, update `docs/CONFIGURATION.md` and the CHANGELOG (`## [Unreleased]`).
- [ ] No stdout writes in the proxy; no new `print`.
- [ ] Docs updated (conversation log, ADR if you decided something, research notes if facts changed).
- [ ] No secrets, no telemetry, no network calls beyond what SECURITY.md describes.
