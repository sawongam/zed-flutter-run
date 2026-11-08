#!/bin/sh
# One-command setup for contributors. Safe to run again. Never uses sudo.
# Checks dart and rustup (flutter is optional), installs the pinned Rust toolchain, then runs
# `dart pub get` and `cargo fetch`.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
missing=0

need() {
  # need <command> <where to get it>
  if command -v "$1" >/dev/null 2>&1; then
    printf 'ok       %s\n' "$1"
  else
    printf 'MISSING  %s: %s\n' "$1" "$2" >&2
    missing=1
  fi
}

need dart "install the Dart SDK 3.13 or newer (it comes with Flutter): https://dart.dev/get-dart"
need rustup "install Rust with rustup: https://rustup.rs"
need cargo "install Rust with rustup: https://rustup.rs"

if ! command -v flutter >/dev/null 2>&1; then
  echo "NOTE     flutter not found: only the Flutter integration tests need it (https://docs.flutter.dev/get-started/install)." >&2
fi

if [ "$missing" -ne 0 ]; then
  echo "Install the missing tools above, then run this script again." >&2
  exit 1
fi

echo "Fetching Dart packages..."
(cd "$root/cli" && dart pub get)

echo "Fetching Rust crates..."
# rustup toolchain install reads extension/rust-toolchain.toml (version,
# components and the wasm32-wasip2 target).
(cd "$root/extension" && rustup toolchain install && cargo fetch)

echo "Done. Run the checks as described in CONTRIBUTING.md."
