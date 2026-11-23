# Extending zed-flutter-run

Recipes for the changes people make most often. [ARCHITECTURE.md](ARCHITECTURE.md) has the module map and the import rule. All Dart paths below are under `cli/`, all Rust paths under `extension/`.

Whatever you change, a user-visible change also needs a row or entry in [CONFIGURATION.md](CONFIGURATION.md) and a line in `CHANGELOG.md`.

## Add a CLI command

1. Write the command class in the module that owns the feature, for example `lib/src/devices/commands/my_command.dart`, extending `Command<int>`. Take every dependency as a constructor argument (`Console`, `HostEnvironment`, `Clock`, a store). Return a code from `ExitCodes` or throw a `FlutterRunException` subclass (`lib/src/common/errors.dart`). The runner prints the message and maps the exit code.
2. Add one entry to `buildCommands()` in `lib/src/cli/commands.dart`. If the command needs a shared object that does not exist yet, build it in `Wiring` (`lib/src/cli/wiring.dart`).
3. Do not declare `--verbose`, `--project` or `--flutter-sdk`. `FlutterRunRunner` adds them to every command.
4. Add a unit test under `test/unit/<module>/` that uses `MemoryConsole` and a hand-built `HostEnvironment`, and add the command name to the list in `test/unit/cli/runner_test.dart`.
5. Add a row to the commands table in [CONFIGURATION.md](CONFIGURATION.md). If `init` should write a Zed task for it, add it to `lib/src/init/templates.dart` and its tests.

A command that talks to a running session does not open sockets itself. It uses `ControlClient` and a control command (next recipe).

## Add an injected debug request

An injected request is one the proxy sends to the adapter on its own, such as `hotReload`.

1. Add the name to `DapCommands` in `lib/src/dap/messages.dart`.
2. If only some adapters support it, add it to `gatedInjections` and to the `supportedInjections` entry of each `DapKind` that has it, both in `lib/src/dap/injected_requests.dart`. A command that is not in `gatedInjections` is never refused.
3. Send it from `HotActions` (`lib/src/dap/hot_actions.dart`) or a similar coordinator with `RequestInjector.inject(command, arguments, timeout)`. `inject` returns the adapter's response, including `success: false`. It throws only `TimeoutException` and `StateError`, so turn those into a `HotResult`. Do not choose sequence numbers. `InjectedRequests` allocates them from 1,000,000,000 and swallows the response.
4. To reach it from the command line, add a method to `SessionControl` in `lib/src/control/control_protocol.dart` and an entry to the `_handlers` map in `ControlServer` (`lib/src/control/control_server.dart`). The map is the list of accepted commands. Implement it in `ProxySessionControl` in `lib/src/cli/wiring.dart`, calling `_checkAlive()` first and `_throwIfFailed` on the result. Add a command class (previous recipe), usually a subclass of `HotActionCommand` like `ReloadCommand` in `lib/src/control/reload_command.dart`. A new command does not change `controlProtocolVersion`. Changing the shape of an existing one does.
5. Describe the new command in the control channel section of [ARCHITECTURE.md](ARCHITECTURE.md).
6. Tests: `test/unit/dap/injected_requests_test.dart` (which adapters accept it), `hot_actions_test.dart` (with `FakeInjector`), `proxy_injection_test.dart` (through `FakeAdapter`), `test/unit/control/control_server_test.dart` (with `FakeControl`) and `test/unit/cli/wiring_test.dart` (`ProxySessionControl`).

## Add a `debug.json` key

1. Decide who handles it.
   - The Dart or Flutter adapter, untouched: only the schema changes (step 2).
   - The proxy: add the key to `LaunchRewriter.ownKeys` in `lib/src/dap/launch_rewriter.dart` so it is removed before the adapter sees it. Read its value from `RewriteResult.ownConfig` where it is needed (`DapSessionHost`, `SessionNotices`, `ReloadOnSaveConfig`). Parse tolerantly: on a bad value, add a note and use the default.
   - The extension, to build the proxy command line or environment: add a `KEY_*` constant and an entry in `READ_KEYS` in `src/proxy_args.rs`, and read it in `parse_config`.
