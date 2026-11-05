# 0004: Architecture accepted (amends 0002)

- **Date:** 2026-11-03
- **Status:** Accepted. Supersedes the *Proposed* status of [0002](0002-architecture-dap-proxy.md); the design in 0002 stands with the amendments below.
- **Decider:** cloud orchestrator (the user is unavailable and asked for decisions to be recorded as ADRs).

## Context
Phase 1 research answered the open questions from conversation 003 (see [risk-register.md](../research/risk-register.md) and research docs A–D). The alternatives (sidecar + attach, PATH shim, fork) were argued in the risk register and rejected as the primary path.

## Decision
Keep **thin Rust Zed extension → Dart DAP proxy (+ CLI in the same executable) → `flutter debug_adapter`**, with these amendments:

1. **Distinctive adapter name.** Not `Flutter` (taken by at least six third-party extensions; Zed silently overwrites duplicates) and not `Dart`. The exact name is fixed in the naming ADR.
2. *(Superseded by [0006](0006-plan-review-resolutions.md) D3: no renumbering; injected requests use seq ≥ 1e9.)* **The proxy owns the adapter-side seq space.** It renumbers every client→adapter request with its own counter and maps `request_seq` back on the way out. Injected requests (`hotReload`, `hotRestart`) use the same counter, and their responses are never forwarded to Zed. Adapter→client messages keep their seq (Zed doesn't check it). Reverse requests (`runInTerminal`, `startDebugging`) pass through untouched.
3. **User feedback = DAP `output` events** (category `console`, ANSI colour allowed because Zed sends `supportsANSIStyling: true`, every line ends in `\n`). That is the only channel Zed shows. CLI commands print their own result in the task terminal and exit non-zero on failure.
4. **Hot restart has two triggers:** our `restart` CLI/task, and Zed's own `debugger::RerunSession` (ctrl/cmd-shift-F5), which sends DAP `restart` once the adapter's `capabilities` event enables `supportsRestartRequest`. The proxy must forward that event. (To confirm in the spike.)
5. **Control channel:** localhost TCP (127.0.0.1, port 0) + random token, published in a per-user session file keyed by project; no POSIX signals, no Unix sockets, no named pipes. Same code on every OS.
6. **Device selection:** `select-device` CLI (numbered list in the task terminal; Zed task terminals are real PTYs) writes a per-project state file; the proxy injects `-d <id>` at launch unless the scenario already sets `deviceId` or `-d`/`--device-id` in `toolArgs`. `debug.json` stays static.
7. **Reload on save lives in the proxy** (file watcher), since Zed has no save hook. Dart-Code rules: `.dart` + configurable globs, skip `.dart_tool`/`build`, debounce, `reason: "save"`, coalesce while a reload is running.
8. **Extension API:** `zed_extension_api = "0.7.0"`, target `wasm32-wasip2`. Implement `get_dap_binary`, `dap_request_kind`, `dap_config_to_scenario` and a locator that only answers for our adapter. Binary: `dap.<adapter>.binary` setting → PATH → download from GitHub Releases with a SHA-256 pinned in the extension.
9. **No `.vscode/launch.json` dependency.** `init` writes `.zed/debug.json`, `.zed/tasks.json` and prints a keymap snippet.

## Consequences
- Coexists with the official Dart extension (which keeps the LSP and its `Dart` adapter).
- Registry publishing needs a human (registry AI policy); a dev-extension install path must be first-class in the docs.
- Gate 2 (spike) must confirm: breakpoints through the proxy, injected reload works and is swallowed correctly, breakpoints survive reload, and the `capabilities`/`restart` path.
