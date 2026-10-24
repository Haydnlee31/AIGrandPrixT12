#!/bin/sh
set -eu

ios_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
generator_version=2.46.0
generator_sha=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
generator_cache="${TMPDIR:-/tmp}/mymah-xcodegen-${generator_version}"
generator_binary="$generator_cache/xcodegen/bin/xcodegen"

# Download the pinned official release locally; no Homebrew/global install needed.
if [ ! -x "$generator_binary" ] || [ ! -f "$generator_cache/xcodegen/share/xcodegen/SettingPresets/base.yml" ]; then
    mkdir -p "$generator_cache"
    if [ ! -f "$generator_cache/xcodegen.zip" ]; then
        curl -fsSL "https://github.com/yonaskolb/XcodeGen/releases/download/${generator_version}/xcodegen.zip" -o "$generator_cache/xcodegen.zip"
    fi
    actual_sha=$(shasum -a 256 "$generator_cache/xcodegen.zip" | cut -d ' ' -f 1)
    if [ "$actual_sha" != "$generator_sha" ]; then
        echo "XcodeGen download checksum did not match the pinned release." >&2
        exit 1
    fi
    ditto -xk "$generator_cache/xcodegen.zip" "$generator_cache"
fi

"$generator_binary" generate --spec "$ios_root/project.yml" --project "$ios_root"

# The release plist keeps standard ATS. Only Debug allows unqualified/local hosts;
# CommonThreadKit separately rejects HTTP except localhost/127.0.0.1/::1.
python3 - "$ios_root" <<'PY'
import pathlib
import plistlib
import sys

root = pathlib.Path(sys.argv[1]) / "Configuration"
for target in ("App", "Share"):
    with (root / f"{target}-Info.plist").open("rb") as source:
        properties = plistlib.load(source)
    properties["NSAppTransportSecurity"] = {"NSAllowsLocalNetworking": True}
    with (root / f"{target}-Debug-Info.plist").open("wb") as output:
        plistlib.dump(properties, output, sort_keys=True)
PY
