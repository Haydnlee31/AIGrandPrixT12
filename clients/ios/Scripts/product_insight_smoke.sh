#!/bin/sh
set -eu
ios_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/mynah-insights.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$scratch/modules" \
  "$ios_root/Examples/CommonThreadApp/ProductInsightSummary.swift" \
  "$ios_root/Scripts/product_insight_smoke.swift" -o "$scratch/insight-smoke"
"$scratch/insight-smoke"
