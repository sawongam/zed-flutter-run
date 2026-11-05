# Release guide (human-run)

**An agent must not do any of these steps.** Everything below publishes something under your name (a GitHub release, a pub.dev package, a Homebrew tap, a Scoop bucket, a Zed registry PR), and the Zed registry explicitly bans autonomous agents from contributing ([AI_POLICY](research/zed-extension-registry.md), section 0). The release workflow (`.github/workflows/release.yml`) only builds artifacts; it never creates a release or publishes anywhere.

Example version used throughout: `0.1.0`. Repository: `sawongam/zed-flutter-run`. Replace as needed.

Order matters because the extension pins SHA-256 checksums of the release binaries:

```
pre-flight -> bump versions -> tag -> build artifacts -> verify -> GitHub release -> pin checksums (next commit)
          -> pub.dev -> Homebrew / Scoop -> Zed registry PR -> post-release checks
```

## 1. Pre-flight

- [ ] **Names are still free** ([research/naming.md](research/naming.md), [ADR 0005](decisions/0005-project-names.md); availability is not a reservation):
  ```sh
  curl -s -o /dev/null -w 'pub.dev flutter_run: %{http_code}\n' https://pub.dev/api/packages/flutter_run          # 404 = free (200 only if it is yours)
  curl -s https://raw.githubusercontent.com/zed-industries/extensions/main/extensions.toml | grep -n '^\[flutter-run-debugger\]' || echo "registry id free"
  gh search code '"debug_adapters.FlutterRun"' --filename extension.toml   # expect no foreign repos
  ```
  Also look at the Homebrew formulae/casks and Scoop buckets for `flutter_run` if you plan to publish there under your own tap (a tap name cannot clash, but the command name should not shadow a core formula).
- [ ] **Read docs.flutter.dev/brand** once (it is blocked in the agent environment). Confirm the README/extension text uses "Flutter" descriptively only, carries the "not affiliated with Google, Flutter or Zed Industries" disclaimer, and uses no Flutter logo or colours. ADR 0005 requires this before the first public release.
- [ ] **Docs the release points at.** The root `README.md`, `CHANGELOG.md`, `SECURITY.md` and `CONTRIBUTING.md` already exist; do not overwrite them. Verify that the README "Install" section (cited by the error messages in `extension/src/install.rs` and `cli/lib/src/cli/*.dart`) matches reality for this release. Still missing, wanted for pub.dev: `cli/README.md` and `cli/CHANGELOG.md`. Also in the GitHub repository settings enable Issues and "Private vulnerability reporting" (`SECURITY.md` and `CODE_OF_CONDUCT.md` point reporters there).
- [ ] **The code is on `master` of `sawongam/zed-flutter-run` (fresh history since 2026-11-05) and CI is green** (`.github/workflows/ci.yml`: version check, Dart tests on three OSes, Rust fmt/clippy/test/wasm build, Linux integration). Run [MANUAL_ZED_TEST.md](MANUAL_ZED_TEST.md) and paste the results table into `docs/conversations/`. Do not release with an unexplained FAIL there.
- [ ] **Bump the version in five places** (they must be equal; `check-versions.sh` enforces it):
  1. `cli/pubspec.yaml` (`version:`)
  2. `cli/lib/src/common/version.dart` (`packageVersion`)
  3. `extension/Cargo.toml` (`version =`)
  4. `extension/extension.toml` (`version =`)
  5. `extension/src/install.rs` (`PROXY_VERSION`)

  Then refresh the lock file and check: `(cd extension && cargo check)` (updates the `flutter_run_debugger` entry in `Cargo.lock`), `sh .github/scripts/check-versions.sh` (expect `OK: all versions match (0.1.0)`), `(cd cli && dart test --exclude-tags integration --exclude-tags integration-dart)` (a unit test compares `packageVersion` with the pubspec).
- [ ] **CHANGELOG**: `CHANGELOG.md` uses Keep a Changelog style (`## [Unreleased]`, `## [0.1.0] - unreleased`). Change `unreleased` to the release date (`## [0.1.0] - YYYY-MM-DD`), keep an empty `## [Unreleased]` above it, and copy the text to `cli/CHANGELOG.md`.
- [ ] Commit ("release: 0.1.0") on `master` and push. This is the commit that gets tagged; it still has an empty `extension/src/checksums.rs`, which is intended (the checksums come in the next commit).

## 2. Build the binaries

