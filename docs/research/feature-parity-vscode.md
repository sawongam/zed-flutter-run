# Feature parity: VS Code Run & Debug + Dart-Code vs Zed

Date: 2026-11-04. Confidence notes: items marked (unverified) come from background knowledge, not a fetched source. Reaction counts for GitHub issues were NOT obtained (search tools could not sort by reactions); prioritisation of pain points is therefore qualitative.

## 1. VS Code core Run & Debug vs Zed

| VS Code feature | Zed today | Source |
|---|---|---|
| Conditional / hit-count / log breakpoints | Yes (adapter-specific syntax for conditions) | [Zed debugger docs](https://zed.dev/docs/debugger) |
| Exception breakpoints | Yes, from the "Breakpoints" item in the session UI; types depend on adapter | Zed docs |
| Inline values | Yes (inlay hints, `inlay_hints.show_value_hints`) | Zed docs |
| launch.json | Fallback to `.vscode/launch.json` if no `.zed/debug.json`; native `.zed/debug.json` | Zed docs |
| preLaunchTask equivalent | `build` field runs a Zed task first | Zed docs |
| Launch / attach | Yes; process picker only for Node | Zed docs |
| Stepping granularity (statement/line/instruction) | Yes, setting | Zed docs |
| Debug console / REPL | Not covered in docs page (exists in panel; verify) | Zed docs (absence) |
| Compound configs / multi-session | Not documented; verify | Zed docs (absence) |
| Triggered, inline (column), function, data breakpoints | Not documented | [VS Code debugging](https://code.visualstudio.com/docs/debugtest/debugging) vs Zed docs |
| Debug toolbar with custom buttons, status bar progress | Not extensible by extensions as far as documented (verify) | Zed docs (absence) |
| Hot reload / Flutter-specific | Not covered by Zed docs | Zed docs (absence) |

VS Code reference features: compound configs, toolbar (continue/step/restart/stop, session switch), Debug Console REPL with frame-scoped evaluation, Watch, Call Stack, Variables with edit/filter ([VS Code docs](https://code.visualstudio.com/docs/debugtest/debugging)). Flutter docs add "Start Without Debugging" (Ctrl+F5) vs F5 ([Flutter VS Code](https://docs.flutter.dev/tools/vs-code)).

## 2. Dart-Code Flutter feature inventory (and settings)

Source for settings: [dartcode.org/docs/settings](https://dartcode.org/docs/settings/). Source for UX: [Flutter in VS Code](https://docs.flutter.dev/tools/vs-code).

| Area | Feature | Setting / command |
|---|---|---|
| Hot reload | Reload on save (Flutter) | `dart.flutterHotReloadOnSave` (default `manual`; other values include `all`/`never`, verify enum) |
| | Non-Flutter Dart | `dart.hotReloadOnSave` (default `never`) |
| | File globs that trigger | `dart.hotReloadPatterns` |
| | FS watcher (catches external tool edits) | `dart.previewHotReloadOnSaveWatcher` (experimental) |
| | Progress UI | `dart.hotReloadProgress` (`notification` / status bar) |
| | Hot restart | command `Flutter: Hot Restart`, Ctrl+Shift+F5; toolbar button for reload |
| | Debounce | No debounce setting found in the settings page |
| Stepping scope | SDK libs | `dart.debugSdkLibraries` (false) |
| | Pub packages incl. `package:flutter` | `dart.debugExternalPackageLibraries` (false) |
| Devices | Status-bar device picker, auto-select latest connected | `dart.flutterSelectDeviceWhenConnected` (true), `dart.flutterRememberSelectedDevice` (true) |
| | Emulator launch | `Flutter: Launch Emulator` (unverified command name) |
| | Multi-device debugging | Compound launch configs; Hot Reload applies to all sessions, Hot Restart only to active ([Flutter wiki](https://flutter.googlesource.com/mirrors/flutter/+/HEAD/docs/wiki_archive/Multi-device-debugging-in-VS-Code.md)) |
| DevTools | Open on session start | `dart.openDevTools` (`never`/`flutter`/`always`) |
| | Share server with `flutter run` | `dart.shareDevToolsWithFlutter` (true) |
| | Widget-error notification with "Inspect Widget" link | `dart.showInspectorNotificationsForWidgetErrors` (true) |
| | Embedded/sidebar DevTools (inspector, performance, network, memory) | commands `Dart: Open DevTools ...` (unverified names) |
| Run args | `flutter run` / test / attach / all | `dart.flutterRunAdditionalArgs`, `dart.flutterTestAdditionalArgs`, `dart.flutterAttachAdditionalArgs`, `dart.flutterAdditionalArgs` |
| Modes | debug/profile/release | launch.json `flutterMode` ([Flutter docs](https://docs.flutter.dev/tools/vs-code)) |
| Flavors / dart-define | via `args`/`toolArgs` in launch.json (`--flavor`, `--dart-define`) (unverified exact keys; flutter-tools.nvim confirms these are passed as run args) |
| Output | `dart:developer` log() in console | `dart.showDartDeveloperLogs` (true) |
| | Log truncation | `dart.maxLogLineLength` (2000) |
| | toString() in variables | `dart.evaluateToStringInDebugViews` (true) |
| | Hex numbers | `dart.showDebuggerNumbersAsHex` |
| Diagnostics | DAP log, daemon log | `dart.dapLogFile`, `dart.flutterDaemonLogFile` |
| Layout debug toggles | Baseline painting, repaint rainbow, slow animations, debug banner | commands in debug session ([Flutter docs](https://docs.flutter.dev/tools/vs-code)) |
| Editor | Flutter Property Editor, closing labels (`dart.closingLabelsPrefix`), outline, snippets | Flutter docs. Mostly LSP/editor side, not Run & Debug |
| Tests | Test Explorer, run/debug test codelens | unverified; Zed has debug tasks generated from tests for some languages ([Zed docs](https://zed.dev/docs/debugger)) |
| Web | Chrome/web-server device via same launch | unverified detail |

## 3. Most-loved features and pain points

Evidence is thin (no reaction counts retrieved). Qualitative:

- Loved/expected: hot reload on save, one-click reload/restart buttons, status-bar device picker (Flutter docs list these as core workflow).
- Known pain: hot reload button vanishing or session stuck on "assembling" ([search result summary of Dart-Code issues](https://www.github.com/Dart-Code/Dart-Code/issues/1859)); status-bar picker ignores launch settings ([Flutter wiki](https://flutter.googlesource.com/mirrors/flutter/+/HEAD/docs/wiki_archive/Multi-device-debugging-in-VS-Code.md)); device names with curly apostrophes failing; multi-device restart asymmetry; breakpoints behaviour across hot reload ([Dart-Code #4419](https://github.com/Dart-Code/Dart-Code/issues/4419)); reload-on-save for plain Dart ([#3637](https://github.com/Dart-Code/Dart-Code/issues/3637)).
- Dart-Code upstream pain list (VS Code limitations it works around): Hot Restart progress notifications, Debug Console completion, "Paused on Entry" with multiple isolates ([dartcode.org/upstream-issues](https://dartcode.org/upstream-issues)). Zed may have similar gaps for progress UI.
- Ecosystem: Flutter web hot reload is a top Flutter tracker issue; experimental flag `--web-experimental-hot-reload` in 3.31 beta ([itsallwidgets](https://forum.itsallwidgets.com/t/hot-reload-on-the-web-with-the-latest-flutter-beta/2927)).
- TODO: sort Dart-Code/Dart-Code issues by `sort:reactions-+1-desc` manually to confirm ranking.

## 4. Other editors

- flutter-tools.nvim ([repo](https://github.com/akinsho/flutter-tools.nvim)): commands `FlutterRun`, `FlutterDebug`, `FlutterReload`, `FlutterRestart` (manual, no on-save documented in README); `FlutterDevices` picker (extra args via `devices.args`), `FlutterEmulators` (uses `flutter emulator --launch` or custom launcher); nvim-dap integration registers Dart adapter at startup; `FlutterDevTools` / `FlutterOpenDevTools` / `FlutterCopyProfilerUrl`; widget outline; LSP closing labels; dev log buffer with filter; per-project run configs (device id, flavor, dart-define); `FlutterWidgetPreview`. Internals (it drives `flutter run --machine`) are from background knowledge (unverified).
- Android Studio / IntelliJ Flutter plugin, Emacs flutter.el, Helix: not researched with sources. Background (unverified): IntelliJ has toolbar device dropdown + reload on save + inspector; flutter.el sends `r`/`R` to a `flutter run` process; Helix has DAP but no Flutter integration. Common pattern for non-VS-Code editors: spawn `flutter run --machine` (daemon) or send reload via DAP custom requests/stdin.

## 5. Prioritised parity matrix

Legend: FREE = Zed already provides; GAP = we build.

| Feature | Priority | Release | Zed status |
|---|---|---|---|
| Breakpoints (cond/log/hit), stepping, variables, call stack, inline values | Must | - | FREE |
| Launch/attach Flutter via DAP | Must | - | FREE (Dart ext) |
| Hot Reload action (button/keybinding/command) | Must | MVP | GAP |
| Hot Restart action | Must | MVP | GAP |
| Device picker + remember last device, injecting `deviceId` | Must | MVP | GAP |
| Reload on save (with patterns, setting like `flutterHotReloadOnSave`) | Must | MVP | GAP |
| Run without debugging (F5 vs Ctrl+F5) | Should | MVP/v1 | GAP (verify) |
| Auto-generate debug.json / launch snippets (modes: debug/profile/release, flavor, dart-define, args) | Should | v1 | partial (debug.json exists) |
| Emulator list/launch | Should | v1 | GAP |
| Open DevTools (launch external browser with VM service URI) | Should | v1 | GAP |
| Debug SDK / external packages toggles | Should | v1 | GAP (DAP launch args `debugSdkLibraries`, `debugExternalPackageLibraries`) |
| Status/progress feedback for reload/restart | Should | v1 | GAP |
| Structured widget errors, dart:developer logs, log truncation | Should | v1 | partly via DAP output |
| Multi-device / compound run | Could | later | Zed compound support unverified |
| Layout toggles (repaint rainbow, slow animations, baseline) via service extensions | Could | later | GAP |
| Test explorer / debug tests | Could | later | partial (Zed test tasks) |
| Embedded DevTools, Property Editor, Flutter Outline, widget preview | Could | later | GAP, needs Zed UI APIs |
| Web (Chrome) debugging and web hot reload | Could | later | depends on Flutter experimental |
| Exception breakpoint presets, REPL completions | Could | later | FREE/partial |

Open question for design: which Zed extension APIs allow adding toolbar buttons, status bar items, and on-save hooks; this determines whether a standalone external process (e.g. companion daemon driving DAP/flutter daemon) is required. Not researched here.
