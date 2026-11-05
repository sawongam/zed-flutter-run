# Risk register (Phase 1 self-questioning)

- **Date:** 2026-11-03 (cloud orchestrator)
- **Inputs:** [coexistence-with-dart-extension](coexistence-with-dart-extension.md) (A), [zed-extension-registry](zed-extension-registry.md) (B), [zed-dap-client-behaviour](zed-dap-client-behaviour.md) (C), [zed-recent-changes-and-picker-ux](zed-recent-changes-and-picker-ux.md) (D), plus the earlier research.
- **Spot checks by the orchestrator:** Zed's `initialize` arguments (`crates/project/src/debugger/dap_command.rs` @ b61f33f8), response routing by `request_seq` (`crates/dap/src/transport.rs:351`), the adapter registry `BTreeMap` with silent overwrite (`crates/dap/src/registry.rs`), the default F-key bindings (`assets/keymaps/default-linux.json:36,740,782,788,1172-1176`), `zed_extension_api` 0.7.0 as the newest crates.io release, and the registry's `AI_POLICY.md`. All matched the agents' reports.

Likelihood and impact: L = low, M = medium, H = high.

| # | Risk | Lik. | Impact | How we handle it | What would make us change direction |
|---|---|---|---|---|---|
| R1 | **Adapter-name collision.** At least six third-party extensions register an adapter literally named `Flutter` (found with `gh api search/code`: sgruhier/zed-flutter-debug, xdkomel/flutter-zed, iWisp360/zed-flutter, gusentanan/zed-fl, kdbhalala/Flutter, Volgar04/flutter_zed_debugger). Zed keys adapters by exact name and silently overwrites duplicates. | M | H (the wrong binary launches with no error) | Use a distinctive adapter name (see the naming ADR), never `Flutter` or `Dart`. `doctor` checks that the proxy is the binary that actually started. | — |
| R2 | **Registry submission.** `zed-industries/extensions` bans autonomous agents from contributing, and reviewers may push back because the Dart extension already does Flutter debugging. | H (that a human must do it) / M (pushback) | M | Everything works as a **dev extension** (`zed: install dev extension`) with no registry. RELEASE.md gives the human the submission steps and the argument (hot reload, reload on save, devices, DevTools: none of which the Dart extension has). | If rejected: keep the dev-extension install path and offer to upstream the proxy hook into `zed-extensions/dart` (honour `user_provided_debug_adapter_path`). |
| R3 | **Zed's extension API changes.** 0.8.0 is on Zed main (unpublished); 0.7.0 is the newest on crates.io. | M | M | Pin `zed_extension_api = "0.7.0"` (wasm32-wasip2). Keep the extension thin (only `get_dap_binary`, `dap_request_kind`, `dap_config_to_scenario`, a locator) so a bump is small. CI builds the extension. | A breaking 0.8 release: bump after it reaches crates.io. |
| R4 | **No user-visible status channel apart from `output` events.** Zed ignores custom events, progress events and `showUser`. | H (certain) | L | Report reload/restart results as `output` events (category `console`, ANSI colour, a short prefix). CLI errors go to the task terminal. Use `hide: on_success` / `reveal: never` on reload tasks so they stay quiet. | Zed adds progress UI: also forward progress. |
| R5 | **Seq collisions** between injected requests and Zed's own. Zed's counter starts at 1 and matches responses by `request_seq`. | M (if done naively) | H (Zed resolves the wrong pending request) | The proxy owns the adapter-side seq space: it renumbers every client→adapter request and maps `request_seq` back on responses; responses to injected requests are swallowed. Unit-tested. | — |
| R6 | **Device selection without a picker.** | H (certain) | M | A `select-device` CLI in a task terminal (real PTY, so stdin works) writes a per-project state file; the proxy injects `-d` at launch when the scenario has no `deviceId` / `-d`. | Zed adds a picker or prompt API. |
| R7 | **Reload on save timing.** Zed has no save hook, so we watch the file system. Editors write files in different ways (atomic rename, truncate+write), and autosave may fire a lot. | M | M | Watch `lib/` and configured globs recursively, skip `.dart_tool`/`build`, debounce, compare content hashes so a touch without change doesn't reload, never run two reloads at once (coalesce). Tested by touching files in an integration test. | Watcher unreliable on some OS (e.g. network drives): add polling fallback. |
| R8 | **Windows.** `.bat` launch, path handling, no POSIX signals, killing process trees. | M | H | No signals anywhere. Control channel is localhost TCP + token (works the same on all OSes). Resolve `flutter.bat`; Windows-path unit tests; CI on windows-latest runs unit tests and `dart compile exe`. | Windows CI exposes a blocker in TCP/firewall prompts (loopback normally needs none). |
| R9 | **Flutter `debug_adapter` behaviour changes across SDK versions** (custom request names, events). | L | M | Only rely on documented requests (`hotReload`, `hotRestart`) and events (`dart.debuggerUris`, `flutter.appStart`, `flutter.appStarted`). Integration test on current stable; CI can add beta. | — |
| R10 | **Orphan processes** when Zed kills the proxy (stop button, crash, window close). | M | M | The proxy owns the adapter child; on stdin EOF/disconnect it forwards a `disconnect`, waits briefly, then kills the child (Windows: `taskkill /T`). Integration test checks for no leftovers. | — |
| R11 | **Control-channel security.** Any local process could send commands. | L | M | Bind 127.0.0.1 only; random 256-bit token in a session file that only the user can read (0600 on POSIX, in the user profile on Windows); constant-time compare; strict JSON, size limits; commands are a fixed enum, nothing is executed from input. | — |
| R12 | **Binary download trust.** `download_file` does no hash check. | M | H | The extension prefers a binary on PATH / `dap.<adapter>.binary`; when downloading from GitHub Releases it checks a SHA-256 pinned in the extension source for that version (vendored `sha2`). | — |
| R13 | **fvm / puro / PATH differences when Zed starts from a GUI** (no shell PATH). | M | M | SDK resolution order: explicit config → `.fvm/flutter_sdk` → `.fvmrc` → puro → `FLUTTER_ROOT` → PATH; the extension passes Zed's worktree shell env to the proxy. `doctor` prints what it found. | — |
| R14 | **Can't test real Zed here.** | H (certain) | M | Fake client sends Zed's exact `initialize`; behaviour of Zed checked by source reading; MANUAL_ZED_TEST.md for the user. | — |

