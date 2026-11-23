# Releasing

For maintainers. A release has an order that matters, because the extension carries the SHA-256 of each release binary and so must be finished after the binaries exist:

```
version bump on `dev` -> merge `dev` into `prod` -> CI builds binaries, tags and publishes the GitHub release -> pin checksums -> pub.dev -> Zed registry
```

Examples below use `0.1.0`.

## One-time repository setup

Do this before the first release.

- **Environment** `pub.dev` (Settings > Environments), with yourself as required reviewer and deployment limited to `v*` tags. It gates `publish-pub.yml`. Without it that job runs without asking.
- **Rules for `dev` and `prod`:** require pull requests and the CI checks, block force pushes. `dev` is the default branch where work lands. `prod` only receives merges from `dev`. Add a tag rule for `v*` that blocks updates and deletion.
- **Security:** enable private vulnerability reporting and secret scanning with push protection.
- **Labels:** run the `Sync labels` workflow once.

## Manual test in Zed

The automated tests drive the real debug adapters but cannot press keys in Zed. Run this checklist before a release and after any change to the extension, the proxy's start or stop path, the tasks or the keymap. It takes about half an hour.

When a step fails, these are the places to look:

- The **Console** tab of Zed's debug panel, for `[flutter_run]` notices.
- `zed: open log`, for extension errors.
- `dev: open debug adapter logs`, for the protocol traffic Zed saw.
- The proxy's own log: add `"logFile": "/tmp/flutter_run.log"` to the scenario.

### Set up

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
4. Run `flutter_run keymap` to add the hot reload and hot restart keys.

### Checklist

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

### Other platforms

**macOS.** Also start Zed from the Dock: it may not see your shell's `PATH`, so check the `dap.FlutterRun.binary` setting works. The F keys need `fn` unless you changed the keyboard setting, and hot restart is Shift+Cmd+F5.

**Windows.** Use a compiled `flutter_run.exe`, not the `.bat` launcher from pub. After stopping, check for leftovers with `tasklist | findstr /i "dart flutter"`.

## 1. Before you release

