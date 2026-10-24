#!/bin/sh
# Compile and exercise the actual native upload/analyze/transcript/delete flow against mocked HTTP.
set -eu
ios_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/mymah-multimodal-flow.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$scratch/modules" -emit-module -emit-library -module-name CommonThreadKit \
  -emit-module-path "$scratch/CommonThreadKit.swiftmodule" "$ios_root"/Sources/CommonThreadKit/*.swift -o "$scratch/libCommonThreadKit.dylib"
xcrun swiftc -swift-version 5 -module-cache-path "$scratch/modules" -I "$scratch" -L "$scratch" -lCommonThreadKit \
  -Xlinker -rpath -Xlinker "$scratch" "$ios_root/Examples/Shared/CaptureIntelligenceModels.swift" \
  "$ios_root/Examples/Shared/MultimodalDraftAnalysis.swift" "$ios_root/Scripts/multimodal_flow_smoke.swift" -o "$scratch/smoke"
"$scratch/smoke"
