import XCTest
import UIKit

/// Synthetic UI acceptance and owner-review gallery. Requires the Debug app.
/// Every attachment includes appearance, size and screen; findings are reported,
/// not treated as a clean accessibility baseline. Simulator execution unverified.
@MainActor final class VoiceRemoteUITests: XCTestCase {
    private var app = XCUIApplication()
    private let appearance = "light"
    private var size = "default"
    private var seekUp = true
    private static var auditedScreens: Set<String> = []
    private static var lastLaunchArguments: [String]?

    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ flags: [String] = [], largest: Bool = false, reuse: Bool = false) {
        let arguments = ["--ui-demo", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + flags
            + (largest ? ["--ui-largest"] : [])
        size = largest ? "accessibility5" : "default"
        app = XCUIApplication()
        if reuse && Self.lastLaunchArguments == arguments && app.state == .runningForeground {
            tab("Talk"); return
        }
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = arguments
        app.launch()
        Self.lastLaunchArguments = arguments
        let root = flags.contains("--ui-storage-denied") ? app.staticTexts["storage-recovery-title"] : app.tabBars.buttons["Talk"]
        require(root, timeout: 30)
    }
    private func require(_ element: XCUIElement, timeout: TimeInterval = 3) {
        let found = element.appears(timeout: timeout)
        if !found { snapshot("missing-element") }
        XCTAssertTrue(found, "Expected element: \(element)")
    }
    private func scroll(up: Bool) {
        // App-relative gestures cannot retain a disappearing sheet's ScrollView.
        // Native swipes scroll the actual hit-tested list/scroll view, including
        // UICollectionView-backed SwiftUI Lists. Talk keeps its controls pinned.
        let keyboard = app.keyboards.firstMatch
        let frame = app.frame
        var lower = keyboard.exists ? min(frame.maxY - 120, keyboard.frame.minY - 24) : frame.maxY - 120
        var hasPinnedControl = false
        if app.buttons["settings-link"].isHittable {
            let pinned = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["hold-to-talk", "preparing-talk", "finishing-talk", "finish-utterance", "enable-capture", "start-continuous", "stop-immediately"])).firstMatch
            if pinned.exists { lower = min(lower, pinned.frame.minY - 32); hasPinnedControl = true }
        }
        if keyboard.exists || hasPinnedControl {
            // Stay inside scrollable content, above the pinned recording controls.
            let upper = frame.minY + 140
            guard lower > upper + 20 else { return }
            let startY = up ? lower : upper
            let endY = up ? upper : lower
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (startY - frame.minY) / frame.height))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (endY - frame.minY) / frame.height))
            start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        } else if up { app.swipeUp(velocity: .fast) } else { app.swipeDown(velocity: .fast) }
    }

    private func visible(_ element: XCUIElement, requireHittable: Bool = true) {
        if !element.exists { _ = element.appears(timeout: 1) }
        var viewport = app.frame.insetBy(dx: 0, dy: 100)
        if !requireHittable && element.identifier == "partial-text" && app.buttons["settings-link"].isHittable {
            let pinned = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["hold-to-talk", "finish-utterance", "stop-immediately"])).firstMatch
            if pinned.exists { viewport.size.height = max(0, min(viewport.maxY, pinned.frame.minY - 32) - viewport.minY) }
        }
        for _ in 0..<8 {
            if element.exists {
                if requireHittable && element.isHittable { seekUp = true; return }
                let frame = element.frame
                if !requireHittable && viewport.intersects(frame) { seekUp = true; return }
                seekUp = frame.minY >= viewport.minY
            }
            scroll(up: seekUp)
        }
        snapshot("element-not-visible")
        XCTFail("Element did not become hittable after eight swipes: \(element)")
    }
    private func tap(_ element: XCUIElement) { visible(element); element.tap() }
    private func tab(_ name: String) {
        if name == "Settings" {
            tab("Talk"); tap(app.buttons["settings-link"])
            require(app.navigationBars["Settings"]); return
        }
        tap(app.tabBars.buttons[name])
        if name == "Talk" {
            for _ in 0..<4 {
                if app.buttons["settings-link"].exists { break }
                tap(app.navigationBars.buttons.firstMatch)
            }
            require(app.buttons["settings-link"])
        } else { require(app.navigationBars[name]) }
    }
    private func ideas() { tab("Talk"); mode("AI Control") }
    private func destinationDone() { tap(app.buttons["destination-done"]) }
    private func finish() {
        if app.buttons["finish-utterance"].exists { tap(app.buttons["finish-utterance"]) }
        else { tap(app.buttons["capture-menu"]); tap(app.buttons["finish-menu"]) }
    }
    private func setSwitch(_ identifier: String, on: Bool) {
        let control = app.switches.matching(identifier: identifier).firstMatch
        visible(control)
        let desired = on ? "1" : "0"
        if control.value as? String == desired { return }
        let native = control.switches.firstMatch
        if native.exists && native.isHittable { native.tap() }
        else { control.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -26, dy: 0)).tap() }
        if control.value as? String == desired { return }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", desired), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed)
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
        expectValue(app.buttons["capture-menu"], value: "Off")
    }
    private func diagnostic(_ id: String) -> String {
        tab("Settings"); tap(app.buttons["settings-demo-details"])
        let element = app.staticTexts[id]
        visible(element); require(element)
        let value = element.label
        tap(app.buttons["settings-demo-details"]); tab("Talk")
        return value
    }
    private func top() { scroll(up: false); seekUp = false }
    private func expect(_ element: XCUIElement, label: String) {
        if element.exists && element.label == label { return }
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", label), object: element)
        let result = XCTWaiter.wait(for: [matched], timeout: 3)
        if result != .completed { snapshot("unexpected-state") }
        XCTAssertEqual(result, .completed, "Expected label: " + label)
    }
    private func expectValue(_ element: XCUIElement, value: String) {
        require(element)
        if element.value as? String == value { return }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed)
    }
    private func state(_ value: String) {
        let labels = ["idle": "Ready", "preparing": "Getting ready", "listening": "Listening", "finishing": "Finishing", "interrupted": "Interrupted", "failed": "Recording unavailable"]
        let ids = ["hold-to-talk", "preparing-talk", "finishing-talk", "finish-utterance", "enable-capture", "start-continuous", "stop-immediately"]
        let control = app.buttons.matching(NSPredicate(format: "identifier IN %@ AND value == %@", ids, labels[value] ?? value)).firstMatch
        require(control)
    }
    private func capture(_ value: String) {
        let labels = ["OFF": "Off", "HOLD": "Hold", "CONTINUOUS": "Continuous"]
        let label = labels[value] ?? value
        tap(app.buttons["capture-menu"])
        tap(app.buttons[label].firstMatch)
        if label != "Continuous" { expectValue(app.buttons["capture-menu"], value: label) }
    }
    private func mode(_ value: String) {
        if app.buttons["mode-menu"].exists { tap(app.buttons["mode-menu"]); tap(app.buttons[value].firstMatch) }
        else { tap(app.segmentedControls["mode-picker"].buttons[value]) }
    }
    private func snapshot(_ screen: String) {
        let captured = app.screenshot()
        let label = "gallery__\(appearance)__\(size)__" + screen
        checkpoint(captured.pngRepresentation, label: label, suffix: "png")
        let screenshot = XCTAttachment(screenshot: captured)
        screenshot.name = label
        screenshot.lifetime = .keepAlways; add(screenshot)
    }
    private func assertHomeLayout() {
        let identifiers = ["destination-link", "hold-to-talk", "preparing-talk", "finishing-talk", "stop-immediately", "enable-capture",
            "start-continuous", "finish-utterance", "capture-menu", "mode-picker", "mode-menu", "settings-link"]
        let viewport = app.frame.insetBy(dx: 0, dy: 100)
        let pinned = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["hold-to-talk", "preparing-talk", "finishing-talk", "finish-utterance", "enable-capture", "start-continuous", "stop-immediately"])).firstMatch
        let contentBottom = pinned.exists ? pinned.frame.minY - 32 : viewport.maxY
        let frames = identifiers.compactMap { id -> (String, CGRect)? in
            let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
            guard element.exists else { return nil }
            var frame = element.frame.insetBy(dx: 1, dy: 1).intersection(viewport)
            if ["destination-link", "mode-picker", "mode-menu"].contains(id) {
                // Only the drawn portion of scroll content can overlap a control.
                frame = frame.intersection(CGRect(x: viewport.minX, y: viewport.minY,
                    width: viewport.width, height: max(0, contentBottom - viewport.minY)))
            }
            return frame.isNull || frame.isEmpty ? nil : (id, frame)
        }
        for (index, upper) in frames.enumerated() {
            for lower in frames.dropFirst(index + 1) {
                XCTAssertFalse(upper.1.intersects(lower.1), "Home controls overlap: " + upper.0 + " / " + lower.0)
            }
        }
    }
    private var checkpointDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ios-ui-checkpoints", isDirectory: true)
    }
    private func checkpoint(_ data: Data, label: String, suffix: String) {
        do {
            let directory = checkpointDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let id = UUID().uuidString
            let filename = id + "." + suffix
            try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
            let metadata: [String: Any] = ["testName": name, "attachments": [
                ["exportedFileName": filename, "suggestedHumanReadableName": label + "." + suffix]]]
            try JSONSerialization.data(withJSONObject: metadata).write(
                to: directory.appendingPathComponent(id + ".meta.json"), options: .atomic)
        } catch { XCTFail("Cannot checkpoint synthetic UI artifact: \(error)") }
    }
    private func shot(_ screen: String, audit: Bool = true) throws {
        let label = "\(appearance)__\(size)__\(screen)"
        snapshot(screen)
        // One audit per navigation/help screen, not per state, type size or
        // screenshot. Audit internally exercises font sizes. No issues waived.
        let canonical: [String: String] = ["Main": "home", "Listening": "home", "AIControl": "suggestions", "Destination": "destination", "Approval": "approval", "History": "history", "Devices": "devices", "Pairing": "confirmation", "Agents": "agents", "main-home": "home", "home": "home", "main-devices": "devices", "devices": "devices",
            "main-history": "history", "history": "history", "main-suggestions": "suggestions", "suggestions": "suggestions",
            "main-agents": "agents", "agent-sessions": "agents", "main-settings": "settings", "settings": "settings",
            "target-picker": "destination", "tier3-approval": "approval", "pairing-invitation": "invitation",
            "pairing-four-words": "confirmation", "first-run": "first-run", "permission-explanation": "permission",
            "benchmark-recorder": "recorder", "owner-completion": "completion", "phone-details": "phone-details",
            "microphone-speech-denied": "permission-denied", "camera-denied": "camera-denied",
            "private-storage-audit-recovery": "storage-recovery", "recording-info": "recording-info", "devices-info": "devices-info",
            "privacy-info": "privacy-info", "recorder-info": "recorder-info"]
        guard audit, size == "default", let key = canonical[screen], !Self.auditedScreens.contains(key) else { return }
        let marker = checkpointDirectory.appendingPathComponent("audit-" + key + ".done")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        var findings: [[String: String]] = []
        try app.performAccessibilityAudit(for: .all) { issue in
            findings.append(["type": String(describing: issue.auditType), "summary": issue.compactDescription,
                "detail": issue.detailedDescription, "element": issue.element?.debugDescription ?? "unavailable"])
            // Initial inventory, deliberately non-gating: preserve every issue for
            // owner triage. Assertion failures and audit infrastructure errors fail.
            return true
        }
        let report: [String: Any] = ["screen": label, "mode": "report-only", "findings": findings]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        checkpoint(data, label: "audit__" + label, suffix: "json")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "audit__" + label; attachment.lifetime = .keepAlways; add(attachment)
        Self.auditedScreens.insert(key)
        try Data().write(to: marker, options: .atomic)
    }

    func testFirstRunAndRecovery() throws {
        launch(["--ui-first-run"])
        try shot("first-run")
        XCTAssertTrue(app.buttons["permission-continue"].exists)
        XCTAssertFalse(app.buttons["hold-to-talk"].exists)
        XCTAssertFalse(app.buttons["capture-menu"].isEnabled)
        tap(app.buttons["permission-continue"])
        try shot("permission-explanation")
        tap(app.buttons["permission-allow"])
        XCTAssertTrue(app.buttons["permission-allow"].disappears(timeout: 5))
        try shot("first-run-consented")

        launch(["--ui-permission-denied"])
        tap(app.buttons["permission-continue"]); tap(app.buttons["permission-allow"])
        XCTAssertTrue(app.alerts["Voice Remote"].appears(timeout: 5))
        try shot("microphone-speech-denied")
        tap(app.alerts.buttons["OK"])
        XCTAssertFalse(app.buttons["hold-to-talk"].exists)

        launch(["--ui-storage-denied"])
        XCTAssertFalse(app.tabBars.buttons["Talk"].exists)
        try shot("private-storage-audit-recovery")
        tap(app.buttons["restore-saved-copy"])
        XCTAssertTrue(app.staticTexts["No verified copy is available in this demo. Nothing was changed."].appears(timeout: 5))
        try shot("audit-recovery-unavailable")
    }

    func testHomeDestinationAndHold() throws {
        launch() // Fresh capture-order flag/history are part of this assertion.
        state("idle"); try shot("home")
        tap(app.buttons["capture-menu"]); tap(app.buttons["About recording"]); try shot("recording-info"); tap(app.buttons["Done"])
        tap(app.buttons["destination-link"])
        XCTAssertTrue(app.buttons["target-auto"].exists)
        try shot("Destination")
        tap(app.buttons["target-phone"]); destinationDone()
        XCTAssertTrue(app.buttons["destination-link"].label.contains("iPhone"))
        tap(app.buttons["destination-link"]); tap(app.buttons["target-auto"]); destinationDone()
        try shot("target-auto-selected")
        tap(app.buttons["destination-link"])
        tap(app.buttons["target-synthetic-pc"]); destinationDone()
        XCTAssertTrue(app.buttons["destination-link"].label.contains("Studio PC"))
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
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "synthetic workspace note")).firstMatch.appears(timeout: 5))
        try shot("history-after-hold")
    }

    func testHistoryFlow() throws {
        launch(); tab("History"); try shot("history")
        tap(app.buttons["send-synthetic-held"])
        expectValue(app.staticTexts["history-synthetic-held"], value: "Sent — insertion unconfirmed; check the computer before resending")
        try shot("history-held-sent-unconfirmed")
        XCTAssertTrue(app.staticTexts["history-synthetic-unconfirmed"].exists)
        let sent = app.staticTexts["history-synthetic-held"]
        visible(sent); sent.press(forDuration: 0.7); try shot("history-actions")
        tap(app.buttons["Copy"])
    }

    func testModeAndCaptureSwitches() throws {
        launch()
        mode("AI Control"); capture("CONTINUOUS"); state("listening")
        XCTAssertTrue(app.buttons["destination-link"].label.contains("arm-design"))
        XCTAssertTrue(app.staticTexts["partial-text"].appears(timeout: 5))
        try shot("AIControl")
        finish(); state("idle")
        visible(app.buttons["start-continuous"]); try shot("utterance-finished")
        capture("Off"); state("idle")
        XCTAssertFalse(app.buttons["stop-immediately"].exists)
        XCTAssertFalse(app.staticTexts["partial-text"].exists)
    }

    func testSuggestionsApprovalAndAgents() throws {
        launch()
        ideas()
        try shot("suggestions")
        XCTAssertFalse(app.staticTexts["suggestion-summary"].label.contains("delegateTaskTool"))
        tab("Agents")
        visible(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "offline, tasks wait")).firstMatch)
        try shot("agent-sessions")
        ideas()
        tap(app.buttons.matching(identifier: "review-suggestion").firstMatch)
        XCTAssertTrue(app.staticTexts["approval-exact-action"].appears(timeout: 5))
        XCTAssertEqual(app.buttons["approve-action"].label, "Approve with Face ID")
        try shot("Approval")
        tap(app.buttons["approve-action"])
        XCTAssertTrue(app.staticTexts["approval-exact-action"].disappears(timeout: 8))
        tab("Agents")
        let task = app.staticTexts.matching(identifier: "task-status").firstMatch
        visible(task); XCTAssertTrue(task.exists)
        try shot("Agents")
        tap(app.buttons.matching(identifier: "Confirm observed completion…").firstMatch)
        XCTAssertTrue(app.navigationBars["Owner completion"].appears(timeout: 5))
        try shot("owner-completion")
        tap(app.buttons["Keep waiting"])
        tap(app.buttons.matching(identifier: "cancel-task").firstMatch)
        XCTAssertTrue(app.buttons.matching(identifier: "cancel-task").firstMatch.wait(for: \.label, toEqual: "Retry cancellation", timeout: 5))
        XCTAssertTrue(app.staticTexts["task-status"].label.contains("Cancelling"))
        try shot("agent-cancellation-pending")
        tap(app.buttons["agent-permissions"])
        visible(app.buttons.matching(identifier: "Revoke permission").firstMatch)
        try shot("scoped-grants")
        tap(app.buttons.matching(identifier: "Revoke permission").firstMatch)
        XCTAssertFalse(app.buttons["Revoke permission"].exists)
    }

    func testDevicesPairingFlow() throws {
        launch()
        tab("Devices"); top(); try shot("devices")
        tap(app.buttons["remote-details"]); tap(app.buttons["About devices"]); try shot("devices-info"); tap(app.buttons["Done"]); tap(app.navigationBars.buttons.firstMatch)
        tap(app.buttons["phone-details"]); try shot("phone-details")
        tap(app.navigationBars.buttons.firstMatch)
        tap(app.buttons["pair-computer"]); try shot("pairing-invitation")
        let invitation = app.descendants(matching: .any).matching(identifier: "pairing-invitation").firstMatch
        tap(invitation)
        UIPasteboard.general.string = "voiceremote://synthetic-invitation"
        invitation.press(forDuration: 1.1)
        let paste = app.menuItems["Paste"]
        if paste.appears(timeout: 2) { paste.tap() } else { tap(app.buttons.matching(identifier: "Paste").firstMatch) }
        if app.alerts.firstMatch.appears(timeout: 1) { tap(app.alerts.buttons["Allow Paste"]) }
        tap(app.buttons["Connect"])
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "pairing-phrase").firstMatch.appears(timeout: 5), true)
        visible(app.descendants(matching: .any).matching(identifier: "pairing-phrase").firstMatch, requireHittable: false); try shot("Pairing")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "pairing-phrase").firstMatch.label, "maple river copper orbit")
        XCTAssertEqual(app.keyboards.count, 0)
        XCTAssertTrue(app.frame.intersects(app.descendants(matching: .any).matching(identifier: "pairing-phrase").firstMatch.frame))
        XCTAssertFalse(app.buttons["device-row-synthetic-new"].exists)
        tap(app.buttons["pairing-confirm"])
        XCTAssertTrue(app.buttons["pairing-cancel"].disappears(timeout: 3))
        visible(app.buttons["device-row-synthetic-new"])
        XCTAssertTrue(app.buttons["device-row-synthetic-new"].exists)
        try shot("pairing-confirmed")
        app.buttons["device-row-synthetic-new"].swipeLeft()
        tap(app.buttons.matching(identifier: "Revoke").firstMatch)
        XCTAssertTrue(app.buttons["device-row-synthetic-new"].disappears(timeout: 5))
        try shot("pairing-revoked")
        tap(app.buttons["pair-computer"])
        tap(app.buttons["Scan QR code"])
        XCTAssertTrue(app.staticTexts["Camera access denied"].appears(timeout: 5))
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
        tab("Talk"); top(); capture("CONTINUOUS"); state("listening")
        tab("Settings"); top()
        setSwitch("cloud-consent", on: false)
        assertSavedConsent(false)
        tab("Talk"); top(); state("idle")
        assertCaptureOff()
        tab("Settings")
        tap(app.buttons["benchmark-recorder"])
        XCTAssertTrue(app.navigationBars["Benchmark recorder"].appears(timeout: 5))
        try shot("benchmark-recorder")
        tap(app.buttons["About recorder"]); try shot("recorder-info"); tap(app.buttons["Done"])
        tap(app.buttons["Record prompt"])
        XCTAssertTrue(app.buttons["Finish"].appears(timeout: 5))
        try shot("benchmark-recording")
        tap(app.buttons["Finish"]); top()
        XCTAssertTrue(app.staticTexts["1 / 1 prompts completed"].appears(timeout: 8))
        try shot("benchmark-completed")
    }

    func testBiometricRefusal() throws {
        launch(["--ui-biometric-refuse"])
        ideas(); tap(app.buttons.matching(identifier: "review-suggestion").firstMatch)
        tap(app.buttons["approve-action"])
        XCTAssertTrue(app.staticTexts["Approval denied or expired. Nothing was started."].appears(timeout: 5))
        try shot("biometric-refused")
        XCTAssertFalse(app.buttons["approve-action"].exists)
        XCTAssertEqual(app.buttons["approval-deny"].label, "Close")
        tap(app.buttons["approval-deny"]); tab("Talk")
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
        if expected == "finishing" { state("listening"); finish() }
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
        launch(reuse: true)
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
        XCTAssertTrue(app.buttons["hold-to-talk"].label.contains("Release to type"))
        visible(app.staticTexts["partial-text"], requireHittable: false); try shot("Listening", audit: false)
        tap(app.buttons["stop-immediately"]); state("idle")
        try shot("capture-off")
        tap(app.buttons["enable-capture"])
        visible(app.buttons["hold-to-talk"]); try shot("hold-ready", audit: false)
        launch(["--ui-slow-finish"], largest: largest)
        capture("Continuous"); state("listening")
        try shot("continuous-live-transcript")
        XCTAssertFalse(app.buttons["hold-to-talk"].exists)
        finish(); state("finishing")
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
        tab("Settings"); setSwitch("mute-suggestions", on: true); setSwitch("mute-suggestions", on: false)
        setSwitch("maximum-accuracy", on: true); setSwitch("maximum-accuracy", on: false)
        setSwitch("comparison-tools", on: false); setSwitch("comparison-tools", on: true)
        setSwitch("cloud-consent", on: true); assertSavedConsent(true)
        setSwitch("cloud-consent", on: false); assertSavedConsent(false)
        tab("Agents"); tap(app.buttons["agent-permissions"])
        for id in ["cloud-fallback", "independent-task", "wake-permission"] {
            setSwitch(id, on: true); setSwitch(id, on: false)
        }
        tap(app.buttons["permissions-done"])
        tab("Settings"); tap(app.buttons["benchmark-recorder"])
        setSwitch("keep-benchmark-audio", on: true); setSwitch("keep-benchmark-audio", on: false)
    }

    func test00MainScreenGallery() throws {
        // Capture the complete approved default gallery before slower audit/flow
        // tests. The task fixture uses real Policy; no decision is pre-applied
        // to the separate, fresh suggestion shown in Approval.
        launch(["--ui-running-task", "--ui-holding-preview"])
        require(app.staticTexts["partial-text"])
        try shot("Listening", audit: false)
        let listeningStopVisible = app.buttons["stop-immediately"].isHittable
        tap(app.buttons["stop-immediately"]); tap(app.buttons["enable-capture"])
        try shot("Main", audit: false)
        let capturePillWidth = app.buttons["capture-menu"].frame.width
        tap(app.buttons["destination-link"]); try shot("Destination", audit: false); destinationDone()
        mode("AI Control"); capture("Continuous")
        require(app.staticTexts["partial-text"]); require(app.buttons["review-suggestion"])
        try shot("AIControl", audit: false)
        tap(app.buttons["review-suggestion"]); require(app.staticTexts["approval-exact-action"])
        try shot("Approval", audit: false)
        let approvalVisible = app.buttons["approve-action"].isHittable
        tap(app.buttons["approval-deny"])
        tab("Agents"); try shot("Agents", audit: false)
        let taskStatus = app.staticTexts["task-status"].label
        let taskProgressVisible = app.descendants(matching: .any).matching(identifier: "agent-task-progress").firstMatch.exists
        let taskCanCancel = app.buttons["cancel-task"].exists
        tab("History"); try shot("History", audit: false)
        tab("Devices"); try shot("Devices", audit: false)
        tap(app.buttons["pair-computer"])
        let invitation = app.descendants(matching: .any).matching(identifier: "pairing-invitation").firstMatch
        tap(invitation); invitation.typeText("voiceremote://synthetic-invitation"); tap(app.buttons["Connect"])
        require(app.descendants(matching: .any).matching(identifier: "pairing-phrase").firstMatch)
        try shot("Pairing", audit: false)
        tap(app.buttons["pairing-cancel"])
        // Non-blocking checks come after the full gallery is safely checkpointed.
        XCTAssertTrue(listeningStopVisible)
        XCTAssertGreaterThan(capturePillWidth, 64, "Capture pill must include its word, not just an icon")
        XCTAssertTrue(approvalVisible)
        XCTAssertEqual(taskStatus, "Running")
        XCTAssertTrue(taskProgressVisible)
        XCTAssertTrue(taskCanCancel)
    }
    func testLargestDynamicTypeMainScreens() throws { try mainScreens(largest: true) }

    private func mainScreens(largest: Bool) throws {
        // Inventory must survive a failed layout assertion on an earlier tab.
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        launch(largest: largest)
        let screens = ["Talk": "Main", "History": "History", "Devices": "Devices", "Agents": "agents-sessions", "Settings": "settings"]
        for name in ["Talk", "History", "Devices", "Agents", "Settings"] {
            tab(name); try shot(screens[name]!)
            if name == "Talk" { assertHomeLayout() }
            if largest {
                let bottomID = ["Talk": "mode-menu", "Devices": "phone-details", "History": "history-more-synthetic-held", "Agents": "agent-permissions", "Settings": "benchmark-recorder"][name]!
                visible(app.buttons[bottomID]); try shot("main-" + name.lowercased() + "-controls")
            }
        }
        XCTAssertEqual(app.tabBars.buttons.count, 4)
        tab("Talk"); tap(app.buttons["destination-link"]); try shot("Destination")
    }

    func testLargestApprovalSheet() throws {
        launch(largest: true)
        ideas(); capture("Continuous"); state("listening"); try shot("AIControl")
        tap(app.buttons.matching(identifier: "review-suggestion").firstMatch)
        require(app.staticTexts["approval-exact-action"]); try shot("Approval")
        XCTAssertTrue(app.buttons["approve-action"].isHittable, "Pinned approval must be visible without scrolling")
        XCTAssertTrue(app.buttons["approval-deny"].isHittable)
        try shot("tier3-approval-action")
        tap(app.buttons["approve-action"]); XCTAssertTrue(app.staticTexts["approval-exact-action"].disappears(timeout: 5))
        tab("Agents"); try shot("Agents")
    }

    func testLargestPairingAndRecorder() throws {
        launch(largest: true)
        tab("Devices"); tap(app.buttons["pair-computer"]); try shot("pairing-invitation")
        let invitation = app.descendants(matching: .any).matching(identifier: "pairing-invitation").firstMatch
        tap(invitation); invitation.typeText("voiceremote://synthetic-invitation")
        tap(app.buttons["Connect"])
        require(app.descendants(matching: .any).matching(identifier: "pairing-phrase").firstMatch); top(); try shot("Pairing")
        visible(app.buttons["pairing-confirm"]); try shot("pairing-confirmation-action")
        tap(app.buttons["pairing-cancel"])
        tab("Settings"); tap(app.buttons["benchmark-recorder"]); try shot("benchmark-recorder")
        tap(app.buttons["Record prompt"]); require(app.buttons["Finish"])
        visible(app.buttons["Finish"]); try shot("benchmark-recording")
        tap(app.buttons["Discard recording"])
    }
}

@MainActor private extension XCUIElement {
    func appears(timeout: TimeInterval) -> Bool { exists || waitForExistence(timeout: timeout) }
    func disappears(timeout: TimeInterval) -> Bool { !exists || waitForNonExistence(timeout: timeout) }
}
