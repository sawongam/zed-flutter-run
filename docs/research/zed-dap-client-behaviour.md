# Zed DAP client behaviour (how Zed handles adapter output, events, errors)

Date: 2026-11-03
Source: `zed-industries/zed` shallow clone at commit `b61f33f8b6bf811e640a9e83fede2cf4640ba061` (HEAD of main, committed 2026-11-03); `dap-types` at rev `1b461b310481d01e02b2603c16d7144b926339f8` (pinned in Zed `Cargo.toml:617`).
Paths below are relative to the Zed repo. Tags: [verified-source] = read in code at that commit; [unverified] = inferred / not run.

## Method
Read `crates/dap/src/{client,transport}.rs`, `crates/project/src/debugger/{session,dap_command}.rs`, `crates/debugger_ui/src/{debugger_panel.rs,session/running.rs,session/running/console.rs}`, `crates/debugger_tools/src/dap_log.rs`, and `dap-types/src/messages.rs`. Static reading only; Zed was not built or run, so nothing here is observed at runtime.

## Q1. `output` events
- Handler: `crates/project/src/debugger/session.rs:1568-1578` (`Events::Output`). The only filter is: category `telemetry` is dropped; everything else goes to `push_output` (ring buffer, `MAX_TRACKED_OUTPUT_EVENTS`) [verified-source].
- Rendering: `crates/debugger_ui/src/session/running/console.rs:159-245` (`add_messages`). Each event's `output` is `trim_end()`ed, a `\n` appended, run through `terminal::parse_ansi_text`, inserted into a read-only editor, and ANSI foreground/background colour spans are highlighted [verified-source].
- Category is NOT used for styling: `console`, `stdout`, `stderr`, `important` and absent category all render identically (no per-category colour, no filter). `grep` of console.rs finds no use of `category` [verified-source]. Colour can only come from ANSI escapes in the text (Zed also advertises `supportsANSIStyling: true`, see Q3).
- `important` is not surfaced as a notification/toast; no code path reads it outside proto conversion (`crates/dap/src/proto_conversions.rs:359-376`) [verified-source].
- `group` (`start`/`startCollapsed`/`end`) is ignored: not read in console.rs [verified-source]. `source`/`line`/`variablesReference` are also unused for linking.
- The console panel shows a "new output" indicator (`console.rs:153-155`, `has_new_output`) [verified-source]. The panel must be open to read it; there is no pop-up.
- Zed itself writes into the same console via `Session::console_output` (`session.rs:1084-1104`), category `None`, e.g. "Tried to launch debugger with: ..." and "Session failed to restart with error" (`debugger_panel.rs:419-424`) [verified-source].

## Q2. Custom events (`dart.debuggerUris`, `flutter.appStarted`, `dart.progressStart`, ...)
- `dap-types` `Events` enum ends with `#[serde(untagged)] Other(OtherEvent { event: String, body: Value })` (`dap-types/dap-types/src/messages.rs:40-67`), so unknown events deserialize fine [verified-source].
- `Session::handle_dap_event` `Events::Other` arm (`session.rs:1643-1658`) only acts on `launchBrowserInCompanion` and `killCompanionBrowser`; every other name is silently ignored (no log, no error) [verified-source].
- Caveat: `OtherEvent.body` is a required `Value` (no `#[serde(default)]`). An unknown event with NO `body` key may fail to deserialize as `Message`, and a deserialize error in `recv_from_server` (`transport.rs:~345-366`, `ConnectionResult::Result(Err(e)) => break Err(e)`) ends the receive loop and flushes pending requests, i.e. kills the session. Always include `"body": {}` on custom events we emit. [verified-source for the code; the exact failure for a missing body is [unverified] since serde `Value` fields can default to null only if `Option`.]
- Also: a malformed frame (bad Content-Length, invalid UTF-8, JSON that is not a `Message`) is fatal to the session (`transport.rs:~330-366, 400-470`) [verified-source]. The proxy must emit only well-formed frames.

