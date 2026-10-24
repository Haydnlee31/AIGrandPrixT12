#!/usr/bin/env python3
"""Run first-share race regressions against the production Swift lifecycle gate.

Requires macOS with Xcode command-line tools. No simulator, secrets, network or
paid API requests are used. Compilation and executable output stay in a temp dir.
Run from any directory: python3 scripts/check_share_lifecycle.py
"""
from pathlib import Path
import subprocess
import tempfile

CHECKS = r"""
import Foundation

@main struct ShareLifecycleRegression {
    @MainActor static func main() async {
        var checks = 0
        func verify(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label); checks += 1
        }
        let importing = ShareIntelligenceRequest(context: "partial source", ready: false)
        let loaded = ShareIntelligenceRequest(context: "watch photo and source caption", ready: true)
        var gate = ShareIntelligenceLifecycle()
        verify(gate.begin(importing, current: importing, cancelled: false) == nil, "Incomplete import cannot claim analysis")
        let firstID = gate.begin(loaded, current: loaded, cancelled: false)!
        verify(gate.begin(importing, current: loaded, cancelled: false) == nil, "Captured old import snapshot cannot claim current source")
        verify(gate.activeID == firstID, "Old import leaves the first real request active")
        verify(gate.begin(loaded, current: loaded, cancelled: true) == nil, "Already-canceled task cannot reset request ownership")
        verify(gate.accepts(firstID, request: loaded, current: loaded, cancelled: false), "First uncached response remains accepted")

        // Reproduce the scheduling failure: an obsolete task resumes after the
        // first full import request has already started. No result cache is used.
        var release: CheckedContinuation<Void, Never>?
        let lateImport = Task { @MainActor in
            await withCheckedContinuation { release = $0 }
            verify(gate.begin(loaded, current: loaded, cancelled: Task.isCancelled) == nil,
                   "Late canceled import task is ignored before state mutation")
        }
        while release == nil { await Task.yield() }
        lateImport.cancel()
        release!.resume()
        await lateImport.value
        verify(gate.activeID == firstID, "Delayed canceled task does not discard first-attempt result")

        let edited = ShareIntelligenceRequest(context: "different photo", ready: true)
        let editedID = gate.begin(edited, current: edited, cancelled: false)!
        verify(!gate.accepts(firstID, request: loaded, current: edited, cancelled: false), "Old product response cannot update new product")
        verify(!gate.finish(firstID), "Old cleanup cannot clear new loading state")
        verify(gate.activeID == editedID, "Replacement keeps spinner ownership")
        verify(gate.accepts(editedID, request: edited, current: edited, cancelled: false), "Edited product result is accepted")
        let saved = ShareIntelligenceRequest(context: edited.context, ready: false)
        verify(!gate.accepts(editedID, request: edited, current: saved, cancelled: false), "Completion after saving cannot replace the persisted draft")
        verify(gate.finish(editedID), "Current owner can finish")
        verify(!gate.finish(editedID), "Cleanup runs only once")
        print("PASS: \(checks) share lifecycle checks using the production gate")
    }
}
"""


def main():
    root = Path(__file__).resolve().parents[1]
    production = root / "clients/ios/Examples/Shared/ShareIntelligenceLifecycle.swift"
    with tempfile.TemporaryDirectory(prefix="mynah-share-lifecycle-") as directory:
        folder = Path(directory)
        tests = folder / "ShareLifecycleChecks.swift"
        executable = folder / "share-lifecycle-checks"
        tests.write_text(CHECKS)
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            str(production), str(tests), "-o", str(executable),
        ], check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    main()
