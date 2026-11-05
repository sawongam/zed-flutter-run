# 0003: Languages: thin Rust Zed extension + Dart proxy/CLI

- **Date:** 2026-11-04
- **Status:** Accepted (user: "if it's the normal, sounds about right")

## Context
Zed extensions with code must be Rust compiled to WASI (`zed_extension_api`, `[lib] kind = "Rust"`). Dart's `dart2wasm` targets browsers and can't produce a Zed extension. The usual pattern is a thin Rust extension that locates or downloads a binary written in any language. The official Dart extension works this way and launches `flutter debug_adapter`, which is written in Dart. See [conversation 003](../conversations/2026-11-04-003-extension-language-and-readiness.md).

## Decision
- **Zed extension:** Rust, kept thin (about 200 lines). It registers the `Flutter` debug adapter, downloads or locates the proxy binary, and ships the schema and locators.
- **Proxy + CLI:** **Dart**, compiled with `dart compile exe` per OS. All the logic goes here.

## Consequences
- Flutter developers can contribute to the core without learning Rust.
- CI must build native Dart binaries on Linux, macOS and Windows (Dart can't cross-compile).
- Users who already have Flutter installed can also install it with `dart pub global activate`.
