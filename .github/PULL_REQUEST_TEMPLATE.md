## What and why

<!-- Describe the change and link the issue (Fixes #123). -->

## Checklist

- [ ] Tests added or updated, and passing (`dart test`, `cargo test`)
- [ ] `dart format .` and `dart analyze --fatal-infos` are clean (in `cli/`)
- [ ] `cargo fmt --check` and `cargo clippy --all-targets -- -D warnings` are clean (in `extension/`)
- [ ] `CHANGELOG.md` updated under `## [Unreleased]` (user-visible changes)
- [ ] Docs updated; an ADR in `docs/decisions/` for design decisions
- [ ] Versions untouched, or `sh .github/scripts/check-versions.sh` passes
