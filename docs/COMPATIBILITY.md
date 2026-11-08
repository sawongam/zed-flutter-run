# Compatibility

Status values: **CI** means exercised by GitHub Actions. **Manual** means a person ran it. **Untested** means nobody has run it. As of 2026-11-08 nothing has been tested manually, so no row says Manual.

## Support policy

- **Flutter:** the latest stable release (CI runs the pinned 3.47.9 and `beta`). Building and testing `flutter_run` needs Dart 3.13+ because of the test dependencies. Older Flutter SDKs used only as the runtime `flutter debug_adapter` are untested.
- **Zed:** the latest stable release. The extension uses extension API 0.7.0, which needs Zed 0.205 or newer according to the `zed_extension_api` README.
- **OS:** Linux, macOS and Windows.
- Older versions may work. They are not tested.

## Zed

| Zed version | Status |
|---|---|
| Latest stable | Untested (never run in real Zed) |
| 0.205 to previous stable | Untested |
| Older than 0.205 | Not supported (no debugger extension API) |

The Zed side was checked by reading Zed's source only.

## Flutter and Dart

| Flutter | Dart | Headless suite (`flutter-tester`) | Notes |
|---|---|---|---|
| 3.47.9 (pinned in CI) | 3.13.7 | CI (Linux) | Original verification run too |
| 3.47.0 | 3.13.0 | Manual, maintainer's Arch machine, headless suite only (not in real Zed) | Fixture constraint lowered to `^3.5.0` |
| Older than 3.47 | < 3.13 | Untested | Not in CI: the test suite needs Dart 3.13+ |
| Other | | Untested | |

## Operating systems

| OS | Unit tests | Dart adapter integration | Flutter integration | Compiled binary | Used by hand |
|---|---|---|---|---|---|
| Linux | CI | CI | CI | CI | Manual: headless suite only |
| macOS | CI | CI | Untested | CI | Untested |
| Windows | CI | CI | Untested | CI | Untested |

On Windows, the `flutter.bat` launch path, hot reload on a Flutter app and the browser launch for DevTools are untested.

## Device types

Only the headless `flutter-tester` device has been used (CI on Linux).

| Device | Status |
|---|---|
| `flutter-tester` (headless) | CI |
| Android emulator | Untested |
| Android phone | Untested |
| iOS simulator | Untested |
| iOS phone | Untested |
| Linux, macOS, Windows desktop | Untested |
| Chrome (web) | Untested |

## Reporting results

Ran something on a combination marked Untested? Open an issue with your Zed, Flutter and OS versions and the output of `flutter_run doctor`. The checklist is [MANUAL_ZED_TEST.md](MANUAL_ZED_TEST.md).
