# 2026-11-05-006: Rename to zed-flutter-run

- **Trigger:** the user chose the name `zed-flutter-run`.
- **Done:** applied the mapping in [ADR 0008](../decisions/0008-rename-to-zed-flutter-run.md) across code, workflows, manifests, fixtures and current docs. `git mv` for `cli/bin/flutter_run.dart`, `cli/lib/flutter_run.dart` and `extension/debug_adapter_schemas/FlutterRun.json`. Cargo.lock updated.
- **Checks:** pub.dev `flutter_run` returned 404 (free); no match in the Zed `extensions.toml` for `flutter-run-debugger` / `FlutterRun`.
- **Left alone on purpose:** conversation logs, reviews, ADRs 0001-0007 and the body of `research/naming.md` (which got a correction note). ADR 0005 got a "superseded by 0008" note.
- **For the user:** rename the GitHub repo and update the remote; change `"adapter"` to `"FlutterRun"` in existing `.zed/debug.json`. Nothing was committed or pushed.

## Follow-up: new repository with fresh history
- **Trigger:** the user created the empty private repo `https://github.com/sawongam/zed-flutter-run` and chose a fresh git history (one initial commit) over carrying the old 70-commit history.
- **Done:** replaced `saadbtch` with `sawongam` in all current files (ADR 0008 addendum). Moved the old `.git` to `../run-and-debug-flutter.git-old` as a backup (nothing deleted), ran `git init` on `master`, made one initial commit and pushed it to the new `origin`.
- **Tests before the commit:** unit 773/773, CLI end-to-end 11/11, Flutter launch 5/5 and attach 2/2 (the Flutter suites must run with `-j 1`, as CI does; the subagent's parallel run is what made them fail in setUpAll), Rust 30/30, wasm build OK.
- **Note:** RELEASE.md mentions of "draft PR #1" and `build/mvp` refer to the old repo.
