# What already exists (checked 2026-11-04)

## Local environment
- Zed 1.26.2 (Arch Linux)
- Flutter 3.47.0 stable through fvm (`~/development/fvm/default/bin`)
- Zed extension **Dart v0.4.1** (`zed-extensions/dart`) is already installed. It registers a `Dart` debug adapter (`~/.local/share/zed/extensions/installed/dart/debug_adapter_schemas/Dart.json`).
- There's no `~/.config/zed/debug.json` yet.

## Zed's debugger
- Zed has a built-in DAP client and a debugger panel. Languages plug in through **debug adapter extensions**: schema, adapter download/launch, config defaults, locators.
- Per project, it reads `.zed/debug.json`. If that file is missing, it falls back to `.vscode/launch.json`.
- Docs: https://zed.dev/docs/debugger

## Dart/Flutter debug adapter (from the SDK)
- `dart debug-adapter` and `flutter debug-adapter` are DAP servers that ship with the SDKs.
- Flutter's adapter supports the **custom requests** `hotReload` and `hotRestart`. `hotReload` takes an optional `reason` (`"manual"` or `"save"`).
- Docs: `packages/flutter_tools/lib/src/debug_adapters/README.md` in the Flutter repo.

## The official Dart extension's debug config (v0.4.1 schema)
Fields: `adapter: "Dart"`, `type: dart|flutter`, `program`, `cwd`, `useFvm`, `args`, `toolArgs`, `env`, `flutterMode` (debug/profile/release/test), `deviceId`, `platform`, `request: launch|attach`, `vmServiceUri`, `stopOnEntry`.

So it already covers **breakpoints, stepping, variables, launch/attach, and choosing a device by ID**.

## Gaps compared with VS Code (Dart-Code)
| Feature | VS Code | Zed today |
|---|---|---|
| Breakpoints, stepping, variables | yes | yes (Dart ext) |
| Hot reload / restart buttons | yes | **no**. PR zed-extensions/dart#72 and zed-industries/zed#51873 (custom debug actions API) were both **closed unmerged on 2026-08-19** (verified with `gh`). There's no native path in sight. |
| Hot reload on save | yes | **no** (planned in PR #72) |
| Device picker UI | status bar picker | **no**. You type `deviceId` by hand |
| DevTools / widget inspector | yes | **no** |
| Auto-generated launch configs | yes | partial (locators) |

> **Correction (2026-11-04):** the first draft said PR #72 was "open, waiting on #51873". In fact both were closed. See [prior-art-and-release-standards.md](prior-art-and-release-standards.md).

## Demand
- zed-industries/zed#11107, "Add Flutter hot reload on save action": open since 2024-04, 109 👍 and 19 🚀 (verified).

## Other projects
- `onepub-dev/zed-dart-extension`: a third-party fork with Flutter attach, device targeting, and an MCP server called `flutter-tools`. Hot reload goes through a temporary slash-command workaround that runs shell commands.

## Sources
- https://zed.dev/extensions/dart
- https://zed.dev/docs/debugger
- https://zed.dev/blog/debugger
- https://github.com/zed-extensions/dart (PR #72)
- https://github.com/onepub-dev/zed-dart-extension
- https://dart.googlesource.com/sdk.git/+/51df1855ff7cc7959d76a57ebacf0a99bf930700%5E%21
