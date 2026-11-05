# Phase 6: security review

Reviewer: independent (wrote none of it). Scope: `cli/lib/src/**`, `extension/src/**`, `.github/**`, lock files, SECURITY.md and the security sections of ARCHITECTURE.md, ADR 0006 and the plan. No code was changed.
Scratch programs: `/tmp/claude-0/-home-user-run-and-debug-flutter/32cd234d-2bba-5c41-b10d-b540117c3393/scratchpad/p6-security/` (`ctl.dart`, `log.dart`, `sym.dart`, `nest.dart`).
CONFIRMED = reproduced or proven from code; PLAUSIBLE = follows from code, not reproduced.

Summary: 0 blocker, 0 major, 3 medium, 5 low, 4 info. The control channel and the extension download path are sound. The weak spot is that a project's `.zed/debug.json` controls more of the proxy than the docs say (`logFile`, `flutterSdkPath`, `env`).

## Threat model used

- Attacker A: another local user on a shared machine (loopback port, shared `/tmp`).
- Attacker B: a malicious repository the user opens in Zed and debugs (`.zed/debug.json`, `.fvm/`, `pubspec.yaml`, `.envrc`).
- Attacker C: network or supply chain (release download, dependencies, CI).
- Out of scope per SECURITY.md: code already running as the user.

