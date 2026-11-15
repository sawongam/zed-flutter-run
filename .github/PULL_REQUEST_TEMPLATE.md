## What and why

<!-- Describe the change and link the issue (Fixes #123). -->

## Checklist

- [ ] Tests added or updated, and passing (`dart test`, `cargo test`)
- [ ] `dart format .` and `dart analyze --fatal-infos` are clean (in `cli/`)
- [ ] `cargo fmt --check` and `cargo clippy --all-targets -- -D warnings` are clean (in `extension/`)
- [ ] Docs updated (`docs/CONFIGURATION.md` for keys, commands and flags; `docs/DESIGN.md` for design choices)
- [ ] Versions untouched, or `sh .github/scripts/check-versions.sh` passes
