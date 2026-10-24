#!/bin/sh
# Compile the additive multimodal SDK and exercise its transport with in-memory fixtures only.
set -eu
ios_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/mymah-multimodal-swift.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$scratch/modules" \
  "$ios_root"/Sources/CommonThreadKit/*.swift "$ios_root/Scripts/multimodal_smoke.swift" \
  -o "$scratch/smoke"
"$scratch/smoke"
