# 0005: Project, binary, extension and adapter names

> **Superseded by [ADR 0008](0008-rename-to-zed-flutter-run.md) (2026-11-05).** The names below are the old ones, kept as history.

- **Date:** 2026-11-03
- **Status:** Accepted (orchestrator decision; the user asked for decisions without questions)
- **Research:** [naming.md](../research/naming.md). Re-checked by the orchestrator on 2026-11-03: pub.dev `flutter_rd` → 404 (free), crates.io `flutter_rd` → 404 (free), crates.io `frd` → taken, `flutter-rd` absent from `zed-industries/extensions` `extensions.toml`, code search for `debug_adapters.FlutterRD` → 0 hits.

## Context
The adapter name has to be distinctive: at least seven repos register a Zed debug adapter called `Flutter`, and Zed overwrites duplicates silently ([ADR 0004](0004-architecture-accepted-with-amendments.md) §1). The registry forbids "zed" and "extension" in ids and asks debugger-only extensions to end in `-debugger`. Flutter's brand page forbids implying endorsement.

## Decision
| Thing | Name |
|---|---|
| Display name | **Run & Debug for Flutter** (README carries a "not affiliated with Google, Flutter or Zed Industries" disclaimer) |
| Repository | `run-and-debug-flutter` (already exists) |
| Dart package + executable | **`flutter_rd`** (`dart pub global activate flutter_rd` → `flutter_rd …`; `dart compile exe` output `flutter_rd` / `flutter_rd.exe`) |
| Zed extension id | **`flutter-rd-debugger`**, extension display name "Flutter Run & Debug" |
| Debug adapter name (`"adapter"` in `.zed/debug.json`) | **`FlutterRD`** |
| Rust crate (extension, not published to crates.io) | `flutter_rd_debugger` |
| Env-var / file prefix | `FLUTTER_RD_` (e.g. `FLUTTER_RD_DEVICE`), state dir `flutter_rd` |

## Consequences
- The placeholder `zflutter` in older docs means `flutter_rd`.
- Availability isn't a reservation. RELEASE.md tells the user to re-check before publishing.
- A human should read docs.flutter.dev/brand once (blocked here) before the first public release.
