# 2026-11-04-004: Handoff to the cloud agent

## What the user said
- On languages: a thin Rust extension plus a Dart proxy "sounds about right". Recorded as [ADR 0003](../decisions/0003-languages-rust-extension-dart-proxy.md) (accepted).
- The project is moving to the cloud. A cloud agent will run the rest **autonomously, with no questions**: more research, self-questioning, plan review, implementation, tests, review and architecture. It should use Sonnet / medium-effort subagents to delegate and check work. The user will check the result later and expects a working system.

## Outcome
- Wrote [HANDOFF.md](../HANDOFF.md): seven gated phases, orchestration rules, safety limits (nothing published), and a Definition of Done.
- Updated the root `CLAUDE.md` so the cloud agent finds the handoff and the standing instructions. The subagent model rule was only in the user's local global config, so it's now copied into the repo.
