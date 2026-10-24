#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
resize() { sips -z "$2" "$2" "$1" --out "$3" >/dev/null; }
for size in 16 24 32; do resize masters/small.png "$size" "chrome/icon-$size.png"; done
for size in 48 128; do resize masters/full.png "$size" "chrome/icon-$size.png"; done
for size in 16 32 48; do resize masters/small.png "$size" "web/favicon-$size.png"; done
for size in 192 512; do resize masters/full.png "$size" "web/icon-$size.png"; done
resize masters/full.png 180 web/apple-touch-icon.png
for size in 192 512; do resize masters/maskable.png "$size" "web/icon-maskable-$size.png"; done
resize masters/full.png 1024 ios/AppIcon.appiconset/AppIcon-1024.png
for size in 20 29 40 58 60 76 80 87 120 152 167 180; do resize masters/full.png "$size" "ios/AppIcon.appiconset/AppIcon-$size.png"; done
