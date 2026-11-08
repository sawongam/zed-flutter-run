#!/bin/sh
# One-command setup for contributors. Safe to run again. Never uses sudo.
# Checks dart, flutter and rustup, adds the wasm32-wasip2 target, then runs
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

need dart "install the Dart SDK 3.8 or newer (it comes with Flutter): https://dart.dev/get-dart"
need flutter "install Flutter (needed for the integration tests): https://docs.flutter.dev/get-started/install"
need rustup "install Rust with rustup: https://rustup.rs"
need cargo "install Rust with rustup: https://rustup.rs"

if [ "$missing" -ne 0 ]; then
  echo "Install the missing tools above, then run this script again." >&2
  exit 1
fi

echo "Adding the wasm32-wasip2 target..."
rustup target add wasm32-wasip2

echo "Fetching Dart packages..."
(cd "$root/cli" && dart pub get)

echo "Fetching Rust crates..."
(cd "$root/extension" && cargo fetch)

echo "Done. Run the checks as described in CONTRIBUTING.md."
