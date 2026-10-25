"""Real simulator microphone/permission tests; never claims physical speech capture."""
import json
import os
from pathlib import Path
import shutil
import subprocess


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    root = Path(__file__).resolve().parents[3]
    evidence = root / "dist/microphone-validation"
    evidence.mkdir(parents=True, exist_ok=True)
    derived = Path(os.environ.get("MYMAH_DERIVED_DATA", Path(os.getenv("TMPDIR", "/tmp")) / "mymah-finds-derived"))
    devices = json.loads(output("xcrun", "simctl", "list", "devices", "available", "-j"))["devices"]
    choices = [device for runtime, entries in devices.items() if "iOS" in runtime
               for device in entries if device.get("isAvailable") and device["name"].startswith("iPhone")
               and "Duo" not in device["name"]]
    if not choices:
        raise RuntimeError("No ordinary iPhone simulator is available")
    device = next((device for device in choices if device["state"] == "Booted"), choices[0])
    udid = device["udid"]
    if device["state"] != "Booted":
        output("xcrun", "simctl", "boot", udid)
    output("xcrun", "simctl", "bootstatus", udid, "-b")
    bundle_id = "com.aigrandprix.mymahfinds"
    # Grant only to the isolated simulator app. XCUITest resets this and operates
    # the actual system alert for first-grant and denial scenarios afterward.
    output("xcrun", "simctl", "privacy", udid, "grant", "microphone", bundle_id)
    common = ["xcodebuild", "-project", str(root / "clients/ios/Mymah Finds.xcodeproj"),
              "-scheme", "Mymah Microphone", "-destination", f"id={udid}",
              "-derivedDataPath", str(derived), "-parallel-testing-enabled", "NO",
              "CODE_SIGNING_ALLOWED=NO"]
    results = {}
    for target, command in [("CommonThreadRecorderTests", "test"),
                            ("CommonThreadMicrophoneUITests", "test-without-building")]:
        with (evidence / f"{target}.log").open("w") as log:
            result = subprocess.run(common + ["-only-testing:" + target,
                "-resultBundlePath", str(evidence / f"{target}.xcresult"), command],
                stdout=log, stderr=subprocess.STDOUT)
        results[target] = "passed" if result.returncode == 0 else "failed"
        print(f"{target}: {results[target]}", flush=True)
        if result.returncode:
            print((evidence / f"{target}.log").read_text()[-16000:], flush=True)
        if target == "CommonThreadRecorderTests":
            try:
                container = Path(output("xcrun", "simctl", "get_app_container", udid, bundle_id, "data"))
                recorded = container / "Documents/microphone-validation"
                if recorded.is_dir():
                    shutil.copytree(recorded, evidence / "native-recording", dirs_exist_ok=True)
            except subprocess.CalledProcessError:
                pass  # Test logs/xcresult still expose any concrete native failure.
    (evidence / "result.json").write_text(json.dumps({"device": device["name"], "tests": results,
        "scope": "Real AVAudioRecorder AAC plus first-use/denied permission and background UI. Simulator input may be silent; physical microphone/Bluetooth are separate checks."}, indent=2))
    if any(value != "passed" for value in results.values()):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
