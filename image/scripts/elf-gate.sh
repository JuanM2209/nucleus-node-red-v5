#!/bin/sh
# NUCLEUS build-stage gate: fail the image build if any native addon that
# node-gyp-build would select on THIS platform (linux / arm / musl) is a glibc
# binary with no musl alternative and no locally compiled build/Release.
#
# Why: classic-level shipped prebuilds/linux-arm/classic-level.armv7.node linked
# against glibc. Alpine has musl. node-gyp-build loads the glibc binary anyway
# and the process dies with SIGSEGV the moment the module is used - no JS
# exception, nothing in the log, and a --restart policy turns it into a crash
# loop. This check turns that class of bug into a build failure.
#
# Run from the build stage AFTER npm install and AFTER any npm rebuild lines.
set -eu
ROOT="${1:-/usr/src/node-red/node_modules}"
bad=0
for pre in $(find "$ROOT" -type d -path '*/prebuilds/linux-arm' 2>/dev/null); do
  pkg=$(dirname "$(dirname "$pre")")
  name=${pkg#"$ROOT"/}
  # A local build always wins in node-gyp-build's resolution order.
  if ls "$pkg"/build/Release/*.node >/dev/null 2>&1; then
    echo "elf-gate: OK   $name (build/Release present)"
    continue
  fi
  if ls "$pre"/*.musl.node >/dev/null 2>&1 || ls "$pre"/*musl*.node >/dev/null 2>&1; then
    echo "elf-gate: OK   $name (musl prebuild present)"
    continue
  fi
  echo "elf-gate: FAIL $name - prebuilds/linux-arm has no .musl variant and no build/Release." >&2
  echo "           This binary is glibc-linked and WILL segfault on Alpine/armv7." >&2
  echo "           Fix: add 'npm rebuild --build-from-source $name' to the build stage." >&2
  bad=1
done
# Second net: any .node that will actually load must not reference the glibc loader.
for so in $(find "$ROOT" -path '*/build/Release/*.node' -o -path '*/prebuilds/linux-arm/*musl*.node' 2>/dev/null); do
  if grep -aq 'ld-linux-armhf.so.3' "$so" 2>/dev/null; then
    echo "elf-gate: FAIL $so references the glibc dynamic loader" >&2
    bad=1
  fi
done
[ "$bad" -eq 0 ] && echo "elf-gate: all native addons are musl-safe" || exit 1
