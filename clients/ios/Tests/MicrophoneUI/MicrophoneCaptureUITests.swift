import XCTest

/// Operates the real app and iOS permission alert. No permission/recorder bypass
/// is injected into the app. Hosted simulator input may be silent.
@MainActor final class MicrophoneCaptureUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testFirstPermissionGrantRecordsAttachesAndSavesLocally() throws {
        let app = launchFreshPermission()
        let record = app.buttons["captureRecordVoice"]
        reveal(record, in: app)
        record.tap()
        let alert = microphoneAlert()
        XCTAssertFalse(app.buttons["captureSave"].isEnabled, "Saving must wait for microphone preparation")
        allowMicrophone(alert)
        let stop = app.buttons["captureStopVoice"]
        XCTAssertTrue(stop.waitForExistence(timeout: 8), "First Allow tap should start recording without a second Record tap")
        XCTAssertEqual(app.staticTexts["captureVoiceState"].value as? String, "recording")
        XCTAssertFalse(app.buttons["captureSave"].isEnabled, "Saving must wait until the voice note is attached")
        Thread.sleep(forTimeInterval: 1.3)
        stop.tap()
        waitForAttachment(in: app)
        let save = app.buttons["captureSave"]
        reveal(save, in: app)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["Saved!"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["captureDone"].exists)
        attachScreenshot(app, name: "Voice note recorded and saved locally")
    }

    func testDeniedMicrophoneKeepsTextCaptureUsableAndExplainsSettings() throws {
        let app = launchFreshPermission()
        let record = app.buttons["captureRecordVoice"]
        reveal(record, in: app)
        record.tap()
        let alert = microphoneAlert()
        let deny = alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Allow")).allElementsBoundByIndex
            .first { $0.label.localizedCaseInsensitiveContains("Don") }
        XCTAssertNotNil(deny, "Expected the real iOS Don't Allow button")
        deny?.tap()
        let error = app.staticTexts["voiceRecordError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("Settings"))
        XCTAssertTrue(record.exists)
        XCTAssertFalse(app.buttons["captureStopVoice"].exists)
        XCTAssertEqual(app.staticTexts["captureVoiceState"].value as? String, "idle")
        XCTAssertFalse(app.staticTexts["voiceAttachment"].exists)
        let save = app.buttons["captureSave"]
        reveal(save, in: app)
        XCTAssertTrue(save.isEnabled, "Denied microphone must not block saving typed content")
        attachScreenshot(app, name: "Microphone denied with useful recovery")
    }

    func testBackgroundDuringRecordingRetainsPartialAudioAndClearsBusyState() throws {
        let app = launchFreshPermission()
        let record = app.buttons["captureRecordVoice"]
        reveal(record, in: app)
        record.tap()
        allowMicrophone(microphoneAlert())
        XCTAssertTrue(app.buttons["captureStopVoice"].waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1.3)
        XCUIDevice.shared.press(.home)
        app.activate()
        waitForAttachment(in: app)
        attachScreenshot(app, name: "Interrupted recording retained")
    }

    private func launchFreshPermission() -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        app.resetAuthorizationStatus(for: .microphone)
        app.launchArguments = ["-skipOnboarding", "-showCapture", "-demoWatchDraft"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Save a find"].waitForExistence(timeout: 15))
        return app
    }

    private func microphoneAlert() -> XCUIElement {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 8), "A real first-use microphone permission alert should appear")
        XCTAssertTrue(alert.label.localizedCaseInsensitiveContains("microphone") ||
            alert.staticTexts.allElementsBoundByIndex.contains { $0.label.localizedCaseInsensitiveContains("microphone") })
        return alert
    }

    private func allowMicrophone(_ alert: XCUIElement) {
        // iOS versions label the affirmative button either Allow or OK.
        let affirmative = alert.buttons.allElementsBoundByIndex.first { ["Allow", "OK"].contains($0.label) }
        XCTAssertNotNil(affirmative, "Expected the real iOS microphone Allow/OK button")
        affirmative?.tap()
    }

    private func waitForAttachment(in app: XCUIApplication) {
        let state = app.staticTexts["captureVoiceState"]
        let attached = NSPredicate(format: "label == %@ AND value == %@", "Voice note attached", "idle")
        expectation(for: attached, evaluatedWith: state)
        waitForExpectations(timeout: 8)
        XCTAssertFalse(app.buttons["captureStopVoice"].exists)
        XCTAssertFalse(app.buttons["captureRecordVoice"].exists)
        XCTAssertTrue(app.staticTexts["voiceAttachment"].exists)
        XCTAssertFalse(app.staticTexts["voiceRecordError"].exists)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, "Could not reach \(element.identifier)")
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
