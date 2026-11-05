# Prior art, demand, and public-release standards

Date: 2026-11-04. Method: `gh` CLI (read-only) and web search. Reddit was not reachable from the research tool, so no r/FlutterDev or r/ZedEditor numbers. Items marked (general knowledge) are not backed by a fetched source and should be spot-checked before they drive a decision.

## 1. Prior art

### Key finding: Zed's extension API cannot add debugger toolbar buttons
- zed-extensions/dart PR #72 (Paulo Cagol, opened 2026-03-18) added Hot Reload and Hot Restart toolbar buttons plus hot reload on save. It depended on zed-industries/zed PR #51873, "Add custom debug actions for extensions".
- Both were **closed unmerged on 2026-08-19**. The Zed maintainer's reasons: hardcoded icons, actions defined only in code, and an API that was "just for flutter". He said it could land later if there is a design discussion, a use case from other DAP adapters, and a seasoned contributor to steer it. Sources: https://github.com/zed-extensions/dart/pull/72, https://github.com/zed-industries/zed/pull/51873
- Consequence: a standalone tool cannot count on native buttons soon. It has to work through tasks, keybindings, a DAP proxy, or a CLI/daemon.

### Existing Zed and Flutter projects
| Project | Approach | License, activity |
|---|---|---|
| onepub-dev/zed-dart-extension (https://github.com/onepub-dev/zed-dart-extension) | Zed Rust/WASM extension forked from the official Dart extension. Adds Flutter launch and attach configs, auto-generated `vmServiceInfoFile`, `device_id`, and a task-to-debug-scenario converter. The `/flutter-devices` and `/flutter-devtools` slash commands list devices and build DevTools URLs. `/flutter-hot-reload` and `/flutter-hot-restart` drive `flutter attach` through a shell shim (the README calls this a "temporary shell-backed workaround"). Bundles a Dart MCP server (`flutter_devices`, `flutter_hot_reload`, and others) that is compiled with `dart compile` on first run. | Apache-2.0. 0 stars, created 2026-04-06, last push 2026-04-12. Early and Windows-leaning. |
| zed-extensions/dart (official) | Basic Flutter DAP, no reload UI. | Apache-2.0. 97 stars, pushed 2026-08-28. |
| sgruhier/zed-flutter-debug (https://github.com/sgruhier/zed-flutter-debug) | Extension. Claims hot reload on save (on by default), FVM, device selection, and DevTools launch. | MIT. 14 stars, pushed 2026-01-19. |
| dea6cat/zed-flutter (https://github.com/dea6cat/zed-flutter) | Extension plus `tool/flutter_zed.dart`. FVM-aware. Imports `.vscode/launch.json` and JetBrains `.run/*.xml` into `.zed/debug.json`. Device picker task. Reload through a pid file and DevTools. Based on the official extension. | Apache-2.0. 0 stars, pushed 2026-10-15. |
| Peixekru/zed-flutter | Extension with auto hot reload and an Inspector. | License "Other". 0 stars. |
| Mister-Ritom/flutter-watch (https://github.com/Mister-Ritom/flutter-watch) | Python file watcher that sends SIGUSR1 (reload) or SIGUSR2 (restart) to `flutter run`. Unix only. | No license. 0 stars. |
| ezechukwu69/zed_dotfiles `FLUTTER_DEBUG_HOT_RELOAD.md`, posted in Zed issue #11107 on 2026-07-27 | A Python DAP proxy that sits between Zed and `flutter debug_adapter`. It watches `lib/**/*.dart` (using fswatch) and injects the custom `hotReload` DAP request. A PATH shim named `flutter` intercepts `debug_adapter`. macOS and Linux only. | A dotfiles gist. |

Other small repos exist: kushalmahapatro/zed-flutter, mambucodev/zed-flutter, Iambahati/zed-flutter, and others. All have 0 stars. None has traction, and none is cross-platform and polished.

Notes from the dotfiles gist (not independently verified):
- The `--pid-file`/SIGUSR1 route is unreliable inside a DAP session.
- Flutter's DAP adapter exposes `hotReload` and `hotRestart` as custom requests.
- The official Dart extension ignores a user-provided adapter path, so overriding `dap.Dart.binary` does not work.

### Lessons and reuse
1. A **DAP proxy** is the one approach that keeps Zed's native debugger UI (breakpoints, variables) and still gets reload. Zed launches our binary as the adapter. We forward traffic unchanged, add watchers, and inject `hotReload` and `hotRestart`. Extra control (reload buttons, device picker) goes through an out-of-band channel such as CLI subcommands bound to Zed tasks and keybindings, or a local socket.
2. Zed tasks and keybindings are the only available UI. Plan for `zed tasks` entries, a keymap snippet, and `.zed/debug.json` generation. Importing `.vscode/launch.json` (dea6cat does this) is a good adoption feature.
3. Reuse is possible. Dart's DAP code is BSD-3 (dart-lang/sdk `pkg/dds/lib/src/dap`, LICENSE verified in pkg/dds). The extensions above are Apache-2.0 or MIT, so ideas and snippets can be adapted with attribution. Do not copy unlicensed repos (flutter-watch, Peixekru, dfdgsdfg).

### flutter-tools.nvim as design reference
(https://github.com/nvim-flutter/flutter-tools.nvim: MIT, 1,426 stars, pushed 2026-10-30.) Layout from the file tree and README:
- `runners/job_runner.lua` spawns and manages the `flutter run` process. Reload and restart go over stdin as the `r` and `R` keystrokes (the `reload = "r"` mapping is in the file). `runners/debugger_runner.lua` handles the debug path. `vm_service_extensions.lua` sends VM service extension calls.
- `devices.lua` runs `flutter devices --machine`, parses the JSON, and shows a picker. The README adds a `devices.args` option to skip the slow wireless scan. There are also emulator pickers, `FlutterReload`, `FlutterDetach`, and a statusline device indicator.
- `dap.lua` registers a `dart` adapter with nvim-dap, which uses `flutter debug_adapter`.
- It also covers an outline view, widget guides, and DevTools.
Design takeaways: separate the process manager, the device layer, and the debugger layer. Parse `--machine` JSON. Remember the selected device per project. Add a statusline-style indicator, which Zed lacks, so a CLI `status` command plus a task is the substitute. Detach must not kill the app.

## 2. Demand signals (GitHub, as of 2026-11-04)
- zed-industries/zed #11107, "Add Flutter hot reload on save action": opened 2024-04-27, still open. It has 128 reactions (109 thumbs up, 19 rocket) and 17 comments. Recent comments (April and July 2026) ask for updates and post workarounds. https://github.com/zed-industries/zed/issues/11107
- zed-industries/zed #5343, "Flutter/Dart support": opened 2022-06, closed, 398 reactions, 45 comments. This shows a large long-standing Flutter audience for Zed. https://github.com/zed-industries/zed/issues/5343
- zed-extensions/dart #72: closed, reactions not visible in the API. The maintainer's closing note (2026-08-19) says "Sorry to disappoint people following here".
- Zed's own Dart docs (https://zed.dev/docs/languages/dart) say nothing about debugging, Flutter, or hot reload. The only Flutter mention is the install note about fvm. Debug and Flutter coverage lives only in the extension.
- The six or more third-party repos created in 2025 and 2026 (table above) are further evidence of unmet need, and of fragmentation with no winner (the most-starred has 14).
- Reddit, Discord, and Hacker News were not checked. Treat demand as real but a niche: roughly 130 to 400 vocal supporters on two issues.

## 3. Implementation language

| Criterion | Rust | Dart (`dart compile exe`) | Go |
|---|---|---|---|
| Distribution | `cargo install`, Homebrew, Scoop/winget, AUR, `cargo binstall`; cargo-dist automates installers | Native exe only. `dart pub global activate` needs the Dart SDK, which every Flutter user already has. | Homebrew, Scoop, winget, AUR, `go install`. goreleaser is mature. |
| Binary size and startup (general knowledge) | 2-6 MB, startup in milliseconds | About 5-10 MB. The AOT exe embeds the runtime, so startup is fast but not as fast as Rust. | 5-10 MB, fast |
| Windows | Excellent | Good (no cross-compiling: `dart compile exe` builds only for the host OS and arch, so CI needs a matrix) | Excellent, trivial cross-compile |
| Flutter-dev contributor pool | Smaller | Largest. Flutter devs write Dart. | Small |
| Reuse of Dart libraries | None. Must hand-write DAP types (crates `dap`, `lsp-types`-style) and the VM service client. | Direct: `package:dap` 1.4.0 (published 2024-11), `package:dds` 5.4.0 (2026-07), `package:vm_service` 15.4.0, plus the DAP implementation inside `pkg/dds`. All BSD-3. | None |
| Bundling with Zed extensions | Zed extensions are Rust/WASM, so a thin Rust wrapper is natural | onepub already compiles a Dart MCP server this way | n/a |
| Risk | Reimplementing VM service semantics | Cross-OS CI builds. Pub libraries depend on the Dart SDK version. The `package:dap` release is stale (2024), though the SDK copy is current. | Same as Rust |

Sources: pub.dev API (https://pub.dev/api/packages/dap, /dds, /vm_service), dart-lang/sdk `pkg/dds` (BSD-3). Sizes, startup, and distribution notes are general knowledge.

Reasoning: the proxy mainly forwards DAP and `flutter run --machine` JSON, and rarely needs VM service depth. The tool's users are Flutter developers who already have Dart. Dart gives direct access to maintained protocol libraries and the best contributor fit. Rust gives the best distribution story and the smallest binary, and it is the better fit if we want the optional Zed extension wrapper to share code with the tool.

## 4. Public release checklist
- **License.** Use MIT or BSD-3-Clause for the tool. BSD-3 matches Flutter and the Dart SDK (both BSD-3, verified above) and is the most natural for Dart ecosystem trust. Apache-2.0 matches the Zed Dart extension and adds a patent grant. All three are mutually compatible for one-way inclusion; keep the NOTICE/attribution for any Apache code we adapt. Zed requires extensions to carry an accepted license (zed-extensions/dart is Apache-2.0); confirm the exact list in the Zed extension-publishing docs before submitting a wrapper (not checked here).
- **Docs.** README (quick start in under 5 minutes, GIF, compatibility matrix, FAQ), CONTRIBUTING (build, test, how to add a device flow), CODE_OF_CONDUCT (Contributor Covenant 2.1), SECURITY.md (private reporting through GitHub advisories), issue and PR templates, and a "known limitations" page (no native toolbar buttons, Zed API gap).
- **Versioning.** SemVer, starting at 0.x. Keep a Changelog format. Tag releases `vX.Y.Z`.
- **CI.** GitHub Actions matrix on ubuntu, macos (arm64 and x64), and windows-latest. Run unit tests plus an integration test against a fake `flutter` script emitting `--machine` JSON. Optionally add a nightly job against real Flutter stable and beta, because the machine protocol changes.
- **Release automation.** Rust: cargo-dist (generates installers, Homebrew tap, and Scoop/npm/shell/PowerShell installers) (general knowledge). Go: goreleaser. Dart: no equivalent, so write a matrix workflow that runs `dart compile exe` per OS and arch, uploads the artifacts, and updates the tap and Scoop bucket by script. Also publish to pub.dev if the tool is Dart.
- **Signing.** Unsigned macOS binaries hit Gatekeeper, though files downloaded by curl or Homebrew are not quarantined. Homebrew installs avoid most friction. A Developer ID plus notarization costs USD 99 a year. Unsigned Windows exes trigger SmartScreen warnings. Use Scoop/winget, and consider SignPath's free OSS signing (general knowledge). Publish SHA256 checksums, and consider GitHub artifact attestations/cosign.
- **Telemetry.** None by default. State this in the README. If it is ever added, make it opt-in and documented. The tool is local-only.
- **i18n.** English docs first. Flutter has a large non-English audience (Portuguese, Chinese, and Indonesian are examples; one prior-art author wrote Portuguese). Accept community translation PRs under `docs/<lang>/`, with a note that English is canonical. Keep CLI messages in a single string table so they can be translated later.
- **Hygiene.** A trademark-neutral name that does not imply Google or Zed endorsement, a disclaimer in the README, and Dependabot.

## Recommendations
1. Build a **standalone daemon/CLI plus DAP proxy**, with an optional thin Zed extension wrapper later. Do not wait for Zed's custom-debug-actions API. It was closed on 2026-08-19 and would need a new design discussion and a Zed champion. Consider helping that effort in parallel.
2. Core features, in order: (a) a DAP proxy over `flutter debug_adapter` that injects hotReload on save and on a command; (b) a device picker over `flutter devices --machine` with a per-project memory; (c) `.zed/debug.json` and tasks/keymap generation, including `.vscode/launch.json` import and FVM detection; (d) DevTools launch; (e) a `status` command.
3. Language: **Dart** compiled with `dart compile exe` is the pragmatic choice, because it reuses `pkg/dds` DAP and `vm_service`, and Flutter devs can contribute. Choose **Rust** instead if the priority is single-binary distribution and a shared codebase with the Zed WASM wrapper. Avoid Go. Decide by prototyping the proxy in the chosen language first.
4. License **BSD-3-Clause** (or MIT). Adapt ideas from the Apache/MIT projects with attribution. Never copy unlicensed repos.
5. Ship the full standards set from day one: README with GIF, CONTRIBUTING, CoC, SECURITY, CHANGELOG, a three-OS CI matrix, automated releases with checksums, a Homebrew tap and Scoop bucket, and no telemetry.
6. Position against the fragmented field: the most-starred rival has 14 stars, so a polished, cross-platform, documented tool can lead the niche. Coordinate with onepub, dea6cat, and sgruhier, since consolidation helps the ecosystem.
7. Follow-ups: check Reddit, Discord, and Hacker News manually, and confirm the Zed extension license list.
