import XCTest
import UIKit

/// Synthetic UI acceptance and owner-review gallery. Requires the Debug app.
/// Every attachment includes appearance, size and screen; findings are reported,
/// not treated as a clean accessibility baseline. Simulator execution unverified.
@MainActor final class VoiceRemoteUITests: XCTestCase {
    private var app = XCUIApplication()
    private let appearance = "light"
    private var size = "default"

    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ flags: [String] = [], largest: Bool = false) {
        app.terminate()
        size = largest ? "accessibility5" : "default"
        app = XCUIApplication()
        app.launchArguments = ["--ui-demo", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + flags
            + (largest ? ["--ui-largest"] : [])
        app.launch()
        let root = flags.contains("--ui-storage-denied") ? app.staticTexts["Private storage / audit recovery"] : app.tabBars.buttons["Home"]
        require(root, timeout: 30)
    }
    private func require(_ element: XCUIElement, timeout: TimeInterval = 8) {
        let found = element.waitForExistence(timeout: timeout)
        if !found { snapshot("missing-element") }
        XCTAssertTrue(found, "Expected element: \(element)")
    }
    private func scroll(up: Bool) {
        let scroller = app.scrollViews.firstMatch.exists ? app.scrollViews.firstMatch :
            (app.tables.firstMatch.exists ? app.tables.firstMatch : app)
        // The content margin avoids accidentally pressing the large talk control.
        let start = scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: up ? 0.8 : 0.2))
        let end = scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: up ? 0.2 : 0.8))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
    private func visible(_ element: XCUIElement, requireHittable: Bool = true) {
        _ = element.waitForExistence(timeout: 2)
        for up in [true, false] {
            for _ in 0..<(size == "accessibility5" ? 20 : 12) {
                if element.exists && (requireHittable ? element.isHittable : app.frame.intersects(element.frame)) { return }
                if element.exists && element.frame.maxY > 0 && element.frame.minY < 100 { scroll(up: false) }
                else { scroll(up: up) }
            }
        }
        snapshot("element-not-visible")
        XCTFail("Element did not become visible: \(element)")
    }
    private func tap(_ element: XCUIElement) { visible(element); element.tap() }
    private func tab(_ name: String) {
        if name == "Settings" {
            tab("Home"); tap(app.buttons["settings-link"])
            require(app.navigationBars["Settings"]); return
        }
        tap(app.tabBars.buttons[name])
        if name == "Home" {
            for _ in 0..<4 where !app.navigationBars["Voice Remote"].exists {
                tap(app.navigationBars.buttons.firstMatch)
            }
            require(app.navigationBars["Voice Remote"])
        } else { require(app.navigationBars[name]) }
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
        let element = app.staticTexts["consent-state"]
        visible(element)
        let value = on ? "On" : "Off"
        expect(element, label: "Cloud processing: " + value + "; saved: " + value)
        tap(app.buttons["settings-demo-details"]); top()
    }
    private func assertCaptureOff() {
        let off = app.segmentedControls["capture-picker"].buttons["Off"]
        visible(off)
        XCTAssertTrue(off.wait(for: \.isSelected, toEqual: true, timeout: 8), "Off must be the selected segment")
    }
    private func diagnostic(_ id: String) -> String {
        tap(app.buttons["demo-disclosure"])
        let element = app.staticTexts[id]
        visible(element); require(element)
        let value = element.label
        tap(app.buttons["demo-disclosure"])
        return value
    }
    private func top() { for _ in 0..<3 { scroll(up: false) } }
    private func expect(_ element: XCUIElement, label: String) {
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", label), object: element)
        let result = XCTWaiter.wait(for: [matched], timeout: 12)
        if result != .completed { snapshot("unexpected-state") }
        XCTAssertEqual(result, .completed, "Expected label: " + label)
    }
    private func state(_ value: String) {
        let element = app.staticTexts["listening-state"]
        if !element.exists || !element.isHittable { top() }
        visible(element)
        let labels = ["idle": "Ready", "preparing": "Getting ready", "listening": "Listening", "finishing": "Finishing", "interrupted": "Interrupted", "failed": "Recording unavailable"]
        expect(element, label: labels[value] ?? value)
    }
    private func capture(_ value: String) {
        let labels = ["OFF": "Off", "HOLD": "Hold", "CONTINUOUS": "Continuous"]
        let segment = app.segmentedControls["capture-picker"].buttons[labels[value] ?? value]
        tap(segment)
        // A fault may end Continuous immediately. Its resulting listening state
        // is asserted by the caller; only stable selections are checked here.
        if !["CONTINUOUS", "Continuous"].contains(value) {
            XCTAssertTrue(segment.wait(for: \.isSelected, toEqual: true, timeout: 8))
        }
    }
    private func mode(_ value: String) {
        tap(app.segmentedControls["mode-picker"].buttons[value])
    }
    private func snapshot(_ screen: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "gallery__\(appearance)__\(size)__" + screen
        screenshot.lifetime = .keepAlways; add(screenshot)
    }
    private func assertHomeLayout() {
        let identifiers = ["destination-link", "hold-to-talk", "preparing-talk", "stop-immediately", "enable-capture",
            "start-continuous", "finish-utterance", "capture-label", "capture-picker", "mode-label", "mode-picker", "demo-disclosure"]
        let viewport = app.frame.insetBy(dx: 0, dy: 100)
        let frames = identifiers.compactMap { id -> (String, CGRect)? in
            let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
            guard element.exists else { return nil }
            let frame = element.frame.insetBy(dx: 1, dy: 1)
            return viewport.intersects(frame) ? (id, frame) : nil
        }
        for (index, upper) in frames.enumerated() {
            for lower in frames.dropFirst(index + 1) {
                XCTAssertFalse(upper.1.intersects(lower.1), "Home controls overlap: " + upper.0 + " / " + lower.0)
            }
        }
    }
    private func shot(_ screen: String, audit: Bool = true) throws {
        let label = "\(appearance)__\(size)__\(screen)"
        snapshot(screen)
        if app.navigationBars["Voice Remote"].exists { assertHomeLayout() }
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

    func testFirstRunAndRecovery() throws {
        launch(["--ui-first-run"])
        try shot("first-run")
        XCTAssertTrue(app.buttons["permission-continue"].exists)
        XCTAssertFalse(app.buttons["hold-to-talk"].exists)
        tap(app.buttons["permission-continue"])
        try shot("permission-explanation")
        tap(app.buttons["permission-allow"])
        XCTAssertTrue(app.buttons["permission-allow"].waitForNonExistence(timeout: 5))
        try shot("first-run-consented")

        launch(["--ui-permission-denied"])
        tap(app.buttons["permission-continue"]); tap(app.buttons["permission-allow"])
        XCTAssertTrue(app.alerts["Voice Remote"].waitForExistence(timeout: 5))
        try shot("microphone-speech-denied")
        tap(app.alerts.buttons["OK"])
        XCTAssertFalse(app.buttons["hold-to-talk"].exists)

        launch(["--ui-storage-denied"])
        XCTAssertFalse(app.tabBars.buttons["Home"].exists)
        try shot("private-storage-audit-recovery")
        tap(app.buttons["Authenticate and restore verified audit copy"])
        XCTAssertTrue(app.staticTexts["Synthetic verified copy unavailable. Approvals remain unavailable; originals are preserved."].waitForExistence(timeout: 5))
        try shot("audit-recovery-unavailable")
    }

    func testHomeDestinationAndHold() throws {
        launch()
        state("idle"); try shot("home")
        tap(app.buttons["About recording"]); try shot("recording-info"); tap(app.buttons["Done"])
        tap(app.buttons["destination-link"])
        XCTAssertTrue(app.buttons["target-auto"].exists)
        try shot("target-picker")
        tap(app.buttons["target-phone"]); tap(app.buttons["target-auto"])
        tap(app.navigationBars.buttons.firstMatch)
        XCTAssertTrue(app.buttons["destination-link"].label.contains("iPhone"))
        try shot("target-auto-selected")
        tap(app.buttons["destination-link"])
        tap(app.buttons["target-synthetic-pc"])
        tap(app.navigationBars.buttons.firstMatch)
        XCTAssertTrue(app.buttons["destination-link"].label.contains("Synthetic Studio"))
        capture("HOLD")
        let hold = app.buttons["hold-to-talk"]
        top(); visible(hold)
        try shot("destination-before-hold", audit: false)
        XCTAssertTrue(app.buttons["destination-link"].isHittable)
        XCTAssertLessThanOrEqual(app.buttons["destination-link"].frame.maxY, hold.frame.minY)
        // Exercise the real hold recognizer. The capture adapter records the
        // destination/empty-text invariant before emitting its first frame.
        hold.press(forDuration: 1.0)
        state("idle")
        XCTAssertEqual(diagnostic("demo-order"), "Destination before capture: Yes")
        tab("History")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "synthetic workspace note")).firstMatch.waitForExistence(timeout: 5))
        try shot("history-after-hold")
    }

    func testHistoryFlow() throws {
        launch(); tab("History"); try shot("history")
        tap(app.buttons["send-synthetic-held"])
        XCTAssertTrue(app.buttons["send-synthetic-held"].wait(for: \.label, toEqual: "Resend after checking computer", timeout: 5))
        try shot("history-held-sent-unconfirmed")
        XCTAssertTrue(app.staticTexts["history-synthetic-unconfirmed"].exists)
        tap(app.buttons["history-more-synthetic-held"]); try shot("history-actions")
        tap(app.buttons["Copy"])
    }

    func testModeAndCaptureSwitches() throws {
        launch()
        tap(app.buttons["destination-link"]); tap(app.buttons["target-synthetic-pc"])
        tap(app.navigationBars.buttons.firstMatch)
        mode("AI Control"); capture("CONTINUOUS"); state("listening")
        XCTAssertTrue(app.buttons["destination-link"].label.contains("Synthetic Studio"))
        XCTAssertTrue(app.staticTexts["partial-text"].waitForExistence(timeout: 5))
        try shot("listening")
        tap(app.buttons["finish-utterance"]); state("idle")
        visible(app.buttons["start-continuous"]); try shot("utterance-finished")
        capture("Off"); state("idle")
        XCTAssertFalse(app.buttons["stop-immediately"].exists)
        XCTAssertFalse(app.staticTexts["partial-text"].exists)
    }

    func testSuggestionsApprovalAndAgents() throws {
        launch()
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
    }

    func testDevicesPairingFlow() throws {
        launch()
        tab("Devices"); top(); try shot("devices")
        tap(app.buttons["About devices"]); try shot("devices-info"); tap(app.buttons["Done"])
        tap(app.buttons["phone-details"]); try shot("phone-details")
        tap(app.navigationBars.buttons.firstMatch)
        tap(app.buttons["pair-computer"]); try shot("pairing-invitation")
        let invitation = app.descendants(matching: .any).matching(identifier: "pairing-invitation").firstMatch
        tap(invitation)
        UIPasteboard.general.string = "voiceremote://synthetic-invitation"
        invitation.press(forDuration: 1.1)
        let paste = app.menuItems["Paste"]
        if paste.waitForExistence(timeout: 2) { paste.tap() } else { tap(app.buttons.matching(identifier: "Paste").firstMatch) }
        if app.alerts.firstMatch.waitForExistence(timeout: 1) { tap(app.alerts.buttons["Allow Paste"]) }
        tap(app.buttons["Connect"])
        XCTAssertEqual(app.staticTexts["pairing-phrase"].waitForExistence(timeout: 5), true)
        visible(app.staticTexts["pairing-phrase"]); try shot("pairing-four-words")
        XCTAssertEqual(app.staticTexts["pairing-phrase"].label, "maple river copper orbit")
        XCTAssertEqual(app.keyboards.count, 0)
        XCTAssertTrue(app.staticTexts["pairing-phrase"].isHittable)
        XCTAssertFalse(app.staticTexts["device-synthetic-new"].exists)
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
    }

    func testSettingsRecorderFlow() throws {
        launch()
        tab("Settings"); top()
        let consent = app.switches["cloud-consent"]
        visible(consent); try shot("settings")
        XCTAssertEqual(consent.value as? String, "0")
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
    }

    func testBiometricRefusal() throws {
        launch(["--ui-biometric-refuse"])
        tab("Suggestions"); tap(app.buttons.matching(identifier: "review-suggestion").firstMatch)
        tap(app.buttons["approve-action"])
        XCTAssertTrue(app.staticTexts["Approval denied or expired. Nothing was started."].waitForExistence(timeout: 5))
        try shot("biometric-refused")
        tap(app.buttons["approval-deny"]); tab("Home")
        XCTAssertEqual(diagnostic("demo-tasks"), "Tasks: 0")
    }

    // Separate cases preserve later state screenshots after an earlier failure.
    func testStopPreparing() throws { try stopScenario("--ui-slow-prepare", expected: "preparing") }
    func testStopFinishing() throws { try stopScenario("--ui-slow-finish", expected: "finishing") }
    func testStopFailed() throws { try stopScenario("--ui-capture-failure", expected: "failed") }
    func testStopInterrupted() throws { try stopScenario("--ui-interrupt", expected: "interrupted") }
    func testStopListening() throws { try stopScenario("", expected: "listening") }

    private func stopScenario(_ flag: String, expected: String) throws {
        launch(flag.isEmpty ? [] : [flag])
        capture("Continuous")
        if expected == "finishing" { state("listening"); tap(app.buttons["finish-utterance"]) }
        state(expected); try shot("stop-before-" + expected)
        if ["preparing", "listening", "finishing"].contains(expected) {
            if expected == "preparing" {
                let preparing = app.buttons["preparing-talk"]
                visible(preparing, requireHittable: false)
                XCTAssertFalse(preparing.isEnabled)
            }
            tap(app.buttons["stop-immediately"])
        } else { capture("Off") }
        state("idle"); try shot("stop-after-" + expected, audit: false)
        assertCaptureOff()
        XCTAssertFalse(app.staticTexts["partial-text"].exists)
        tab("History")
        XCTAssertEqual(app.staticTexts.matching(identifier: "history-synthetic-held").count, 1)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "synthetic workspace note")).firstMatch.exists)
    }

    func testOffInEveryCaptureMode() {
        launch()
        for value in ["Off", "Hold", "Continuous"] {
            capture(value); capture("Off"); state("idle"); assertCaptureOff()
        }
    }

    func testTalkStateGallery() throws { try talkStateGallery(largest: false) }
    func testLargestTalkStateGallery() throws { try talkStateGallery(largest: true) }

    private func talkStateGallery(largest: Bool) throws {
        launch(["--ui-holding-preview"], largest: largest)
        state("listening"); visible(app.buttons["hold-to-talk"])
        try shot("holding")
        XCTAssertTrue(app.buttons["hold-to-talk"].label.contains("Release to finish"))
        top(); visible(app.staticTexts["partial-text"]); try shot("holding-live-transcript", audit: false)
        tap(app.buttons["stop-immediately"]); state("idle")
        try shot("capture-off")
        tap(app.buttons["enable-capture"])
        visible(app.buttons["hold-to-talk"]); try shot("hold-ready", audit: false)
        launch(["--ui-slow-finish"], largest: largest)
        capture("Continuous"); state("listening")
        try shot("continuous-live-transcript")
        XCTAssertFalse(app.buttons["hold-to-talk"].exists)
        tap(app.buttons["finish-utterance"]); state("finishing")
        try shot("finishing")
        tap(app.buttons["stop-immediately"]); state("idle")
    }

    func testReduceTransparencyGallery() throws {
        launch(["--ui-holding-preview", "--ui-reduce-transparency"])
        state("listening"); visible(app.buttons["hold-to-talk"])
        try shot("reduce-transparency-preview")
        tap(app.buttons["stop-immediately"]); state("idle")
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

    func testMainScreenGallery() throws { try mainScreens(largest: false) }
    func testLargestDynamicTypeMainScreens() throws { try mainScreens(largest: true) }

    private func mainScreens(largest: Bool) throws {
        // Inventory must survive a failed layout assertion on an earlier tab.
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        launch(largest: largest)
        for name in ["Home", "Devices", "History", "Suggestions", "Agents", "Settings"] {
            tab(name); top(); try shot("main-" + name.lowercased())
            if largest {
                let bottomID = ["Home": "mode-picker", "Devices": "phone-details", "History": "history-more-synthetic-held",
                    "Suggestions": "review-suggestion", "Agents": "wake-permission", "Settings": "benchmark-recorder"][name]!
                visible(app.descendants(matching: .any).matching(identifier: bottomID).firstMatch)
                try shot("main-" + name.lowercased() + "-controls")
            }
        }
        XCTAssertEqual(app.tabBars.buttons.count, 5)
        tab("Home"); tap(app.buttons["destination-link"]); try shot("target-picker")
    }

    func testLargestApprovalSheet() throws {
        launch(largest: true)
        tab("Suggestions"); tap(app.buttons.matching(identifier: "review-suggestion").firstMatch)
        require(app.staticTexts["approval-exact-action"]); try shot("tier3-approval")
        visible(app.buttons["approve-action"]); try shot("tier3-approval-action")
    }

    func testLargestPairingAndRecorder() throws {
        launch(largest: true)
        tab("Devices"); tap(app.buttons["pair-computer"]); try shot("pairing-invitation")
        let invitation = app.descendants(matching: .any).matching(identifier: "pairing-invitation").firstMatch
        tap(invitation); invitation.typeText("voiceremote://synthetic-invitation")
        tap(app.buttons["Connect"])
        require(app.staticTexts["pairing-phrase"]); top(); try shot("pairing-four-words")
        visible(app.buttons["The words match on both screens"]); try shot("pairing-confirmation-action")
        tap(app.buttons["pairing-cancel"])
        tab("Settings"); tap(app.buttons["benchmark-recorder"]); try shot("benchmark-recorder")
        tap(app.buttons["Record prompt"]); require(app.buttons["Finish"])
        visible(app.buttons["Finish"]); try shot("benchmark-recording")
        tap(app.buttons["Discard recording"])
    }
}
