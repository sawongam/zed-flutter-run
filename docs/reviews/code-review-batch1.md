# Code review, batch 1: WP4 devices, WP5 watch, WP6 devtools, WP7 init, WP8 extension (+ common)

Reviewer: independent (wrote none of this code). Contract: `docs/IMPLEMENTATION_PLAN.md` §3, §4.5-4.8, §4.10-4.12, WP4-WP8, ADR 0006. No code was modified.

Baseline checks (all green): `dart analyze --fatal-infos` and `dart format` clean for the four modules and their tests; `dart test test/unit/{common,devices,watch,devtools,init}` = 339 passed; `cargo fmt --check`, `cargo clippy --all-targets -D warnings`, `cargo test` (27 tests), `cargo clippy --target wasm32-wasip2`, `cargo build --release --target wasm32-wasip2` (289 KB wasm) all OK. No cross-module imports, no `print`, no Unicode ellipsis, no CRLF in the reviewed files.

Status legend: CONFIRMED = reproduced or proved from source; PLAUSIBLE = reasoned from code, not reproduced.

Totals: blocker 0, major 4, minor 13, nit 4.

## Answer to the capability question (download_file and redirects)

CONFIRMED by reading Zed (`crates/extension_host/src/wasm_host/wit/since_v0_8_0.rs:1076-1090`, same shape in `since_v0_6_0.rs` which is what API crate 0.7.0 uses; `capability_granter.rs:49`; `crates/extension/src/capabilities/download_file_capability.rs`):
- `grant_download_file` is called once, with the URL string the extension passed. It is checked only against the user's `granted_extension_capabilities` setting (default in `assets/settings/default.json:2376` is `{kind: download_file, host: "*", path: ["**"]}`). The `[[capabilities]]` block in `extension.toml` is NOT consulted for `download_file` (only `allow_exec` reads the manifest), so it is documentation only, as the plan says.
- The HTTP fetch then runs with `http_client.get(&url, Default::default(), true)` (follow redirects = true). Redirects to `objects.githubusercontent.com` are not re-checked. So a user with a locked-down grant of `host = "github.com", path = ["saadbtch","run-and-debug-flutter","**"]` still gets the release download; the initial URL path `/saadbtch/run-and-debug-flutter/releases/download/v0.1.0/<asset>` matches. No change needed to the flow. See B20 for a docs-only follow-up.
- The destination goes through `writeable_path_from_extension` (must stay inside the extension work dir); the absolute path built from `current_dir()` is accepted (it is lexically normalised and canonicalised against the work dir).

## Findings

### Major

**B1 - major - CONFIRMED - `cli/lib/src/devtools/browser_opener.dart:37-43` - `Process.run(...).timeout(15s)` reports success as failure and hangs the command**
Problem: `xdg-open` (and some `open` setups) starts the browser as a background child that inherits the captured stdout/stderr pipes. `Process.run` waits for pipe EOF, so it does not complete until the browser exits. After 15 s the `TimeoutException` becomes "The browser launcher xdg-open did not finish in time." and exit 10, although the browser opened. The child is not killed (`Future.timeout` does not stop the process), so the CLI also lingers.
Evidence: scratch `review1/t1.dart` with a fake `xdg-open` (`sleep 40 & exit 0`) on PATH: `ERR after 15032ms: The browser launcher xdg-open did not finish in time.` The default runner is also not covered by any test (all tests inject a fake `runProcess`).
Fix: start the launcher with `Process.start(..., mode: ProcessStartMode.detached)` (stdio not captured), or `ProcessStartMode.normal` and only await `exitCode` with the pipes drained/ignored; on timeout treat as success-with-warning, not failure. Add a test that runs the real runner against a script that backgrounds a child.

**B2 - major - CONFIRMED (Zed default) - `cli/lib/src/init/templates.dart:62-72` (Hot Reload / Hot Restart tasks) - tasks do not save buffers first**
Problem: Zed's `TaskTemplate.save` defaults to `none` (`crates/task/src/task_template.rs:126-135`). With autosave off, Ctrl+F5 reloads the on-disk code, which does not contain the user's latest edit, so the headline feature looks broken. VS Code saves before reload.
Evidence: Zed source above; `save` is in the test's allow-list of keys but never emitted.
Fix: add `'save': 'all'` to the `hot` map (reload and restart). Add it to the §4.8 task table and to the template test.

