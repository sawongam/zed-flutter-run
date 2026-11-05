# 2026-11-04-003: Extension language and design readiness

## Q1: Can the Zed extension be written in Dart?
**No, not in practice.** Zed extensions with code are Rust compiled to WebAssembly (WASI) against the `zed_extension_api` crate. The installed Dart extension's `extension.toml` says `[lib] kind = "Rust"`. Dart's WASM output (`dart2wasm`) targets browsers, not the WASI component model that Zed loads.

**What people normally do:** keep the Rust extension *thin*. It finds or downloads a binary and tells Zed how to launch it, and the real tool can be written in any language. Examples:
- The official Dart extension is Rust, but it just launches `flutter debug_adapter`, which is written in Dart.
- Most language-server extensions work the same way: a Rust wrapper around a binary written in TypeScript, Go, Python and so on.

So **a thin Rust extension plus a Dart proxy** is the standard pattern. We'd expect the extension to stay at roughly 200 lines of Rust.

## Q2: Is the design fixed?
**No.** Decision 0002 stays *Proposed*. The overall direction (a proxy in the debug path) is well supported. The details aren't, and **a spike answers most of what's left better than more desk research would.**

### Needs a spike (only running code can tell us)
1. Does a live `flutter run` behave correctly through the proxy? Do breakpoints survive a hot reload?
2. The side channel on Windows (named pipes vs TCP on localhost).
3. Reload on save: is a file watcher in the proxy reliable with Zed's save and autosave behaviour?

### Needs targeted research (short, specific)
4. **Coexisting with the official Dart extension:** can two extensions both offer a debugger for `.dart` files? How do debug locators and "New Session" pick between them?
5. **Zed extension registry rules:** licenses, downloading binaries from GitHub Releases, naming, review process.
6. **Zed's DAP client:** does it show custom events or output from the adapter (reload status, errors) anywhere useful?
7. **Is the device picker UX acceptable** as a terminal picker run from a task? What do comparable Zed extensions do?
8. **Recent Zed changes** (Aug–Nov 2026) to the extension or debugger API that could change the plan.
