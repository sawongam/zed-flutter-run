# HANDOFF: autonomous build plan for the cloud agent

> **Note (2026-11-05):** the project was renamed to `zed-flutter-run` after this was written; see [ADR 0008](decisions/0008-rename-to-zed-flutter-run.md). Names in this file already use the new forms.

> **Read this whole file first.** You are the cloud agent, and you are taking this project from research to a **working, tested, documented system** in one autonomous run.
> **The user is unavailable.** Don't ask questions or wait for input. Decide, record the decision, and keep going.
> Written 2026-11-04 by the local session. All prior context lives in `docs/`.

---

## 0. What we are building
A **standalone, open-source tool that brings VS Code–style Flutter Run & Debug to the Zed editor**, for Flutter developers worldwide on Linux, macOS and Windows.

Required reading, in this order:
1. [`docs/README.md`](README.md): the index
2. [`docs/research/synthesis.md`](research/synthesis.md): the five facts that shape the design
3. Decisions [0001](decisions/0001-standalone-tool.md) (standalone), [0002](decisions/0002-architecture-dap-proxy.md) (DAP proxy architecture, *proposed*), [0003](decisions/0003-languages-rust-extension-dart-proxy.md) (Rust extension + Dart proxy, *accepted*)
4. The research docs as needed: [zed-integration-surface](research/zed-integration-surface.md), [flutter-tooling-protocols](research/flutter-tooling-protocols.md), [feature-parity-vscode](research/feature-parity-vscode.md), [prior-art-and-release-standards](research/prior-art-and-release-standards.md)
5. [Conversation 003](conversations/2026-11-04-003-extension-language-and-readiness.md): the open questions you must close

### Architecture in one picture (from 0002)
```
Zed debugger panel ──DAP/stdio──▶ <tool> dap (Dart proxy) ──DAP/stdio──▶ flutter debug_adapter ──▶ app
                                        ▲
 Zed task + keybinding ──▶ <tool> reload | restart | devtools | devices | init
 file watcher (inside proxy) ──▶ hotReload {reason:"save"}
```
- **Rust Zed extension**, thin: registers a `Flutter` debug adapter whose binary is our proxy, and downloads or locates that binary.
- **Dart proxy + CLI**, one executable: forwards DAP, injects `hotReload` / `hotRestart`, captures the VM service URI (`dart.debuggerUris`), watches files for reload on save, injects the device, opens DevTools, and runs `init` to write the Zed config.

---

## 1. Operating rules (non-negotiable)

### Autonomy
- **Never ask the user anything.** When something is ambiguous, pick the option that best serves *global users and public-release quality*. Write it up as an ADR in `docs/decisions/NNNN-*.md` (context, options, decision, consequences) and carry on.
- When you're blocked (a tool is missing, a network call fails), find a workaround, record it in `docs/conversations/`, and keep going. Don't stop until the Definition of Done (§6) is met, or you've proven an item is impossible in this environment. In that case, document exactly what's left and how the user can finish it.

### Subagent orchestration
- **Every subagent runs with `model: "sonnet"` and `effort: "medium"`.** This is the user's standing instruction.
- You are the **orchestrator**. You plan, delegate, verify and integrate. Send independent work out in parallel, several agents per message.
- Give each agent a **self-contained prompt**: its goal, the files it owns, the files it must not touch, the docs it should read, its acceptance criteria, and the summary it should return.
- **Ownership of files must not overlap** between agents running at the same time. Where they might collide, use `isolation: "worktree"`.
- **Never trust a subagent report blindly.** After each one finishes, check its key claims: run the tests yourself, read the diff, re-run commands, and spot-check sources.
- **Reviewers are never the agents that wrote the code.** Every implementation batch gets an independent review agent.

### Documentation (the user's standing instruction)
After every milestone or useful finding:
- add a conversation log to `docs/conversations/YYYY-MM-DD-NNN-*.md`
- record decisions in `docs/decisions/`
- fix any wrong facts in `docs/research/`, with a correction note
- update the `docs/README.md` index

### Safety and outward-facing actions
- **Allowed:** commit often on a working branch (`build/mvp`). Push that branch if a remote exists. Open a draft PR against the default branch (currently `master` on `sawongam/zed-flutter-run`) if GitHub access is available.
- **Not allowed:**
  - publish packages (pub.dev, crates.io, Homebrew, Scoop)
  - submit to the Zed extension registry
  - create GitHub releases or tags
  - post on issues or forums
  - push to or rewrite history on `master`

  Instead, prepare these as ready-to-run steps in `docs/RELEASE.md` for the user.
- Don't edit files outside the repo, apart from installing toolchains.

---