**B3 - major - CONFIRMED (source reading) - `extension/src/lib.rs:138` + `extension/src/proxy_args.rs` (`cwd`) - a relative `cwd` is passed through unresolved**
Problem: config `"cwd": "example"` or `"."` becomes `--cwd example` and `DebugAdapterBinary.cwd = Some("example")`. Zed does `command.current_dir(cwd)` as is (`crates/dap/src/transport.rs:570`, `:719`), i.e. relative to Zed's own process directory, not the worktree. Spawn fails or runs in the wrong folder; the proxy then resolves `--cwd` against that wrong directory too. (The Dart extension has the same gap, but this tool targets monorepos.)
Evidence: transport.rs lines above; `get_dap_binary` uses `cfg.cwd.clone().unwrap_or_else(|| worktree.root_path())` with no join. Not run in Zed.
Fix: if `cwd` is relative, join it with `worktree.root_path()` (use `Path::is_absolute`, plus a Windows drive/`\\` check, since the wasm target uses POSIX path rules: treat `^[A-Za-z]:[\\/]`, `\\\\` and leading `/` as absolute). Add unit tests for `.`, `sub`, `/abs`, `C:\abs`.

**B4 - major - CONFIRMED - `cli/test/unit/watch/reload_on_save_watcher_test.dart:388-406` - "burst of 200 files reloads once or twice" is flaky**
Problem: debounce is 20 ms (`_fast`); writing 200 files plus OS event delivery on a loaded or slower CI machine (Windows, macOS FSEvents) easily has gaps over 20 ms, giving 3+ reloads, and the assertion is `inInclusiveRange(1, 2)`.
Evidence: with 8 busy loops on a 4-core box, 1 of 6 runs failed: `Expected: be in range from 1 (inclusive) to 2 (inclusive)  Actual: <3>`.
Fix: use a debounce large relative to the burst (for example 500 ms) in this test only, or assert on the property that matters (no overlapping reloads and `count < 200`/`<= 5`), or drive the burst through the fake `watcherFactory` where timing is deterministic and keep the real-FS test to "at least one".

### Minor

**B5 - minor - CONFIRMED (cross-WP wiring) - `cli/lib/src/devices/device_lister.dart:66` vs `cli/lib/src/sdk/managed_process.dart` (`runTool`)**
Problem: `runFlutterChecked` only maps `TimeoutException` to the "startup lock" message (§4.5, WP4 acceptance). WP3's `runTool` does not throw `TimeoutException`; it kills the tree and throws `ExternalToolException('<exe> did not finish within N seconds and was stopped.')`. If WP10a hands `runTool` through directly (the natural wiring), the lock hint is lost and the message names the flutter.bat path.
Fix: WP10a's `FlutterRunnerFactory` adapter must translate the timeout into `TimeoutException` (typedef contract says so); better, give `runTool` a typed `ToolTimeoutException` so the adapter is trivial. Add a WP10a test for the lock text.

**B6 - minor - CONFIRMED (code reading) - `cli/lib/src/devices/commands/devices_command.dart:47-49` (also `emulators_command.dart:59`)**
Problem: `devices` looks up the saved device with `findProjectRootFor` (not canonicalised) while `select-device` writes with `requireProjectRoot` (`canonicalDirectory`, resolves symlinks). `projectRootHash` hashes `pathKey` only, so for `--project` given through a symlink (macOS `/tmp`, `/var`, Windows junction) the `*` marker and "saved device" never match what `select-device` stored. The proxy's `DeviceStore.readSync` caller (WP10a) has the same trap.
Fix: use `requireProjectRoot`-style canonicalisation in `devices` (without failing when there is no project), and document that every `DeviceStore` caller must pass `canonicalDirectory`. Alternative: canonicalise inside `DeviceStore.filePath`. Add a symlink test.

