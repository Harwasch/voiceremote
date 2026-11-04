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
    private func tab(_ name: String) { app.tabBars.buttons[name].tap() }
    private func top() { for _ in 0..<5 { app.swipeDown() } }
    private func state(_ value: String) {
        let element = app.staticTexts["demo-state"]
        if !element.exists { top() }
        let predicate = NSPredicate(format: "label BEGINSWITH %@", value + " / ")
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: 12)
    }
    private func capture(_ value: String) {
        tap(app.buttons["capture-picker"])
        tap(app.buttons.matching(identifier: value).firstMatch)
    }
    private func mode(_ value: String) {
        tap(app.buttons["mode-picker"])
        tap(app.buttons.matching(identifier: value).firstMatch)
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
        XCTAssertFalse(app.buttons["hold-to-talk"].isEnabled)
        try shot("first-run")
        tap(app.buttons["permission-continue"])
        XCTAssertTrue(app.buttons["permission-continue"].waitForNonExistence(timeout: 5))
        try shot("first-run-consented")

        launch(dark: dark)
        state("idle"); try shot("home")
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
        XCTAssertEqual(app.staticTexts["demo-order"].label, "Destination before capture: true")
        tab("History")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "synthetic workspace note")).firstMatch.waitForExistence(timeout: 5))
        try shot("history-after-hold")
        tap(app.buttons["send-synthetic-held"])
        XCTAssertTrue(app.buttons["send-synthetic-held"].wait(for: \.label, toEqual: "Resend after checking computer", timeout: 5))
        try shot("history-held-sent-unconfirmed")
        XCTAssertTrue(app.staticTexts["history-synthetic-unconfirmed"].exists)

        tab("Home"); top()
        mode("AI Control"); capture("CONTINUOUS"); state("listening")
        XCTAssertTrue(app.buttons["destination-link"].label.contains("Synthetic Studio"))
        XCTAssertTrue(app.staticTexts["partial-text"].waitForExistence(timeout: 5))
        try shot("listening")
        tap(app.buttons["finish-utterance"]); state("idle")
        try shot("utterance-finished")
        tap(app.buttons["stop-immediately"]); state("idle")
        XCTAssertFalse(app.staticTexts["partial-text"].exists)

        tab("Suggestions")
        try shot("suggestions")
        visible(app.staticTexts["Offline — commands held"])
        try shot("agent-sessions")
        top()
        tap(app.buttons.matching(identifier: "review-suggestion").firstMatch)
        XCTAssertTrue(app.staticTexts["approval-exact-action"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Face ID or iPhone passcode required"].exists)
        try shot("tier3-approval")
        tap(app.buttons["approve-action"])
        XCTAssertTrue(app.staticTexts["approval-exact-action"].waitForNonExistence(timeout: 8))
        let task = app.staticTexts.matching(identifier: "task-status").firstMatch
        visible(task); XCTAssertTrue(task.exists)
        try shot("agent-task-dispatched")
        tap(app.buttons.matching(identifier: "Confirm observed completion…").firstMatch)
        XCTAssertTrue(app.navigationBars["Owner completion"].waitForExistence(timeout: 5))
        try shot("owner-completion")
        tap(app.buttons["Keep waiting"])
        tap(app.buttons.matching(identifier: "cancel-task").firstMatch)
        XCTAssertTrue(app.buttons.matching(identifier: "cancel-task").firstMatch.wait(for: \.label, toEqual: "Retry cancellation", timeout: 5))
        try shot("agent-cancellation-pending")
        visible(app.buttons.matching(identifier: "Revoke permission").firstMatch)
        try shot("scoped-grants")
        tap(app.buttons.matching(identifier: "Revoke permission").firstMatch)
        XCTAssertFalse(app.buttons["Revoke permission"].exists)

        tab("Devices"); top(); try shot("devices")
        let invitation = app.descendants(matching: .any).matching(identifier: "pairing-invitation").firstMatch
        tap(invitation)
        UIPasteboard.general.string = "voiceremote://synthetic-invitation"
        invitation.press(forDuration: 1.1)
        let paste = app.menuItems["Paste"]
        if paste.waitForExistence(timeout: 2) { paste.tap() } else { app.buttons.matching(identifier: "Paste").firstMatch.tap() }
        if app.alerts.firstMatch.waitForExistence(timeout: 1) { app.alerts.buttons["Allow Paste"].tap() }
        // Hide the keyboard without triggering Connect implicitly.
        app.swipeUp()
        tap(app.buttons["Connect"])
        XCTAssertEqual(app.staticTexts["pairing-phrase"].waitForExistence(timeout: 5), true)
        XCTAssertEqual(app.staticTexts["pairing-phrase"].label, "maple river copper orbit")
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
        tap(app.buttons["Scan QR code"])
        XCTAssertTrue(app.staticTexts["Camera access denied"].waitForExistence(timeout: 5))
        try shot("camera-denied")
        tap(app.buttons["Cancel scan"])
        visible(app.staticTexts["remote-status"])
        try shot("remote-bluetooth-denied")

        tab("Settings"); top()
        let consent = app.switches["cloud-consent"]
        XCTAssertEqual(consent.value as? String, "0")
        try shot("settings")
        consent.tap(); XCTAssertEqual(consent.value as? String, "1")
        try shot("settings-cloud-consented")
        tab("Home"); top(); capture("CONTINUOUS"); state("listening")
        tab("Settings"); top()
        consent.tap(); XCTAssertEqual(consent.value as? String, "0")
        tab("Home"); top(); state("idle")
        XCTAssertTrue(app.staticTexts["demo-state"].label.hasSuffix("off"))
        tab("Settings")
        tap(app.buttons["benchmark-recorder"])
        XCTAssertTrue(app.navigationBars["Benchmark recorder"].waitForExistence(timeout: 5))
        try shot("benchmark-recorder")
        tap(app.buttons["Record prompt"])
        XCTAssertTrue(app.buttons["Finish phrase"].waitForExistence(timeout: 5))
        try shot("benchmark-recording")
        tap(app.buttons["Finish phrase"]); top()
        XCTAssertTrue(app.staticTexts["1 / 1 prompts completed"].waitForExistence(timeout: 8))
        try shot("benchmark-completed")

        launch(["--ui-biometric-refuse"], dark: dark)
        tab("Suggestions"); tap(app.buttons.matching(identifier: "review-suggestion").firstMatch)
        tap(app.buttons["approve-action"])
        XCTAssertTrue(app.staticTexts["Approval denied or expired. Nothing was started."].waitForExistence(timeout: 5))
        try shot("biometric-refused")
        tap(app.buttons["Deny"]); tab("Home")
        XCTAssertEqual(app.staticTexts["demo-tasks"].label, "Tasks: 0")

        launch(["--ui-permission-denied"], dark: dark)
        tap(app.buttons["permission-continue"])
        XCTAssertTrue(app.alerts["Voice Remote"].waitForExistence(timeout: 5))
        try shot("microphone-speech-denied")
        app.alerts.buttons["OK"].tap()
        XCTAssertFalse(app.buttons["hold-to-talk"].isEnabled)

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
                tap(app.buttons["stop-immediately"]); state("idle")
                XCTAssertTrue(app.staticTexts["demo-state"].label.hasSuffix("off"))
                XCTAssertFalse(app.staticTexts["partial-text"].exists)
                try shot("stop-after-" + expected)
                tab("History")
                XCTAssertEqual(app.staticTexts.matching(identifier: "history-synthetic-held").count, 1)
                XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "synthetic workspace note")).firstMatch.exists)
            }
            launch(dark: dark)
            for value in ["OFF", "HOLD", "CONTINUOUS"] {
                capture(value); tap(app.buttons["stop-immediately"]); state("idle")
                XCTAssertTrue(app.staticTexts["demo-state"].label.hasSuffix("off"))
            }
        }
    }

    func testLargestDynamicTypeMainScreens() throws {
        launch(largest: true)
        for name in ["Home", "Devices", "History", "Suggestions", "Settings"] {
            tab(name); try shot("main-" + name.lowercased())
        }
        tab("Home"); tap(app.buttons["destination-link"]); try shot("target-picker")
        app.navigationBars.buttons.firstMatch.tap()
        launch(largest: true) // Refresh the review card after the main-screen audits.
        tab("Suggestions"); tap(app.buttons.matching(identifier: "review-suggestion").firstMatch)
        try shot("tier3-approval")
    }
}
