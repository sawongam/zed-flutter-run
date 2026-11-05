# Phase 6 review: architecture, simplicity, public docs, CI

- **Reviewer:** independent (wrote none of the code or docs). **Date:** 2026-11-03 (container clock). **Branch reviewed:** `build/mvp` @ e75de05.
- **Method:** read the docs and code; ran `flutter_rd <cmd> --help` for every command, `init --dry-run` on a temp copy of `fixtures/sample_app`; compared against `extension/debug_adapter_schemas/FlutterRD.json`, `templates.dart`, `keymap.dart`, `install.rs`, the three `.github` scripts and both workflows; checked Zed keymaps (`assets/keymaps/default-{linux,macos,windows}.json`) and `crates/extension/src/extension_builder.rs` in the Zed checkout; ran `pin-checksums.sh` on a fake `SHA256SUMS` and `rustfmt --check` on its output; tried `dart compile exe` into a missing directory. Not run: the Flutter integration suite, Windows or macOS runners (those findings are from reading and are marked PLAUSIBLE).
- **Status values:** CONFIRMED = reproduced or shown by reading the exact lines. PLAUSIBLE = follows from the code but not executed.

## Summary

| Severity | Count | IDs |
|---|---|---|
| BLOCKER | 1 | D1 |
| MAJOR | 5 | D2, D3, D4, D5, D6 |
| MINOR | 11 | D7 to D17 |
| INFO | 3 | D18 to D20 |

Verdict on the seven questions:

1. **Code vs plan and ADRs:** matches. Module layout, command surface, exit codes, seq range (ADR 0006 D3), held `terminate` response (D2), allow-list watcher (D6), per-user device store (D7) and the deferred locator (D4) are all as written. Small unrecorded deviations: D12, D13.
2. **Simplicity:** modules respect the import rule (no cross-module imports found, no `print`, no stdout writes in the proxy). Dead or duplicated code is small: D9, D10. The big files (`dap/proxy.dart` 928 lines, `sdk/sdk_resolver.dart` 700, `cli/dap_command.dart` 605) are cohesive; nothing needs cutting before 0.1.0 (D20).
3. **Docs accuracy:** commands, flags, exit codes, defaults, env vars, task labels, key bindings and nearly all quoted messages are correct. Errors found: D3, D4, D5, D6, D7, D11, D14, D15.
4. **MANUAL_ZED_TEST.md:** workable with corrections (D6, D7, D8, D3).
5. **RELEASE.md:** asset names, tag-vs-branch warning and the agent prohibition are right. Stale pre-flight text (D6), small gaps (D14).
6. **docs/README.md index:** incomplete (D5).
7. **CI:** will not pass as written (D1); Windows unit tests likely fail (D2).

---

## BLOCKER

### D1. CI "Compile native executable" fails on every OS
- **Severity:** BLOCKER. **Status:** CONFIRMED.
- **File:** `.github/workflows/ci.yml:63-64`.
- **Problem:** `dart compile exe bin/flutter_rd.dart -o "$EXE"` with `EXE=build/flutter_rd[.exe]`. `cli/build/` is git-ignored and nothing creates it before this step, and `dart compile exe` does not create missing output directories. The `dart` job is red on ubuntu, macOS and Windows, the executable smoke test and the artifact upload never run, and the `integration` job (`needs: [dart]`) is skipped. `release.yml:57` does `mkdir -p build &&` first, so only CI is affected.
- **Evidence:** `cd cli && dart compile exe bin/flutter_rd.dart -o <scratch>/nodir1/flutter_rd` prints `Error: AOT compilation failed ... PathNotFoundException: Cannot open file ... No such file or directory`; `ls cli/build` does not exist in a clean tree; the test helper `build_exe.dart` builds into `.dart_tool/flutter_rd_test`, so it does not mask this.
- **Fix:** add `mkdir -p build` (bash shell is already set for the job) before the compile, as in `release.yml`.

---

## MAJOR

