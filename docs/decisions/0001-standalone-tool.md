# 0001: Build a standalone tool for global users

- **Date:** 2026-11-04
- **Status:** Accepted

## Context
Zed's official Dart extension (v0.4.x) already provides DAP debugging. Hot reload/restart, a device picker and DevTools are missing, and the upstream fix is blocked on a Zed API (zed#51873). See [research/landscape.md](../research/landscape.md).

## Options
1. Contribute to the official `zed-extensions/dart`
2. Fork the Dart extension
3. Build a standalone tool that works alongside the official extension

## Decision
**Option 3: standalone.** The user wants to ship this to Flutter developers worldwide, not just for personal use.

## Consequences
- It has to meet public-release standards: cross-platform (Linux, macOS, Windows), easy install, documentation, tests, versioning, a license, and a contribution guide.
- It must not conflict with the official Dart extension. Ideally it complements it.
- We stay free to upstream pieces later, once Zed's API allows it.
