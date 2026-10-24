#!/bin/sh
set -eu
ios_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/mynah-radar.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$scratch/modules" \
  "$ios_root/Examples/CommonThreadApp/RadarStore.swift" \
  "$ios_root/Scripts/radar_store_smoke.swift" -o "$scratch/radar-smoke"
"$scratch/radar-smoke"