The workflow runs on `v*` tag pushes and on manual dispatch. It builds `dart compile exe bin/flutter_run.dart` on five runners and uploads one artifact per platform plus `SHA256SUMS`. It does **not** create a release.

Asset names must be exactly what `extension/src/install.rs::asset_name` computes, because the checksums are looked up by name. The workflow derives the name from the ref name (`flutter_run-$GITHUB_REF_NAME-<target>`), so **run it on the tag**, not on a branch: a dispatch on `master` produces `flutter_run-master-linux-x64`, which the extension will never find.

```sh
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0          # starts the workflow
# or, to rebuild an existing tag by hand:
gh workflow run release.yml --repo sawongam/zed-flutter-run --ref v0.1.0
gh run watch --repo sawongam/zed-flutter-run
```

Expected artifacts:

| Artifact name | Runner |
|---|---|
| `flutter_run-v0.1.0-linux-x64` | ubuntu-latest |
| `flutter_run-v0.1.0-linux-arm64` | ubuntu-24.04-arm |
| `flutter_run-v0.1.0-macos-arm64` | macos-latest |
| `flutter_run-v0.1.0-macos-x64` | macos-15-intel |
| `flutter_run-v0.1.0-windows-x64.exe` | windows-latest |
| `SHA256SUMS` | ubuntu-latest (`sha256sum flutter_run-*`, lines `<hex>  <asset>`) |

Each build ran `<binary> version` as a smoke test. The Linux binaries are built on current Ubuntu runners (new glibc); say in the release notes that older distributions may not run them. Windows on ARM uses the x64 binary under emulation (the extension maps it); there is no separate asset.

## 3. Download and verify

```sh
RUN=$(gh run list --repo sawongam/zed-flutter-run --workflow release.yml --limit 1 --json databaseId -q '.[0].databaseId')
rm -rf dist release && mkdir release
gh run download "$RUN" --repo sawongam/zed-flutter-run -D dist
find dist -type f -exec mv {} release/ \;
cd release && ls -l
sha256sum -c SHA256SUMS         # every line must say OK  (macOS: shasum -a 256 -c SHA256SUMS)
```

- [ ] Five binaries plus `SHA256SUMS`, all checksums OK, names exactly as in the table above.
- [ ] Run the binary for your platform: `chmod +x flutter_run-v0.1.0-linux-x64 && ./flutter_run-v0.1.0-linux-x64 version` prints `flutter_run 0.1.0`; `... doctor` works.
- [ ] Optionally test the macOS and Windows binaries on those machines (artifact download strips the executable bit; GitHub release assets carry none either, which is why the extension calls `make_file_executable` and the Homebrew formula uses `bin.install`).
- [ ] Keep this exact `SHA256SUMS` file. It is the source for the pinned checksums.

### macOS signing and notarization

`dart compile exe` output is ad-hoc signed (CI prints `codesign -dv`), which is enough to run on Apple Silicon, but it is not notarized. Consequences for v0.1.0:

- A binary downloaded **in a browser** gets the quarantine attribute and Gatekeeper refuses it ("cannot be opened because the developer cannot be verified"). Workarounds to document: `xattr -d com.apple.quarantine flutter_run`, or install through Homebrew / `curl` / `dart pub global activate` / the Zed extension's own download, none of which set quarantine.
- To ship a properly signed binary you need an Apple Developer ID (paid program): `codesign --force --options runtime --timestamp --sign "Developer ID Application: <name> (<team>)" flutter_run`, then submit a zip with `xcrun notarytool submit --wait`. A bare executable cannot be stapled; Gatekeeper checks online. Dart AOT executables need the right entitlements under the hardened runtime and re-signing can break them; [unverified], test the signed binary with `flutter_run doctor` and a real debug session before shipping it. Not required for 0.1.0; decide for a later release.

### Windows SmartScreen

The `.exe` is unsigned. A browser download shows "Windows protected your PC": More info > Run anyway (or `Unblock-File .\flutter_run.exe`). Files fetched by Scoop, `dart pub global activate` or the extension's download do not carry the Mark-of-the-Web. Reputation builds over downloads; signing options for later: Azure Trusted Signing, SignPath (free for open source), or an EV/OV certificate.

## 4. Create the GitHub release (manual)

```sh
cd release
gh release create v0.1.0 \
  flutter_run-v0.1.0-linux-x64 \
  flutter_run-v0.1.0-linux-arm64 \
  flutter_run-v0.1.0-macos-arm64 \
  flutter_run-v0.1.0-macos-x64 \
  flutter_run-v0.1.0-windows-x64.exe \
  SHA256SUMS \
  --repo sawongam/zed-flutter-run \
  --verify-tag \
  --title "v0.1.0" \
  --notes-file ../RELEASE_NOTES.md      # your text: changes, install steps, checksums, the unsigned-binary notes above
```

