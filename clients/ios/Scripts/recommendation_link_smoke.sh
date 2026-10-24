#!/bin/sh
set -eu
ios_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/mynah-recommendation-links.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
# Compile the production decoding and URL validation without the SwiftUI views.
awk 'BEGIN { print "import Foundation" } /^\/\/\/ Local saves/ { exit } /^import / { next } { print }' \
  "$ios_root/Examples/CommonThreadApp/LocalExploreScreen.swift" > "$scratch/Recommendation.swift"
xcrun swiftc -swift-version 5 -module-cache-path "$scratch/modules" \
  "$scratch/Recommendation.swift" "$ios_root/Scripts/recommendation_link_smoke.swift" \
  -o "$scratch/recommendation-link-smoke"
"$scratch/recommendation-link-smoke"