### D2. `dap_command_test.dart` (and one `wiring_test` case) will fail on the Windows runner
- **Severity:** MAJOR. **Status:** PLAUSIBLE (read, not run on Windows).
- **File:** `cli/test/unit/cli/dap_command_test.dart:108-114, 330-337, 359-366` (no `skip:` anywhere in the file); `cli/test/unit/cli/wiring_test.dart:~196-202`; `cli/test/unit/sdk/fake_sdk.dart:14-17`.
- **Problem:** `makeFakeSdk` creates `bin/flutter.bat` on Windows. The tests then overwrite `bin/flutter` (no extension) with a `#!/bin/sh` script that execs the fake adapter. The resolver on Windows picks `flutter.bat`, whose content is still `#!/bin/sh`, so the fake adapter never starts and every test that launches the adapter fails or times out. Other tests that need a shell (`wiring_test` lines 175/187/202 siblings, `doctor_test`, `browser_opener_test`, `sdk_resolver_test`) do carry `skip: Platform.isWindows`; this file was missed.
- **Fix:** skip the group on Windows, or write a `.bat` equivalent (`@echo off` plus `"%DART%" fake_adapter.dart %*`).

### D3. README install instructions say "works today" but `master` contains no code
- **Severity:** MAJOR. **Status:** CONFIRMED.
- **File:** `README.md:33, 50` (also `docs/MANUAL_ZED_TEST.md:29`).
- **Problem:** `git ls-tree master` shows only `CLAUDE.md` and `docs`. All code is on `build/mvp`. `git clone ...` (default branch) and `dart pub global activate --source git <url> --git-path cli` therefore fail for any reader until `build/mvp` is merged. The MANUAL clone line says "or use your checkout, branch build/mvp" but the command clones the default branch.
- **Fix:** merge to `master` before the README is public (a human step per HANDOFF), or add `--git-ref build/mvp` / `git clone -b build/mvp` until then. Re-check `RELEASE.md` section 1 ("CI is green on master") against the same fact.

### D4. README links to a file that does not exist
- **Severity:** MAJOR (front page, and it is the pointer to "what is verified"). **Status:** CONFIRMED.
- **File:** `README.md:7` -> `docs/STATUS.md` (absent; `ls docs` shows ARCHITECTURE, HANDOFF, IMPLEMENTATION_PLAN, MANUAL_ZED_TEST, README, RELEASE and folders).
- **Fix:** write `docs/STATUS.md` (verified vs unverified, from the Phase 5 log and MANUAL_ZED_TEST) or point to `docs/ARCHITECTURE.md` section 9 and `docs/MANUAL_ZED_TEST.md`.

### D5. `docs/README.md` index is incomplete and partly stale
- **Severity:** MAJOR (CLAUDE.md and CONTRIBUTING both require the index to be current). **Status:** CONFIRMED.
- **File:** `docs/README.md` (index section, lines 15-56).
- **Missing from the index:** `ARCHITECTURE.md`, `IMPLEMENTATION_PLAN.md`, `MANUAL_ZED_TEST.md`, `RELEASE.md`, `HANDOFF.md` (only a banner), ADR `0006-plan-review-resolutions.md`, conversations `2026-11-03-008-phase3-plan-gate3.md` and `2026-11-03-009-phase4-implementation.md` (and any later phase 5 log), all four `reviews/*.md` (this file too), `research/attach-probe.md`. The layout table has no `reviews/` row.
- **Stale:** "Open questions" item 2 still says "(0002, proposed)" although 0004 accepted it; the "Code" (`spike/`) block is nested under "Open questions"; the root files (README, CHANGELOG, SECURITY, CONTRIBUTING) are not linked.
- **Fix:** add the entries; move "Code" up; fix item 2.

