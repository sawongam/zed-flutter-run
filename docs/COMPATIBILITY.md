# Compatibility

## What is supported

| | Supported |
|---|---|
| Zed | The latest stable release. The minimum is 0.205, the first version with debugger extensions |
| Flutter | The latest stable release. CI also runs against `beta` |
| Operating systems | Linux, macOS and Windows |

Older Flutter versions may work as long as they ship `flutter debug_adapter`, but they are not tested.

## What is tested

Every push runs these on GitHub Actions:

| | Linux | macOS | Windows |
|---|---|---|---|
| Unit tests | Yes | Yes | Yes |
| Dart debug adapter through the compiled proxy (launch, breakpoints, stop, crash cleanup) | Yes | Yes | Yes |
| Flutter debug adapter through the compiled proxy (launch, breakpoints, hot reload, hot restart, reload on save, attach, DevTools address, stop) | Yes | No | No |
| Compiled binary builds and runs | Yes | Yes | Yes |
| Extension builds for `wasm32-wasip2` | Yes | | |

The Flutter suite uses the headless `flutter-tester` device. Real devices are not part of CI:

| Device | Status |
|---|---|
| Linux, macOS, Windows desktop | Not covered by CI |
| Android emulator and phone | Not covered by CI |
| iOS simulator and phone | Not covered by CI |
| Chrome and web server | Not covered by CI |

If you use one of these, a short report in an [issue](https://github.com/sawongam/zed-flutter-run/issues) helps a lot: include your Zed, Flutter and OS versions and the output of `flutter_run doctor`. [TESTING_IN_ZED.md](TESTING_IN_ZED.md) lists what to try.

## Known limitations

**From Zed**

- Zed has no extension API for toolbar buttons, a status bar device selector or on-save hooks. Hot reload, hot restart, device selection and DevTools are tasks and key bindings, and reload on save uses the proxy's own file watcher.
- Zed tasks can only run commands on `PATH`, so `flutter_run` must be installed separately from the extension.
- There is no key for "run without debugging". Choose **Flutter: Run (no debug)** from the F4 list.

**From Flutter and Dart**

- For plain Dart programs, breakpoints and hot reload work. Hot restart and DevTools do not, because `dart debug_adapter` does not support them.
- `vmServiceInfoFile` must contain JSON of the form `{"uri": "..."}`. The file written by `flutter run --vmservice-out-file` is a bare address, and Flutter's adapter waits forever on it. Use `vmServiceUri` instead.
- DevTools is served by the Dart Development Service. Attach sessions run without it, so `flutter_run devtools` is not available while attached.

**From this project**

- Reload on save watches `lib/`, `bin/` for Dart programs, and folders named in `reloadOnSaveGlobs`. Edits in a sibling package of a monorepo do not trigger a reload unless you add a glob for it.
- If the proxy is killed with `SIGKILL`, the app and the debug adapter can be left running, and the session file stays until the next `flutter_run status` or `flutter_run reload` removes it. Zed's normal stop does not do this.
- On Windows, finding leftover child processes needs PowerShell or `wmic`. Without either, cleanup after an adapter crash can miss processes.
- On Windows, the `flutter_run.bat` launcher created by `dart pub global activate` cannot be used by Zed's debugger. Use a compiled `flutter_run.exe`.
