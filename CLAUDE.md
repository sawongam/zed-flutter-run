# zed-flutter-run

VS Code-style Flutter run and debug for the Zed editor. A thin Rust Zed extension (`extension/`) plus a Dart command-line tool and debug adapter proxy, `flutter_run` (`cli/`).

## Before you change anything

- `docs/ARCHITECTURE.md`: how the parts fit together.
- `docs/DESIGN.md`: why it is built this way. Do not undo one of these choices without saying so.
- `CONTRIBUTING.md`: build and test commands, and the code rules.

## Working rules

- Launch subagents with `model: "sonnet"` and `effort: "medium"`, unless the user names something else.
- Keep the docs true. When behaviour changes, update `docs/CONFIGURATION.md`, `docs/ARCHITECTURE.md` and `CHANGELOG.md` in the same change. Record a new design choice in `docs/DESIGN.md`.
- Do not add process notes, conversation logs, review reports or planning documents to the repository.
- Write docs and comments in plain, direct English. Comments explain why, not what.
- Format, analysis and the unit tests must pass before a change is done: see `CONTRIBUTING.md`.