Note for B: pressing F5 on a repo already runs repo-controlled code (`flutter run` runs Gradle/Xcode/CocoaPods/build hooks, and Zed's own `build` field runs shell commands). So "the repo can make the proxy run something" is not a new capability by itself. The findings below are about *unexpected* reach (writes outside the project, secrets at rest) and about claims in the docs.

## Medium

### S1 (medium, CONFIRMED) A repo's `logFile` makes the proxy append attacker-influenced text to any path the user can write
- `extension/src/proxy_args.rs:52,134-137` (config `logFile` becomes `--log-file`), `cli/lib/src/cli/dap_command.dart:177-185`, `cli/lib/src/common/logger.dart:20-24` (`createSync(recursive: true)`, `FileMode.append`).
- Problem: `logFile` from `.zed/debug.json` is passed unchanged. The proxy creates missing parent directories and appends. Log lines contain strings from the launch config verbatim, e.g. `launch_rewriter.dart:~171` logs `Ignored flutterMode "$mode"`; `Logger._log` does not escape newlines (only `dap()` goes through `jsonEncode`).
- Evidence: `p6-security/log.dart` set `flutterMode` to `x"\ntouch /tmp/pwned #\n` and logged to `out/sub/target.sh` (parent created). The file contained a line that is exactly `touch /tmp/pwned #`. Pointing `logFile` at `~/.bashrc`, `~/.zshenv`, `~/.ssh/authorized_keys` (`ssh-ed25519 ...` as the injected line) or a cron/autostart file turns this into code execution or key planting outside the project, on the next shell login, without a debug action by the user beyond F5.
- Realistic assessment: Zed runs the proxy as the user, so no privilege boundary is crossed. It is a project-config-to-home-directory reach, which a developer who clones and debugs an untrusted repo does not expect from a "log file" setting. It is PLAUSIBLE that Zed's own restricted/trusted-worktree prompt covers it, but the extension should not rely on that (not verified here). Acceptable for 0.1.0 only if documented; recommended to fix because it is cheap.
- Fix (any one is enough, do 1 and 2):
  1. Ignore `logFile` coming from the scenario in the extension unless it resolves inside the worktree or the proxy state dir; otherwise drop it and add a console notice. Prefer: log files only via user-level setting/`FLUTTER_RD_LOG`.
  2. In `Logger._log`, replace `\r`/`\n` in messages with `\\n` (keep multi-line stack traces by indenting continuation lines, not by starting new lines).
  3. Open the log with owner-only mode (see S3) and refuse non-regular files / symlinks (`FileSystemEntity.typeSync(path, followLinks: false)`).
  4. Document in SECURITY.md that `logFile`, `flutterSdkPath`, `env` come from the project file and are trusted like Zed tasks.

### S2 (medium, CONFIRMED) Docs claim a scope the code does not enforce: project config selects the executable the proxy runs (`flutterSdkPath`, `.fvm`, `env`)
- `extension/src/proxy_args.rs:125-128` (`--flutter-sdk` from the scenario), `extension/src/lib.rs:~170` (`merge_env(shell_env, cfg.env)`), `cli/lib/src/sdk/sdk_resolver.dart:200-232` (explicit path, then `FLUTTER_RD_FLUTTER_SDK`, then `.fvm/flutter_sdk` link), `cli/lib/src/cli/dap_command.dart:216-222` (`Process.start(<sdk>/bin/flutter, debug_adapter)`).
- Problem: A repo can (a) set `flutterSdkPath` to `./tool/sdk` so the proxy starts `./tool/sdk/bin/flutter debug_adapter`, (b) ship `.fvm/flutter_sdk -> ./evil`, (c) set `env` in debug.json to `PATH`, `LD_PRELOAD`, `DYLD_INSERT_LIBRARIES`, `FLUTTER_RD_FLUTTER_SDK`, `FLUTTER_RD_STATE_DIR`, `FLUTTER_RD_LOG`. `env` is merged over the worktree shell env (`merge_env`, config wins) and applies to the proxy and everything it spawns (`ps`, `chmod`, `taskkill` are looked up through PATH).
- Same trust as Zed's own tasks and `build` commands (`.zed/debug.json` is project config), so this is expected and out of scope per SECURITY.md ("anyone who can already write your project's `.zed/` files"). But `.fvm/flutter_sdk` and `pubspec`-adjacent files are not `.zed/` files, and SECURITY.md's wording ("no shell execution of user input") may read as stronger than it is.
- Fix: state it in SECURITY.md and README ("treat `.zed/debug.json` and `.fvm/` like a Makefile: opening an untrusted repo and pressing F5 runs its code"). Optional hardening: `doctor` and the first console notice print the resolved SDK path when it lies inside the project root; refuse an SDK inside the project unless `flutterSdkPath` was set in user settings.

### S3 (medium, CONFIRMED) Log file and DAP trace are created with the default umask (0644) and contain secrets
- `cli/lib/src/common/logger.dart:20-24`, `:76-79` (`dap()` writes every DAP message), `cli/lib/src/cli/wiring.dart:53` (`FLUTTER_RD_LOG`).
- Problem: `p6-security/log.dart` printed mode `rw-r--r--` for the new log file. The DAP trace holds the launch arguments (`env`, `toolArgs`, `args` which users put API keys in), the VM service URI with its auth code (`ws://127.0.0.1:PORT/CODE=/ws`, which allows full control of the debuggee for any local user), and stdout/stderr of the app. A shared log directory (for example a log file under `/tmp`) leaks these to other local users. The control token itself is never written (checked, see Verified).
- Fix: create the file with mode 0600 on POSIX (`File.createSync` then `chmod 600` before first write, or `open` via `dart:ffi` is overkill; creating then `Process.run('chmod')` matches the existing helper). Say in docs that the log contains VM service URIs. Redact `vmServiceUri`/`uri` values in `dap()` unless level is `trace`.

## Low

### S4 (low, CONFIRMED) `ensureOwnerOnlyDirectory` follows symlinks
- `cli/lib/src/common/files.dart:61-72`.
- Problem: `chmod 700` follows a symlink. Evidence: `p6-security/sym.dart` with `st/sessions -> st/victim` (mode 755) printed `ok` and left `victim` at 700; the session file (with the token) would then be written into the link target. Needs a pre-planted link in the state directory. The default state dir is under `$HOME` (`~/.local/state/flutter_rd`, not `/tmp`), so only reachable with `FLUTTER_RD_STATE_DIR` or `XDG_STATE_HOME` pointing into a shared directory. If the planted directory is owned by someone else, `chmod` fails and the code fails closed (good).
- Fix: before chmod, `FileSystemEntity.typeSync(path, followLinks: false)` must be `directory` (not `link`); on POSIX also check owner via `stat` and refuse otherwise. Use `/bin/chmod` (absolute) or `dart:ffi` `chmod` so PATH is not consulted. Create the directory with `mkdir -m 700` semantics where possible to avoid the 0755 window (today the window is harmless because the file is written after chmod).

### S5 (low, PLAUSIBLE) Saved/configured/env device ids are not validated; `safeIdPattern` is dead code
- `cli/lib/src/sdk/process_spec.dart:13` (declared, no users: `grep safeIdPattern` finds only tests), `cli/lib/src/dap/launch_rewriter.dart:95-113` (config, env `FLUTTER_RD_DEVICE`, saved id become `-d <id>` in `toolArgs`).
- Problem: ids go to the Flutter DAP adapter, which starts `flutter(.bat) run -d <id>`. On Windows the target is a `.bat`; `buildProcessSpec` validates only the arguments of the processes *this* tool starts (`debug_adapter`, `devices --machine`, `emulators --launch <id>`; emulator ids are checked by `safeEmulatorIdPattern`). The adapter spawn with attacker text from `deviceId` is outside our validation. Whether Dart's `Process.start` rejects unsafe batch arguments depends on the SDK version; not tested (no Windows host).
- Fix: validate `deviceId` from config/env/saved with `safeIdPattern` in `LaunchRewriter` (emit a note and skip on mismatch) and also in `select-device --device`. Document that `toolArgs` is passed through untouched.

### S6 (low, CONFIRMED) Deeply nested DAP message can crash the logger path with an uncaught `StackOverflowError`
- `cli/lib/src/dap/channel.dart:62-64` (`_logger.dap('$_label<', message)` inside a try that only catches `DapFramingException`), `cli/lib/src/common/logger.dart:76-79` (`jsonEncode` unguarded), `framing.dart:117-121`.
- Evidence: `p6-security/nest.dart`: `jsonDecode` of 65,536 nested arrays succeeds (10 ms, even 20M levels succeed), but `jsonEncode` of 65,536 levels throws `StackOverflowError`. The decoder is therefore not a problem; the re-encode is. `StreamDapChannel.send` already guards it (`on Object`), the receive-side log call and `Logger.dap` do not. Effect: with a log file configured, a hostile or buggy peer sending about 65K nested brackets (only 130 KB) throws inside the stream listener; the error is async-uncaught (caught only by `runZonedGuarded` in `dap_command`, which logs it and continues, so likely a lost message, not a crash). Peers are Zed and the Dart SDK adapter, both trusted, so this is robustness, not an attack.
- Fix: wrap `Logger.dap` body in `try/catch (Object)` and log `<unprintable message>`; optionally cap nesting depth when decoding (reject at, say, 512) in `_decodeBody`.

### S7 (low, CONFIRMED) Memory bound for a DAP frame is 256 MiB body plus buffer doubling plus decoded tree plus log copy
- `cli/lib/src/dap/framing.dart:23,117-121,48-70`.
- Problem: `Content-Length` is digit-checked (`^\d{1,10}$`, no overflow in Dart's 64-bit ints) and capped at 256 MiB; the header cap is 8 KiB. Memory is only allocated as bytes arrive (not pre-sized), but a legitimate-looking 256 MiB message needs the buffer (up to 512 MiB after doubling), the UTF-8 string, the decoded tree and, with a log file, a re-encoded string: roughly 1.5 GiB peak. A hostile adapter is not in the model (it is the SDK's own), and Zed is trusted.
- Fix: lower `maxBodyBytes` to 64 MiB (Flutter `variables`/`evaluate` responses are far smaller; check `output`/`scopes` with large strings) and make the cap a constant documented in ARCHITECTURE.md. Optional.

### S8 (low, CONFIRMED) Local DoS of the control port by unauthenticated connections
- `cli/lib/src/control/control_server.dart:40-52,92-100`.
- Problem: any local user (not just the owner) can open 16 connections without a newline; each holds a pending slot for 3 s, so a loop of connects keeps `reload` returning `busy`. 64 total cap holds. SECURITY.md already lists "DoS by a local user against their own session" as out of scope, but here it is any local user. No information leak. Verified in `p6-security/ctl.dart`: wrong token, missing token, unknown command (with a valid token), 70 KB line (`payload_too_large`), and an HTTP request line all get a JSON error and no token or internal detail; non-loopback address (192.0.2.2) and `::1` refuse connections.
- Fix (optional): on POSIX, check peer credentials is not available in Dart; accept as is and document, or lower the pending timeout to 1 s.

## Info

### S9 (info) Session file for `status --json` and `doctor`: no token, but `vmServiceUri` (a credential) is printed
- `cli/lib/src/control/status_command.dart:60-76`. `status --json` prints `vmServiceUri` including its auth code; the token is absent. `doctor` prints `FLUTTER_RD_*` env values (`cli/lib/src/cli/doctor_command.dart:154-157`), no secrets by design. Suggest redacting the auth segment in `status` human output if it is ever pasted into issues (it is not printed in the human table today).

### S10 (info) `init` writes through a symlinked `.zed`
- `cli/lib/src/init/commands/init_command.dart:51,139-198`, `common/files.dart:15-30`. Paths are fixed (`<project>/.zed/debug.json|tasks.json`); there is no config- or glob-driven path. `atomicWriteString` resolves a symlinked *file* but not a symlinked *directory*, so a repo with `.zed -> ~/.config/zed` would get `debug.json`/`tasks.json` written there (fixed template content, and `.bak` copies with `--force`). Also `reloadOnSaveGlobs` cannot escape the project: `_staticPrefix` rejects absolute, drive, `..`, dot-prefixed and `Pods` prefixes (`watch/path_filter.dart:128-151`). Fix (optional): refuse when `.zed` is a symlink pointing outside the project.

### S11 (info) Extension runtime behaviour verified
- Download URL is built only from the constants `REPO` and `PROXY_VERSION` plus a fixed asset name (`install.rs:43-45`); `extension.toml` limits `download_file` to `github.com/saadbtch/run-and-debug-flutter/**`.
- Sequence in `lib.rs:49-98`: pinned checksum lookup first; an **empty table returns the "not found" error before any download** (`checksums.rs:7` is `&[]`), so dev builds never download (matches SECURITY.md). Download goes to `flutter_rd[.exe].part-<ns>`, is read back, hashed with SHA-256 (case-insensitive hex compare, `verify_sha256`), the `.part` file is deleted on mismatch, and only then renamed and made executable. Stale `.part-*` files are removed before a new download. Two minor notes: after a successful verification in this process, the binary is not re-hashed again (`self.verified`, TOCTOU only against a same-user writer, out of scope); the pin script (`pin-checksums.sh`) validates hex/length/asset-name characters and fails on an empty input, but it replaces `checksums.rs` entirely, dropping `pinned_in` and the tests there (harmless to build; keep in mind when reviewing the release commit).
- `dap.FlutterRD.binary` (user setting) is used without validation (`pick_command`), correct since it is user-level. PATH lookup uses `worktree.which`, which honours the worktree shell env (direnv), same trust as S2.
- `cargo build --target wasm32-wasip2` is in CI; `Cargo.lock` has checksums for all 97 registry entries; no `build.rs`, no `unsafe`.

### S12 (info) CI and dependency hygiene
- All third-party actions are pinned to full SHAs; `permissions: contents: read` on both workflows; no `secrets.*`, no `pull_request_target`, no expression injection from `github.event` into `run:`. The release workflow only builds and uploads workflow artifacts and `SHA256SUMS` (no release, pub or crates publish step), as documented.
- `pubspec.lock` has sha256 for 57 hosted packages, no git or path sources except the app itself; CI uses `dart pub get --enforce-lockfile` in the `dart` job but plain `dart pub get` in the `integration` job (`ci.yml`), `cargo` commands are not run with `--locked`, `setup-dart` and `rust-toolchain` use moving `stable`. Recommend `--enforce-lockfile` / `--locked` everywhere so a lock drift fails CI. Dependabot is configured for pub, cargo and actions.
- `dtolnay/rust-toolchain` is pinned to a SHA that the comment calls a moving tag; confirm the SHA is the intended commit when Dependabot bumps it.

## Verified, no finding

1. Control channel: binds `InternetAddress.loopbackIPv4` only (`control_server.dart:56`); live test showed the non-loopback interface and `::1` refuse. Token is 32 bytes from `Random.secure()`, base64url without padding, 43 chars (`:96-100`). Compare is constant time over the longer length (`:13-24`). The token is checked right after JSON parse and object check, before `id`/`v`/`command`/`args` are examined; unauthorized replies carry `id: null`. Limits: 64 KiB line, 3 s to send the line, 16 pending, 64 total, one request per connection, 2 s grace on close. Command set is the closed list `ping|reload|restart`; `args` only supplies a `reason` string that goes into a DAP `hotReload` argument, nothing is executed from input. Token appears only in `control_server.dart`, `control_client.dart:101` (sent), `dap_command.dart:345` and the session file; no log, error, `status`, `doctor` or DAP-log path prints it (grep over `cli/lib`).
2. Session file: `<state>/sessions/<pid>.json`, state dir default `$XDG_STATE_HOME|~/.local/state/flutter_rd`, macOS `~/Library/Application Support/flutter_rd`, Windows `%LOCALAPPDATA%\flutter_rd`; never `/tmp` by default. Directory 0700 is set before the file is written, the file is written to a random-suffix temp name in the same directory and renamed (atomic), temp is removed on failure. Pruning deletes only if token and pid still match. Session files hold token, pid, port, project root, device id, VM service URI. Device store (`devices/<hash>.json`) holds only device id and project path, no secret, and is created with the default umask (acceptable).
3. Processes: every start is `Process.start`/`Process.run` with `runInShell: false` or the default (false) (`managed_process.dart:35-41`, `browser_opener.dart:42-47`, `process_tree.dart:94,169`, `files.dart:64`); no shell string anywhere. Windows `.bat`/`.cmd` targets reject `\n \r " % ^ & | < > ! ( ) , ; NUL`, control characters and a trailing backslash in every argument, and `% ! ^` in the executable path (`process_spec.dart:20-69`). Browser: `isSafeBrowserUrl` allows only `http(s)` to `127.0.0.1`, `localhost`, `::1` without userinfo (`url_builder.dart:57-64`), the URL is one argument, always starts with `http`, so `xdg-open`/`open` cannot see a leading `-`; `rundll32 url.dll,FileProtocolHandler <url>` only gets the validated URL. Emulator ids use `safeEmulatorIdPattern` (cannot start with `-`). `kill` uses pids from our own process table with start-time checks and never signals pid 0/1.
4. Reload globs cannot watch outside the project (see S10).

## Recommended order

1. S1 + S3 (log file path, newline escaping, 0600) and the SECURITY.md wording from S2: small, and they close the only "repo reaches outside itself" path.
2. S4, S5 (validate before chmod, wire up `safeIdPattern`).
3. S6, S7, CI `--locked` flags (S12).

## Verification (after fixes)

Re-checked against the current tree (HEAD c5ca0ce) with the original repros in `p6-security/` (`log2.dart`, `sym.dart`) plus code reading. No code changed.

| ID | Status | Evidence |
|---|---|---|
| S1 | resolved | `logger.dart` `_openLogFile`: name must end in `.log`, parent must exist (no mkdir), regular file only. Repro: `target.sh` and `nodir/x.log` refused with a warning, nothing created. Newlines are escaped (`...\ntouch /tmp/pwned #\n` on one line). Residual (info): any existing `*.log` the user can write can still be appended to, with escaped content. |
| S2 | accepted-by-ADR (P4) | Documented in SECURITY.md. |
| S3 | resolved | Log file mode `rw-------` (repro); uses `/bin/chmod`. `vmServiceUri` is still logged in the trace, which is acceptable at 0600. |
| S4 | resolved | `files.dart`: refuses a link or non-directory, absolute `/bin/chmod`. Repro: link `sessions -> victim` now throws, victim stays 755. |
| S5 | resolved | `LaunchRewriter` takes `isSafeDeviceId`, wired to `safeIdPattern` at `dap_command.dart:350`; an unsafe id is dropped with a note. The constructor default is permissive (test seam only). |
| S6 | resolved | `Logger.dap` with 70,000 nested levels: no exception ("deep dap ok"). |
| S7 | resolved | `maxBodyBytes` is 64 MiB (`framing.dart:23`). |
| S8 | accepted-by-ADR (P6) | |
| S9 | not changed | Info only. |
| S10 | not resolved | Info only: `init` still writes through a symlinked `.zed`. |
| S12 | resolved | `--enforce-lockfile` in ci.yml (both jobs) and release.yml; `cargo ... --locked` on all four cargo steps. |

New issues: none.
