#!/bin/bash
set -euo pipefail
ios_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/mynah-catalog-images.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 5 "$ios_root/Examples/CommonThreadApp/CatalogImageLoader.swift" \
  "$ios_root/Scripts/catalog_image_smoke.swift" -o "$test_dir/catalog-image-smoke"
"$test_dir/catalog-image-smoke"
