#!/bin/sh
# Compile the actual frontend store and SDK models; no backend or network needed.
set -eu
ios_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/mymah-local-library.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$scratch/modules" \
  -emit-module -emit-library -module-name CommonThreadKit \
  -emit-module-path "$scratch/CommonThreadKit.swiftmodule" \
  "$ios_root"/Sources/CommonThreadKit/*.swift -o "$scratch/libCommonThreadKit.dylib"
xcrun swiftc -swift-version 5 -module-cache-path "$scratch/modules" \
  -I "$scratch" -L "$scratch" -lCommonThreadKit \
  -Xlinker -rpath -Xlinker "$scratch" \
  "$ios_root/Examples/Shared/CaptureIntelligenceModels.swift" \
  "$ios_root/Examples/Shared/LocalShareInbox.swift" \
  "$ios_root/Examples/CommonThreadApp/LocalShareImport.swift" \
  "$ios_root/Examples/CommonThreadApp/LocalLibrary.swift" \
  "$ios_root/Scripts/local_library_smoke.swift" -o "$scratch/local-smoke"
"$scratch/local-smoke" "$@"
