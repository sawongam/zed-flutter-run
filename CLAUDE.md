# zed-flutter-run

Flutter run and debug for the Zed editor: a thin Rust Zed extension (`extension/`) and a Dart command-line tool and debug adapter proxy, `flutter_run` (`cli/`).

## Read first

- `docs/ARCHITECTURE.md`: how the parts fit together.
- `docs/DESIGN.md`: why it is built this way. Do not undo a recorded choice without saying so.
- `CONTRIBUTING.md`: build and test commands and the code rules.

## Rules

- Keep the docs true. When behaviour changes, update `docs/CONFIGURATION.md`, `docs/ARCHITECTURE.md` and `CHANGELOG.md` in the same change, and record a new design choice in `docs/DESIGN.md`.
- Format, analysis and the unit tests must pass before a change is done (see `CONTRIBUTING.md`).
- Commit messages use Conventional Commits: `type: short imperative summary`.
- Do not add process notes, review reports or planning documents to the repository.
- Docs and comments are plain, direct English. Comments explain why, not what.