2. Declare it in `debug_adapter_schemas/FlutterRun.json` with `type`, `description`, `markdownDescription`, `examples` for important keys, and `x-support` (`implemented`, `passthrough` or `ignored`). Every property needs a description and an `x-support`.
3. Update the tests that pin the lists.
   - `test/unit/schema_test.dart` checks `ownKeys` against the schema and pins the count with `hasLength`. Change the count.
   - In `src/lib.rs`, `PROXY_KEYS` lists the keys the proxy handles, and `proxy_keys_match_the_dart_rewriter` fails if it differs from `ownKeys`. Update both.
   - Add a case to `test/unit/dap/launch_rewriter_test.dart`.
4. Add the key to the tables in [CONFIGURATION.md](CONFIGURATION.md). If `init` should write it, edit `lib/src/init/templates.dart`. `schema_test.dart` validates the generated scenarios.

## Add a locator pattern

The locator turns a Zed task into a scenario. It is a pure function in `src/locator.rs` and is deliberately narrow.

1. Add the parsing to `parse_flutter_run` or `parse_dart`, or write a new `parse_*` function and route to it from the `match program_name(head)` in `scenario_config`. Return `None` for anything that is not clearly a task that starts an app, including a flag whose value is missing.
2. Put only keys that exist in the schema into the scenario (`Parsed::into_config`). The test `output_is_accepted_by_the_extension_parser` runs the result through `proxy_args::parse_config`.
3. Add tests in the same file: one for the forms you accept and one for near misses that must return `None`. Run `cargo test` in `extension/`.
4. Update the locator section of [CONFIGURATION.md](CONFIGURATION.md).
5. Leave `build` empty in `dap_locator_create_scenario`. The scenario is complete, so Zed never needs to run the locator's build step.

## Add an injected dependency

Use this for anything with I/O or time that a test needs to control, and for anything that differs by operating system.

1. Define a small `abstract interface class` next to the code that uses it, or in `lib/src/common/` if several modules use it. Keep it to the methods callers need.
2. Write the real implementation beside it, or in `lib/src/cli/` if it needs another module. Stateless ones take a `const` constructor (`SystemClock`).
3. Pass it to the consumer as a constructor argument. Build the shared instance in `Wiring` so `buildCommands` can hand it out. Do not call `DateTime.now()`, `Timer(...)`, `Process.start`, `ProcessSignal.watch` or `Platform.*` in module code.
4. For an OS difference, take a `HostEnvironment` and use `env.os`, `env.isWindows`, `env.pathsCaseInsensitive`, `env.pathContext` and `env.env(name)`. Tests can then build a `HostEnvironment` for any OS, as `test/unit/sdk/sdk_windows_test.dart` does. In the extension, the same role is played by the `Os` value passed to functions in `src/install.rs` and `src/proxy_args.rs`.
5. Put the fake with the tests that use it. Shared ones are in `test/unit/dap/fakes.dart` (`FakeChannel`, `FakeAdapter`, `FakeClock`), `test/unit/cli/support.dart` (`TestWiring`, `FakeSignalSource`) and `test/unit/control/support.dart` (`FakeControl`).
6. Add the interface to the table in the module map of [ARCHITECTURE.md](ARCHITECTURE.md).

## Testing

- `test/unit/<module>/` mirrors `lib/src/<module>/`. Run it with `dart test test/unit`.
- Control time with `fake_async` and `FakeClock`. Do not sleep in a unit test. Shrink waits through `ProxyOptions` and `ProxyTimings` instead of waiting for the defaults.
- `dart test test/unit/architecture_test.dart` checks the import rule. Run it after adding or moving an import.
- Tests tagged `integration-dart` drive a real `dart debug_adapter` and the compiled CLI: `dart test -t integration-dart -j 1`. Tests tagged `integration` need a Flutter SDK and run on the `flutter-tester` device: `dart test -t integration -j 1`. Run them after changing the proxy, the control channel, the watcher or SDK discovery.
- Run `dart pub get` in `cli/` before `dart format` and `dart analyze`, because the formatter reads the language version from the resolved package config. In `extension/`, run `cargo fmt`, `cargo clippy --all-targets` and `cargo test`.
- Changes to the extension's start-up path, the tasks or the keymap also need the checklist in [TESTING_IN_ZED.md](TESTING_IN_ZED.md).