### D6. RELEASE.md and MANUAL_ZED_TEST.md still say the root README and CHANGELOG do not exist
- **Severity:** MAJOR for RELEASE (a human following it literally would "write" a README over the real one), MINOR for MANUAL. **Status:** CONFIRMED.
- **File:** `docs/RELEASE.md:24`; `docs/MANUAL_ZED_TEST.md:209` ("Note: the README does not exist yet") and `:285-287` ("Open items").
- **Problem:** `README.md` (277 lines, has the "Install" section the error messages cite), `CHANGELOG.md`, `SECURITY.md`, `CONTRIBUTING.md` and `CODE_OF_CONDUCT.md` all exist. Only `cli/README.md` and `cli/CHANGELOG.md` (wanted for pub.dev) are still missing.
- **Fix:** replace the RELEASE bullet with "verify the README Install section against reality; create `cli/README.md` and `cli/CHANGELOG.md`"; delete the MANUAL note and the Open items section.

---

## MINOR

### D7. MANUAL shows the wrong project name in reload/restart result lines
- **Status:** CONFIRMED. **File:** `docs/MANUAL_ZED_TEST.md:133, 157`.
- **Problem:** expected `Hot reload: linux sample_app ok in 0.6 s`. The code prints the directory basename (`cli/lib/src/control/hot_command.dart:152`, `basename(info.projectRoot)`), and the manual copies the app to `/tmp/rdf-sample`, so the line is `linux rdf-sample`. Step 5.2's `status` line (`rdf-sample`) is already right.
- **Fix:** use `rdf-sample` in 7.3 and 9.1.

