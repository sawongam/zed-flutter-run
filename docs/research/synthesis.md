# Research synthesis (2026-11-04)

This merges the four research docs and checks their claims against each other:
- [zed-integration-surface.md](zed-integration-surface.md)
- [flutter-tooling-protocols.md](flutter-tooling-protocols.md)
- [feature-parity-vscode.md](feature-parity-vscode.md)
- [prior-art-and-release-standards.md](prior-art-and-release-standards.md)

## Five facts that shape the design
1. **Zed won't add native hot reload any time soon.** zed#51873 (custom debug actions API) and zed-extensions/dart#72 were both closed unmerged on 2026-08-19. *Verified with `gh`.*
2. **We can't hijack the official Dart adapter.** Its `get_dap_binary` ignores the user-provided adapter path (`_user_provided_debug_adapter_path`), and `.zed/debug.json` can't name an arbitrary adapter command. *Verified in `zed-extensions/dart/src/dart.rs`.* To put a proxy in the path, we have to **ship our own small Zed extension that registers its own adapter**.
3. **Extensions get no UI.** Zed extensions can't add panels, pickers, toolbar buttons or on-save hooks. What users get is **tasks + keybindings** (`task::Spawn` with `task_name`), plus the terminal.
4. **Flutter's DAP already does the hard work.** `flutter debug-adapter` takes the `hotReload` / `hotRestart` custom requests (`reason: manual|save`) and emits `dart.debuggerUris` (the VM service URI) for DevTools. A proxy only needs to **inject requests and watch events**. A Python proof of concept in zed#11107 shows breakpoints still work with a proxy in the middle.
5. **Demand is real and unmet.** zed#11107 has 109 👍 and 19 🚀 and has been open since 2024-04. About six prior attempts exist, and none has more than 14 stars.

## Where the agents disagreed
- The protocols agent called "can an extension send custom DAP requests" the key open question. The Zed agent answered it: **no**. So the design is a proxy plus a side channel, and the fallback where a sidecar owns `flutter run --machine` isn't needed for the MVP.
- POSIX signals (`--pid-file` + SIGUSR1/2) would let us avoid writing an extension, but they **don't work on Windows**. That rules them out as the main path for a global tool. They could still be a stopgap on Linux and macOS.

## Still unverified (test in the spike)
- Running a full `flutter run` through a proxy: the `app.restart` and `hotReload` response shapes against a live app
- Whether an adapter launched from an extension can use TCP rather than stdio (affects the Windows side channel)
- The exact fvm and puro file formats
- Reddit, Discord and Hacker News demand (Reddit was blocked for the agents)
