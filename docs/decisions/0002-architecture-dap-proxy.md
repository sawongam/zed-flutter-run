# 0002: Architecture: thin Zed extension + DAP proxy + CLI

- **Date:** 2026-11-04
- **Status:** **Accepted with amendments** by [0004](0004-architecture-accepted-with-amendments.md) (2026-11-03). Originally proposed; working name `zflutter` (placeholder).

## Context
See [research/synthesis.md](../research/synthesis.md). There's no native hot-reload API, we can't override the official Dart adapter, and extensions get no UI. Users interact only through tasks, keybindings and the terminal.

## Design

```
Zed debugger panel ──DAP/stdio──▶ zflutter dap (proxy) ──DAP/stdio──▶ flutter debug-adapter
                                       │  ▲                                  │
                       local socket /  │  │ events: dart.debuggerUris,       ▼
                       named pipe      │  │ flutter.appStarted          flutter run --machine
                                       ▼  │                                  │
 Zed task + keybinding ──▶ zflutter reload|restart|devtools|devices         app on device
 file watcher (in proxy) ──▶ hotReload {reason:"save"}
```

| Part | Language | Job |
|---|---|---|
| **Zed extension** (`flutter-run-debug`) | Rust → WASM (required by Zed) | Registers a `Flutter` debug adapter whose binary is the proxy. Downloads the proxy from GitHub Releases. Ships a schema and debug locators. Provides task templates. |
| **Proxy** (`zflutter dap`) | open question, see below | Forwards DAP traffic both ways. Injects `hotReload` / `hotRestart`. Captures the VM service URI. Watches files for reload on save (Dart-Code rules: `.dart` + globs, skip `.dart_tool`, debounce). Puts the chosen device into `toolArgs`. |
| **CLI** (`zflutter …`) | same binary as the proxy | `reload`, `restart`, `devtools [page]`, `devices` (terminal picker that remembers the choice), `init` (writes `.zed/debug.json`, `tasks.json` and keymap snippets). |

## MVP scope (from [feature-parity-vscode.md](../research/feature-parity-vscode.md))
Hot reload and hot restart on keybindings; reload on save; a device picker that remembers the last device; `zflutter init`; opening DevTools. All of it has to work on Linux, macOS **and Windows**.

## Open choices
- **Proxy language:** Dart (`dart compile exe`, reuses `package:dap` and `vm_service`, familiar to Flutter contributors) vs Rust (one toolchain with the extension, small static binaries). Recommendation: **Dart**, unless the spike runs into startup-time or packaging problems.
- **Coexisting with the official Dart extension:** we use a distinct adapter name (`Flutter`) and keep using the official extension for the language server.

## Next step
Spike (milestone 1): a minimal proxy plus a dev extension, run against a sample app on Linux. Success criteria: breakpoints work through the proxy, a keybinding hot-reloads the app, and saving a file hot-reloads it.
