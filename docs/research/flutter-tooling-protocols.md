# Flutter/Dart tooling protocols our tool would speak

Date: 2026-11-04. Local env: Flutter 3.47.0 stable (fvm), Dart 3.13.0, DevTools 2.60.0, Linux.

Legend: **[L]** verified by running a command locally; **[S]** read from local SDK source at `~/development/fvm/default/packages/flutter_tools/lib/src/...` (rev 4cf2416426, Flutter 3.47.0); **[D]** from online docs/repos (URL given); **[DC]** read from a shallow clone of Dart-Code master (https://github.com/Dart-Code/Dart-Code); **[?]** unverified/secondary source.

## 1. `flutter debug-adapter` / `dart debug-adapter`

Docs: Flutter-specific https://github.com/flutter/flutter/blob/main/packages/flutter_tools/lib/src/debug_adapters/README.md (identical to local copy **[S]**); Dart base https://github.com/dart-lang/sdk/blob/main/third_party/pkg/dap/tool/README.md **[D]**.

Command line **[L]** (`flutter debug-adapter --help`): `--[no-]dds`, `--dds-port`, `--[no-]test`, `-d/--device-id`. The client speaks first; stdio DAP, no output until `initialize`. `--test` runs `flutter test` and emits `dart.testNotification` events.

### Launch args (Flutter) **[S: flutter_adapter_args.dart; D: README]**
Common to launch+attach: `cwd`, `env` (map), `toolArgs` (args for `flutter run|attach|test`, e.g. `-d <id>`, `--flavor`, `--profile`, `--dart-define=...`), `customTool`, `customToolReplacesArgs`, `debugExternalPackageLibraries`, `debugSdkLibraries`, `evaluateGettersInDebugViews`, `evaluateToStringInDebugViews`, `sendLogsToClient`, `additionalProjectPaths`, plus base Dart args (`showGettersInDebugViews`, `vmServicePort`, `sendCustomProgressEvents`, `allowAnsiColorOutput`).
Launch only: `program` (passed as `--target`), `args` (app args, after toolArgs), `noDebug`.
Attach only: `vmServiceUri` XOR `vmServiceInfoFile` (both -> adapter errors and terminates); neither -> `flutter attach` discovers from device.
Profile/release: adapter detects `--profile`/`--release` in `toolArgs` and disables the debugger (no VM service connection) but hot reload via daemon still works **[S]**. `console: terminal` (runInTerminal) is in the Dart (non-Flutter) base docs **[D]**; the Flutter adapter always spawns `flutter` itself (`launchAsProcess`) **[S]**, so do not rely on runInTerminal for Flutter.

### What the adapter actually runs **[S: flutter_adapter.dart:140-300]**
- launch: `flutter run --machine [--no-dds] [--start-paused if debugging] [--dart-define=flutter.inspector.structuredErrors=false if noDebug] <toolArgs> --target <program> <args>`
- attach: `flutter attach --machine [--no-dds] [--debug-uri <uri>] <toolArgs>` (`--debug-uri` is an alias of `--debug-url` **[S: commands/attach.dart:104]**).
- Executable = `<flutterRoot>/bin/flutter` or `flutter.bat` on Windows; the adapter's own Flutter root (the SDK that runs `debug-adapter`) is used, so the SDK we launch is the SDK used.
- Stop: sends `app.stop` (launch) or `app.detach` (attach) to the machine process.

### Custom requests
| Request | Args | Source |
|---|---|---|
| `hotReload` | `{"reason":"manual"\|"save"}` -> `app.restart {fullRestart:false}` | [S][D] |
| `hotRestart` | `{"reason":...}` -> `app.restart {fullRestart:true}` | [S][D] |
| `$/hotReload` | alias (internal IDE convention) | [S] |
| `flutter.sendForwardedRequestResponse` | `{id, result?, error?}` answers a `flutter.forwardedRequest` | [S] |
| `callService` | `{method, params}` any VM service RPC / registered service | [D dart README] |
| `updateDebugOptions` | `{debugSdkLibraries?, debugExternalPackageLibraries?}` | [D dart README] |
Also standard DAP `restartRequest` is supported (capability `supportsRestartRequest` is sent via a `capabilities` event once `app.start` says `supportsRestart`) **[S:_handleAppStart]** - i.e. the toolbar "restart" maps to hot restart.

### Custom events
- `flutter.appStart` body = `app.start` params (`appId, deviceId, mode, supportsRestart, launchMode, directory`) **[S]**
- `flutter.appStarted` `{}` (also in profile/release/noDebug) **[D][S]**
- `flutter.serviceExtensionStateChanged` `{"extension":"ext.flutter.debugPaint","value":"true"}` (values always strings) **[D]**
- `flutter.forwardedRequest` `{id, method, params}`: reverse requests from `flutter run --machine` that need the client. Only `app.exposeUrl` is forwarded **[S]**; client must answer via `flutter.sendForwardedRequestResponse`. Dart-Code does exactly this **[DC: src/extension/commands/debug.ts ~L830-850]**.
- `app.webLaunchUrl`, `app.warning` forwarded as events **[S]** (names as given in `_eventsToForwardToClient`).
- Dart base: `dart.debuggerUris {vmServiceUri}` (debug only; Dart-Code also reads `observatoryUri`, `clientVmServiceUri`), `dart.serviceRegistered/Unregistered {service, method}`, `dart.serviceExtensionAdded {extensionRPC, isolateId}`, `dart.log`, `dart.progressStart/Update/End`, `dart.testNotification` **[D]**.
- No `dart.devToolsServer` event exists in the DAP; DevTools is obtained separately (section 4).

Example launch config (DAP arguments) **[composed from S/D, not run end to end]**:
```json
{"request":"launch","type":"dart","program":"lib/main.dart","cwd":"/path/app",
 "toolArgs":["-d","linux","--dart-define=ENV=dev"],"args":[],"noDebug":false}
```
Hot reload from a client: `{"type":"request","command":"hotReload","arguments":{"reason":"save"}}`. Progress ("Hot reloading...") is surfaced as DAP progress events by the adapter **[S:_performRestart]**.

## 2. `flutter run --machine` and `flutter daemon`

Spec: https://github.com/flutter/flutter/blob/main/packages/flutter_tools/doc/daemon.md **[D]**. Transport: one JSON array per line on stdin/stdout, `[{...}]`; requests `{"id":N,"method":..,"params":{..}}`, responses `{"id":N,"result":..}` or `{"id":N,"error":..}`, events `{"event":..,"params":{..}}`.

`flutter run --machine` subset: commands `app.restart`, `app.callServiceExtension`, `app.detach`, `app.stop`, `daemon.version/shutdown`; events `daemon.connected/log/logMessage`, `app.start`, `app.debugPort`, `app.started`, `app.log`, `app.progress`, `app.stop`, `app.warning`, `app.webLaunchUrl`, plus `app.devTools {uri}` and `app.dtd {uri}` emitted after `app.debugPort` when served **[D][S: commands/daemon.dart:807-811]**.

Examples (shapes from doc; field lists above from doc):
```
-> [{"id":1,"method":"app.restart","params":{"appId":"<id>","fullRestart":false,"reason":"save","pause":false}}]
<- [{"id":1,"result":{"code":0,"message":""}}]
-> [{"id":2,"method":"app.callServiceExtension","params":{"appId":"<id>","methodName":"ext.flutter.debugPaint","params":{"enabled":"true"}}}]
-> [{"id":3,"method":"app.stop","params":{"appId":"<id>"}}]
<- [{"event":"app.debugPort","params":{"appId":"<id>","port":51234,"wsUri":"ws://127.0.0.1:51234/abc=/ws"}}]
```
`app.restart` extra params: `pause`, `debounce` **[D]**. The DAP adapter also sets `debounce`-less restarts with `reason` **[S:_performRestart]**.

`flutter daemon` **[L]** (ran `flutter daemon`, sent `device.getDevices`, then `daemon.shutdown`):
```
<- [{"event":"daemon.connected","params":{"version":"0.6.1","pid":217615}}]
<- [{"event":"daemon.logMessage","params":{"level":"status","message":"Device daemon started."}}]
<- [{"event":"device.added","params":{"id":"linux","name":"Linux","platform":"linux-x64","emulator":false,"category":"desktop","platformType":"linux","ephemeral":false,"emulatorId":null,"sdk":"Arch Linux 7.2.11-arch1-1","isConnected":true,"connectionInterface":"attached","capabilities":{"hotReload":true,"hotRestart":true,"screenshot":false,"fastStart":false,"flutterExit":true,"hardwareRendering":true,"startPaused":true}}}]
-> [{"id":1,"method":"device.getDevices"}]
<- [{"id":1,"result":[{"id":"linux",...},{"id":"chrome",...}]}]
-> [{"id":2,"method":"daemon.shutdown"}]   <- [{"id":2}]
```
Note: `device.added` events already arrived for the initial devices without calling `device.enable` in this run [L]; `device.enable` starts polling for later plug/unplug. Real field set is larger than the doc (adds `isConnected`, `connectionInterface`, `capabilities`) [L].
Other daemon methods **[D]**: `device.enable/disable/forward/unforward`, `emulator.getEmulators` (`id,name,category,platformType`), `emulator.launch {emulatorId, coldBoot?}`, `emulator.create`, `devtools.serve` (returns `{success, host, port}`), `daemon.getSupportedPlatforms {projectRoot}`, `app.exposeUrl` reverse request (needs `--web-allow-expose-url`). The daemon's own `app.start` domain (daemon-mode `app.start`) is not needed.
Simpler device list **[L]**: `flutter devices --machine` -> JSON array (id, name, targetPlatform, emulator, sdk, capabilities). `flutter emulators` for emulator listing (not run).

## 3. Attach to an already running app
- `flutter attach --machine [--debug-url <vm-service-uri>] [-d device] [--app-id] [--device-vmservice-port] [--host-vmservice-port] [--[no-]dds] [--pid-file]` **[L: --help -v]**. Without `--debug-url`, it discovers the VM service via mDNS/logs on the device.
- `flutter run --vmservice-out-file=<path>` writes the VM service URL after start **[L]**; the DAP `vmServiceInfoFile` arg consumes a file like this (adapter waits for it via `waitForVmServiceInfoFile`) **[S]**. The Dart VM `--write-service-info=<file>` produces the JSON format the DAP attach expects **[?: not verified locally]**.
- If `flutter run` already started DDS, attach with `--no-dds` (help text: "may be necessary ... when attaching to an application currently connected to by flutter run") **[L]**; DAP exposes `--no-dds` on `flutter debug-adapter` **[L]**.
- `flutter run/attach --pid-file <f>`: SIGUSR1 = hot reload, SIGUSR2 = hot restart (POSIX only) **[L]**; handy fallback, not for Windows.
- DAP attach example: `{"request":"attach","type":"dart","vmServiceUri":"http://127.0.0.1:51234/abc=/","cwd":"/path/app"}`.

## 4. DevTools, DTD
- `dart devtools --machine --no-launch-browser --port 0 [--dtd-uri U] [--dtd-exposed-uri U] [--allow-embedding]` **[L: --help]**. Output **[L]**: `{"event":"server.started","method":"server.started","params":{"host":"127.0.0.1","port":41481,"pid":222682,"protocolVersion":"1.2.0"}}` and also a `server.dtdStarted {uri}` event when it spawns its own DTD **[L]**. Default port 9100 (falls back if busy) **[L]**.
- DTD: `dart tooling-daemon --machine` **[L]** prints `{"tooling_daemon_details":{"uri":"ws://127.0.0.1:38945/p1GVoU9ACWw=","trusted_client_secret":"tfQd27bN118="}}`; also `--list`, `--port`, `--unrestricted`. DTD is the 2025+ hub: IDE registers services/editor info, DevTools and the Dart MCP server connect to it; Flutter apps register with DTD automatically in debug/profile unless `--no-dds` **[D: https://github.com/dart-lang/ai/blob/main/pkgs/dart_mcp_server/README.md]**.
- How Dart-Code gets a DevTools URL **[DC: src/extension/sdk/dev_tools/manager.ts]**: starts `dart devtools --machine --allow-embedding [--dtd-uri <DTD>]` once per workspace, reads host:port from `server.started`, then builds `http://host:port/<pageRoute>?uri=<url-encoded vmServiceUri>&ide=VSCode&ideFeature=<src>&theme=..&inspectorRef=..&embed=true&embedMode=one` (page is a **path segment**, e.g. `/inspector`, `/performance`, `/cpu-profiler`; ids in src/shared/constants.ts). Default page for Flutter debug = `inspector`, Flutter profile = `performance`, else `cpu-profiler`. Alternatively it calls the DAP custom request `callService` with the VM service `LaunchDevTools` method to let the app's DevTools launch Chrome.
- Simplest for us: take `app.devTools {uri}` from flutter run's machine events if present **[D]** (`devTools` URI already includes `?uri=`), else build the URL as above from `dart.debuggerUris.vmServiceUri` (the `ws://` or `http://` URI both appear in Dart-Code's usage; unverified which DevTools prefers **[?]**). The `ide=` param is legacy-ish (https://github.com/flutter/devtools/issues/9811 per Dart-Code comment) - use `dashTool`/`dashIdeName` params if we want attribution **[DC]**.
- Deep links to the page set: inspector, performance, cpu-profiler, memory, network, logging, debugger, deep-links (route ids to confirm per DevTools version **[?]**).
- Docs: https://docs.flutter.dev/tools/devtools/cli , https://docs.flutter.dev/tools/devtools/vscode (VS Code page does not document DTD or deep links **[D]**).

## 5. Hot reload on save, web hot reload, previews, MCP
Dart-Code implementation **[DC: src/extension/dart/hot_reload_save_handler.ts, src/extension/utils.ts, package.json]**:
- Triggers on `onDidSaveTextDocument` (optional experimental FS watcher on `**/*.dart`).
- Files: ext in `dart, htm, html, css, frag` + user globs `dart.hotReloadPatterns`; must be `file:` scheme, inside workspace, not inside a `.dart_tool` folder.
- Skips if the saved file has Dart analyzer **errors** (severity Error).
- Modes `dart.hotReloadOnSave` / `dart.flutterHotReloadOnSave`: `never|manual|manualIfDirty|all|allIfDirty` (default `never` for Dart; Flutter default "always"-style per its own setting). "manual" = ignore autosave (FocusOut/AfterDelay) saves; "IfDirty" = only if document was dirty.
- Debounce: 200 ms for Dart apps, **10 ms** for Flutter (to collapse Save All), then command `dart.hotReload {reason:"save", debounce:true}` -> DAP `hotReload` with `reason:"save"`.
- Zed note: Zed has no onWillSave save-reason; we need our own file watcher/save hook (unverified what Zed extension API offers **[?]**). Hot reload during an in-flight reload: the tool queues/ignores; `app.restart` supports `debounce`.
Web: stateful hot reload on web is stable and default since Flutter 3.35; `--web-experimental-hot-reload` is now deprecated ("will be removed") **[L: flutter run -h -v]**; https://flutter.dev/blog/whats-new-in-flutter-3-35 **[D, via search summary]**. Hot restart still available.
Widget Previews: `flutter widget-preview start [--dtd-url]` is launched by Dart-Code **[DC: src/extension/flutter/widget_preview_server.ts]**; experimental since 3.35/3.38, detection moved to the analysis server in 3.44 **[?: secondary https://flutter.dev/blog/whats-new-in-flutter-3-44]**.
Dart MCP server: `dart mcp-server` (Dart >= 3.9) **[D: dart-lang/ai README]**; local flags `--enable/--disable` with tool names (launch_app, hot_reload, hot_restart, list_devices, get_app_logs, get_runtime_errors, stop_app, widget_inspector, dtd, vm_service, run_tests...) **[L: dart mcp-server --help]**. Default-enabled per README: hot_reload, hot_restart, get_runtime_errors, widget_inspector, dtd, vm_service; app-lifecycle tools (launch_app, stop_app, list_devices, get_app_logs, list_running_apps) off by default **[D]**. Flutter 3.44 advertised "agentic hot reload" (agents auto-discover running apps via DTD) **[?: secondary]**. Relevance: if our tool registers the running app with a DTD, MCP agents in Zed could hot reload alongside our UI; low priority.

## 6. Cross-platform, fvm/puro, SDK discovery
- Windows: use `flutter.bat` (adapter does) **[S]**; process-kill pid is the cmd shell, not flutter (adapter special-cases) **[S: flutter_adapter.dart ~L478]**; no SIGUSR on Windows; paths need `\` care in `program`/`cwd`; spawn `dart.exe`/`flutter.bat` needs `shell` or explicit `.bat` handling.
- macOS/Linux: GUI-launched editors may not inherit shell PATH (fvm/asdf/puro shims); resolve PATH via login shell or explicit setting.
- Dart-Code SDK discovery order for Flutter **[DC: src/extension/sdk/utils.ts ~L400-430]**: user setting `dart.flutterSdkPath` -> custom `dart.getFlutterSdkCommand` -> project `.flutter` / `vendor/flutter` -> PATH (`flutter` location resolved through symlinks) -> SDK path recorded in `.dart_tool/package_config.json` -> fallback locations. Dart-Code has no first-class fvm code (grep found none); fvm works through `dart.flutterSdkPath` (documented as `.fvm/flutter_sdk`) or PATH. **[DC]**
- fvm: project has `.fvm/flutter_sdk` symlink and `.fvm/fvm_config.json` / `.fvmrc`; prefer reading `.fvm/flutter_sdk` (or `.fvmrc` version -> `~/fvm/versions/<v>` / `FVM_CACHE_PATH`). puro: `.puro.json`/`PURO_ROOT`, shim at `~/.puro/envs/<name>/flutter` **[?: from memory, not fetched]**. Local env here uses `~/development/fvm/default` symlink on PATH **[L]**.
- Dart SDK is bundled at `<flutter>/bin/cache/dart-sdk/bin/dart` **[L]**; use that for `dart devtools`/`dart tooling-daemon`/`dart mcp-server` so versions match the app's Flutter.

## Implications for our tool
1. Backbone should be the DAP adapter: Zed spawns `flutter debug-adapter` (from the resolved SDK) and we layer buttons/commands on top; get hot reload/restart via custom requests `hotReload`/`hotRestart` with `reason`. Whether Zed lets an extension send arbitrary DAP custom requests is the key open question (research Zed side separately). If not, fall back to a sidecar that owns `flutter run --machine` (full control: `app.restart`, `app.stop`, `app.callServiceExtension`) and a Zed task/attach flow.
2. A standalone sidecar/daemon is justified: it can speak `flutter daemon` for the device picker (`device.getDevices`, `device.added/removed`, `emulator.getEmulators/launch`) and inject the chosen device as `toolArgs: ["-d", id]` into the Zed debug scenario.
3. Hot reload on save: copy Dart-Code semantics: watch `.dart` (+html/css/frag, user globs), ignore `.dart_tool`, skip when analyzer errors (needs LSP diagnostics; otherwise skip this guard), debounce ~10-200 ms, send `reason:"save"`; distinguish autosave if Zed exposes it. SIGUSR1 via `--pid-file` is a POSIX-only fallback.
4. DevTools: spawn `dart devtools --machine` once (optionally with a DTD), read `server.started`, construct `http://host:port/<page>?uri=<vmService>` and open in browser (Zed has no embedded webview); prefer `app.devTools` if the machine stream gives it. Page deep links: inspector, performance, cpu-profiler, memory, network.
5. Capture VM service URI from `dart.debuggerUris` (DAP) or `app.debugPort.wsUri` (machine) for attach flows, DevTools, and for `flutter.appStart/appStarted` UI state (running, device, mode). Handle `flutter.forwardedRequest` (`app.exposeUrl`) only if supporting remote/web-allow-expose-url.
6. Attach: offer `vmServiceUri` and `vmServiceInfoFile` configs; warn that attaching to an app already under `flutter run` needs `--no-dds`.
7. SDK resolution: setting > `.fvm/flutter_sdk` / `.fvmrc` > puro > PATH > package_config.json; use that SDK's bundled dart; handle `.bat` on Windows and login-shell PATH on macOS/Linux.
8. Web: stateful hot reload works by default (3.35+); do not pass `--web-experimental-hot-reload`. Optional later: DTD registration to coexist with Dart MCP/agents; widget preview launch.
9. Unverified items to test next: `app.restart` response against a real running app (not run locally: no full `flutter run` executed), Zed's custom-request/event support, DevTools ws vs http URI preference, fvm/puro file formats.
