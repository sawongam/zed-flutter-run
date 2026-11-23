# Privacy

**No telemetry.** Nothing in this project collects usage data, crash reports or identifiers, and nothing phones home.

## Network use

| What | When | Where to |
|---|---|---|
| Download of the `flutter_run` binary | Release builds of the Zed extension, only when no `dap.FlutterRun.binary` setting and no `flutter_run` on PATH is found | GitHub releases of `sawongam/zed-flutter-run`. The SHA-256 is pinned in the extension and checked before use. Dev builds never download |
| Control channel | While a debug session runs | Loopback only (`127.0.0.1`) on your machine, with a per-session token |
| Flutter and Dart tools | When you debug | Whatever `flutter`, `dart` and your app do. Their own telemetry settings apply, not ours |
| Browser | When you open DevTools | Your default browser opens a local DevTools URL |

## Files

State (saved device, session files) lives in a per-user folder, see [CONFIGURATION.md](CONFIGURATION.md#environment-variables). Log files exist only when you set `logFile` or `FLUTTER_RUN_LOG`. They can contain your app's output and the full debug protocol traffic. Check them before sharing.

No project data leaves your machine through this tool. See [SECURITY.md](../SECURITY.md) for the security model.