### D8. MANUAL 0.1 overstates the rustup requirement and misses the PATH trap for `cargo`
- **Status:** PLAUSIBLE. **File:** `docs/MANUAL_ZED_TEST.md:22`; `README.md` Step 2.
- **Evidence:** `crates/extension/src/extension_builder.rs:408-446`: Zed runs `rustc --print target-libdir --target wasm32-wasip2`; if the directory exists it proceeds, and only otherwise requires `rustup` to run `rustup target add`. So "a distro rust package breaks this" is wrong when the target is present; rustup is the easy path (matches Zed's `developing-extensions.md:27-29`). Zed runs `cargo` (line 214) from its own process environment, so with Zed started from a launcher `~/.cargo/bin` may be missing, the same issue as `flutter_rd` in step 0.3.
- **Fix:** reword 0.1 to "rustup recommended; any toolchain that has the `wasm32-wasip2` target works"; add "start Zed from the shell (`zed .`) for step 1 too, so it sees `cargo`". The dev-extension flow itself (`zed: install dev extension`, pick the folder with `extension.toml`) and the log path `~/.local/share/zed/logs/Zed.log` are correct per source.

### D9. Dead and duplicated code
- **Status:** CONFIRMED.
- `cli/lib/src/sdk/process_spec.dart:13` `safeIdPattern`: no use in `lib/` or `bin/` (test only). `devices/emulators.dart:32` defines `safeEmulatorIdPattern` as a "local copy of the shared rule", so the shared one is dead. `docs/ARCHITECTURE.md` section 7 says "device and emulator ids are checked against a safe pattern"; device ids are matched against the `flutter devices` list, not a pattern.
- Test-only symbols: `adapterName` (`common/version.dart:5`), `PathFilter.isIgnored` (`watch/path_filter.dart:48`), `isStrictJson` (`init/json_merge.dart:37`).
- **Fix:** delete `safeIdPattern` (or make emulators use it, which breaks the import rule, so delete), drop or `@visibleForTesting` the other three; correct the ARCHITECTURE sentence.

### D10. Same user message in four places, and it breaks CONTRIBUTING rule 3
- **Status:** CONFIRMED. **Files:** `control/status_command.dart:83`, `control/hot_command.dart:73`, `cli/wiring.dart:124`, `devices/commands/select_device_command.dart:127` ("Start ... from the debugger (F4 opens the debug picker in Zed)").
- **Problem:** rule 3 says no hard-coded shortcut names outside `init`/README text, and "keep text next to the code that uses it" (one place). Four copies will drift, and a Zed key change needs four edits.
- **Fix:** one helper in `common/` (for example `noSessionHint()`), or drop the key name ("start it from the Zed debugger").

### D11. Schema text for `vmServiceInfoFile` contradicts the README and the attach probe
- **Status:** CONFIRMED. **File:** `extension/debug_adapter_schemas/FlutterRD.json:97-99`.
- **Problem:** description says "File written by flutter run --vmservice-out-file". `README.md` (Attach) and `ARCHITECTURE.md` 3.5 say that file is a bare string and makes the adapter wait forever; the file must contain JSON `{"uri": "..."}`. Zed shows this schema text in the settings editor, so the schema steers users into the hang.
- **Fix:** "JSON file `{\"uri\": \"ws://...\"}`. The file written by `flutter run --vmservice-out-file` does not work; use `vmServiceUri`." (Update `schema_test` if it asserts text.)

### D12. Undocumented deviation: reload and restart tasks use `"save": "all"`
- **Status:** CONFIRMED. **File:** `cli/lib/src/init/templates.dart:74`.
- **Problem:** `init --dry-run` output has `"save": "all"` on Hot Reload and Hot Restart. The plan's task table (`IMPLEMENTATION_PLAN.md` 4.8) lists `use_new_terminal, allow_concurrent_runs, reveal, hide, show_summary, show_command` only; no ADR, README or ARCHITECTURE sentence mentions it. It is a sensible choice (unsaved edits get reloaded) but it interacts with reload on save: the task's save fires the watcher, then the manual reload runs, producing two reloads (the coalescer should merge them, `coalesced: true`).
- **Fix:** record it (one line in ARCHITECTURE 3.2 or a short ADR) and add a MANUAL step: edit without saving, press `ctrl-f5`, observe one reload.

### D13. Undocumented behaviour: `hotRestart` is refused for `type: dart`
- **Status:** CONFIRMED. **File:** `cli/lib/src/dap/proxy.dart:198, 320` (latest commit 7bd417c).
- **Problem:** `ARCHITECTURE.md` section 9 says only that the tasks skip Dart sessions and that reload on save for Dart is "untested". The new refusal of injected `hotRestart` and of a client `restart` for kind dart is not described anywhere (no ADR, no conversation entry yet).
- **Fix:** add to ARCHITECTURE 3.2/9 and to the phase 5/6 log.

### D14. Release docs: small mismatches and gaps
- **Status:** CONFIRMED except the last bullet (PLAUSIBLE).
- `docs/RELEASE.md:27` tells the human to write `## 0.1.0 - YYYY-MM-DD`; `CHANGELOG.md` uses `## [0.1.0] - unreleased` (Keep a Changelog style, with an empty `## [Unreleased]` above). Pick one.
- `SECURITY.md` and `CODE_OF_CONDUCT.md` direct reporters to GitHub private vulnerability reporting, and `cli/pubspec.yaml` points at the issue tracker, but the RELEASE pre-flight never says to enable "Private vulnerability reporting" and Issues in the repository settings. Add a checkbox.
- `docs/RELEASE.md` section 8 says the registry builds with "Rust 1.90"; no source in the repo supports that number. Mark `[unverified]` or drop it.
- Linux binaries are built on `ubuntu-latest` and `ubuntu-24.04-arm` (new glibc); older distros may not run them. Add one line to the release notes template or build on an older runner.

### D15. README wording and small inaccuracies
- **Status:** CONFIRMED.
- `README.md` Requirements: "(the first stable release of 0.205 was not checked; use a recent Zed)" is an internal hedge in public text. State the minimum Zed once it is verified, or say "Zed with debugger extension support (tested with 1.26)".
- `dap` row of the Commands table omits `--client-version`, which is in `dap --help` and in `proxy_args.rs:136`.
- `program` default `lib/main.dart` applies to Flutter launches only (`launch_rewriter.dart:80`); the schema default has the same gap. For `type: dart` there is no default.
- Option (b) warns only about the Windows `.bat` shim. On Linux and macOS pub also creates a wrapper script that starts `dart pub global run`, so Zed supervises a shell rather than the proxy (ADR 0006 D1 covers shutdown through stdin EOF, but startup is slower). Say so, or recommend option (a) for the debugger.

### D16. MANUAL: other small accuracy points
- **Status:** CONFIRMED (informational for the reader).
- Step 13.3/15.1 expected message text matches `install.rs:not_found_message` exactly (good) but the referenced README section now exists, so drop the caveat (see D6).
- 7.3 "task terminal flashes and closes (hide on success)" is right for `hide: on_success`, but with `reveal: no_focus` the tab opens in the terminal panel; say "tab appears without taking focus".

### D17. No `.gitattributes`; CONTRIBUTING requires LF
- **Status:** PLAUSIBLE. **File:** repository root.
- **Problem:** CONTRIBUTING rule 6 demands LF endings. On `windows-latest`, `actions/checkout` applies `core.autocrlf=true`, so Dart and Rust sources arrive as CRLF. `dart format --set-exit-if-changed` and rustfmt tolerate this, but any test comparing file content to a fixed `\n` string (templates, golden JSON) can differ. Nothing failed in the tests read, but it is a cheap guard.
- **Fix:** add `.gitattributes` with `* text=auto eol=lf`.

---

## INFO (verified correct, no action)

### D18. Keybindings, actions and contexts exist in Zed
Checked in `default-linux/macos/windows.json`: context `Workspace && debugger_session` (linux:1172), `f4` `debugger::Start`, `f5` `debugger::Rerun` (Workspace) with `f5: null` in `debugger_running` and `debugger::Continue` in `debugger_stopped`, `shift-f5` `debugger::Stop`, `f6` `debugger::Pause`, `ctrl-shift-f5` `debugger::RerunSession` (macOS `shift-cmd-f5`, as `keymap.dart` uses). `task::Spawn` with `task_name` exists (`zed_actions/src/lib.rs:740`). `ctrl-f5` and `ctrl-alt-shift-d` are unbound by Zed except Windows `ctrl-alt-shift-d` -> `dev::ResetFrameOverlayStats` (`default-windows.json:940`, debug-build action, global context, so our more specific context wins). Task keys (`save`, `hide: on_success`, `reveal: no_focus`, ...) are valid `TaskTemplate` fields. `dev::OpenDebugAdapterLogs` is real.

### D19. Release mechanics verified
`install.rs::asset_name` gives `flutter_rd-v0.1.0-{linux-x64,linux-arm64,macos-arm64,macos-x64,windows-x64.exe}`, equal to the `release.yml` matrix (`flutter_rd-$GITHUB_REF_NAME-<target>`, so a tag run yields the `v` prefix and a branch run yields the wrong name; RELEASE.md warns about exactly this and is right). URL `releases/download/v<version>/<asset>` matches section 4's `gh release create v0.1.0`. `pin-checksums.sh` on five fake lines produced a file that passes `rustfmt --edition 2024 --check`, exposes `PINNED_SHA256` and `pinned_sha256` as `lib.rs` expects. `check-versions.sh` prints `OK: all versions match (0.1.0)`. `release.yml` has `permissions: contents: read` and no publish step. `RELEASE.md` opens with the agent prohibition and every outward action (tag, release, pub.dev, Homebrew, Scoop, registry PR) is a human step, consistent with HANDOFF section 1.

### D20. Simplicity notes (no change needed for 0.1.0)
Module import rule holds everywhere (no import of another module's file outside `common/`; `cli/` is the only composition root). No `print` or stdout writes in `lib/` outside `Console`. `cli/dap_command.dart` (605 lines) carries more than wiring (device notices, DevTools opener, version and PATH notices); consider splitting it after 0.1.0. `spike/` is documented as historical and not built. `.github/dependabot.yml` covers pub, cargo and actions.

---

## Plan and ADR conformance (question 1, details)

| Item | Plan / ADR | Code | Recorded? |
|---|---|---|---|
| Names | 0005 | `FlutterRD`, `flutter_rd`, `flutter-rd-debugger` everywhere | yes |
| Install order | 0004 section 8, 0006 D1 | `lib.rs::resolve_command`: setting, PATH (`.exe` before `.bat`), pinned download, error | yes |
| Seq handling | 0006 D3 | injected from 1e9, no renumbering | yes (ARCHITECTURE 3.1) |
| Stop path | 0006 D2 | held `terminate` response, 5 s bound, EOF and crash paths | yes |
| Locator | 0006 D4 deferred | absent | yes (ARCHITECTURE 9) |
| No control `status`, `<pid>.json`, mode 0700 | 0006 D4 | as written | yes |
| No hash baseline | 0006 D4 | `content_hash.dart:8` says first event counts as changed | yes |
| Watcher allow-list | 0006 D6 | `lib/`, `bin/` for Dart, glob prefixes | yes |
| `--no-dds` for attach only | plan 4.2a | `dap_command.dart` | yes |
| Task `save: all` | not in plan | `templates.dart:74` | no (D12) |
| `hotRestart` refused for Dart | not in plan | `proxy.dart:198` | no (D13) |

## Verification (after fixes)

Checked against HEAD c5ca0ce (docs 59dca53). Flutter integration suite not run.

| ID | Result | Evidence |
|---|---|---|
| D1 | resolved | `ci.yml:64` now `mkdir -p build && dart compile exe ...` |
| D2 | resolved | `dap_command_test.dart:97-106` writes `flutter.bat` on Windows; `wiring_test.dart:196/208/223` skip on Windows (not executed on Windows here) |
| D3 | resolved | README:33-58 uses `git checkout build/mvp` and `--git-ref build/mvp`; RELEASE:25 lists the merge as a gate |
| D4 | pending | README:7 still links `docs/STATUS.md`, which does not exist yet (docs/README.md also links it) |
| D5 | resolved | docs/README.md lists ARCHITECTURE, RELEASE, MANUAL, ADR 0007, reviews |
| D6 | resolved | RELEASE:24 and MANUAL no longer say the README is missing |
| D7 | resolved | MANUAL:134, 159 use `rdf-sample` |
| D8 | resolved | MANUAL:22-23 reworded; start Zed from the shell for step 1 |
| D9 | partially | `safeIdPattern` is now used (`dap_command.dart:350`), so that item is resolved. `adapterName`, `isStrictJson` and `PathFilter.isIgnored` are still test-only (unchanged) |
| D10 | accepted-by-ADR | ADR 0007 P6 |
| D11 | resolved | `FlutterRD.json:99` corrected |
| D12, D13 | accepted-by-ADR | ADR 0007 P5 |
| D14 | partially | RELEASE:24 now includes the Issues and private reporting checkbox. Not checked: the changelog heading format, the "Rust 1.90" claim and the glibc note |
| D15 | partially | The README no longer says "was not checked" (line 23). `--client-version` is not in the README `dap` row. The Unix pub shim note was not checked |
| D16 | not checked | Minor wording; not re-verified |
| D17 | not resolved | There is still no `.gitattributes` |

New out-of-sync items:
- **N1.** `ARCHITECTURE.md:186` still says "256 MiB body limit", but `framing.dart:23` is 64 MiB.
- **N2.** The `ARCHITECTURE.md:186` initialize sentence is garbled: "The code written before ADR 0007 used 10 s; the decided behaviour is 120 s, event capture ..." is wedged into the list. The code is 120 s (`proxy.dart:21`), so the number is right.
- **N3.** README:275 suggests `"logFile": "/tmp/flutter_rd.log"`. That is allowed under the new rules (ends in `.log`, `/tmp` exists). MANUAL still uses `/tmp/rdf-proxy.log`, which is also fine.
- **N4.** README does not mention the signal handlers; this is acceptable, since ARCHITECTURE:149 covers them.
