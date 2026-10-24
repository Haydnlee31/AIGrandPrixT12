"""Transfer only the scoped relay configuration to a DEBUG iPhone app.

Usage: python3 configure-intelligence-device.py DEVICE_UDID HTTPS_ORIGIN
Reads MYNAH_PREVIEW_TOKEN from ignored .env.local; never transfers OPENAI_API_KEY.
The app imports the connection into shared Keychain, then deletes its transfer file.
"""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

if len(sys.argv) not in (3, 4):
    raise SystemExit("Provide device UDID and the HTTPS relay origin.")
device, origin = sys.argv[1:3]
multimodal_origin = sys.argv[3] if len(sys.argv) == 4 else None
parts = urlsplit(origin)
if parts.scheme != "https" or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment or parts.path not in ("", "/"):
    raise SystemExit("Use an HTTPS origin without credentials, path or query.")
root = Path(__file__).resolve().parents[3]
values = dict(line.split("=", 1) for line in (root / ".env.local").read_text().splitlines() if "=" in line and not line.lstrip().startswith("#"))
token = values.get("MYNAH_PREVIEW_TOKEN", "").strip()
if len(token) < 24 or token.startswith("sk-"):
    raise SystemExit("A scoped service access token is required; an OpenAI key cannot be transferred.")
payload = {"baseURL": origin, "accessToken": token}
if multimodal_origin:
    parts = urlsplit(multimodal_origin)
    if parts.scheme != "https" or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment or parts.path not in ("", "/"):
        raise SystemExit("Use a valid HTTPS analysis origin.")
    config = json.loads((root / ".env.multimodal-device").read_text())
    payload.update(multimodalURL=multimodal_origin, multimodalToken=config["access_token"])
with tempfile.TemporaryDirectory(prefix="mynah-intelligence-") as directory:
    path = Path(directory) / "mynah-preview-connection.json"
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        json.dump(payload, handle)
    subprocess.run(["xcrun", "devicectl", "device", "copy", "to", "--device", device,
                    "--source", str(path), "--destination", "Documents/mynah-preview-connection.json",
                    "--domain-type", "appDataContainer", "--domain-identifier", "com.aigrandprix.mymahfinds"],
                   check=True, stdout=subprocess.DEVNULL)
print("Scoped connection transferred. Launch Mynah to finish secure import.")
