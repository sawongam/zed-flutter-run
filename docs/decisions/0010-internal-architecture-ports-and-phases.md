# 0010: Internal architecture: ports, injected clock, explicit session phases

- **Date:** 2026-11-08
- **Status:** Accepted (implemented on branch `improve/world-class`).
- **Inputs:** the code review of 2026-11-08, [0002](0002-architecture-dap-proxy.md), [0006](0006-plan-review-resolutions.md) D2/D3, [0007](0007-phase6-review-resolutions.md) P1/P2, the commits `30aa29e`, `9e2e0f8` and `0dbaa5f`.

## Context
The 2026-11-08 review found that the proxy worked but was hard to change safely:

- `dap/proxy.dart` was 994 lines. It routed messages, ran the whole stop sequence, tracked adapter events, ran the `initialize` watchdog and formatted failures.
- Session state was a set of loose booleans (`_started`, `_finishing`, `_terminateReceived`, `_terminateFinishing`, `_terminateFinished`, `_terminateDeadline`, `_shutdownRequested` and more, over a dozen in all). Which combinations were legal was not written down, so every new stop path risked a race.
- Time was hard-wired (eleven `Timer(` / `DateTime.now` uses in `proxy.dart` alone, fixed `Duration`s inside methods). Shutdown tests either waited in real time or could not reach some paths.
- `Process.start`, `Platform.*` and `ProcessSignal.watch` were called from module code, and `cli/dap_command.dart` mixed wiring with session logic.
- The module rule from the plan (modules import only `common/`) was a convention nobody checked.

## Options
1. **Leave the structure, add more tests.** Cheapest, but the tests would still need real time and the flag combinations would stay implicit.
2. **A dependency-injection framework or service locator** (for example `get_it` or a generated container). Gives one place to register things, but adds a dependency, hides the object graph behind lookups, and the graph is small (a dozen objects).
3. **A full typed DAP model** (a class per request, response and event, generated or hand-written). Gives compile-time safety, but the proxy touches about ten message kinds and must forward everything else byte for byte, including fields from newer Zed and adapter versions. A typed model would drop unknown fields or need a catch-all that defeats it, and it is a large surface to maintain. **Rejected.**
4. **Small interfaces (ports) with constructor injection, an explicit phase machine, a view type over raw messages, and a test that enforces the module rule.** **Chosen.**

## Decision
- **Ports.** `Clock` (`common/`), `HostEnvironment` (`common/`), `ProcessRunner` (`sdk/`), `SignalSource` and `ControlEndpoint` (`cli/`), plus the existing `AdapterConnection`, `DapChannel`, `RequestInjector`, `SessionControl`. Real adapters are `SystemClock`, `HostEnvironment.system()`, `SystemProcessRunner`, `SystemSignalSource`, `ServerEndpoint`, `ManagedAdapterConnection`, `ProxySessionControl`. Wiring is plain constructor injection in `Wiring`, `CommandContext` and `DapSessionHost`. No framework.
- **Injected clock.** Every timer and timestamp in the proxy, watchdog, coordinator, control server, watcher and stores goes through `Clock`. Tests use `FakeClock` over `fake_async`. All fixed waits live in `ProxyOptions` / `ProxyTimings` with the production values as defaults.
- **Explicit phases.** `SessionPhase` (`starting, running, stopping, finishing, finished`) with `SessionPhaseMachine` as the only authority on legal moves; illegal moves are logged and ignored. `ShutdownCoordinator` owns the terminate/disconnect/EOF/crash flows (each with a `StopFlow`) and talks to the proxy through `ShutdownHost`. `InitializeWatchdog`, `SessionTracker` and `FailureReporter` are separate classes. `DapProxy` is reduced to routing (497 lines, from 994).
- **`DapMessage` view.** An extension type over the decoded map with tolerant read-only getters. The proxy reads through it and forwards `message.raw`; only `launch`/`attach` arguments are replaced.
- **Injected request capabilities.** `supportedInjections` per `DapKind`, checked by `injectionSupported`, so unsupported requests (`hotRestart` on the Dart adapter) are refused before they are sent.
- **Attach validation** in `LaunchRewriter`: the `init` placeholder URI is rejected; Dart attach needs an address; Flutter attach may wait for the app, with the 15 s watchdog notice.
- **Enforcement.** `cli/test/unit/architecture_test.dart` fails when `common/` imports a sibling, a feature module imports anything but `common/` and itself, or anything outside `cli/` imports `cli/`.
- **Extension side.** `install.rs` gets a pure planner (`plan_install` returning an `InstallPlan`, typed `InstallError`), and `locator.rs` holds the debug locator of [0009](0009-debug-locator.md); `lib.rs` is glue.

## Consequences
- Shutdown, startup-failure and attach paths are tested with fake time in milliseconds of real time, and the stop sequence that Zed relies on (ADR 0006 D2) is covered by `shutdown_coordinator_test.dart` and `session_phase_test.dart`.
- Adding a command, request, key or locator pattern follows a fixed recipe ([EXTENDING.md](../EXTENDING.md)).
- Constructors take more arguments. `Wiring` and `CommandContext` keep call sites short, but a new dependency touches two or three files.
- The phase machine forbids moving backwards. A future "restart the session in place" feature would need a new phase or a new session object, not a reset.
- `DapMessage` getters cast and return empty maps for bad shapes; malformed messages from the adapter are treated as "field missing", not as errors.
- Known gap: `FlutterRunRunner.runWithExit` still calls `ProcessSignal.sigint.watch()` directly for non-`dap` commands instead of using `SignalSource`.
- No new runtime dependency, and no behaviour change for users beyond the attach validation and the locator.
