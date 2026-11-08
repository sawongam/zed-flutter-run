# 2026-11-08-008: Status check and "world-class" quality review

## What was asked
1. What state is the project in, and is it ready to use?
2. Analyse the codebase and research comparable projects. How could the architecture and patterns become world-class and scalable? (Three Sonnet/medium subagents, read-only.)

## Status findings
- CI on `master` (run 42020956342) passed all 8 jobs, Windows included. The Windows session-file flake is fixed.
- Nothing has run inside real Zed or on a real device. `MANUAL_ZED_TEST.md` has never been done.
- Nothing is published, and `PINNED_SHA256` is empty, so the extension can't download the binary.
- The maintainer's machine still has the pre-rename `~/.local/bin/flutter_rd`. `flutter_run` isn't installed, and the dev extension isn't installed in Zed.
- `STATUS.md` and the README still point at `build/mvp` / PR #1. That history is now squashed into `master`, and #1 is a Dependabot PR. **These docs are stale.**

## Review findings (orchestrator spot-checked the key claims)
**Keep:** the star module graph. Every `lib/src/*` module imports only `common/`, and only `cli/` wires them together, with no cycles. Also keep: ports defined by the consumer and adapters in `wiring.dart`, `HostEnvironment`, the typed exceptions with exit codes, the sealed `ProxyEvent`, raw pass-through of DAP messages, the separate seq range for injected requests (ADR 0006 D3), and the three-tier test split.

**Dart CLI:**
- `dap/proxy.dart` is a 994-line state machine with about 15 loose shutdown flags. Proposal: a `SessionPhase` type, then extract a `ShutdownCoordinator`.
- Timers and `DateTime.now` are hard-wired. Proposal: a `Clock` / `fake_async`, and one `ProxyTimings` class.
- `cli/dap_command.dart` (660 lines) is the hidden composition root.
- DAP messages are raw maps read with string keys. Proposal: an `extension type DapMessage` view plus command constants, without modelling the whole DAP.
- There is no `ProcessRunner` or `FileSystem` port.
- Three direct `Platform.isWindows` checks bypass `HostEnvironment`.
- The dependency direction isn't enforced. Proposal: an architecture test.
- Coverage isn't measured.

**Rust extension:**
- There is no `[debug_locators]` / `dap_locator_create_scenario`. Ruby uses one, and it would give gutter and task debugging. This reverses ADR 0006 D4, so it needs a new ADR.
- `lib.rs:141` decides the "not found" case by comparing error strings. Proposal: a typed error enum.
- There are no tests of the download state machine.
- The schema has no `markdownDescription`, no conditional rules for attach, and generic descriptions.
- `zed_extension_api` 0.8.0 exists on Zed main but isn't on crates.io yet. It adds `GithubReleaseAsset.digest`.
- zed#51873 is still closed. There is still no Zed API for custom actions or on-save hooks.

**OSS hygiene:**
- No issue or PR templates, CODEOWNERS or labels.
- No build provenance or attestations, and no OpenSSF Scorecard, `cargo deny` or CodeQL.
- The release is manual.
- `dtolnay/rust-toolchain` follows a moving tag, and there is no `rust-toolchain.toml`.
- The README has no demo GIF or badges, and it tells users to install from `build/mvp`.
- Internal agent logs are mixed in with user docs, and there is no `docs/CONFIGURATION.md`.
- Lints are modest (`lints/recommended`, default clippy).
- `cli/README.md` and `cli/CHANGELOG.md` are needed for pub.dev.

## Outcome
The maintainer received a ranked plan (see the chat). No code changed. The decisions still open are whether to add a debug locator (needs an ADR superseding 0006 D4) and whether to split `docs/` into user docs and internal docs.
