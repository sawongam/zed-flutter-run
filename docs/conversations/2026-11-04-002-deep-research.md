# 2026-11-04-002: Deep research round

## What the user asked
"Let's research more." Their decisions: **standalone**, built for **global users**, held to public-release standards. Research to be done by Sonnet / medium-effort subagents.

## What we did
We ran four parallel research agents: Zed integration surface, Flutter tooling protocols, VS Code / Dart-Code parity, and prior art plus release standards. The main session then checked the key claims with `gh` and by reading the source.

## Outcomes
- Recorded [decision 0001: standalone](../decisions/0001-standalone-tool.md).
- Merged the findings in [research/synthesis.md](../research/synthesis.md).
- Proposed [decision 0002: DAP proxy architecture](../decisions/0002-architecture-dap-proxy.md).
- **Correction:** the kickoff doc said to "contribute upstream once zed#51873 lands". zed#51873 was closed unmerged, so that path is shelved.

## Waiting on the user
- Approve or change decision 0002
- Pick the proxy language (Dart vs Rust)
- Pick a project name
