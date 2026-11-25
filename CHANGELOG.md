# Changelog

This project follows [Semantic Versioning](https://semver.org/). The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

- Every command now uses colour in a terminal, not only `doctor`, `devices` and error lines. This covers `help` and `--help` (headings, flags, command names and exit codes), `init`, `keymap`, `select-device`, `emulators`, `reload`, `restart`, `status` and `devtools`. The text is the same as before, and the colour rules have not changed.
- `devtools` prints a browser failure as `error:` and `hint:`, like the other commands. A usage error now starts with `error:`.

## [0.1.3]

- Release process fix. No change in behaviour.

## [0.1.2]

- Coloured output for `doctor`, `devices` and error lines when the stream is a terminal. Respects `NO_COLOR`; `FORCE_COLOR` turns it on for pipes.

## [0.1.1]

Documentation release. No change in behaviour.

- The README and the pub.dev package page now say that `flutter_run` is on pub.dev and install with `dart pub global activate flutter_run`.
- Removed the preview notice. The docs describe how releases are checked, in CI and by hand in Zed.
- Windows install points to the prebuilt `.exe` on the release page.

## [0.1.0]

First preview release.

- Zed extension `flutter-run-debugger` with the debug adapter `FlutterRun`.
- `flutter_run` command-line tool and debug adapter proxy.
- Launch and attach for Flutter apps and Dart programs, with breakpoints, stepping, variables and the debug console.
- Hot reload and hot restart from tasks and key bindings, and hot reload on save.
- Device picker, emulator launcher and DevTools.
- Flutter SDK discovery: explicit path, `FLUTTER_RUN_FLUTTER_SDK`, FVM, Puro, `FLUTTER_ROOT`, then `PATH`.
- `flutter_run init` writes `.zed/debug.json` and `.zed/tasks.json`. It takes entry points and flavors from `.vscode/launch.json` or `lib/main_<flavor>.dart`, watches local path packages for reload on save, and merges into files with comments.
- `flutter_run keymap` adds the hot reload, hot restart and DevTools keys to the Zed keymap, with your own keys if you like, and warns about known key clashes.
- A hot restart pressed while a reload runs waits for it instead of failing, and pressing a key twice joins the running action.
