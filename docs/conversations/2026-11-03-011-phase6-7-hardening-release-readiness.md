# 2026-11-03-011: Phase 6 reviews, hardening and Gate 6; Phase 7 release readiness

## Phase 6: three independent reviewers
| Review | Result | Doc |
|---|---|---|
| Correctness | 0 blocker, 4 major, 8 minor, 4 nit | [phase6-correctness](../reviews/phase6-correctness.md) |
| Security | 0 blocker, 0 major, 3 medium, 5 low, 4 info | [phase6-security](../reviews/phase6-security.md) |
| Architecture & docs | 1 blocker, 5 major, 11 minor, 3 info | [phase6-architecture-docs](../reviews/phase6-architecture-docs.md) |

Main findings and what was done (decisions in [ADR 0007](../decisions/0007-phase6-review-resolutions.md)):
- **CI could never pass** (D1, blocker): `dart compile exe -o build/…` into a missing folder. Fixed with `mkdir -p`; CI also uses `--enforce-lockfile` / `--locked` now.
- **Process cleanup** (R1, R2, R3, R12): the sweep now kills a still-alive adapter; a normal stop only kills the adapter and its *current* children; only a crash sweeps earlier-seen processes, and never `adb`, Gradle/Kotlin daemons or other sessions' tooling daemon; POSIX signal handlers run the same cleanup as stdin EOF. SIGKILL of the proxy remains a documented limit.
- **Slow first start** (R4): 120 s `initialize` timeout with a notice at 10 s.
- **Log-file write primitive** (S1, S3): a repo's `logFile` could append to `~/.bashrc`. Now the path must end in `.log` in an existing folder, files are 0600, and control characters are escaped.
- Smaller items: `/ws/ws` DevTools URLs (R5), DevTools refused for Dart programs (R6), save-reloads during an in-flight reload get exactly one follow-up (R7), paused save-reloads aren't failures (R8), non-protocol ports pruned (R10), device ids validated (S5), 64 MiB DAP body cap (S7), deep-nesting log safety (S6), no chmod through symlinks (S4), Windows-safe test shims (D2), stale docs (D3, D5–D8, D11), `.gitattributes` forcing LF (D17).
- Rejected with reasons: D10 (shared message string), S8 (local DoS of pending slots, token unreadable to others).

**Verification pass:** the three reviewers re-checked their own findings against the fixed code (sections "Verification (after fixes)" in each review). Security: all resolved or accepted. Architecture/docs: all resolved except D4 (STATUS.md, written in Phase 7) and minor partials. Correctness: 12 resolved; the orchestrator adjudicated R7 and R16 as resolved (the verifier had read only part of the path / a stale line) and R10's remaining edge as a known issue (see the adjudication note in the review).

## Gate 6 re-test (orchestrator)
`cd cli && dart format … ; dart analyze --fatal-infos ; dart test (unit) ; dart test -t integration-dart -j 1 ; dart test -t integration -j 1 ; cd ../extension && cargo fmt/clippy/test --locked && cargo build --release --target wasm32-wasip2`

```
Formatted 130 files (0 changed) in 0.39 seconds.
No issues found!
00:18 +762: All tests passed!
UNIT EXIT 0
00:22 +15: All tests passed!
IDART EXIT 0
04:45 +21: All tests passed!
IFLUTTER EXIT 0
test result: ok. 30 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
RUST EXIT 0
295664 Nov  3 20:53 target/wasm32-wasip2/release/flutter_rd_debugger.wasm
```

**Gate 6: passed.** No confirmed finding remains open; the accepted ones are listed in STATUS.md "Known issues".

## CI on GitHub runners (after Gate 6)
The first complete CI runs found real cross-platform problems that the Linux container couldn't show:
- Windows unit tests: 28 failures → fixed in three rounds (refused loopback connects report errno 1225 or time out after ~2 s; a busy reply lost to a TCP reset; sharing violations during atomic renames; 8.3 short temp paths; Windows path separators and `flutter.bat`/`dart.exe` names in test expectations).
- Windows `integration-dart`: a crashed adapter's `dart.exe`/`dartvm.exe` survived, a real product gap; Windows now snapshots descendants from `Win32_Process` (ADR 0007 P8). The test's orphan check also had false positives from Windows pid reuse; fixed.
- Linux `integration` (Flutter): a flaky "identical content does not reload" on the slower runner, caused by split save events; fixed with an arm-time hash baseline (ADR 0007 P7).
- The `doctor` e2e test assumed Flutter in the Dart-only job; it now checks the right result in both environments.
- CI's Flutter integration job no longer waits for the whole OS matrix.

Final CI run [41740646030](https://github.com/saadbtch/run-and-debug-flutter/actions/runs/41740646030) on commit 9369bf6: Version consistency ✔, Dart (ubuntu) ✔, **Dart (windows) ✔** (unit + integration-dart + compile + smoke), Rust (ubuntu) ✔ (incl. wasm build), Rust (windows) ✔, **Integration (flutter-tester, Linux) ✔**. **macOS jobs never started**: on every run they stayed "queued" until cancelled, so no macOS runner was available to this repository. macOS is therefore unverified.

## Phase 7: release readiness
- Root docs: README (install per OS, quick start, key table, config and command reference, VS Code comparison, troubleshooting, privacy), LICENSE (BSD-3-Clause), CHANGELOG (Keep a Changelog, 0.1.0 unreleased), CONTRIBUTING, CODE_OF_CONDUCT (Contributor Covenant 2.1), SECURITY.
- docs: [ARCHITECTURE](../ARCHITECTURE.md), [MANUAL_ZED_TEST](../MANUAL_ZED_TEST.md), [RELEASE](../RELEASE.md), [STATUS](../STATUS.md).
- Names: [ADR 0005](../decisions/0005-project-names.md) (`flutter_rd`, `FlutterRD`, `flutter-rd-debugger`), availability re-checked on pub.dev, crates.io, the Zed registry and GitHub code search.
- Nothing was published. The draft PR is [saadbtch/run-and-debug-flutter#1](https://github.com/saadbtch/run-and-debug-flutter/pull/1).

## Process notes
- Frequent snapshot pushes (required by the session's commit hook) cancelled most CI runs, because the workflow uses `cancel-in-progress`. CI was changed to run once per PR update and skip docs-only pushes to `master`; for the final state the orchestrator stopped pushing until a full CI run completed.