**B7 - minor - CONFIRMED - `cli/lib/src/devices/flutter_device.dart:83-96` - bracketed text after the array is mis-parsed**
Problem: the parser decodes from the first `[` to the LAST `]`. Output `<json>\nnote [1]` yields 0 devices (it decodes `[1]`) and the user gets "No devices found" instead of a parse error or the real list. `note [see docs]` throws the "could not be read" error although the JSON is fine.
Evidence: scratch `review1/t2.dart` printed `0 <- [...]|note [1]` and `ERR ... <- [...]|note [see docs]`.
Fix: try each `[` that starts a line, and decode with a prefix-tolerant approach (scan matching brackets honouring strings, or `jsonDecode` on progressively shorter suffix ends), preferring a list whose elements are objects with an `id`. Add tests for trailing noise.

**B8 - minor - CONFIRMED - `cli/lib/src/watch/reload_on_save_watcher.dart:193-210` - `_noticeShown` sticks after a throwing reload**
Problem: `_noticeShown` is set true before `_reload()` and reset only after it returns; when `reload` throws (the coalescer's `onError` path exists for exactly this), it stays true and every later `Hot reload on save: <file>` notice is suppressed for the rest of the session.
Evidence: scratch `review1/t3.dart` (first reload throws, second succeeds): two reloads ran, the second printed no `Hot reload on save` notice.
Fix: wrap in `try/finally` (reset `_noticeShown` unless the outcome is `busy`). Add a watcher test with a throwing reload.

**B9 - minor - PLAUSIBLE - `extension/src/lib.rs:76-100` - leftover `.part-<n>` files**
Problem: if `download_file` fails midway, `fs::read` fails, or `rename` fails, the `flutter_rd[.exe].part-<n>` file stays in `flutter_rd-<ver>/`; only other-version directories are swept, so repeated failures accumulate tens of MB each.
Fix: on every error path after `download_file` is attempted, `let _ = fs::remove_file(&part)`; also sweep `*.part-*` in the current version dir at the start of a download.

**B10 - minor - PLAUSIBLE - `extension/src/lib.rs:108-124` + `install.rs::not_found_message` - Windows user with only a `flutter_rd.bat` shim gets a misleading error**
Problem: a `dart pub global activate` install on Windows produces only `flutter_rd.bat`. `pick_command` correctly ignores it, then with no pinned download the user sees "flutter_rd was not found. Install it from the README ...", although they did install it. The message does not say a batch wrapper was found and why it is not usable.
Fix: when Windows `which` returned a `.bat`/`.cmd` that was ignored, return a dedicated message ("Found <path>, but Zed cannot supervise a .bat wrapper. Install the release flutter_rd.exe or set "dap": {"FlutterRD": {"binary": "<path to flutter_rd.exe>"}}.") and unit-test it.

**B11 - minor - CONFIRMED - `cli/lib/src/init/json_merge.dart:62-67` - empty file or UTF-8 BOM reported as "comments or trailing commas", exit 9**
Problem: `jsonDecode('')` and `jsonDecode('\uFEFF[]')` throw `FormatException`, and both map to `reason: 'it has comments or trailing commas'`. A zero-byte `.zed/tasks.json` (editors create these) or a BOM file (PowerShell `Out-File`, Windows editors) makes `init` exit 9 with a wrong explanation. The plan lists "empty file -> MergeNeedsManual", but whitespace-only/empty is better treated as absent.
Evidence: scratch `review1/t2.dart`: both returned `MergeNeedsManual`.
Fix: strip a leading BOM before parsing; treat empty/whitespace-only text like absent (`MergeCreated`) (update the plan/test); choose the reason text by cause (`it is empty`, `it is not valid JSON`, `it has comments or trailing commas`).

**B12 - minor - CONFIRMED (code reading) - `cli/lib/src/init/json_merge.dart:80,85` and `init_command.dart:228`**
Problem: (a) `kept` is `decoded.length`, i.e. ALL existing entries including the user's unrelated ones, so output reads "kept 7 that were already there" when none of ours existed (the plan says "kept M that were already there" meaning ours). (b) `_commitNote` is garbled: `...the tasks fail for them; they only see "Flutter: Doctor" explain why.` (§3 rule 4: whole sentences). (c) Zed itself creates `.zed/tasks.json`/`debug.json` from a commented template, so the common first-run case is exit 9; consider mentioning in the manual-step text that the comments may simply be Zed's template.
Fix: count `kept` as the number of wanted labels already present; reword (b) to `Teammates without flutter_rd on their PATH can still debug, but the tasks fail for them; "Flutter: Doctor" explains why.`

**B13 - minor - CONFIRMED (matches spec, spec is questionable) - `cli/lib/src/watch/path_filter.dart:28,56-62` - any segment named `build` is ignored, even inside `lib/`**
Problem: `lib/build/x.dart`, `lib/src/build/...`, `lib/features/build/...` (a plausible feature or CI-tool folder) never trigger a reload. The directories `build/.dart_tool/.git/node_modules` matter only at the project root, and the allow-list (lib, bin, glob prefixes) already excludes them. Ignoring them deep inside `lib/` silently drops legitimate saves with no notice.
Evidence: scratch `review1/t2.dart`: `/proj/lib/build/a.dart -> false`.
Fix: apply `ignoredSegments` only to the first relative segment (and keep the hidden-segment rule everywhere). Update §4.6 and the PathFilter table test.

**B14 - minor - PLAUSIBLE - `cli/lib/src/watch/reload_on_save_watcher.dart:155-165` and `coalescer.dart` `dispose()`**
Problem: `stop()` awaits the in-flight reload (and the event queue) with no bound. If the DAP reload request never completes (adapter dying, ADR 0006 D2 shutdown path), `stop()` never returns and shutdown cleanup stalls until the proxy's 5 s cap, skipping later cleanup steps if they are sequenced after it.
Fix: `dispose()` should not await the running reload (mark disposed, let the result be ignored), or take an optional timeout; document that WP10a must not sequence cleanup behind `stop()` without a timeout.

**B15 - minor - CONFIRMED (code reading) - `cli/lib/src/watch/reload_on_save_watcher.dart:131,155-165` - `_watched` is not cleared by `stop()`**
Problem: `start()` after `stop()` (re-arm on restart/attach) appends the directories again, so `watchedDirectories` contains duplicates and the "Reload on save is on for lib/, lib/" notice repeats them; `_changedPaths`/`_noticeShown`/hash state also survive.
Fix: clear `_watched` (and `_changedPaths`) in `stop()`; add a stop-then-start test.

**B16 - minor - CONFIRMED (grep) - interactive commands (`select-device`, `emulators`) - no SIGINT handling**
Problem: §4.12 says interactive commands handle `ProcessSignal.sigint` and exit 130 (and `ExitCodes.interrupted` exists). Nothing in `picker.dart`/commands does; `SystemConsole.readLine` is `stdin.readLineSync()` (blocking). Default Dart behaviour kills the process (POSIX status is also 130, but Windows differs and `finally` blocks do not run).
Fix: decide the owner: either WP10a wraps `run()` with a sigint listener, or the picker takes a cancel future. Record in the WP10a notes; no test covers it.

**B17 - minor - PLAUSIBLE - `cli/lib/src/common/files.dart:atomicWriteString` used by `init`**
Problem: temp-file + `rename` replaces a symlinked `.zed/debug.json` or `tasks.json` (dotfiles managers, shared configs) with a regular file, silently breaking the link; `--force`'s `.bak` is a copy of the target content.
Fix: resolve the link first (`File.resolveSymbolicLinksSync`) and write to the target, or refuse with a manual-step message when `FileSystemEntity.isLinkSync`.

**B18 - minor - PLAUSIBLE - `cli/lib/src/watch/reload_on_save_watcher.dart:170-176` + `content_hash.dart:33-38` - hash is committed before the reload outcome is known**
Problem: in `changed` mode the stored hash is updated when the event is classified. If the reload fails for a reason other than the code (app paused, transient `busy`-like state reported as failure) the same content saved again is skipped as "unchanged" and the user has no way to retry by saving.
Fix: record the hash only after a successful reload (two-phase: `hasChanged` returns a pending hash, commit on `ok`), or on failure forget the hashes of the paths in that batch.

### Nit

**B19 - nit - CONFIRMED - `cli/lib/src/devtools/commands/devtools_command.dart:108-113`** - the "If the page does not load, DevTools needs the Dart Development Service" sentence is printed for every launch failure, including "Refusing to open ... not a local http address", where it is misleading. A refusal also gives the user no way forward (a non-loopback VM service host, for example wireless iOS with `--no-dds`, cannot be opened at all). Fix: print the DDS sentence only for launcher failures, and for a refusal say that `flutter_rd devtools --print` shows the address.

**B20 - nit - CONFIRMED - `extension/extension.toml:11-14` + docs** - the `[[capabilities]]` block is not enforced by Zed (see the section above). Keep it, but README/`docs` should say that users who restrict `granted_extension_capabilities` need `{ "kind": "download_file", "host": "github.com", "path": ["saadbtch", "run-and-debug-flutter", "**"] }` in their settings, and that this covers the release redirect.

**B21 - nit - PLAUSIBLE - `extension/src/proxy_args.rs:merge_env`** - keys are compared case-sensitively; on Windows a config `env` key `Path` and the shell's `PATH` both reach the process, with undefined winner. Fix: compare ASCII-case-insensitively when the host OS is Windows (the pure fn can take an `Os`/bool).

**B22 - nit - CONFIRMED (code reading) - `cli/lib/src/watch/content_hash.dart:20,41` and `reload_on_save_watcher.dart:41`** - `_hashes` is keyed by the raw event path and never pruned (unbounded in a long session with generated files), and on case-insensitive file systems an event for `Lib/A.dart` and `lib/a.dart` are two keys (one extra reload). Fix: key by `pathKey(path, env)`; cap the map.

## Checked and found fine

- WP4: `FlutterDevice`/`DeviceStore`/picker/commands match the interfaces and exit codes in WP4 (7 for unknown/zero devices, 2 for no terminal and 3 bad answers, 8 no project, 10 flutter failure); `DeviceStore.readSync` never throws; Windows case-insensitive keying tested; emulator ids validated twice (command and `launchEmulator`), argv is a list (no shell); `--launch` rejects ids starting with `-`.
- WP5: `ReloadOnSaveConfig` is tolerant (NaN/Infinity/strings handled, clamp 10-5000); globs: absolute, `..`, drive-letter, `**.json` (no directory prefix), hidden and ignored prefixes are rejected, so a config glob cannot widen watching beyond the project or into `build/` etc.; no timers or subscriptions leak in `stop()` (subscriptions cancelled, coalescer timer cancelled); unit tests use `fake_async`; real-FS tests are event driven with 10 s deadlines apart from B4.
- WP6: URL builder handles the three input forms, `=`/`-`/`_` tokens, IPv6, default ports; `isSafeBrowserUrl` rejects `file:`, `javascript:`, remote hosts, userinfo; the browser command is argv-only (no shell) with the URL as one argument on all OSes; exit codes 2/3/4/10 as specified.
- WP7: all generated task keys exist in Zed's `TaskTemplate`; `reveal`/`hide` values are valid enum values; generated JSON is deterministic LF with trailing newline; idempotent second run; JSONC never overwritten without `--force`; `.bak` numbering works; `--dry-run` writes nothing.
- WP8: `get_dap_binary`, `dap_request_kind`, `dap_config_to_scenario` signatures match `zed_extension_api` 0.7.0 (which uses wit `since_v0.6.0`, still supported by Zed stable); checksum is verified before the rename and the cached binary is re-verified; the rename flow is safe for two racing windows; stale-dir cleanup ignores errors; hand-written hex is correct against the known vectors; `x86` and unsupported combos error out cleanly.
- WP0 (as used): `paths.dart`, `files.dart`, `host_environment.dart` behave as specified for the cases exercised above; `runTool` decodes UTF-8 with `allowMalformed`, so the `•` in `flutter emulators` output is safe on Windows.

## Notes for WP10a wiring (not defects here)

- Pass `canonicalDirectory(projectRoot)` to `ReloadOnSaveWatcher` (macOS FSEvents reports real paths) and to every `DeviceStore` call (B6).
- The extension always passes `--request launch|attach` and `--client-version`; the `dap` command must accept both (§4.1 lists them).
- `DevToolsOpenException` extends `ExternalToolException`; the proxy's `openDevTools` auto-open should catch it and print the carried `url`.
- `DevicesCommand`/`SelectDeviceCommand`/`EmulatorsCommand` all take a `store`; `EmulatorsCommand` ignores it (interface kept for symmetry).
