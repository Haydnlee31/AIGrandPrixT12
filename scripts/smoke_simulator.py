"""Install and launch the built host + embedded share app in an ordinary iPhone simulator."""
import json
import os
from pathlib import Path
import subprocess
import time


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    root = Path(__file__).resolve().parents[1]
    output = root / "dist/simulator-validation"
    output.mkdir(parents=True, exist_ok=True)
    derived = Path(os.getenv("MYMAH_DERIVED_DATA", os.getenv("TMPDIR", "/tmp")))
    if not os.getenv("MYMAH_DERIVED_DATA"):
        derived /= "mymah-finds-derived"
    apps = list((derived / "Build/Products/Debug-iphonesimulator").glob("*.app"))
    if len(apps) != 1:
        raise RuntimeError("Expected exactly one built iPhone app")
    if not list((apps[0] / "PlugIns").glob("*.appex")):
        raise RuntimeError("Share Extension was not embedded")
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j"))["devices"]
    choices = [d for runtime, values in devices.items() if "iOS" in runtime
               for d in values if d.get("isAvailable") and d["name"].startswith("iPhone") and "Duo" not in d["name"]]
    if not choices:
        raise RuntimeError("No ordinary iPhone simulator is available")
    device = choices[0]
    udid = device["udid"]
    if device["state"] != "Booted":
        run("xcrun", "simctl", "boot", udid)
    run("xcrun", "simctl", "bootstatus", udid, "-b")
    run("xcrun", "simctl", "install", udid, str(apps[0]))
    launched = run("xcrun", "simctl", "launch", udid, "com.aigrandprix.mymahfinds")
    time.sleep(5)
    run("xcrun", "simctl", "io", udid, "screenshot", str(output / "launch.png"))
    (output / "result.json").write_text(json.dumps({"status": "launched", "device": device["name"],
        "share_extension_embedded": True, "launch": launched,
        "scope": "Simulator install and launch; not a physical microphone or share-sheet test"}, indent=2))
    print("iPhone simulator install and launch passed; Share Extension embedded.")


if __name__ == "__main__":
    main()