- [x] CI is green on `dev`.
- [x] You ran the [manual test in Zed](#manual-test-in-zed) on this commit.
- [x] The version is the same in all five places. Edit:
  1. `cli/pubspec.yaml`
  2. `cli/lib/src/common/version.dart`
  3. `extension/Cargo.toml` (then run `cargo check` in `extension/` to update `Cargo.lock`)
  4. `extension/extension.toml`
  5. `extension/src/install.rs` (`PROXY_VERSION`)

  Check with `sh .github/scripts/check-versions.sh`.
- [x] `CHANGELOG.md` has a `## [0.1.0] - YYYY-MM-DD` section with the date filled in. The release workflow takes the release notes from it and fails if it is missing. Copy the section to `cli/CHANGELOG.md` for pub.dev.
- [x] The README install section is true for this release.

## 2. Push and build

Merge `dev` into `prod` with the version bumped. There is no tag to push. `release.yml` runs when a push to `prod` changes `cli/pubspec.yaml` to a version that has no GitHub release yet, and does nothing otherwise. It creates the tag `v0.1.0` on that commit itself. It compiles `flutter_run` on five runners and produces:

| Asset | Runner |
|---|---|
| `flutter_run-v0.1.0-linux-x64` | `ubuntu-latest` |
| `flutter_run-v0.1.0-linux-arm64` | `ubuntu-24.04-arm` |
| `flutter_run-v0.1.0-macos-arm64` | `macos-latest` |
| `flutter_run-v0.1.0-macos-x64` | `macos-15-intel` |
| `flutter_run-v0.1.0-windows-x64.exe` | `windows-latest` |
| `SHA256SUMS` | |

The asset names come from the version in `cli/pubspec.yaml` and must match what `asset_name` in `extension/src/install.rs` computes.

Each file gets a build provenance attestation. Anyone can check one:

```sh
gh attestation verify flutter_run-v0.1.0-linux-x64 --repo sawongam/zed-flutter-run
```

## 3. Check the GitHub release

The workflow publishes the release with the six files and the notes from `CHANGELOG.md`. Then:

- [ ] Download the binary for your platform, run `flutter_run version` and `flutter_run doctor`.
- [ ] Check `sha256sum -c SHA256SUMS`.

Never replace an asset on a release. The checksums are about to be compiled into the extension, and a changed file would fail verification for every user. Fix a bad release with a new patch version.

The binaries are not signed. Add this to the release notes by editing the release:

- **macOS:** a binary downloaded with a browser is quarantined. Remove the flag with `xattr -d com.apple.quarantine flutter_run`. Downloads made by `curl`, pub or the Zed extension are not affected.
- **Windows:** SmartScreen warns on first run. Choose **More info > Run anyway**.

## 4. Pin the checksums

```sh
gh release download v0.1.0 --pattern SHA256SUMS --dir /tmp/release
sh .github/scripts/pin-checksums.sh /tmp/release/SHA256SUMS > extension/src/checksums.rs
git diff extension/src/checksums.rs    # five entries, one per asset
cd extension && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test && cargo build --release --target wasm32-wasip2
```

Commit this as `chore(release): pin v0.1.0 checksums` and push. This commit, not the tagged one, is what the Zed registry will point at.

- [ ] Test the download: install the extension from this commit as a dev extension, take `flutter_run` off your `PATH`, unset `dap.FlutterRun.binary` and start a debug session. The extension should download the binary, verify it, and start. The console warns that `flutter_run` is not on `PATH`, which is correct.

## 5. pub.dev

The first publish of a new package must be done by hand. Published versions cannot be deleted.

```sh
cd cli
dart pub publish --dry-run    # fix every warning and read the file list
dart pub publish
```

Afterwards:

- [ ] On pub.dev, open the package's **Admin** tab and enable automated publishing from `sawongam/zed-flutter-run` with the tag pattern `v{{version}}` and the environment `pub.dev`. Later releases publish when you run `publish-pub.yml` by hand from the release tag, after your approval.
- [ ] Set `PUBLISHED_ON_PUB` to `true` in `extension/src/install.rs`, so the "not found" message also suggests `dart pub global activate flutter_run`. Run `cargo test` and commit.

## 6. Zed extension registry

Zed's registry does not accept contributions from autonomous agents. Write the pull request and every reply yourself. Expect the first review to take several weeks, and answer feedback within three weeks or the pull request is closed.

Check first:

- [ ] `extension/extension.toml` has the version you are registering and a real name in `authors`.
- [ ] `extension/LICENSE` is the unmodified BSD 3-Clause text. A licence only at the repository root does not count.
- [ ] The commit you submit is on `prod`, contains the pinned checksums, and is the one you tested in Zed.

Then, in a fork of `zed-industries/extensions` under your personal account:

```sh
git checkout -b add-flutter-run-debugger
git submodule add https://github.com/sawongam/zed-flutter-run.git extensions/flutter-run-debugger
git -C extensions/flutter-run-debugger checkout <commit>
```

Add to `extensions.toml`. The `path` is needed because the extension is in a subfolder:

```toml
[flutter-run-debugger]
submodule = "extensions/flutter-run-debugger"
path = "extension"
version = "0.1.0"
```

Run `pnpm install && pnpm sort-extensions`, commit, and open the pull request.

Reviewers aim for one extension per use case, so expect to be asked why this is not part of the Dart extension. The points to make, in your own words:

- It is a debugger-only extension. It adds no language, grammar or language server, and uses its own adapter name, so it works next to the Dart extension without conflict.
- Hot reload, reload on save, device selection and DevTools need a process in the middle of the debug protocol stream. That cannot be done inside the Dart extension with today's extension API. The proposals that would have allowed it (`zed-industries/zed#51873`, `zed-extensions/dart#72`) were closed.
- It bundles no binaries. The tool is found on `PATH` or downloaded from this repository's releases after a checksum check, and the download capability is limited to this repository.

To update the registry later, move the submodule to the new commit and change `version` in `extensions.toml`. A new `flutter_run` version always needs a new release, new pinned checksums and a new extension version together.

## 7. After the release

- [ ] The release page lists six files and the download addresses work.
- [ ] `dart pub global activate flutter_run` on a clean machine gives a working `flutter_run doctor`.
- [ ] Once the registry lists the extension: install it from `zed: extensions` and start a debug session with and without `flutter_run` on `PATH`.
- [ ] Update the README install section with the real commands.
