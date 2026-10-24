#!/bin/sh
set -eu
ios_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/mynah-radar-budget.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$scratch/modules" \
  "$ios_root/Examples/CommonThreadApp/RadarStore.swift" \
  "$ios_root/Examples/CommonThreadApp/RadarBudgetScale.swift" \
  "$ios_root/Scripts/radar_budget_smoke.swift" -o "$scratch/radar-budget-smoke"
"$scratch/radar-budget-smoke"