## 2. Environment setup (Phase 0)
1. Install or verify the toolchains: **Flutter stable** (includes Dart) and **Rust stable** with the `wasm32-wasip2` target (check the target that `zed_extension_api` currently requires; older versions use `wasm32-wasip1`). Also `git` and `gh` if available.
2. Record the versions in `docs/conversations/<date>-NNN-cloud-env.md`.
3. You can't run Zed's GUI in the cloud. Plan to verify everything **headlessly** (see §5), and write a **manual Zed checklist** for the user.
4. For a headless Flutter target, try these in order:
   1. `flutter run -d flutter-tester` (may need `--show-test-device` or similar)
   2. `-d web-server` (headless web, supports hot reload since Flutter 3.35)
   3. Linux desktop under `xvfb-run`

   Record which one works.

---

## 3. Phases and gates
Each phase ends with a **gate**: the conditions that must be true before you move on. Record each gate result in `docs/conversations/`.

### Phase 1: Close the open research (parallel, about 4 agents)
Answer the questions in [conversation 003](conversations/2026-11-04-003-extension-language-and-readiness.md), items 4–8. Each agent writes `docs/research/<topic>.md` with sources.
- **A: Coexisting with the official Dart extension.** Can two extensions both register a debugger for Dart? How do `.zed/debug.json` `adapter` names and debug locators pick between them? Read the Zed source (`crates/dap*`, `crates/debugger_ui`, `crates/extension*`). This is **the most important risk**.
- **B: Zed extension registry rules.** `zed-industries/extensions` repo, accepted licenses, rules for downloading binaries (`download_file`, `latest_github_release`), naming, review process, and an example extension that ships a downloaded binary as a debug adapter.
- **C: How Zed's DAP client handles adapter output.** Are `output` events, custom events, `progressStart`/`progressEnd` and `showUser` shown anywhere? How should reload status and errors be shown to the user?
- **D: Recent Zed changes** (2026-08 → now) to the extension or debugger API, tasks, and keymap actions. Also: how other Zed extensions let users choose between options, to settle the device-picker UX.

**Self-questioning step (you, the orchestrator):** after the agents report, write `docs/research/risk-register.md`. For each risk, record its likelihood and impact, how we'll handle it, and what would make us change direction. Explicitly try to argue *against* 0002 (for example: "would a sidecar that owns `flutter run --machine`, used with Zed's attach, be simpler?"). Then accept, amend or replace 0002 as a new ADR.

**Gate 1:** every open question has a sourced answer or a planned spike test, and the architecture ADR is **Accepted**.

### Phase 2: Spike (you, or one agent, in a worktree)
A minimal proof of concept, ugly code allowed, in `spike/`:
1. A Dart proxy that forwards DAP over stdio with Content-Length framing to `flutter debug_adapter`, and logs traffic to a file.
2. A **fake DAP client** script that acts like Zed: `initialize` → `launch` → `setBreakpoints` → `configurationDone`. It then waits for `stopped` and continues.
3. A control channel (localhost TCP + a token in a session file is the default) so that `spike reload` makes the proxy send `hotReload`.
4. A sample app in `fixtures/sample_app` with a counter and a breakpoint target.

**Gate 2:** run headlessly and show that (a) a breakpoint hits through the proxy, (b) the `reload` command hot-reloads (change a string, then check the app output, logs or `flutter.appStarted` / the reload response), and (c) breakpoints still work after the reload. If any of these fails, go back to Phase 1 with what you learned.

### Phase 3: Implementation plan + plan review
Write `docs/IMPLEMENTATION_PLAN.md` covering:
- the final repo layout
- module boundaries and public interfaces
- the session-file and control-protocol spec (versioned)
- the config schema (`debug_adapter_schemas/Flutter.json`)
- the CLI commands and flags
- the error-handling and logging policy
- SDK resolution order (setting → `.fvm/flutter_sdk` / `.fvmrc` → puro → `FLUTTER_ROOT` → PATH, with `.bat` handling on Windows)
- a test plan
- work packages (WPs), each with an owner agent, the files it owns, its dependencies and acceptance criteria

**Plan review:** spawn **2 independent review agents**:
1. an *architecture* reviewer covering simplicity, cross-platform support and failure modes
2. a *user-experience* reviewer who walks through it as a first-time user on Windows and macOS against [feature-parity-vscode.md](research/feature-parity-vscode.md)

Fix the plan according to their findings, and record what changed.

**Gate 3:** the plan has been reviewed, the findings are resolved, and the WPs are ready to run in parallel.

Suggested layout (amend if needed):
```
extension/                     # Rust, zed_extension_api
  extension.toml  Cargo.toml  src/lib.rs
  debug_adapter_schemas/Flutter.json
cli/                           # Dart package (proxy + CLI, one executable)
  bin/<tool>.dart
  lib/src/dap/        # framing, message models, proxy core
  lib/src/control/    # session file + localhost control server/client
  lib/src/sdk/        # Flutter/Dart SDK discovery (fvm, puro, PATH, Windows)
  lib/src/devices/    # flutter daemon / devices --machine, picker, remembered device
  lib/src/watch/      # reload-on-save watcher (Dart-Code rules, debounce)
  lib/src/devtools/   # dart devtools --machine, page URLs, open browser
  lib/src/init/       # writes .zed/debug.json, .zed/tasks.json, prints keymap snippet
  test/  (unit + integration)
fixtures/sample_app/
docs/  .github/workflows/
```