## Q3. Progress events and `initialize` arguments
- Zed does NOT show progress. `Events::ProgressStart/Update/End` are empty arms (`session.rs:1639-1641`) [verified-source]. Zed sends `supportsProgressReporting: false`, so the Flutter adapter will not send them anyway.
- Exact `initialize` arguments, `crates/project/src/debugger/dap_command.rs:1535-1555` [verified-source]:
```rust
fn dap_client_capabilities(adapter_id: String) -> InitializeRequestArguments {
    InitializeRequestArguments {
        client_id: Some("zed".to_owned()),
        client_name: Some("Zed".to_owned()),
        adapter_id,                       // the debug adapter name from the debug scenario
        locale: Some("en-US".to_owned()),
        path_format: Some(InitializeRequestArgumentsPathFormat::Path),
        supports_variable_type: Some(true),
        supports_variable_paging: Some(false),
        supports_run_in_terminal_request: Some(true),
        supports_memory_references: Some(true),
        supports_progress_reporting: Some(false),
        supports_invalidated_event: Some(false),
        lines_start_at1: Some(true),
        columns_start_at1: Some(true),
        supports_memory_event: Some(false),
        supports_args_can_be_interpreted_by_shell: Some(false),
        supports_start_debugging_request: Some(true),
        supports_ansistyling: Some(true),
    }
}
```
- Consequence: the proxy can rewrite `supportsProgressReporting` to `true` toward the Flutter adapter if it wants the adapter's progress events, but must then consume them (Zed would ignore them). `supportsANSIStyling: true` means ANSI colour codes in `output` are safe. [verified-source]

## Q4. `ErrorResponse` / `showUser` / failed responses
- `show_user` is never read in Zed source (only set to `None` when Zed builds its own `ErrorResponse`, `session.rs:1190, 1247`) [verified-source]. `showUser: true` has no effect.
- Failed response handling: `transport.rs:370-400` (`process_response`) turns a failed response into an `anyhow` error, preferring `body.error.format` (with `{var}` interpolation from `variables`), else `response.message`. `client.rs:131-150` wraps it as `Request failed: <message>` [verified-source].
- Where it shows: mostly `log::error!` only (`.log_err()` / `detach_and_log_err` in `session.rs` e.g. 2100-2125, 2133, 2156) - i.e. Zed's own log, not the UI. Failures of `launch`/`attach`/`initialize` during boot propagate to the debugger panel start-up path (`session.rs:~960-995` also prints "Tried to launch debugger with: ..." to the console) [verified-source for log-only on ordinary requests; how the boot error is displayed in the UI is [unverified]].
- Implication: the response to a user-initiated request (continue, step, etc.) is not a good channel for user messages.

## Q5. Reverse requests
- `runInTerminal` and `startDebugging` are both supported, and advertised (Q3). Dispatch: `session.rs:937-943`; handlers `handle_start_debugging_request` (`session.rs:1136-1171`, spawns a child session and responds) and `handle_run_in_terminal_request` (`session.rs:1173-1270`) [verified-source].
- Any OTHER reverse request command is silently dropped with NO response (the `if/else if` at `session.rs:937-943` has no else) [verified-source]. Proxy must not rely on Zed answering custom reverse requests.
- Zed's response uses `seq: request_seq + 1` (`session.rs:1406-1413`) - Zed's own seq is not meaningful. The proxy must forward these responses to the adapter untouched.
- Note: `transport.rs:876-898` also special-cases `RunInTerminal`/`StartDebugging` (test/fake client code). [verified-source]

## Q6. Unknown responses and `seq`
- Response routing is by `request_seq` only: `transport.rs:351-361`. If `request_seq` matches a pending Zed request, it completes it; otherwise the response goes to `message_handler(Message::Response(res))`, and the session loop (`session.rs:~918-946`) handles only `Message::Event` and `Message::Request`; a stray `Response` is silently ignored [verified-source]. So an un-swallowed response to an injected request is harmless UNLESS its `request_seq` collides with a pending Zed request id, in which case it would wrongly complete that request (and the real response then finds nothing pending).
- `seq` on adapter->client messages is never inspected: no monotonic or duplicate check anywhere in `transport.rs` / `client.rs` / `session.rs` (Zed's own counter is `sequence_count: AtomicU64`, starts at 1, `client.rs:34, 53, 168-170`, used only for its outgoing requests) [verified-source]. => The proxy does NOT need to rewrite adapter->client `seq`. It is still good hygiene (spec compliance) but not required for Zed.
- The real constraint is the other direction (client->adapter): Zed's request seqs are 1,2,3,... The proxy's injected requests need seqs that cannot collide with Zed's (e.g. start at 1_000_000_000, or rewrite) because the Flutter adapter / `dart` DAP code correlates responses by `request_seq`. [verified-source for Zed's counter; adapter side [unverified]]

