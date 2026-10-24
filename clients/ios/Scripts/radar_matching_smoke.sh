#!/bin/sh
set -eu
ios_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/mynah-radar-matching.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
# Compile the exact production service with real SDK models; only its network
# boundary and UI-owned context/page types are replaced by isolated test doubles.
sed '/^import CommonThreadKit$/d' "$ios_root/Examples/CommonThreadApp/RadarMatchingService.swift" > "$scratch/RadarMatchingService.swift"
xcrun swiftc -swift-version 5 -module-cache-path "$scratch/modules" \
  "$ios_root"/Sources/CommonThreadKit/*.swift \
  "$ios_root/Examples/CommonThreadApp/RadarStore.swift" \
  "$scratch/RadarMatchingService.swift" "$ios_root/Scripts/radar_matching_smoke.swift" \
  -o "$scratch/radar-matching-smoke"
"$scratch/radar-matching-smoke"
