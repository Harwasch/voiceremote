import XCTest
import UIKit

/// Synthetic UI acceptance and owner-review gallery. Requires the Debug app.
/// Every attachment includes appearance, size and screen; findings are reported,
/// not treated as a clean accessibility baseline. Simulator execution unverified.
@MainActor final class VoiceRemoteUITests: XCTestCase {
    private var app = XCUIApplication()
    private var appearance = "light"
    private var size = "default"

    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ flags: [String] = [], dark: Bool = false, largest: Bool = false) {
        app.terminate()
        appearance = dark ? "dark" : "light"; size = largest ? "accessibility5" : "default"
        app = XCUIApplication()
        app.launchArguments = ["--ui-demo", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + flags
            + (dark ? ["--ui-dark"] : []) + (largest ? ["--ui-largest"] : [])
        app.launch()
        let root = flags.contains("--ui-storage-denied") ? app.staticTexts["Private storage / audit recovery"] : app.tabBars.buttons["Home"]
        XCTAssertTrue(root.waitForExistence(timeout: 20), "Debug demo must start without private storage or hardware")
    }
    private func visible(_ element: XCUIElement) {
        for reverse in [false, true] {
            for _ in 0..<12 {
                if element.exists && element.isHittable { return }
                if element.exists && element.frame.maxY > 0 && element.frame.minY < 100 { app.swipeDown() }
                else if reverse { app.swipeDown() } else { app.swipeUp() }
            }
        }
        XCTFail("Element did not become visible: \(element)")
    }
    private func tap(_ element: XCUIElement) { visible(element); element.tap() }
    private func tab(_ name: String) {
        if name == "Settings" {
            tab("Home"); tap(app.buttons["settings-link"])
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5)); return
        }
        app.tabBars.buttons[name].tap()
        if name == "Home" {
            for _ in 0..<4 where !app.segmentedControls["capture-picker"].exists && !app.buttons["permission-continue"].exists && !app.buttons["permission-allow"].exists {
                app.navigationBars.buttons.firstMatch.tap()
            }
        }
    }
    private func setSwitch(_ identifier: String, on: Bool) {
        let control = app.switches.matching(identifier: identifier).firstMatch
        visible(control)
        let desired = on ? "1" : "0"
        if control.value as? String == desired { return }
        let native = control.switches.firstMatch
        if native.exists && native.isHittable { native.tap() }
        else { control.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -26, dy: 0)).tap() }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", desired), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    }
    private func assertSavedConsent(_ on: Bool) {
        tap(app.buttons["settings-demo-details"])
        let value = on ? "On" : "Off"
        XCTAssertTrue(app.staticTexts["consent-state"].wait(for: \.label, toEqual: "Cloud processing: " + value + "; saved: " + value, timeout: 5))
        tap(app.buttons["settings-demo-details"]); top()
    }
    private func assertCaptureOff() {
        XCTAssertEqual(app.segmentedControls["capture-picker"].buttons["Off"].value as? String, "1")
    }
    private func diagnostic(_ id: String) -> String {
        tap(app.buttons["demo-disclosure"])
        let value = app.staticTexts[id].label
        tap(app.buttons["demo-disclosure"])
        return value
    }
    private func top() { for _ in 0..<5 { app.swipeDown() } }
    private func state(_ value: String) {
        let element = app.staticTexts["listening-state"]
        if !element.exists { top() }
        let labels = ["idle": "Ready", "preparing": "Getting ready", "listening": "Listening", "finishing": "Finishing", "interrupted": "Interrupted", "failed": "Recording unavailable"]
        let predicate = NSPredicate(format: "label == %@", labels[value] ?? value)
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: 12)
    }
    private func capture(_ value: String) {
        let labels = ["OFF": "Off", "HOLD": "Hold", "CONTINUOUS": "Continuous"]
        let segment = app.segmentedControls["capture-picker"].buttons[labels[value] ?? value]
        tap(segment)
    }
    private func mode(_ value: String) {
        tap(app.segmentedControls["mode-picker"].buttons[value])
    }
    private func shot(_ screen: String, audit: Bool = true) throws {
        let label = "\(appearance)__\(size)__\(screen)"
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "gallery__" + label; screenshot.lifetime = .keepAlways; add(screenshot)
        guard audit else { return }
        var findings: [[String: String]] = []
        try app.performAccessibilityAudit(for: .all) { issue in
            findings.append(["type": String(describing: issue.auditType), "summary": issue.compactDescription,
                "detail": issue.detailedDescription, "element": issue.element?.debugDescription ?? "unavailable"])
            // Initial inventory, deliberately non-gating: preserve every issue for
            // owner triage. Assertion failures and audit infrastructure errors fail.
            return true
        }
        let report: [String: Any] = ["screen": label, "mode": "report-only", "findings": findings]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
            uniformTypeIdentifier: "public.json")
        attachment.name = "audit__" + label; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testLightGalleryAndFlows() throws { try gallery(dark: false) }
    func testDarkGalleryAndFlows() throws { try gallery(dark: true) }

    private func gallery(dark: Bool) throws {
        launch(["--ui-first-run"], dark: dark)
        XCTAssertTrue(app.buttons["permission-continue"].exists)
        XCTAssertFalse(app.buttons["hold-to-talk"].exists)
        try shot("first-run")
        tap(app.buttons["permission-continue"])
        try shot("permission-explanation")
        tap(app.buttons["permission-allow"])
        XCTAssertTrue(app.buttons["permission-allow"].waitForNonExistence(timeout: 5))
        try shot("first-run-consented")

        launch(dark: dark)
        state("idle"); try shot("home")
        tap(app.buttons["About recording"]); try shot("recording-info"); tap(app.buttons["Done"])
        tap(app.buttons["destination-link"])
        XCTAssertTrue(app.buttons["target-auto"].exists)
        try shot("target-picker")
        tap(app.buttons["target-phone"]); tap(app.buttons["target-auto"])
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["destination-link"].label.contains("iPhone"))
        try shot("target-auto-selected")
        tap(app.buttons["destination-link"])
        tap(app.buttons["target-synthetic-pc"])
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["destination-link"].label.contains("Synthetic Studio"))
        capture("HOLD")
        let hold = app.buttons["hold-to-talk"]
        visible(hold)
        // Exercise the real hold recognizer. The capture adapter records the
        // destination/empty-text invariant before emitting its first frame.
        hold.press(forDuration: 1.0)
        state("idle")
        XCTAssertEqual(diagnostic("demo-order"), "Destination before capture: Yes")
        tab("History")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "synthetic workspace note")).firstMatch.waitForExistence(timeout: 5))
        try shot("history-after-hold")
        tap(app.buttons["send-synthetic-held"])
        XCTAssertTrue(app.buttons["send-synthetic-held"].wait(for: \.label, toEqual: "Resend after checking computer", timeout: 5))
        try shot("history-held-sent-unconfirmed")
        XCTAssertTrue(app.staticTexts["history-synthetic-unconfirmed"].exists)
        tap(app.buttons["history-more-synthetic-held"]); try shot("history-actions")
        tap(app.buttons["Copy"])

        tab("Home"); top()
        mode("AI Control"); capture("CONTINUOUS"); state("listening")
        XCTAssertTrue(app.buttons["destination-link"].label.contains("Synthetic Studio"))
        XCTAssertTrue(app.staticTexts["partial-text"].waitForExistence(timeout: 5))
        try shot("listening")
        tap(app.buttons["finish-utterance"]); state("idle")
        XCTAssertTrue(app.buttons["start-continuous"].exists)
        try shot("utterance-finished")
        capture("Off"); state("idle")
        XCTAssertFalse(app.buttons["stop-immediately"].exists)
        XCTAssertFalse(app.staticTexts["partial-text"].exists)

        tab("Suggestions")
        try shot("suggestions")
        XCTAssertFalse(app.staticTexts["suggestion-summary"].label.contains("delegateTaskTool"))
        tab("Agents")
        visible(app.staticTexts["Offline — commands held"])
        try shot("agent-sessions")
        tab("Suggestions")
        tap(app.buttons.matching(identifier: "review-suggestion").firstMatch)
        XCTAssertTrue(app.staticTexts["approval-exact-action"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Face ID or iPhone passcode required"].exists)
        try shot("tier3-approval")
        tap(app.buttons["approve-action"])
        XCTAssertTrue(app.staticTexts["approval-exact-action"].waitForNonExistence(timeout: 8))
        tab("Agents")
        let task = app.staticTexts.matching(identifier: "task-status").firstMatch
        visible(task); XCTAssertTrue(task.exists)
        try shot("agent-task-dispatched")
        tap(app.buttons.matching(identifier: "Confirm observed completion…").firstMatch)
        XCTAssertTrue(app.navigationBars["Owner completion"].waitForExistence(timeout: 5))
        try shot("owner-completion")
        tap(app.buttons["Keep waiting"])
        tap(app.buttons.matching(identifier: "cancel-task").firstMatch)
        XCTAssertTrue(app.buttons.matching(identifier: "cancel-task").firstMatch.wait(for: \.label, toEqual: "Retry cancellation", timeout: 5))
        XCTAssertTrue(app.staticTexts["task-status"].label.contains("Cancelling"))
        try shot("agent-cancellation-pending")
        visible(app.buttons.matching(identifier: "Revoke permission").firstMatch)
        try shot("scoped-grants")
        tap(app.buttons.matching(identifier: "Revoke permission").firstMatch)
        XCTAssertFalse(app.buttons["Revoke permission"].exists)

        tab("Devices"); top(); try shot("devices")
        tap(app.buttons["About devices"]); try shot("devices-info"); tap(app.buttons["Done"])
        tap(app.buttons["phone-details"]); try shot("phone-details")
        app.navigationBars.buttons.firstMatch.tap()
        tap(app.buttons["pair-computer"]); try shot("pairing-invitation")
        let invitation = app.descendants(matching: .any).matching(identifier: "pairing-invitation").firstMatch
        tap(invitation)
        UIPasteboard.general.string = "voiceremote://synthetic-invitation"
        invitation.press(forDuration: 1.1)
        let paste = app.menuItems["Paste"]
        if paste.waitForExistence(timeout: 2) { paste.tap() } else { app.buttons.matching(identifier: "Paste").firstMatch.tap() }
        if app.alerts.firstMatch.waitForExistence(timeout: 1) { app.alerts.buttons["Allow Paste"].tap() }
        tap(app.buttons["Connect"])
        XCTAssertEqual(app.staticTexts["pairing-phrase"].waitForExistence(timeout: 5), true)
        XCTAssertEqual(app.staticTexts["pairing-phrase"].label, "maple river copper orbit")
        XCTAssertEqual(app.keyboards.count, 0)
        XCTAssertTrue(app.staticTexts["pairing-phrase"].isHittable)
        XCTAssertFalse(app.staticTexts["device-synthetic-new"].exists)
        try shot("pairing-four-words")
        tap(app.buttons["The words match on both screens"])
        top()
        XCTAssertTrue(app.staticTexts["device-synthetic-new"].waitForExistence(timeout: 5))
        try shot("pairing-confirmed")
        app.staticTexts["device-synthetic-new"].swipeLeft()
        tap(app.buttons.matching(identifier: "Revoke").firstMatch)
        XCTAssertTrue(app.staticTexts["device-synthetic-new"].waitForNonExistence(timeout: 5))
        try shot("pairing-revoked")
        tap(app.buttons["pair-computer"])
        tap(app.buttons["Scan QR code"])
        XCTAssertTrue(app.staticTexts["Camera access denied"].waitForExistence(timeout: 5))
        try shot("camera-denied")
        tap(app.buttons["Cancel scan"])
        tap(app.buttons["pairing-cancel"])
        visible(app.staticTexts["remote-status"])
        try shot("remote-bluetooth-denied")

        tab("Settings"); top()
        let consent = app.switches["cloud-consent"]
        XCTAssertEqual(consent.value as? String, "0")
        try shot("settings")
        tap(app.buttons["Privacy and help"]); try shot("privacy-info"); tap(app.buttons["Done"])
        setSwitch("cloud-consent", on: true)
        assertSavedConsent(true)
        try shot("settings-cloud-consented")
        tab("Home"); top(); capture("CONTINUOUS"); state("listening")
        tab("Settings"); top()
        setSwitch("cloud-consent", on: false)
        assertSavedConsent(false)
        tab("Home"); top(); state("idle")
        assertCaptureOff()
        tab("Settings")
        tap(app.buttons["benchmark-recorder"])
        XCTAssertTrue(app.navigationBars["Benchmark recorder"].waitForExistence(timeout: 5))
        try shot("benchmark-recorder")
        tap(app.buttons["About recorder"]); try shot("recorder-info"); tap(app.buttons["Done"])
        tap(app.buttons["Record prompt"])
        XCTAssertTrue(app.buttons["Finish"].waitForExistence(timeout: 5))
        try shot("benchmark-recording")
        tap(app.buttons["Finish"]); top()
        XCTAssertTrue(app.staticTexts["1 / 1 prompts completed"].waitForExistence(timeout: 8))
        try shot("benchmark-completed")

        launch(["--ui-biometric-refuse"], dark: dark)
        tab("Suggestions"); tap(app.buttons.matching(identifier: "review-suggestion").firstMatch)
        tap(app.buttons["approve-action"])
        XCTAssertTrue(app.staticTexts["Approval denied or expired. Nothing was started."].waitForExistence(timeout: 5))
        try shot("biometric-refused")
        tap(app.buttons["approval-deny"]); tab("Home")
        XCTAssertEqual(diagnostic("demo-tasks"), "Tasks: 0")

        launch(["--ui-permission-denied"], dark: dark)
        tap(app.buttons["permission-continue"]); tap(app.buttons["permission-allow"])
        XCTAssertTrue(app.alerts["Voice Remote"].waitForExistence(timeout: 5))
        try shot("microphone-speech-denied")
        app.alerts.buttons["OK"].tap()
        XCTAssertFalse(app.buttons["hold-to-talk"].exists)

        launch(["--ui-storage-denied"], dark: dark)
        XCTAssertFalse(app.tabBars.buttons["Home"].exists)
        try shot("private-storage-audit-recovery")
        tap(app.buttons["Authenticate and restore verified audit copy"])
        XCTAssertTrue(app.staticTexts["Synthetic verified copy unavailable. Approvals remain unavailable; originals are preserved."].waitForExistence(timeout: 5))
        try shot("audit-recovery-unavailable")
    }

    func testStopEveryState() throws {
        for dark in [false, true] {
            for (flag, expected) in [("--ui-slow-prepare", "preparing"), ("--ui-slow-finish", "finishing"),
                ("--ui-capture-failure", "failed"), ("--ui-interrupt", "interrupted"), ("", "listening")] {
                launch(flag.isEmpty ? [] : [flag], dark: dark)
                capture("CONTINUOUS")
                if expected == "finishing" { state("listening"); tap(app.buttons["finish-utterance"]) }
                state(expected); try shot("stop-before-" + expected)
                if expected == "listening" || expected == "finishing" { tap(app.buttons["emergency-stop"]) }
                else { XCTAssertFalse(app.buttons["stop-immediately"].exists); capture("Off") }
                state("idle")
                assertCaptureOff()
                XCTAssertFalse(app.staticTexts["partial-text"].exists)
                try shot("stop-after-" + expected)
                tab("History")
                XCTAssertEqual(app.staticTexts.matching(identifier: "history-synthetic-held").count, 1)
                XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "synthetic workspace note")).firstMatch.exists)
            }
            launch(dark: dark)
            for value in ["OFF", "HOLD", "CONTINUOUS"] {
                capture(value); capture("Off"); state("idle")
                assertCaptureOff()
            }
        }
    }

    func testTalkStateGallery() throws {
        for dark in [false, true] {
            for largest in [false, true] {
                launch(["--ui-holding-preview"], dark: dark, largest: largest)
                state("listening")
                visible(app.buttons["hold-to-talk"])
                XCTAssertTrue(app.buttons["hold-to-talk"].label.contains("Release to finish"))
                try shot("holding", audit: !largest)
                top(); visible(app.staticTexts["partial-text"]); try shot("holding-live-transcript", audit: !largest)
                tap(app.buttons["emergency-stop"]); state("idle")
                try shot("capture-off", audit: !largest)
                tap(app.buttons["enable-capture"])
                XCTAssertTrue(app.buttons["hold-to-talk"].exists)
                try shot("hold-ready", audit: !largest)
                launch(["--ui-slow-finish"], dark: dark, largest: largest)
                capture("Continuous"); state("listening")
                XCTAssertFalse(app.buttons["hold-to-talk"].exists)
                try shot("continuous-live-transcript", audit: !largest)
                tap(app.buttons["finish-utterance"]); state("finishing")
                try shot("finishing", audit: !largest)
                tap(app.buttons["emergency-stop"]); state("idle")
            }
            launch(["--ui-holding-preview", "--ui-reduce-transparency"], dark: dark)
            state("listening"); visible(app.buttons["hold-to-talk"])
            try shot("reduce-transparency-preview")
            tap(app.buttons["emergency-stop"])
        }
    }

    func testToggleControls() throws {
        launch()
        tab("Suggestions"); setSwitch("mute-suggestions", on: true); setSwitch("mute-suggestions", on: false)
        tab("Settings")
        setSwitch("maximum-accuracy", on: true); setSwitch("maximum-accuracy", on: false)
        setSwitch("comparison-tools", on: false); setSwitch("comparison-tools", on: true)
        setSwitch("cloud-consent", on: true); assertSavedConsent(true)
        setSwitch("cloud-consent", on: false); assertSavedConsent(false)
        tab("Agents")
        for id in ["cloud-fallback", "independent-task", "wake-permission"] {
            setSwitch(id, on: true); setSwitch(id, on: false)
        }
        tab("Settings"); tap(app.buttons["benchmark-recorder"])
        setSwitch("keep-benchmark-audio", on: true); setSwitch("keep-benchmark-audio", on: false)
    }

    func testLargestDynamicTypeMainScreens() throws {
        launch(largest: true)
        XCTAssertEqual(app.tabBars.buttons.count, 5)
        for name in ["Home", "Devices", "History", "Suggestions", "Agents", "Settings"] {
            tab(name); try shot("main-" + name.lowercased())
        }
        tab("Home"); tap(app.buttons["destination-link"]); try shot("target-picker")
        app.navigationBars.buttons.firstMatch.tap()
        launch(largest: true) // Refresh the review card after the main-screen audits.
        tab("Suggestions"); tap(app.buttons.matching(identifier: "review-suggestion").firstMatch)
        try shot("tier3-approval")
    }
}