## Q7. Restart button and `capabilities` event
- Toolbar button "Rerun Session" (`debugger_panel.rs:863-880`) calls `rerun_session` (`running.rs:1865-1891`). If the scenario has a `build` step it starts a fresh debug session; otherwise it calls `Session::restart` [verified-source].
- `Session::restart` (`session.rs:2216-2245`): if `capabilities.supports_restart_request` is true and the session is not terminated, sends DAP `restart` (with `Null` args, so `arguments` may be `null`/absent). If that fails, or the capability is false, it emits `SessionStateEvent::Restart` which makes `handle_restart_request` (`debugger_panel.rs:374-433`) shut the session down and boot a brand-new session with the same binary - i.e. our proxy and `flutter debug_adapter` would be re-spawned [verified-source].
- Therefore: the proxy should advertise `supportsRestartRequest: true` (it does if the adapter does, after `flutter.appStarted`/`capabilities` event) and answer `restart` by performing hot restart, otherwise Rerun = full cold restart.
- `capabilities` event IS handled: `session.rs:1611-1635` merges `event.capabilities` into `self.capabilities` (so `supportsRestartRequest` set mid-session takes effect) and refreshes exception-breakpoint filters [verified-source]. Initial capabilities come from the `initialize` response, and the proxy can also patch these in-flight.

## Q8. Adapter / debuggee stderr
- The adapter child's stderr is read line by line (`transport.rs:241-270` `handle_adapter_log`; stdio spawn at `transport.rs:722-733`; TCP at `575-596`), each line `log::debug!`ed and forwarded to handlers of kind `LogKind::Adapter` as `IoKind::StdErr` [verified-source].
- `debugger_tools/src/dap_log.rs` registers those handlers (`dap_log.rs:~395-450`) and renders them as "stderr: <line>" in the "Adapter Logs" view (`dap_log.rs:321, 939`), opened via the `dev: open debug adapter logs` action (`OpenDebugAdapterLogs`, `dap_log.rs:955-973`) [verified-source]. Adapter stderr is therefore visible only there, not in the debugger console, and the view is a developer tool (not discoverable by end users). The `Rpc` view (all DAP messages) is gated by the `log_dap_communications` setting (`transport.rs:~176`), the stderr log is not [verified-source].
- Whether the Adapter Logs view captures lines written before the view is opened is [unverified] (handlers are registered at session start, per code above, so probably yes).

## Recommendation (how the proxy should surface status)
1. Primary channel: DAP `output` events from the proxy to Zed, `category: "console"` (or `"stdout"`), with ANSI colour in the text, e.g. `"\u001b[32mHot reload: 1.2s\u001b[0m\n"`, `"\u001b[31mHot reload failed: ...\u001b[0m\n"`. This is the only user-visible path that renders in the debugger console with colours. Category/`important`/`group` give nothing extra, so do not depend on them; set `important` for other clients but expect the same display in Zed. Always end with `\n` and give compile errors as multi-line text (Zed trims trailing whitespace, keeps inner newlines). Include a stable prefix (`[flutter-run]`) so users can tell proxy messages from app output.
2. "No session running" and similar CLI-side errors should be returned to the CLI over the localhost control channel (stdout/exit code of the CLI), not through Zed; additionally, if a session exists, mirror it as an `output` event.
3. Do not use `ErrorResponse.showUser`, `window/showMessage`-style notifications, progress events or custom events for user messaging: Zed ignores `showUser`, ignores progress (and advertises it unsupported), and silently drops unknown events. A proxy-side notification via the OS (e.g. `notify-send`) or a Zed task is the only way to get a toast; treat as optional.
4. Keep proxy diagnostics on stderr (visible in `dev: open debug adapter logs`) for debugging only.
5. Injected requests: use a disjoint seq range (e.g. >= 1_000_000_000) toward the adapter, swallow their responses (do not forward), and wrap the hot-reload result into an `output` event. No seq rewriting of adapter->client messages is needed for Zed, but renumbering them is harmless and spec-correct; if done, keep it monotonic. If a response leaks, Zed ignores it unless `request_seq` collides with a pending Zed request.
6. Make sure every frame is valid DAP with `Content-Length` and, for events, a `body` field; a malformed frame ends the session.
7. Hot restart: advertise `supportsRestartRequest: true` (forward the adapter's `capabilities` event) so Zed's Rerun button sends DAP `restart` (hot restart) rather than tearing the session down.
8. Optional: rewrite `supportsProgressReporting` to `true` toward the adapter, then convert `progressStart/End` from Flutter ("Launching lib/main.dart...") into plain `output` lines, since Zed will not display them.

## Unverified / open items
- Behaviour was derived from source only; nothing run in a real Zed build.
- Exact failure mode if a custom event has no `body` (see Q2).
- How a failing boot (`initialize`/`launch` error) is displayed in the UI; only the console message "Tried to launch debugger with: ..." was found.
- Whether Zed's Rerun button is shown/enabled when `supportsRestartRequest` is false at button time (button always rendered in `debugger_panel.rs:863`, falls back to full restart).
- Flutter adapter's handling of `seq` collisions and of a null `restart` argument (adapter side, not covered here).
