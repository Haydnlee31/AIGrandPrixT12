#!/bin/sh
set -eu
ios_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/mynah-appearance.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$scratch/modules" \
  "$ios_root/Examples/CommonThreadApp/AppAppearanceState.swift" \
  "$ios_root/Scripts/appearance_state_smoke.swift" -o "$scratch/appearance-smoke"
"$scratch/appearance-smoke"
