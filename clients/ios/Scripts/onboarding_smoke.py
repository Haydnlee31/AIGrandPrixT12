"""Read-only assertions after exercising onboarding in an isolated Simulator app.

Use the fresh test bundle from docs/ios-shopping-onboarding/README.md.
Run `preview` after viewing the example and cancelling capture, `skipped` after
Skip and relaunch, `saved` after the photo save, and `completed` after opening
Library. This checks persisted outcomes; it does not drive the UI.
"""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("device", help="Simulator UUID")
parser.add_argument("phase", choices=["preview", "skipped", "saved", "completed"])
parser.add_argument("--bundle", default="com.aigrandprix.mynahonboardingqa")
args = parser.parse_args()
container = Path(subprocess.check_output(
    ["xcrun", "simctl", "get_app_container", args.device, args.bundle, "data"], text=True
).strip())
prefs_file = container / "Library/Preferences" / f"{args.bundle}.plist"
prefs = plistlib.loads(prefs_file.read_bytes()) if prefs_file.exists() else {}
library_file = container / "Library/Application Support/MymahFinds/local-library.json"
library = json.loads(library_file.read_text()) if library_file.exists() else {"items": []}
expected_complete = args.phase in {"skipped", "completed"}
assert bool(prefs.get("finds.onboarding.complete")) == expected_complete, "Completion must match Skip/Done, including after relaunch"
if args.phase in {"preview", "skipped"}:
    assert library["items"] == [], "Practice and cancelled capture must leave the library empty"
else:
    assert len(library["items"]) == 1, "A first save must create exactly one real find"
    item = library["items"][0]
    assert item["client"] != "sample" and item["hasImage"], "Result must use the real captured photo"
    assert item["title"] == "Reading corner lamp", "Result must retain the user's product name"
    assert item["note"] == "Warm light for my reading corner. Budget under $100.", "Shopping context must persist unchanged"
    attachments = library["metadata"][item["id"]]["attachments"]
    assert attachments and all((library_file.parent / a["relativePath"]).is_file() for a in attachments), "Saved media must exist on disk"
print(f"PASS onboarding {args.phase}: persisted completion, content and media match the UI action")
