#!/bin/sh
# Fails if the version differs between the five places that must move together.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"

status=0
first=""
check() { # label file extracted
  label=$1; file=$2; ver=$3
  if [ -z "$ver" ]; then
    echo "ERROR: could not read a version from $file ($label)" >&2
    status=1
    return
  fi
  printf '%-34s %s\n' "$file" "$ver"
  if [ -z "$first" ]; then first=$ver; elif [ "$ver" != "$first" ]; then
    echo "ERROR: $file has $ver, expected $first" >&2
    status=1
  fi
}
need() { [ -f "$1" ] || { echo "ERROR: missing $1" >&2; status=1; return 1; }; }

if need cli/pubspec.yaml; then
  check pubspec cli/pubspec.yaml "$(sed -n 's/^version:[[:space:]]*\([0-9][^[:space:]#]*\).*/\1/p' cli/pubspec.yaml | head -n 1)"
fi
if need cli/lib/src/common/version.dart; then
  check version.dart cli/lib/src/common/version.dart "$(sed -n "s/^[^/]*const[^=]*=[[:space:]]*['\"]\([0-9][^'\"]*\)['\"].*/\1/p" cli/lib/src/common/version.dart | head -n 1)"
fi
if need extension/Cargo.toml; then
  check cargo extension/Cargo.toml "$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' extension/Cargo.toml | head -n 1)"
fi
if need extension/extension.toml; then
  check extension.toml extension/extension.toml "$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' extension/extension.toml | head -n 1)"
fi
if need extension/src/install.rs; then
  check install.rs extension/src/install.rs "$(sed -n 's/.*PROXY_VERSION[^=]*=[[:space:]]*"\([^"]*\)".*/\1/p' extension/src/install.rs | head -n 1)"
fi

[ "$status" -eq 0 ] && echo "OK: all versions match ($first)"
exit "$status"
