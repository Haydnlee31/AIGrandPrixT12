#!/bin/sh
set -eu
ios_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/commonthread-swift.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$scratch/modules" \
  "$ios_root"/Sources/CommonThreadKit/*.swift "$ios_root/Scripts/smoke.swift" \
  -o "$scratch/smoke"
"$scratch/smoke" "$ios_root/Tests/CommonThreadKitTests/Fixtures"
