# Contributing

Bug reports, fixes and features are welcome. For anything larger than a small fix, open an issue first so we can agree on the approach before you write the code.

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Report security problems privately, as described in [SECURITY.md](SECURITY.md).

## Layout

| Path | Contents |
|---|---|
| `cli/` | The Dart package `flutter_run`: the command-line tool and the debug adapter proxy |
| `extension/` | The Rust Zed extension `flutter-run-debugger` |
| `fixtures/` | Sample projects the integration tests copy and run |
| `docs/` | User and developer documentation |

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the parts fit together and [docs/DESIGN.md](docs/DESIGN.md) for why.

## Set up

You need:

- Flutter 3.47 or newer (Dart 3.13 or newer)
- Rust through [rustup](https://rustup.rs), with the `wasm32-wasip2` target
- Zed, to try your change for real

```sh
sh tool/bootstrap.sh
```

The script checks for the tools above, adds the wasm target and fetches dependencies. It is safe to run again.

## Build and test

The CLI, from `cli/`:

```sh
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test test/unit
dart test -t integration-dart -j 1    # drives the real Dart debug adapter
dart test -t integration -j 1         # drives the real Flutter debug adapter on the headless flutter-tester device
```

The extension, from `extension/`:

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
cargo clippy --target wasm32-wasip2 -- -D warnings
cargo build --release --target wasm32-wasip2
```

CI runs all of these on Linux, macOS and Windows, plus `.github/scripts/check-versions.sh`, which checks that the version numbers in the two packages agree.

To try a change in Zed, compile the CLI onto your `PATH` and install the extension as a dev extension:

```sh
cd cli && dart compile exe bin/flutter_run.dart -o ~/.local/bin/flutter_run
```

Then run `zed: install dev extension` in Zed and choose the `extension/` folder.

## Code rules

1. **Module boundaries.** A module under `cli/lib/src/<module>/` imports only `package:*`, `dart:*`, `common/` and its own files. Modules are wired together in `cli/lib/src/cli/` and nowhere else. A test enforces this.
2. **The proxy's standard output belongs to the debug protocol.** Nothing else may write to it. Do not use `print` in `lib/`; use `Console` for command output and `Logger` for diagnostics.
3. **Pass collaborators in.** Classes that touch the clock, processes, signals or the environment take them as constructor arguments, so tests can replace them. Use the injected `Clock` for timers.
4. **Never start a process through a shell string.**
5. **Messages are whole sentences that say what to do next.** Notices in the debug console start with `[flutter_run]`.
6. **Commands return an exit code from `ExitCodes`** and throw a `FlutterRunException` subclass for expected failures.

## Pull requests

- Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `ci:`, `chore:`). Versions and release notes are generated from them.
- Add or update tests for what you changed. Run the integration suites if you touched the proxy, the control channel, the file watcher or SDK discovery.
- If you change a `debug.json` key, update `extension/debug_adapter_schemas/FlutterRun.json`, the `init` templates and [docs/CONFIGURATION.md](docs/CONFIGURATION.md) together.
- If you change a command, flag, message or exit code, update [docs/CONFIGURATION.md](docs/CONFIGURATION.md).
- No telemetry and no new network access.

## Releasing

1. Bump the version in the five places `.github/scripts/check-versions.sh` checks (it also needs a section for the version in `CHANGELOG.md` and `cli/CHANGELOG.md`), merge to `dev`, then open a pull request from `dev` to `prod`.
2. The merge to `prod` runs `release.yml`: it builds the binaries, creates the tag and the GitHub release, and starts the pub.dev publish. Approve that in the `pub.dev` environment.
3. Pin the checksums: `gh release download vX.Y.Z --pattern SHA256SUMS`, then `sh .github/scripts/pin-checksums.sh SHA256SUMS > extension/src/checksums.rs`. Open a pull request into `prod` with that file (`chore: pin vX.Y.Z checksums`), and merge `prod` back into `dev`.

## Testing on your setup

The project needs reports from real devices and operating systems more than anything else. If you run it on Android, iOS, the web, macOS or Windows, open an issue with the output of `flutter_run doctor` and what worked or did not.