## Arguing against ADR 0002

**Alternative X: a sidecar that owns `flutter run --machine`, used with Zed's attach (official Dart adapter).** The sidecar starts the app, prints the VM service URI, and handles reload (`app.restart`) and reload on save; the user attaches Zed's `Dart` adapter for breakpoints.
- *For:* no Zed extension at all, so no registry risk (R2) and no name collision (R1). Works today with the official extension.
- *Against:*
  1. Two steps every run (start sidecar, then attach), and the VM service URI changes each run. The Dart extension's schema has `vmServiceUri` but no `vmServiceInfoFile`, and `additionalProperties: false`, so the user would edit `debug.json` every run or run another rewrite step.
  2. Two Flutter tools on one app: the Dart adapter's `flutter attach` and the sidecar's `flutter run` both talk to the VM; attach needs `--no-dds`, and app output goes to the sidecar terminal, not Zed's debug console.
  3. Zed's Stop detaches instead of ending the app; F5/Start doesn't start anything; "restart" in the debugger does nothing useful.
  4. Feels nothing like VS Code, which is the whole goal.
- **Verdict:** rejected as the primary path. It could become a later "no-extension lite mode" (post-MVP, not planned).

**Alternative Y: PATH shim named `flutter` that intercepts `debug_adapter`** (the zed#11107 Python gist). Rejected: it changes every use of `flutter` on the machine, is fragile with fvm/puro, and needs per-OS shim tricks (`.bat` on Windows).

**Alternative Z: fork the Dart extension.** Rejected by ADR 0001 (users would lose updates from the official extension, and two LSP registrations would conflict).

So 0002's shape stands, with amendments recorded in [ADR 0004](../decisions/0004-architecture-accepted-with-amendments.md).
