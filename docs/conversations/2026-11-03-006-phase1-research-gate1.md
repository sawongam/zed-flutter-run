# 2026-11-03-006: Phase 1 research and Gate 1

## What happened
Four Sonnet/medium research agents ran in parallel on the open questions 4–8 from [conversation 003](2026-11-04-003-extension-language-and-readiness.md). Each wrote one research doc. The orchestrator spot-checked the key claims in the cloned sources (Zed @ b61f33f8, dart extension @ fba74df) and on crates.io.

| Question (conv. 003) | Answer | Doc |
|---|---|---|
| 4. Coexisting with the Dart extension | Low risk with a distinct adapter name. Adapters live in one global map keyed by exact name; duplicates silently overwrite. The Dart extension has no locator. | [coexistence-with-dart-extension](../research/coexistence-with-dart-extension.md) |
| 5. Registry rules | BSD-3-Clause accepted. Ids can't contain "zed"/"extension"; debugger-only ids should end in `-debugger`. Downloads from our own GitHub Releases are the expected pattern; no built-in hash check. **The registry bans autonomous agents from contributing**, so a human submits. | [zed-extension-registry](../research/zed-extension-registry.md) |
| 6. How Zed shows adapter output | Only `output` events are visible (ANSI parsed, `important`/`group` ignored). Custom and progress events are ignored; `showUser` is never read; Zed sends `supportsProgressReporting: false`. Responses are matched by `request_seq`, so injected requests need care. `capabilities` events are merged, and RerunSession sends DAP `restart` when supported. | [zed-dap-client-behaviour](../research/zed-dap-client-behaviour.md) |
| 7. Device-picker UX | No picker or prompt API. Task terminals are real PTYs, so a numbered CLI prompt works. Recommended: `select-device` task writes a state file; the proxy injects `-d`. | [zed-recent-changes-and-picker-ux](../research/zed-recent-changes-and-picker-ux.md) |
| 8. Recent Zed changes | Zed stable 1.26.2. No new extension host functions or debugger exports since Aug 2026, no custom-request API, no on-save hook. New debugger contexts: `debugger_running`, `debugger_stopped`, `debugger_session`. `zed_extension_api` 0.7.0 is the newest on crates.io (wasm32-wasip2); 0.8.0 exists only on Zed main. | same |

## Orchestrator finding
A code search (`gh api search/code`, `"debug_adapters.Flutter" filename:extension.toml`) found at least six third-party extensions registering an adapter named exactly `Flutter`. Research A had recommended `Flutter`; that recommendation is overridden: our adapter needs a distinctive name. A naming agent is checking candidates.

## Self-questioning
[risk-register.md](../research/risk-register.md) lists 14 risks and argues against 0002 (sidecar + attach, PATH shim, fork). None beats the proxy for a VS Code-like experience.

## Gate 1: passed
- Every open question has a sourced answer or a planned spike/manual test (see "unverified" lists in each doc).
- Architecture accepted: [ADR 0004](../decisions/0004-architecture-accepted-with-amendments.md).

## Process notes
- The spike (Phase 2) was started in parallel with the research, because it doesn't depend on the Zed-side answers. Gate 1 was still closed before Gate 2 is evaluated.
- Research D could not reach zed.dev release notes (DNS blocked) or the GitHub releases API (403); it read git tags and source instead.
