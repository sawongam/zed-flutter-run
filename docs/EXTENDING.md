# Extending zed-flutter-run

Recipes for the changes people most often make. Read [ARCHITECTURE.md](ARCHITECTURE.md) sections 4.9 to 4.15 first for the module map, the ports and the phase model. Last checked against the code on 2026-11-08 (branch `improve/world-class`).

Rules that apply to every recipe:

- A feature module (`dap, control, sdk, devices, watch, devtools, init`) imports only `common/` and itself. Only `cli/` wires modules together. `cli/test/unit/architecture_test.dart` fails on a violation.
- Time, processes, signals and the OS come in through ports (`Clock`, `ProcessRunner`, `SignalSource`, `HostEnvironment`). Do not call `DateTime.now()`, `Timer(...)`, `Process.start` or `Platform.*` in module code.
- The proxy forwards `message.raw`. Never rebuild a client message from typed fields.
- Update [CONFIGURATION.md](CONFIGURATION.md) for anything a user can see, and add a line to `CHANGELOG.md` if the change ships.

## 1. Add a CLI command

1. Create the command class in the module that owns the feature, for example `cli/lib/src/devices/commands/my_command.dart`, extending `Command<int>`. Take every dependency as a constructor argument (`Console`, `HostEnvironment`, `Clock`, a store). Return an exit code from `ExitCodes` (`common/errors.dart`) or throw a `FlutterRunException` subclass; the runner maps it.
2. Add it to `CommandContext.commands()` in `cli/lib/src/cli/command_context.dart`, one entry, passing fields from the context (`env`, `console`, `clock`, `sessionStore`, `controlClient`, `deviceStore`, `sdkResolver`, `processRunner`). If it needs a new shared object, add it to `Wiring` (`cli/lib/src/cli/wiring.dart`) with a production default, then expose it on `CommandContext`.
3. Global options (`--verbose`, `--project`, `--flutter-sdk`) are added to the runner. Do not declare them again; `runner_test.dart` fails if you do.
4. Tests: a unit test under `cli/test/unit/<module>/` using `MemoryConsole` and a hand-built `HostEnvironment`; add the name to the "every planned command is registered" list in `cli/test/unit/cli/runner_test.dart`.
5. Docs: a row in the commands table of [CONFIGURATION.md](CONFIGURATION.md). If `init` should write a Zed task for it, add it to `init/templates.dart` (`task(...)`) and its tests.

If the command talks to a running session, do not add TCP code. Use `ControlClient` and a control command (recipe 2).

## 2. Add an injected DAP request (and, optionally, a control command)

An injected request is one the proxy sends to the adapter itself, such as `hotReload`.

1. **Name it.** Add a constant to `DapCommands` in `cli/lib/src/dap/messages.dart`.
2. **Gate it by adapter.** If only some adapters support it, add it to `gatedInjections` and to the `supportedInjections` entry of each `DapKind` that has it (`cli/lib/src/dap/injected_requests.dart`). The capability table in [ARCHITECTURE.md](ARCHITECTURE.md) section 4.13 must match. An ungated command is never refused.
3. **Send it.** Add a method to `HotActions` (`dap/hot_actions.dart`) or a similar coordinator, calling `RequestInjector.inject(command, args, timeout)`. `inject` returns the adapter response including `success: false`; it throws only `TimeoutException` and `StateError`. Map failures to a `HotResult` / `HotError` rather than throwing outward. Do not allocate seq numbers yourself: `InjectedRequests` does, from 1,000,000,000, and swallows the response.
4. **Expose it to the CLI (optional).** In `cli/lib/src/control/control_protocol.dart` add the name to `controlCommands` and a method to `SessionControl`; add a `case` in `ControlServer._dispatch` (`control_server.dart`); implement it in `ProxySessionControl` (`cli/lib/src/cli/wiring.dart`) with `_checkAlive()` first and `_throwIfFailed` for errors. Add a `Command` for it (recipe 1), usually by subclassing `HotActionCommand` like `ReloadCommand`. The protocol version (`controlProtocolVersion`) changes only if an existing command changes shape; a new command is additive.
5. **Document the wire contract** in [ARCHITECTURE.md](ARCHITECTURE.md) section 5.1 (command table, `result` fields).
6. Tests: `injected_requests_test.dart` (gate), `hot_actions_test.dart` (`FakeInjector`), `proxy_injection_test.dart` (end to end with `FakeAdapter`), `control_server_test.dart` (`FakeControl`).

## 3. Add a `debug.json` key

1. **Decide who handles it.** Three cases:
   - Passed to the adapter untouched (`passthrough`): only the schema changes (step 2).
   - Read by the proxy (reload, devices, DevTools, notices): add it to `LaunchRewriter.ownKeys` in `cli/lib/src/dap/launch_rewriter.dart`, so it is stripped before the adapter sees it, and read it from `RewriteResult.ownConfig` where needed (`DapSessionHost`, `SessionNotices`). Parse tolerantly and add a note instead of throwing.
   - Read by the extension to build the proxy command line or environment: add a `KEY_*` constant and an entry in `READ_KEYS` in `extension/src/proxy_args.rs`, and read it in `parse_config`.
