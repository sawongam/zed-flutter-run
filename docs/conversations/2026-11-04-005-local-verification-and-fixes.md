# 2026-11-04-005: Local verification on Arch, small fixes, authorship cleanup

## Context
After the cloud build (see 011), the MVP on `build/mvp` was reviewed on the
maintainer's Arch Linux machine (Flutter 3.47.0 / Dart 3.13.0, Zed 1.26.2).

## What was done
- **Authorship:** the 66 cloud-built commits on `build/mvp` were rewritten so the
  maintainer is the author/committer, and the agent trailers were dropped. The
  tree is identical to the original (`d7ca554`). The mirror branch
  `claude/keen-planck-o5gnpm` is redundant and can be deleted.
- **Rust toolchain** installed user-locally via rustup.rs (no sudo): rustc 1.99.1,
  targets wasm32-wasip1/wasip2, clippy, rustfmt.
- **Extension (`extension/`)**: `cargo fmt --check`, clippy (host + wasm32-wasip2,
  `-D warnings`), `cargo test` (30/30), and the wasm32-wasip2 release build all
  pass. No changes were needed. Compatibility of `zed_extension_api` 0.7.0 with
  Zed 1.26.2 is only confirmed once the dev extension is installed in the GUI.
- **Fixes:**
  - `fixtures/sample_app` SDK constraint lowered from `^3.13.7` to `^3.5.0`
    (it blocked the Flutter integration tests on Dart 3.13.0).
  - `flutter_rd --version` / `-V` added (same output as `flutter_rd version`).
  - Windows flake in session_store "update is atomic": the rename retry is now
    30 attempts with 10→200 ms backoff (about 5 s), and the test's reader no longer
    busy-spins. Not yet confirmed on Windows CI.
  - `docs/STATUS.md` CI claims corrected (41740646030 was cancelled; 41741647402
    failed on Windows only; macOS passed).
  - `docs/MANUAL_ZED_TEST.md`: no-sudo rustup install path.
- **Local results:** analyze clean; unit 773/773; integration-dart 15/15;
  Flutter integration (flutter-tester) 21/21. `flutter_rd` compiled to
  `~/.local/bin/flutter_rd`, and `doctor` finds the fvm SDK.

## Still open
1. Manual Zed GUI test (`docs/MANUAL_ZED_TEST.md`): launch Zed from a shell
   with `~/.cargo/bin` on PATH, then run `zed: install dev extension` → `extension/`.
2. Real device / emulator test (Android, Chrome).
3. Windows CI green after push; brand check; release per `docs/RELEASE.md`.
