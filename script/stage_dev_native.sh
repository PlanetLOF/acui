#!/usr/bin/env bash
# Stage the local FFI engine build into the pub-cache git checkout of
# autocipher_dart.
#
# The git dependency cannot carry the native binary (it is gitignored in the
# monorepo), but the wrapper's pubspec declares it as a Flutter asset, so
# `flutter test` / `flutter build` fail unless the staged library exists inside
# the package that pub resolves. This script copies it there.
#
# Run after `flutter pub get` whenever the git ref or the pub cache changes.
#
# Usage:
#   bash script/stage_dev_native.sh
#   bash script/stage_dev_native.sh /path/to/autocipher
#   AUTOCIPHER_ROOT=/path/to/autocipher bash script/stage_dev_native.sh
set -euo pipefail

if [ -n "${BASH_SOURCE:-}" ]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  script_dir="$(cd "$(dirname "$0")" && pwd)"
fi
repo_root="$(cd "$script_dir/../.." && pwd)"
autocipher_root="${1:-${AUTOCIPHER_ROOT:-$repo_root/autocipher}}"

case "$(uname -s)" in
  Darwin)              os="macos"; name="libautocipher_ffi.dylib" ;;
  MINGW*|MSYS*|CYGWIN*) os="win"; name="autocipher_ffi.dll" ;;
  Linux)               os="linux"; name="libautocipher_ffi.so" ;;
  *) echo "unsupported host OS: $(uname -s)" >&2; exit 1 ;;
esac

src="$autocipher_root/dart/lib/src/native/$os/$name"
if [ ! -f "$src" ]; then
  echo "staged engine not found at $src (run script/build_ffi.sh in the autocipher repo first)" >&2
  exit 1
fi

if [ -n "${LOCALAPPDATA:-}" ]; then
  pub="${PUB_CACHE:-${LOCALAPPDATA//\\/\/}/Pub/Cache}"
else
  pub="${PUB_CACHE:-$HOME/.pub-cache}"
fi
pkg="$(ls -dt "$pub"/git/autocipher-* 2>/dev/null | head -n 1)"
if [ -z "$pkg" ] || [ ! -d "$pkg" ]; then
  echo "no autocipher_dart checkout in the pub cache (run flutter pub get first)" >&2
  exit 1
fi

dst_dir="$pkg/dart/lib/src/native/$os"
mkdir -p "$dst_dir"
cp "$src" "$dst_dir/$name"
echo "staged $src -> $dst_dir/$name"