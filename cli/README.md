# flutter_run

Command-line tool and Debug Adapter Protocol (DAP) proxy for **Flutter Run & Debug in the [Zed](https://zed.dev) editor**. It adds hot reload, hot restart, reload on save, a device picker and DevTools to Zed's debugger. It is the Dart half of [zed-flutter-run](https://github.com/sawongam/zed-flutter-run); the other half is a small Rust Zed extension.

> **Status: 0.1.0 preview.** Tested headlessly in CI on Linux, macOS and Windows. Not yet tested in a real Zed session or on a real device. Not published to pub.dev yet.

## Install

Until it is on pub.dev, install from Git (needs the Dart SDK 3.8 or newer):

```sh
dart pub global activate --source git https://github.com/sawongam/zed-flutter-run --git-path cli
```

Put `~/.pub-cache/bin` (Windows: `%LOCALAPPDATA%\Pub\Cache\bin`) on your PATH, then:

```sh
flutter_run doctor
```

## Use

```sh
cd my_flutter_app
flutter_run init        # writes .zed/debug.json and .zed/tasks.json
```

Then open the project in Zed, press F4 and pick **Flutter: Debug**. You also need the Zed extension; see the [main README](https://github.com/sawongam/zed-flutter-run#readme).

Commands: `init`, `reload`, `restart`, `status`, `devices`, `select-device`, `emulators`, `devtools`, `doctor`, `version` and `dap` (started by the extension).

## Documentation

- [Configuration reference](https://github.com/sawongam/zed-flutter-run/blob/master/docs/CONFIGURATION.md)
- [Compatibility](https://github.com/sawongam/zed-flutter-run/blob/master/docs/COMPATIBILITY.md)
- [Troubleshooting](https://github.com/sawongam/zed-flutter-run/blob/master/docs/TROUBLESHOOTING.md)
- [Privacy](https://github.com/sawongam/zed-flutter-run/blob/master/docs/PRIVACY.md): no telemetry
- [Security policy](https://github.com/sawongam/zed-flutter-run/blob/master/SECURITY.md)

Not affiliated with, endorsed by or sponsored by Google, Flutter, Dart or Zed Industries.

## License

BSD 3-Clause, see [LICENSE](LICENSE).