### Phase 4: Implement (parallel WPs, Sonnet / medium agents)
Run the WPs from the plan, with independent WPs in parallel. Suggested split:
1. DAP framing + proxy core
2. Control channel + CLI skeleton
3. SDK discovery
4. Devices + picker
5. Watcher
6. DevTools
7. `init` + Zed config templates
8. Rust extension
9. CI workflows

Rules for every WP:
- It comes with tests.
- `dart analyze` is clean, `dart format` is applied, and `cargo clippy` is clean for Rust.
- No WP is done until the orchestrator has re-run its tests.

The MVP must include:
- hot reload and hot restart from Zed tasks / keybindings
- reload on save (`.dart` + configurable globs; skip `.dart_tool`; debounce; `reason:"save"`)
- device listing and picking, with the choice remembered and injected as `-d` unless the config already sets a device
- `devtools [inspector|performance|cpu-profiler|memory|network]`
- `init`
- support for both launch and attach
- working behaviour on Linux, macOS and Windows: path handling, `.bat`, a control channel that isn't POSIX-only

**Don't** use POSIX signals as the main mechanism.

**Gate 4:** all WPs are merged on `build/mvp`, the full test suite passes locally, and the Rust extension builds for the WASI target.

### Phase 5: Test
- **Unit tests:** framing (partial and multiple messages per chunk), request/response seq rewriting for injected requests, debounce, SDK resolution matrix, path handling on Windows (pure functions), schema validation.
- **Integration tests (headless, real SDK):** the fake DAP client drives the proxy, which drives `dart debug_adapter` (a Dart console fixture: breakpoint, step, variables, terminate) and `flutter debug_adapter` (the sample app on the headless device from §2: launch, breakpoint, hot reload, hot restart, reload on save by touching a file, stop).
- **CLI end-to-end tests:** `init` into a temp project creates valid JSON; `devices` works in non-interactive `--json` mode.
- **CI:** a GitHub Actions matrix for ubuntu, macos and windows that runs analysis, unit tests, `dart compile exe` and `cargo build --target wasm32-wasip*`. Integration tests run on Linux at minimum.

**Gate 5:** everything passes. Record the actual command output in a conversation log. If a test is flaky, fix it rather than skipping it.

### Phase 6: Review + hardening
Spawn **3 independent reviewers** in parallel:
1. **Correctness:** races in proxy seq handling, shutdown and orphan processes, error paths
2. **Security:** the control channel must bind to localhost only and require a token, handle files carefully, never shell-inject, and the extension must check binary checksums
3. **Architecture and docs:** does the code match the plan, is it simple, are the public docs accurate

Fix every confirmed finding and re-run all tests. Use `/code-review` or `/simplify` if they're available.

**Gate 6:** no confirmed findings remain open.

### Phase 7: Release readiness (prepare, don't publish)
- `README.md`: what it is, install for each OS, quick start (`<tool> init` → open Zed → F5 / keybindings), a comparison with VS Code, troubleshooting.
- `LICENSE` (**BSD-3-Clause**, matching the Flutter ecosystem, unless Phase 1 B finds a reason to change), `CHANGELOG.md` (Keep a Changelog, `0.1.0`), `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`.
- `docs/ARCHITECTURE.md`: the final architecture with diagrams.
- `docs/MANUAL_ZED_TEST.md`: a step-by-step checklist the user runs in real Zed. It covers installing the dev extension, the sample app, breakpoint, F-key reload, save-reload, device pick and DevTools, with the expected result for each step.
- `docs/RELEASE.md`: the exact commands and steps for tagging, building binaries, Homebrew and Scoop, pub.dev, and Zed registry submission. The user runs these, not you.
- **Name:** pick a final project and binary name. Check it doesn't clash on pub.dev, crates.io, GitHub and the Zed registry, and record it in an ADR. Until then, use a placeholder that's easy to rename.

---

## 6. Definition of Done (what the user expects to find)
- [ ] Branch `build/mvp` with clean, frequent commits (and a draft PR if possible)
- [ ] A working Dart proxy + CLI and a Rust Zed extension that builds for WASI
- [ ] Headless integration tests proving breakpoint, hot reload, hot restart and reload on save through the proxy, all passing, with the output logged
- [ ] CI workflows for Linux, macOS and Windows
- [ ] All reviews done and their findings resolved
- [ ] All docs listed in Phase 7, plus an up-to-date `docs/README.md` index, ADRs and conversation logs for every phase
- [ ] `docs/STATUS.md`, the first thing the user reads, covering:
  - what works, and how you verified it
  - what's untested (especially anything that needs real Zed or a real device)
  - known issues
  - the exact next steps for the user, starting with `MANUAL_ZED_TEST.md`

## 7. When you're stuck
1. Re-read the research docs.
2. Read the source: Zed, the Dart extension, flutter_tools, Dart-Code.
3. Try the simplest alternative that still works across platforms.
4. Write an ADR and move on.

Never end the run silently. `STATUS.md` must always say honestly where things stand.
