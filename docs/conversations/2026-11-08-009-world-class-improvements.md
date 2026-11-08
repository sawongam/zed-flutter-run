# 2026-11-08-009: "World-class" improvements on `improve/world-class`

## What was asked
Act on the whole quality review from [008](2026-11-08-008-quality-review.md): make the codebase stronger, more scalable and ready to stand out. The work was done by Sonnet/medium subagents, and the orchestrator checked it.

## How it was done
- Wave 1 ran in parallel, each agent on its own files: Dart groundwork, the Rust extension, CI/supply chain, and docs.
- Wave 2 ran in git worktrees: the proxy core refactor and the `DapSessionHost` extraction.
- Wave 3 added three independent reviews (Dart correctness, extension/locator, CI/security), an architecture-docs agent, two fix agents and a lint agent.
- After each wave the orchestrator re-ran every check itself before committing.

## Outcome (all local, branch not pushed)
- **Extension:**
  - A debug locator (ADR 0009).
  - A pure install planner with typed errors.
  - A richer schema with an `x-support` field on every key.
  - Strict Rust lints.
  - Rust tests went from 30 to 76.
- **Dart:**
  - Ports for Clock, HostEnvironment, ProcessRunner and SignalSource, plus `CommandContext` and an architecture test.
  - The proxy uses `SessionPhase` and a `ShutdownCoordinator`. `proxy.dart` went from 994 to under 500 lines.
  - `ProxyTimings`, a `DapMessage` view and a capability table.
  - `dap_command.dart` went from 660 to 255 lines.
  - Stricter lints.
  - Unit tests went from 773 to 881.
- **Bugs found by the new tests and reviews, now fixed:**
  - A signal during start-up left a stale session file and an unmarked control channel.
  - A refused attach was recorded as a launch.
  - Getters on malformed DAP messages threw.
  - A terminate during finishing started new timers.
  - The locator mis-parsed `-d --release`.
  - The program kind was decided from absolute paths.
- **Attach decision:**
  - The schema requires a VM service address only for `type: dart`.
  - A Flutter attach may wait for the app, and the proxy warns after 15 s.
  - The proxy rejects the `init` placeholder `PORT/TOKEN`.
- **CI:**
  - The Rust toolchain is pinned.
  - New coverage, cargo-deny, Scorecard and CodeQL workflows.
  - Provenance attestations and gated draft-release and pub.dev jobs.
  - release-please, with `release-as: 0.1.0` for the first release.
  - Templates and labels.
  - `persist-credentials: false` on checkouts.
  - A tag/version check in the release workflow.
- **Correction:** the "oldest Flutter 3.32 / Dart 3.8" support claim was wrong. The test dependencies need Dart 3.13 or newer, so that CI leg was removed and COMPATIBILITY, CONTRIBUTING and RELEASE were corrected. Older Flutter versions used only as the runtime adapter are untested.
- **Docs:**
  - New README, CONFIGURATION, COMPATIBILITY, TROUBLESHOOTING, PRIVACY and EXTENDING.
  - ARCHITECTURE brought up to date.
  - ADR 0010 written.
  - The `docs/README.md` index is split into "Using and contributing" and "Project memory".

## Final local verification (orchestrator)
- **Repo-wide checks:** `check-versions.sh` OK and actionlint clean.
- **Rust:** cargo fmt, clippy (host and wasm32-wasip2) and 76 tests pass, and the wasm release build succeeds.
- **Dart:** format, analyze (`--fatal-infos`), 881 unit tests, 15 integration-dart tests and 21 Flutter integration tests (flutter-tester) pass, and the compiled exe prints `flutter_run 0.1.0`.

## Still open
1. Push the branch, open a PR and get GitHub CI green. The new workflows (Scorecard, CodeQL, deny, coverage) have never run on GitHub.
2. Run `MANUAL_ZED_TEST.md` in real Zed, including the locator (`languages.Dart.debuggers = ["FlutterRun"]`) and whether `$ZED_*` is substituted in locator scenarios.
3. Set up the GitHub settings in RELEASE.md section 0 (environments, branch protection, private vulnerability reporting).
4. Record a demo GIF for the README slot.
5. `public_member_api_docs` (524 findings) was skipped. Add API docs over time.