Add `--draft` first if you want to look at it before it is public. Then check the exact URL the extension will use:

```sh
curl -fsSLo /tmp/check https://github.com/sawongam/zed-flutter-run/releases/download/v0.1.0/flutter_run-v0.1.0-linux-x64
sha256sum /tmp/check     # must equal the line in SHA256SUMS
```

**Never replace or re-upload an asset of a published tag.** The checksums get pinned into the extension; a changed binary would fail verification for every user. A bad release is fixed with a new patch version.

## 5. Pin the checksums (next commit, not the tag commit)

```sh
cd <repo>
sh .github/scripts/pin-checksums.sh release/SHA256SUMS > extension/src/checksums.rs
git diff extension/src/checksums.rs        # exactly five (asset, hash) entries, names as in section 2
```

The script (POSIX `sh`; use Git Bash or WSL on Windows) validates 64-hex hashes and asset-name characters and writes `PINNED_SHA256` plus `pinned_sha256()`. Review that all five names are present: a missing platform gets the "flutter_run was not found" message instead of a download.

```sh
(cd extension && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test \
   && cargo build --release --target wasm32-wasip2)
git add extension/src/checksums.rs
git commit -m "release: pin v0.1.0 checksums"
git push origin master
```

Note that regenerating the file drops the unit tests that lived in the hand-written `checksums.rs` (`dev_build_has_no_pins`); that is expected.

- [ ] **Test the download path** with this commit: dev-install the extension (`zed: install dev extension` > `extension/`), make sure `flutter_run` is not on the PATH and `dap.FlutterRun.binary` is unset, start a session. Expected: the binary appears at Zed's extension work dir (`.../extensions/work/flutter-run-debugger/flutter_run-0.1.0/flutter_run`), debugging starts, a PATH notice appears in the Console (the downloaded copy is not on the PATH). This reverses step 15 of the manual test.

## 6. pub.dev

pub.dev needs a Google account. Published versions cannot be deleted (they can be retracted for a limited time and discontinued), so dry-run first.

```sh
cd cli
dart pub get
dart pub publish --dry-run     # fix every warning; look at the file list: no build/, no .dart_tool/, no secrets
dart pub publish               # opens a browser login the first time, asks for confirmation
```

- [ ] The dry run needs `cli/LICENSE` (present, BSD-3-Clause), `repository`/`issue_tracker` (present in `cli/pubspec.yaml`), and should have `cli/README.md` and `cli/CHANGELOG.md` (not yet in the repository; create them, see section 1).
- [ ] The package name `flutter_run` and `executables: flutter_run:` are already set. After publishing, `dart pub global activate flutter_run` installs the command. On Windows it creates a `flutter_run.bat` shim, which the extension deliberately ignores (it would orphan the real proxy); tell Windows users to use the release `.exe`.
- [ ] Optional: a verified publisher (pub.dev > Create publisher, DNS-verify a domain, then transfer the package). Not needed for 0.1.0.
- [ ] After publication, flip `PUBLISHED_ON_PUB` to `true` in `extension/src/install.rs` (the not-found message then also suggests `dart pub global activate flutter_run`), run `cargo test` in `extension/`, commit as a separate commit (the workflow header calls this "next commit, not the tag commit").

## 7. Homebrew tap and Scoop bucket

Optional for 0.1.0, easy to add later. Create two small public repositories: `sawongam/homebrew-tap` and `sawongam/scoop-bucket`. Use the hashes from `SHA256SUMS`.

`homebrew-tap/Formula/flutter_run.rb`:

