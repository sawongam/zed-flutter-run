# Project docs: Flutter Run & Debug in Zed

> **Start with [STATUS.md](STATUS.md)**: what works, how it was checked, what's untested, and your next steps.
> Cloud/autonomous agents: the original plan is [HANDOFF.md](HANDOFF.md).

This folder is the project's memory. Read it before building, and add to it at every milestone.

## Layout

| Folder | What goes in it | File naming |
|---|---|---|
| [`conversations/`](conversations/) | Write-ups of conversations and milestones: what was asked, what we learned, what we decided | `YYYY-MM-DD-NNN-topic.md` |
| [`research/`](research/) | Facts about Zed, the Dart/Flutter debug adapter, and VS Code's Dart-Code, with sources | `topic.md` (keep these current) |
| [`decisions/`](decisions/) | One file per architecture decision (ADR): context, options, choice, consequences | `NNNN-title.md` |
| [`reviews/`](reviews/) | Independent plan and code reviews, with finding ids referenced by ADRs and logs | `topic.md` |

## Top-level documents
- **[STATUS.md](STATUS.md)**: honest state of the build (read first)
- [MANUAL_ZED_TEST.md](MANUAL_ZED_TEST.md): step-by-step checklist to run in real Zed
- [ARCHITECTURE.md](ARCHITECTURE.md): final architecture, modules, protocols, security model
- [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md): the reviewed plan the code was built from (§11 maps every plan-review finding)
- [RELEASE.md](RELEASE.md): human-run release steps (nothing has been published)
- [HANDOFF.md](HANDOFF.md): the autonomous build plan
- Repo root: [README](../README.md), [CONTRIBUTING](../CONTRIBUTING.md), [SECURITY](../SECURITY.md), [CHANGELOG](../CHANGELOG.md), [CODE_OF_CONDUCT](../CODE_OF_CONDUCT.md)

## Index

### Conversations
- [2026-11-04-001: Kickoff, "a Flutter Run & Debug in Zed"](conversations/2026-11-04-001-kickoff.md)
- [2026-11-04-002: Deep research round](conversations/2026-11-04-002-deep-research.md)
- [2026-11-04-003: Extension language and design readiness](conversations/2026-11-04-003-extension-language-and-readiness.md)
- [2026-11-04-004: Handoff to the cloud agent](conversations/2026-11-04-004-cloud-handoff.md)
- [2026-11-04-005: Local verification on Arch, small fixes, authorship cleanup](conversations/2026-11-04-005-local-verification-and-fixes.md)
- [2026-11-05-006: Rename to zed-flutter-run](conversations/2026-11-05-006-rename-to-zed-flutter-run.md)
- [2026-11-03-005: Cloud environment setup (Phase 0)](conversations/2026-11-03-005-cloud-env.md) (the cloud container's clock is a day behind the local session's; order by NNN)
- [2026-11-03-006: Phase 1 research and Gate 1](conversations/2026-11-03-006-phase1-research-gate1.md)
- [2026-11-03-007: Phase 2 spike and Gate 2](conversations/2026-11-03-007-phase2-spike-gate2.md)
- [2026-11-03-008: Phase 3 plan, plan reviews and Gate 3](conversations/2026-11-03-008-phase3-plan-gate3.md)
- [2026-11-03-009: Phase 4 implementation and code reviews](conversations/2026-11-03-009-phase4-implementation.md)
- [2026-11-03-010: Phase 5 tests and Gate 5](conversations/2026-11-03-010-phase5-tests-gate5.md)
- [2026-11-03-011: Phase 6 reviews, hardening and Gate 6; Phase 7](conversations/2026-11-03-011-phase6-7-hardening-release-readiness.md)

### Research
- **[Synthesis: start here](research/synthesis.md)**
- [What already exists (Nov 2026)](research/landscape.md)
- [Zed integration surface](research/zed-integration-surface.md)
- [Flutter tooling protocols](research/flutter-tooling-protocols.md)
- [Feature parity with VS Code / Dart-Code](research/feature-parity-vscode.md)
- [Prior art and release standards](research/prior-art-and-release-standards.md)
- [Coexisting with the official Dart extension](research/coexistence-with-dart-extension.md) (Phase 1 A)
- [Zed extension registry rules](research/zed-extension-registry.md) (Phase 1 B)
- [How Zed's DAP client handles adapter output](research/zed-dap-client-behaviour.md) (Phase 1 C)
- [Recent Zed changes and device-picker UX](research/zed-recent-changes-and-picker-ux.md) (Phase 1 D)
- [Attach probe: attach through `flutter debug_adapter`](research/attach-probe.md) (measured)
- [Naming](research/naming.md)
- **[Risk register](research/risk-register.md)**

### Decisions
- [0001: Standalone tool for global users](decisions/0001-standalone-tool.md) (accepted)
- [0002: Thin Zed extension + DAP proxy + CLI](decisions/0002-architecture-dap-proxy.md) (accepted with amendments by 0004)
- [0003: Thin Rust extension + Dart proxy/CLI](decisions/0003-languages-rust-extension-dart-proxy.md) (accepted)
- [0004: Architecture accepted, with amendments](decisions/0004-architecture-accepted-with-amendments.md) (accepted; §2 superseded by 0006 D3)
- [0005: Names: `flutter_rd`, `FlutterRD`, `flutter-rd-debugger`](decisions/0005-project-names.md) (superseded by 0008)
- [0008: Rename to `zed-flutter-run`: `flutter_run`, `FlutterRun`, `flutter-run-debugger`](decisions/0008-rename-to-zed-flutter-run.md) (accepted)
- [0006: Plan-review resolutions (install model, shutdown, simplifications)](decisions/0006-plan-review-resolutions.md) (accepted)
- [0007: Phase 6 review resolutions (process cleanup, log file, behaviour choices)](decisions/0007-phase6-review-resolutions.md) (accepted)

### Reviews
- Plan: [architecture](reviews/plan-review-architecture.md), [user experience](reviews/plan-review-ux.md)
- Code, per batch: [WP4–WP8](reviews/code-review-batch1.md), [WP1–WP3](reviews/code-review-batch2.md)
- Phase 6: [correctness](reviews/phase6-correctness.md), [security](reviews/phase6-security.md), [architecture & docs](reviews/phase6-architecture-docs.md)

### Code
- [`cli/`](../cli/): Dart package `flutter_run` (proxy + CLI), unit and integration tests
- [`extension/`](../extension/): Rust Zed extension `flutter-run-debugger`
- [`fixtures/`](../fixtures/): `sample_app` (Flutter) and `dart_console` used by tests
- [`spike/`](../spike/README.md): Phase 2 proof of concept (historical; not built by CI)

## Open questions
1. ~~Scope~~: standalone (0001).
2. ~~Hot reload path~~: zed#51873 is closed, so we use a DAP proxy (0002, accepted via 0004).
3. ~~Proxy language~~: Dart proxy, thin Rust extension (0003).
4. ~~Project name~~: `zed-flutter-run` / `flutter_run` / `FlutterRun` / `flutter-run-debugger` (0008, supersedes 0005).
5. ~~Research items 4–8 from conversation 003~~: answered in Phase 1 (conversation 006).
6. Open: everything that needs real Zed or a real device. See [STATUS.md](STATUS.md) and [MANUAL_ZED_TEST.md](MANUAL_ZED_TEST.md).

## Rules for keeping these docs
- Every write-up records the **date**, the **decision or outcome**, and the **sources**.
- When a fact turns out to be wrong, fix it in `research/` and record the correction. Don't leave stale claims.
- Update this index whenever you add a file.
