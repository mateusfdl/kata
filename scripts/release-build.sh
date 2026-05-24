#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?usage: release-build.sh <version>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGETS=(
  x86_64-linux-musl
  aarch64-linux-musl
  x86_64-macos
  aarch64-macos
  x86_64-windows
)

sed -i.bak -E "s/(\.version = \")[^\"]+(\")/\1${VERSION}\2/" build.zig.zon
rm -f build.zig.zon.bak

rm -rf dist
mkdir -p dist

for target in "${TARGETS[@]}"; do
  out="zig-out-${target}"
  rm -rf "$out"
  zig build --prefix "$out" -Doptimize=ReleaseFast -Dtarget="$target" -Dstrip=true

  stage="kata-${VERSION}-${target}"
  mkdir -p "dist/$stage"
  cp "$out/bin/"kata* "dist/$stage/"

  case "$target" in
    *windows*)
      (cd dist && zip -qr "${stage}.zip" "$stage")
      ;;
    *)
      tar -C dist -czf "dist/${stage}.tar.gz" "$stage"
      ;;
  esac

  rm -rf "dist/$stage" "$out"
done

ls -la dist/