```ruby
class FlutterRun < Formula
  desc "Flutter Run & Debug in Zed: DAP proxy and CLI (hot reload, devices, DevTools)"
  homepage "https://github.com/sawongam/zed-flutter-run"
  version "0.1.0"
  license "BSD-3-Clause"

  on_macos do
    on_arm do
      url "https://github.com/sawongam/zed-flutter-run/releases/download/v0.1.0/flutter_run-v0.1.0-macos-arm64"
      sha256 "<sha256 of flutter_run-v0.1.0-macos-arm64>"
    end
    on_intel do
      url "https://github.com/sawongam/zed-flutter-run/releases/download/v0.1.0/flutter_run-v0.1.0-macos-x64"
      sha256 "<sha256 of flutter_run-v0.1.0-macos-x64>"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/sawongam/zed-flutter-run/releases/download/v0.1.0/flutter_run-v0.1.0-linux-arm64"
      sha256 "<sha256 of flutter_run-v0.1.0-linux-arm64>"
    end
    on_intel do
      url "https://github.com/sawongam/zed-flutter-run/releases/download/v0.1.0/flutter_run-v0.1.0-linux-x64"
      sha256 "<sha256 of flutter_run-v0.1.0-linux-x64>"
    end
  end

  def install
    # The download is the bare executable; Homebrew stages it under its file name.
    bin.install Dir["flutter_run-v*"].first => "flutter_run"
  end

  test do
    assert_match "flutter_run #{version}", shell_output("#{bin}/flutter_run version")
  end
end
```

Users: `brew install sawongam/tap/flutter_run`. Test with `brew install --build-from-source ./Formula/flutter_run.rb && brew test flutter_run && brew audit --strict --new flutter_run` before pushing.

`scoop-bucket/bucket/flutter_run.json`:

```json
{
  "version": "0.1.0",
  "description": "Flutter Run & Debug in Zed: DAP proxy and CLI (hot reload, devices, DevTools)",
  "homepage": "https://github.com/sawongam/zed-flutter-run",
  "license": "BSD-3-Clause",
  "architecture": {
    "64bit": {
      "url": "https://github.com/sawongam/zed-flutter-run/releases/download/v0.1.0/flutter_run-v0.1.0-windows-x64.exe#/flutter_run.exe",
      "hash": "<sha256 of flutter_run-v0.1.0-windows-x64.exe>"
    }
  },
  "bin": "flutter_run.exe",
  "checkver": "github",
  "autoupdate": {
    "architecture": {
      "64bit": {
        "url": "https://github.com/sawongam/zed-flutter-run/releases/download/v$version/flutter_run-v$version-windows-x64.exe#/flutter_run.exe",
        "hash": {
          "url": "$baseurl/SHA256SUMS",
          "regex": "$sha256\\s+$basename"
        }
      }
    }
  }
}
```

Users: `scoop bucket add rdf https://github.com/sawongam/scoop-bucket` then `scoop install flutter_run`. Scoop puts a shim `.exe` (not `.bat`) on the PATH, which the extension accepts; because the shim starts the real binary as a child, verify on Windows that stopping a session leaves no `flutter_run.exe` process (the proxy exits on stdin EOF, ADR 0006 D1, but this combination has not been tested).

## 8. Zed registry submission (written and submitted by a human)

Rules: [research/zed-extension-registry.md](research/zed-extension-registry.md). Summary: `zed-industries/extensions` forbids autonomous agents; the PR text and every reply to maintainers must be in your own words (AI-assisted context only in quote blocks with your commentary). One extension per PR, at most 3 open PRs per person, reply to feedback within 3 weeks or the PR is closed as stale, fork into a **personal** account.

Prerequisites (all in this repo already; re-check):

- [ ] `extension/extension.toml`: `id = "flutter-run-debugger"` (kebab-case, no "zed"/"extension", `-debugger` suffix for debugger-only extensions), `name = "Flutter Run & Debug"` (no "Zed"/"extension"), `schema_version = 1`, `version` equal to the one you register, `repository` set, `[debug_adapters.FlutterRun]` with `extension/debug_adapter_schemas/FlutterRun.json`.
- [ ] `extension/LICENSE` is the unmodified BSD-3-Clause text (the registry matches the text; a repo-root license does not count for a subdirectory extension).
- [ ] The commit you submit is on a branch of the public repository (not detached) and contains the pinned `checksums.rs`; the release assets for that version exist publicly.
- [ ] You tested **that exact commit** as a dev extension, and built with the registry's toolchain if possible (`cargo build --release --target wasm32-wasip2`, the registry CI pins its own Rust version; check `.github/workflows` in `zed-industries/extensions`).

Steps:

```sh
gh repo fork zed-industries/extensions --clone --remote   # personal account
cd extensions
git checkout -b add-flutter-run-debugger
git submodule add https://github.com/sawongam/zed-flutter-run.git extensions/flutter-run-debugger
git -C extensions/flutter-run-debugger checkout <commit sha on master>    # the commit with pinned checksums
```

Add to `extensions.toml` (the extension lives in the `extension/` subdirectory, so `path` is required):

```toml
[flutter-run-debugger]
submodule = "extensions/flutter-run-debugger"
path = "extension"
version = "0.1.0"
```

