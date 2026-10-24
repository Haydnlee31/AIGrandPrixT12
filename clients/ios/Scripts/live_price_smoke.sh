#!/bin/sh
set -eu
ios_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/mynah-live-price.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$scratch/modules" \
  "$ios_root/Examples/CommonThreadApp/LivePriceModels.swift" \
  "$ios_root/Scripts/live_price_smoke.swift" -o "$scratch/live-price-smoke"
"$scratch/live-price-smoke"
