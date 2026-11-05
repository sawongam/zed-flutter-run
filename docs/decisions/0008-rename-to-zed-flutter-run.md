# 0008: Rename to zed-flutter-run

- **Date:** 2026-11-05
- **Status:** Accepted (user decision). Supersedes [ADR 0005](0005-project-names.md).

## Context
On 2026-11-05 the user picked the project name **zed-flutter-run**. Nothing had been published under the old names, so renaming was safe. The constraints from ADR 0005 still apply: the Zed registry forbids "zed" in extension ids and asks debugger extensions to end in `-debugger`, and the project must not imply endorsement by Google, Flutter or Zed Industries (the README keeps its disclaimer).

## Decision
| Thing | Old | New |
|---|---|---|
| GitHub repo / URLs | `saadbtch/run-and-debug-flutter` | `sawongam/zed-flutter-run` |
| Display name (project) | Run & Debug for Flutter | Flutter Run & Debug |
| Zed extension id | `flutter-rd-debugger` | `flutter-run-debugger` |
| Extension display name | Flutter Run & Debug | unchanged |
| Rust crate | `flutter_rd_debugger` | `flutter_run_debugger` |
| Dart package + executable | `flutter_rd` | `flutter_run` (release assets `flutter_run-v...`) |
| Debug adapter | `FlutterRD` (`FlutterRD.json`) | `FlutterRun` (`FlutterRun.json`) |
| Env var / file / state-dir prefix | `FLUTTER_RD_`, `flutter_rd` | `FLUTTER_RUN_`, `flutter_run` |
| Derived identifiers (symbols such as `FlutterRdRunner`, task labels, templates, temp files, user agents, log prefixes) | `flutter_rd` / `FlutterRd` forms | `flutter_run` / `FlutterRun` forms |

## Availability checks (2026-11-05)
- pub.dev `flutter_run`: `curl https://pub.dev/api/packages/flutter_run` returned **404**, so it is free and the Dart package keeps the name `flutter_run` (the `zed_flutter_run` fallback was not needed).
- `zed-industries/extensions` `extensions.toml`: no match for `flutter-run-debugger`, `FlutterRun` or `flutter_run`.
- As in ADR 0005, a free name is not a reservation; RELEASE.md tells the user to re-check before publishing.

## Consequences
- The user must rename the GitHub repo to `zed-flutter-run` and update the git remote by hand. GitHub redirects the old URLs.
- The local folder `run-and-debug-flutter` keeps its name for now.
- Existing users' `.zed/debug.json` needs `"adapter": "FlutterRun"`, and `FLUTTER_RD_*` variables become `FLUTTER_RUN_*`. No release shipped under the old names.
- History docs (`docs/conversations/`, `docs/reviews/`, ADRs 0001-0007, the body of `research/naming.md`) still use the old names on purpose.

## Addendum (2026-11-05): repo owner
The project moved to a new private repository, **`sawongam/zed-flutter-run`**, owned by the user's own account. That replaces the planned `saadbtch/zed-flutter-run`, so all current URLs (extension download capability, `install.rs`, pubspec, workflows, docs, and the Homebrew/Scoop tap names in RELEASE.md) now use `sawongam`. History docs still mention `saadbtch` on purpose.