2. **Declare it in the schema**, `extension/debug_adapter_schemas/FlutterRun.json`: type, `description`, `markdownDescription`, `examples` for important keys, and `x-support` (`implemented`, `passthrough` or `ignored`). Every property must have one.
3. **Update the tests that pin the lists.**
   - Dart: `cli/test/unit/schema_test.dart` checks that every `ownKeys` entry is in the schema and marked `implemented` or `ignored`, and pins the count (`hasLength(12)`); change the count with the key.
   - Rust: in `extension/src/lib.rs`, `keys_marked_implemented_are_the_ones_we_know_about` has a `PROXY_KEYS` list; add proxy-handled keys there. `every_key_the_extension_reads_is_in_the_schema` covers `READ_KEYS`.
   - Add a launch rewriter test in `cli/test/unit/dap/launch_rewriter_test.dart`.
4. **Document it** in the key tables of [CONFIGURATION.md](CONFIGURATION.md) and, for an own key, in the list in ARCHITECTURE.md section 4.2 and 5.5.
5. If `init` should write it into templates, edit `cli/lib/src/init/templates.dart`; the schema test validates the generated scenarios.

## 4. Add a locator pattern

The locator turns a Zed task into a scenario. It is a pure function in `extension/src/locator.rs`; keep it narrow (ADR 0009).

1. Add the parsing in `parse_flutter_run` / `parse_dart` or a new `parse_*` function, and route to it from `scenario_config`'s `match program_name(head)`. Return `None` for anything that is not clearly "start an app".
2. Emit only keys that exist in the schema (`into_config`). The test `output_is_accepted_by_the_extension_parser` feeds the result through `proxy_args::parse_config`.
3. Add tests in the same file: one for the accepted forms, one for the near misses that must return `None`. Run `cargo test` in `extension/`.
4. Update the mapping table in [ADR 0009](decisions/0009-debug-locator.md) only if the decision changes; otherwise update the locator section of [CONFIGURATION.md](CONFIGURATION.md).
5. Do not add a build step (`build: Some(..)`); the scenario is complete and `run_dap_locator` stays unused.

## 5. Add a port or a platform branch

**A new port** (something with I/O or time that tests need to control):

1. Define a small `abstract interface class` next to the code that needs it, or in `common/` if several modules use it. Keep the surface to what callers actually call.
2. Add the real implementation (`SystemX`, `const` constructor if stateless) beside it, or in `cli/` when it needs another module.
3. Take the port as a constructor argument. A default for production is fine on `Wiring` or on the entry point (`DapSessionHost`, `DapCommand`); module classes should have no hidden defaults beyond `const SystemClock()`.
4. Put the fake in the test support files (`cli/test/unit/dap/fakes.dart`, `cli/test/unit/cli/support.dart`) and add the port to the table in ARCHITECTURE.md section 4.10.

**A platform branch** (behaviour that differs by OS): do not read `Platform.isWindows`. Take a `HostEnvironment` and branch on `env.os` / `env.isWindows` / `env.pathsCaseInsensitive`, use `env.pathContext` for paths and `env.env(name)` for variables (case-insensitive on Windows). Tests then build a `HostEnvironment(os: HostOs.windows, ...)` on any host, as `sdk_windows_test.dart` does. For the extension, the same idea is the `Os` enum passed into `install.rs` and `proxy_args.rs` functions.

## 6. Testing conventions

- **Layout.** `cli/test/unit/<module>/` mirrors `lib/src/<module>/`. Shared fakes: `cli/test/unit/dap/fakes.dart` (`FakeChannel`, `FakeAdapter`, `FakeClock`), `cli/test/unit/cli/support.dart` (`TestWiring`, `FakeSignalSource`), `cli/test/unit/control/support.dart` (`FakeControl`), `cli/test/unit/sdk/fake_sdk.dart`.
- **Time.** Use `fake_async` with `FakeClock(async)` and `async.elapse(...)`. Never `await Future.delayed` or sleep in a unit test. Shrink waits with `ProxyOptions` / `ProxyTimings` instead of waiting for the defaults.
- **Tags** (`cli/dart_test.yaml`):
  - none: unit tests, run everywhere, fast.
  - `integration-dart`: drives a real `dart debug_adapter` and the compiled CLI; runs on Linux, macOS and Windows CI.
  - `integration`: needs a Flutter SDK and `flutter_tester`; runs on Linux CI.
  - Locally: `dart test --exclude-tags integration --exclude-tags integration-dart` for unit tests, `dart test -t integration-dart -j 1`, `dart test -t integration -j 1`.
- **Architecture rule.** Run `dart test test/unit/architecture_test.dart` after moving or adding imports.
- **Formatting and analysis.** Run `dart pub get` in `cli/` before `dart format` (the formatter reads the package language version from the resolved package config) and before `dart analyze`. Rust: `cargo fmt`, `cargo clippy`, `cargo test` in `extension/`.
- **Schema.** `schema_test.dart` validates generated scenarios against `FlutterRun.json`; Rust tests in `extension/src/lib.rs` check the same file from the other side.
- **Docs.** Record decisions that change the design as an ADR in `docs/decisions/` and add a line to the index in [README.md](README.md).
