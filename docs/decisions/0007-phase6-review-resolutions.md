# 0007: Phase 6 review resolutions (process cleanup, log file, small behaviour choices)

- **Date:** 2026-11-03
- **Status:** Accepted (orchestrator)
- **Inputs:** [phase6-correctness](../reviews/phase6-correctness.md) (R1–R16), [phase6-security](../reviews/phase6-security.md) (S1–S12), [phase6-architecture-docs](../reviews/phase6-architecture-docs.md) (D1–D20).

## Decisions

### P1. Which processes the proxy may kill (R1, R2, R3, R12)
- On a normal stop (`terminate`, `disconnect`, stdin EOF) the sweep targets **the adapter itself if it is still alive** plus its **current** descendants (a fresh snapshot right before the sweep). Processes that were seen earlier but have left the tree (e.g. a Gradle daemon started during an Android build) are **not** killed.
- Only after an **adapter crash** does the proxy also sweep earlier-seen processes that were reparented, with the PID-reuse guard, and **never** well-known shared daemons: `adb`, Gradle daemons (`GradleDaemon`, `GradleWrapperMain` children that detached), Kotlin compile daemons, and the Dart tooling daemon of other sessions. Killing `adb` would drop every device connection on the machine.
- The 2 s snapshot poll keeps only pids that are still alive (bounded set) and stops at shutdown.
- POSIX signal handlers (`SIGTERM`, `SIGINT`, `SIGHUP`) run the same cleanup as stdin EOF. A **SIGKILL of the proxy** can't be handled; then the adapter may survive until its stdin read fails. This is a documented known issue (Zed only kills the proxy *after* our held `terminate` response, so the normal path is clean).

### P2. Slow first start (R4)
The `initialize` timeout becomes 120 s. After 10 s the proxy prints one notice ("Flutter is still starting. The first run after an upgrade, or another flutter command holding the startup lock, can take a while.").

### P3. `logFile` from a project's debug.json (S1, S3)
A cloned repository must not be able to make the proxy append to `~/.bashrc` or `authorized_keys`. So the log path must end in `.log`, its parent directory must already exist (no `mkdir -p`), it is opened with owner-only permissions (0600 on POSIX), and every logged line has control characters escaped. `FLUTTER_RD_LOG` (set by the user, not the project) follows the same rules.

### P4. Project-controlled execution (S2)
`flutterSdkPath`, `.fvm/flutter_sdk` and the scenario `env` choose which binaries run, exactly like Zed tasks and the official Dart extension. That is accepted and documented in SECURITY.md ("open only projects you trust, as with any Zed task").

### P5. Small behaviour choices made during the build, now recorded (D12, D13, B13)
- Hot Reload / Hot Restart tasks use `"save": "all"`, so reload sees what's on screen (VS Code saves before reload too).
- Hot restart is refused for Dart programs; `dart debug_adapter` supports `hotReload` but not `hotRestart`. Dart programs are "started" on the first `dart.debuggerUris`.
- `build/`, `.dart_tool/`, `.git/`, `node_modules/` are ignored only as top-level folders of the project; hidden segments at any depth.
- DevTools for Dart programs is refused with a hint (DDS of `dart debug_adapter` doesn't serve DevTools: R6).

### P6. Rejected / deferred
- D10 (one shared "press F4" string): rejected. ADR 0006 D4 keeps messages next to their code; the duplication is four short sentences.
- S8 (a local user filling the pending-connection slots): accepted risk. The token is unreadable to other users (0700 directory) and the effect is a `busy` reply for a few seconds.
- R3's SIGKILL case: documented known issue (P1).

## Consequences
Cleanup can't hurt unrelated developer daemons; a hostile repository can't use the log file as a write primitive; slow Flutter starts don't fail the session.

## Addendum (2026-11-03, after CI on GitHub runners)
- **P7. Arm-time hash baseline in the watcher** (reverses the "no hash baseline" cut in ADR 0006 D4). On a slow CI runner, one save arrived as two file events (truncate, then write); the second queued a follow-up reload of content that was already applied, so "identical content does not reload" failed. Now, in `changed` mode, the watcher hashes the watched files when it arms, and re-hashes a batch right before reloading, skipping it if every file already has the content of the previous reload. Cost: one read of `lib/` at arm time (files > 2 MiB skipped).
- **P8. Windows process table.** Windows now snapshots descendants from `Win32_Process` (PowerShell `Get-CimInstance`, `wmic` fallback) with the same PID-reuse guard (creation date) and daemon exclusions as POSIX, so a crashed adapter's `dart.exe`/`dartvm.exe` are swept. Found by the `integration-dart` suite on `windows-latest`.
- **P9. Windows loopback connect.** A refused loopback connect on Windows can take ~2 s and reports errno 1225 (or a timeout); the control client's connect timeout is 6 s on Windows and treats 1225/10061 as refused.
