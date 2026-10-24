#!/bin/sh
set -eu

ios_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
derived_data="${MYMAH_DERIVED_DATA:-${TMPDIR:-/tmp}/mymah-finds-derived}"

sh "$ios_root/Scripts/generate-project.sh"
xcodebuild \
    -project "$ios_root/Mymah Finds.xcodeproj" \
    -scheme "Mymah Finds" \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO build
