# Testing in Zed

The automated tests drive the real debug adapters but cannot press keys in Zed. Run this checklist before a release and after any change to the extension, the proxy's start or stop path, the tasks or the keymap. It takes about half an hour.

When a step fails, these are the places to look:

- The **Console** tab of Zed's debug panel, for `[flutter_run]` notices.
- `zed: open log`, for extension errors.
- `dev: open debug adapter logs`, for the protocol traffic Zed saw.
- The proxy's own log: add `"logFile": "/tmp/flutter_run.log"` to the scenario.

## Set up

1. Build the tool onto your `PATH`:
   ```sh
   cd cli && dart pub get && dart compile exe bin/flutter_run.dart -o ~/.local/bin/flutter_run
   flutter_run doctor
   ```
2. Start Zed from a terminal, so it sees the same `PATH`. Run `zed: install dev extension` and choose the `extension/` folder. The first build takes a few minutes.
3. Make a scratch project:
   ```sh
   cp -r fixtures/sample_app /tmp/sample_app && cd /tmp/sample_app
   flutter pub get && flutter_run init
   zed .
   ```
4. Paste the keymap snippet printed by `init` into your keymap (`zed: open keymap file`).

## Checklist

**Launch and debug**

- [ ] F4 lists **Flutter: Debug**, **Flutter: Run (no debug)**, **Flutter: Profile** and **Flutter: Attach**.
- [ ] Zed's Dart extension still gives hover, completion and diagnostics in `lib/main.dart`.
- [ ] The **Flutter: Select Device** task lists devices and saves the one you pick.
- [ ] **Flutter: Debug** starts the app. The console shows `[flutter_run] Using device ...` and `[flutter_run] Reload on save is on for lib/ ...`.
- [ ] A breakpoint on `lib/main.dart` line 7 is hit. Variables show `x`. Step over and continue work.

**Hot reload and restart**

- [ ] Change `kGreeting` and save. The console shows `[flutter_run] Hot reload on save: lib/main.dart` and the app updates.
- [ ] Save again without changing anything. Nothing reloads.
- [ ] Save a syntax error. The console shows a reload failure that suggests hot restart. Fix it and save; the reload succeeds.
- [ ] Ctrl+F5 hot reloads. The task terminal hides itself on success.
- [ ] Ctrl+Shift+F5 hot restarts: `main()` runs again.
- [ ] Zed's own restart button works, and the app is not left running twice.

**DevTools**

- [ ] The **Flutter: Open DevTools** task opens the inspector in your browser, connected to the app.

**Stop**

- [ ] Shift+F5 closes the app within a few seconds.
- [ ] `flutter_run status` reports no sessions.
- [ ] Nothing is left running:
  ```sh
  pgrep -af 'flutter_tester|sample_app|flutter_run|development-service|frontend_server|debug_adapter' || echo none
  ```
- [ ] Closing the Zed window during a session also leaves nothing running.

**Attach**

- [ ] Run `flutter run -d linux` in a terminal and copy the VM service address. Put it in the **Flutter: Attach** scenario as `"vmServiceUri"`, with `"toolArgs": ["-d", "linux"]`. Attaching works, breakpoints hit and hot reload works.
- [ ] Stopping in Zed detaches. The app and `flutter run` keep running.

**Errors**

- [ ] With no saved device (`flutter_run select-device --clear`) and several devices available, launching fails with a hint to run **Flutter: Select Device**.
- [ ] With `flutter_run` off `PATH` and `dap.FlutterRun.binary` set in Zed settings, debugging works and the console warns once that the tasks cannot run.
- [ ] With `flutter_run` nowhere to be found, the session fails with a message that says how to install it.
- [ ] `"flutterSdkPath": "/nonexistent"` fails with a message that lists where the SDK was looked for.

**Dart program**

- [ ] In a copy of `fixtures/dart_console`, `flutter_run init` writes a **Dart: Debug bin/main.dart** scenario. A breakpoint on line 11 is hit and the program runs to the end.

## Other platforms

**macOS.** Also start Zed from the Dock: it may not see your shell's `PATH`, so check the `dap.FlutterRun.binary` setting works. The F keys need `fn` unless you changed the keyboard setting, and hot restart is Shift+Cmd+F5.

**Windows.** Use a compiled `flutter_run.exe`, not the `.bat` launcher from pub. After stopping, check for leftovers with `tasklist | findstr /i "dart flutter"`.