```sh
pnpm install
pnpm sort-extensions       # sorts extensions.toml and .gitmodules; CI fails if unsorted
pnpm build && pnpm test    # as in their CI, if time allows
git add .gitmodules extensions.toml extensions/flutter-run-debugger
git commit -m "Add flutter-run-debugger"
git push -u origin add-flutter-run-debugger
gh pr create --repo zed-industries/extensions --title "Add flutter-run-debugger" --body-file <your own text>
```

(`extensions.toml` `version` must equal `extension.toml` at the pinned commit; their CI also builds the extension, checks the license, and checks that the `id` matches the table key.)

What to put in the PR body (your words), and the arguments for the reviewer:

1. **What it is.** A debugger-only extension (no language, grammar or LSP) that registers the `FlutterRun` adapter and runs a small proxy in front of `flutter debug_adapter`.
2. **Why not just the `dart` extension.** The official Dart extension has a `Dart` adapter that can launch Flutter, but nothing for hot reload/hot restart triggers, reload on save, remembered device selection, emulator launch or DevTools; those need a process in the middle of the DAP stream (a proxy plus a CLI), which cannot be done inside that extension. Earlier Flutter-toolbar-style change attempts to the Dart extension were closed (`zed-extensions/dart#72`, `zed-industries/zed#51873`). Offer to upstream anything the maintainers prefer there (for example honouring a user-provided adapter path).
3. **No conflict.** Distinct adapter name (`FlutterRun`, not `Flutter` which at least seven third-party repos use, and not `Dart`), so both adapters appear in the picker; the user keeps the Dart extension for the language server.
4. **Prerequisites met.** Does not bundle the adapter: the proxy is found on `PATH`/via the `dap.FlutterRun.binary` setting or downloaded from this repository's GitHub release, only after a SHA-256 pinned in the extension source matches; the declared `download_file` capability is limited to `github.com/sawongam/zed-flutter-run/**`; no `process:exec`; English user-facing text; BSD-3-Clause; the proxy and CLI are open source in the same repository (BSD-3-Clause, Dart).
5. **Tested.** As a dev extension on Linux with Zed 1.26.x and fvm-managed Flutter (state what you actually tested; add macOS/Windows only if you did), link the results of [MANUAL_ZED_TEST.md](MANUAL_ZED_TEST.md) as a gist or in the repository.
6. **Maintenance.** Issue tracker is enabled, CI covers three OSes, versions are checked by script, and you will reply within the 3-week window.
7. **Known tradeoff to acknowledge.** The install is two steps (extension plus the `flutter_run` binary), because Zed tasks can only run commands from the PATH; the extension can download the binary for the debug session but tasks and keybindings need it on the PATH ([ADR 0006](decisions/0006-plan-review-resolutions.md) D1).

If rejected: keep the dev-extension install path documented in the README and consider the upstream route ([risk R2](research/risk-register.md)).

Updating later: bump the submodule to the new commit and `version` in `extensions.toml` (`git submodule update --remote extensions/flutter-run-debugger`), same PR rules. A new proxy version needs a new release, new pinned checksums and a new extension version together.

## 9. Post-release checks

- [ ] `https://github.com/sawongam/zed-flutter-run/releases/tag/v0.1.0` lists the six files; the download URLs return 200 and match `SHA256SUMS`.
- [ ] On a clean machine or VM (no Flutter_run, no Rust): `dart pub global activate flutter_run` (after publishing) then `flutter_run version` prints the new version; `brew install sawongam/tap/flutter_run` and `scoop install flutter_run` work and `flutter_run doctor` runs.
- [ ] After the registry PR merges and Zed lists the extension: install "Flutter Run & Debug" from `zed: extensions`, with no `flutter_run` on the PATH. Expected: first debug session downloads `flutter_run-0.1.0/flutter_run` into Zed's extension work dir, the checksum verifies, debugging works, and the Console shows the "not on your PATH" notice. Then put the binary on the PATH and confirm the tasks (`ctrl-f5`) work.
- [ ] A mismatch warning does not appear (`[flutter_run] Warning: The Zed extension is version X but the flutter_run command is Y` means extension and binary versions differ).
- [ ] `sh .github/scripts/check-versions.sh` passes on `master`; the tag points at the version-bump commit.
- [ ] Announce / update README install section with the real commands (brew, scoop, pub, registry) and remove "dev extension only" wording.
- [ ] Write the release up in `docs/conversations/` and add any new decisions as ADRs in `docs/decisions/`.
