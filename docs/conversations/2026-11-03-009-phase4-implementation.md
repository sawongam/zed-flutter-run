# 2026-11-03-009: Phase 4 implementation (WP0–WP10a) and code reviews

## Order of work
| Wave | Work packages | Notes |
|---|---|---|
| 1 | WP0 scaffold + `common/`; WP8 Rust extension; WP9 CI | WP8/WP9 don't depend on `common/`, so they started with WP0. |
| 2 | WP1 DAP proxy core, WP2 control channel, WP3 SDK/processes, WP4 devices, WP5 watcher, WP6 DevTools, WP7 init | Seven agents in parallel, disjoint directories, no cross-module imports. |
| 3 | WP10a composition root (runner, `dap`/`doctor`/`version`, wiring, schema test) | Wired every module; reconciled cross-WP mismatches. |
| 4 | WP10b integration tests | Running at the time of writing (see conversation 010). |

Every agent ran Sonnet / medium. After each WP the orchestrator re-ran `dart format`, `dart analyze --fatal-infos` and that module's tests (or `cargo fmt/clippy/test` + the wasm build) before committing.

## Independent code reviews
- [Batch 1](../reviews/code-review-batch1.md) (WP4–WP8): 0 blocker, 4 major, 14 minor, 4 nit. Majors: browser launcher waited on inherited pipes and reported failure (fixed: detached spawn); Hot Reload/Restart tasks didn't save buffers first (fixed: `"save": "all"`); relative `cwd` in the extension (fixed: resolved against the worktree root); a flaky 200-file burst test (fixed and stress-run 20× under CPU load).
- [Batch 2](../reviews/code-review-batch2.md) (WP1–WP3): 0 blocker, 2 major, 9 minor, 6 nit. Majors: `flush()` on a broken stdout hung shutdown (fixed: bounded flush, cleanup before flush); a throwing rewrite step left the request unanswered (fixed: error response + notice).
- Every finding was routed to the module's author (never to the reviewer) and re-verified by the orchestrator. Not applied, with reason: B16 (SIGINT in the picker: Ctrl-C already ends the process and nothing is written before the final choice); B20 (capabilities block isn't enforced by Zed: documentation item, handled in README).

## Cross-WP mismatches found and fixed in wiring (WP10a)
- `runTool` throws `ExternalToolException` on timeout, while `devices` expected `TimeoutException`; the wiring adapter translates.
- `--flutter-sdk` is a global option and also passed after `dap`; `GlobalOptions.addTo` on `dap` makes both parse.
- `--no-dds` is only passed to the Flutter adapter (the Dart adapter has no such flag).
- Start notices (PATH, device source, version mismatch) are emitted on the first `launch`/`attach` request, not before `initialize`.

## Results at the end of Phase 4
- `cd cli && dart format --output=none --set-exit-if-changed .` → `Formatted 115 files (0 changed)`
- `dart analyze --fatal-infos` → `No issues found!`
- `dart test --exclude-tags integration --exclude-tags integration-dart` → `+720: All tests passed!` (twice)
- `cd extension && cargo test` → 30 passed; clippy clean on host and `wasm32-wasip2`; `cargo build --release --target wasm32-wasip2` → `flutter_rd_debugger.wasm` (~289 KB)
- WP10a smoke run of the compiled `flutter_rd dap` against `fixtures/dart_console`: initialize ok, session file created then deleted, `terminated`, exit 0, no orphans; startup-failure path with empty PATH → failed response + stderr output event + exit 6.

## Known gaps carried forward
- `dart debug_adapter` never emits `flutter.appStarted`, so reload on save doesn't arm for pure Dart programs (Flutter apps are the target; documented).
