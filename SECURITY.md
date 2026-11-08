# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| 0.1.x (preview, not yet released) | Yes |

Only the latest release receives security fixes.

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private vulnerability reporting: on the repository page choose **Security** > **Report a vulnerability** (a GitHub Security Advisory; direct link: <https://github.com/sawongam/zed-flutter-run/security/advisories/new>). If that is unavailable, contact the repository owner through their GitHub profile and ask for a private channel.

Include the version, your OS, steps to reproduce and the impact. We aim to acknowledge reports within a week and to agree on a disclosure date with you.

## Threat model: the downloaded binary

The Zed extension is a small WebAssembly module. The tool it runs, `flutter_run`, is a separate native binary. The extension finds it in this order: the `dap.FlutterRun.binary` setting, `PATH`, then (release builds only) a download from this repository's GitHub releases.

The risk is a tampered or substituted binary. What protects you:

- **Pinned SHA-256.** Each release's checksums are written into the extension source (`extension/src/checksums.rs`) at release time. The extension refuses a downloaded file whose SHA-256 does not match. A dev build, or a build with no pinned checksums, never downloads.
- **Fixed source.** The extension may only download from `github.com/sawongam/zed-flutter-run` (its declared `download_file` capability).
- **Build provenance (being added).** Release binaries will carry GitHub build provenance attestations. Verify one yourself with `gh attestation verify <file> --repo sawongam/zed-flutter-run`. This is not in place until the first release is published.

What is not covered: a compromised maintainer account or repository can publish a release and update the pinned checksums together. Attestations let you check which workflow built a binary. If you do not want automatic downloads at all, install `flutter_run` yourself and set `dap.FlutterRun.binary`.

## Scope

In scope:

- **Control channel** between `flutter_run reload`/`restart`/`status` and a running debug session: it listens on loopback (`127.0.0.1`) only, requires a per-session token on every request, accepts a fixed command set, and keeps its session files in a directory with mode 0700 (POSIX) or under the user profile (Windows).
- **Extension download:** the Zed extension downloads `flutter_run` from this repository's GitHub releases only after verifying a SHA-256 checksum pinned in the extension at release time. Dev builds never download.
- **No shell execution of user input:** processes are started directly, never through a shell string. On Windows, `.bat` targets only accept validated arguments.

- **`logFile` / `FLUTTER_RUN_LOG`:** a project's `debug.json` must not be able to write arbitrary files. The log path must end in `.log`, its folder must already exist (nothing is created), the file is opened owner-only (0600 on POSIX), and control characters in logged lines are escaped.

**Trust note:** settings such as `flutterSdkPath`, a project's `.fvm/flutter_sdk` link and the scenario `env` choose which programs run, exactly like Zed tasks and other debugger extensions. Open only projects you trust.

Out of scope:

- Vulnerabilities in Flutter, Dart, Zed, DevTools or the operating system (report those upstream).
- Anything that needs an attacker who already runs code as your user, or who can already write to your project's `.zed/` files or your PATH.
- Debug sessions exposing an app's own VM service to the local machine, which is how Flutter debugging works.
- Denial of service by a local user against their own session.
