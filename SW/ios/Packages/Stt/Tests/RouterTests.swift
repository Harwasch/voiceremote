import XCTest
@testable import Stt

@MainActor final class RouterTests: XCTestCase {
    let local = EngineDescriptor(id: "local", version: "test", location: .onDevice)
    let cloud = EngineDescriptor(id: "cloud", version: "test", location: .cloud)
    func testRouterDefaultsAndAllCloudTriggers() {
        let router = EngineRouter()
        XCTAssertEqual(router.select(onDevice: [local], cloud: [cloud], conditions: .init(online: true)), .engine("local"))
        for state in [EngineRouter.Conditions(online: true, hot: true, cloudConsent: true),
                      .init(online: true, lowBattery: true, cloudConsent: true), .init(online: true, maxAccuracy: true, cloudConsent: true)] {
            XCTAssertEqual(router.select(onDevice: [local], cloud: [cloud], conditions: state), .engine("cloud"))
        }
        XCTAssertEqual(router.select(onDevice: [], cloud: [cloud], conditions: .init(online: true, cloudConsent: true)), .engine("cloud"))
    }
    func testRouterOfflineNeverUsesCloudOrShowsErrorEvenWithDebugOverride() {
        let router = EngineRouter()
        let state = EngineRouter.Conditions(online: false, hot: true, lowBattery: true, maxAccuracy: true)
        XCTAssertEqual(router.select(onDevice: [local], cloud: [cloud], conditions: state, preferredID: "cloud"), .engine("local"))
        XCTAssertEqual(router.select(onDevice: [], cloud: [cloud], conditions: state), .silentlyUnavailable)
    }
    func testRouterFallbackAndPerUtterancePicker() {
        let router = EngineRouter()
        XCTAssertEqual(router.select(onDevice: [local], cloud: [], conditions: .init(online: true, hot: true)), .engine("local"))
        XCTAssertEqual(router.select(onDevice: [local], cloud: [cloud], conditions: .init(online: true, cloudConsent: true), preferredID: "cloud"), .engine("cloud"))
        XCTAssertEqual(router.select(onDevice: [cloud], cloud: [local], conditions: .init(online: true)), .silentlyUnavailable)
        XCTAssertEqual(router.select(onDevice: [local], cloud: [cloud], conditions: .init(online: true)), .engine("local"))
    }
    func testMeasuredBatteryAndLowPowerPolicy() {
        XCTAssertTrue(EngineRouter.lowBattery(level: 0.1, lowPowerMode: false))
        XCTAssertTrue(EngineRouter.lowBattery(level: 0.8, lowPowerMode: true))
        XCTAssertFalse(EngineRouter.lowBattery(level: -1, lowPowerMode: false))
        XCTAssertFalse(EngineRouter.lowBattery(level: 0.8, lowPowerMode: false))
    }
    func testSafetyConditionsOverridePreferredLocal() {
        for state in [EngineRouter.Conditions(online: true, hot: true, cloudConsent: true),
                      .init(online: true, lowBattery: true, cloudConsent: true),
                      .init(online: true, maxAccuracy: true, cloudConsent: true)] {
            XCTAssertEqual(EngineRouter().select(onDevice: [local], cloud: [cloud], conditions: state, preferredID: "local"), .engine("cloud"))
        }
    }

    func testRouterStreamsPartialsCleansFinalsAndSuppressesOfflineFailures() async {
        let engine = FakeEngine(script: [.partial("um, codex"), .final("um, codex")])
        var result: [SttEvent] = []
        for await event in EngineRouter().transcribe(source: ScriptedCaptureSource([]), engines: [engine],
            conditions: .init(online: false), vocabulary: .init(userID: "test", terms: ["Codex"])) {
            result.append(event)
        }
        XCTAssertEqual(result, [.selected(engine.descriptor), .partial("um, codex"), .partial("um, codex"), .final("Codex.")])
        var unavailable: [SttEvent] = []
        for await event in EngineRouter().transcribe(source: ScriptedCaptureSource([]), engines: [],
            conditions: .init(online: false), vocabulary: .init(userID: "test", terms: [])) {
            unavailable.append(event)
        }
        XCTAssertEqual(unavailable, [])
    }

    func testRouterCleansWholeUtteranceSoSplitNegationNeverBecomesSendInstruction() async {
        let engine = FakeEngine(script: [.final("do not"), .partial("send"), .final("send the message")])
        var result: [SttEvent] = []
        for await event in EngineRouter().transcribe(source: ScriptedCaptureSource([]), engines: [engine],
            conditions: .init(online: true), vocabulary: .init(userID: "test", terms: [])) {
            result.append(event)
        }
        XCTAssertEqual(result, [.selected(engine.descriptor), .partial("do not"), .partial("do not send"), .partial("do not send the message"),
                                .final("Do not send the message.")])
    }
    func testRouterOfflineFailureStaysSilentAndDuplicateIDsCannotSelectCloud() async {
        var result: [SttEvent] = []
        let localEngine = FakeEngine(id: "same", script: [.failure(.unavailable)])
        for await event in EngineRouter().transcribe(source: ScriptedCaptureSource([]), engines: [localEngine],
            conditions: .init(online: false), vocabulary: .init(userID: "test", terms: [])) {
            result.append(event)
        }
        XCTAssertEqual(result, [.selected(localEngine.descriptor)])
        result.removeAll()
        let cloudEngine = FakeEngine(id: "same", script: [.final("cloud must not run")], location: .cloud)
        for await event in EngineRouter().transcribe(source: ScriptedCaptureSource([]), engines: [cloudEngine, localEngine],
            conditions: .init(online: false), vocabulary: .init(userID: "test", terms: [])) {
            result.append(event)
        }
        XCTAssertEqual(result, [])
    }

    func testStableFinalsSurviveFailuresOnlineAndOffline() async {
        for online in [true, false] {
            let engine = FakeEngine(script: [.final("do not send"), .partial("unconfirmed"), .failure(.transport)])
            var events: [SttEvent] = []
            for await event in EngineRouter().transcribe(source: ScriptedCaptureSource([]), engines: [engine],
                conditions: .init(online: online), vocabulary: .init(userID: "test", terms: [])) {
                events.append(event)
            }
            XCTAssertTrue(events.contains(.final("Do not send.")))
            XCTAssertEqual(events.contains(.failure(.transport)), online)
            if online, let committed = events.firstIndex(of: .final("Do not send.")), let failed = events.firstIndex(of: .failure(.transport)) {
                XCTAssertLessThan(committed, failed)
            }
            XCTAssertFalse(events.contains(.final("Do not send unconfirmed.")))
        }
    }
    func testRouterAnnouncesSelectionBeforeTextAndHasConsentInput() async {
        let engine = FakeEngine(script: [.final("synthetic")])
        var events: [SttEvent] = []
        for await event in EngineRouter().transcribe(source: ScriptedCaptureSource([]), engines: [engine],
            conditions: .init(online: true), vocabulary: .init(userID: "test", terms: [])) { events.append(event) }
        XCTAssertTrue(String(describing: events.first).contains("selected("))
        XCTAssertTrue(Mirror(reflecting: EngineRouter.Conditions(online: true)).children.contains { $0.label == "cloudConsent" })
    }

    func testCloudConsentDefaultsToDeniedAndCannotBeOverriddenByPickerOrConditions() {
        for state in [EngineRouter.Conditions(online: true), .init(online: true, hot: true),
                      .init(online: true, lowBattery: true), .init(online: true, maxAccuracy: true)] {
            XCTAssertEqual(EngineRouter().select(onDevice: [local], cloud: [cloud], conditions: state, preferredID: "cloud"), .engine("local"))
            XCTAssertEqual(EngineRouter().select(onDevice: [], cloud: [cloud], conditions: state, preferredID: "cloud"), .silentlyUnavailable)
        }
        XCTAssertEqual(EngineRouter().select(onDevice: [], cloud: [cloud], conditions: .init(online: true, cloudConsent: true)), .engine("cloud"))
    }
    func testConsentedCloudSelectionExposesIsCloudBeforeText() async {
        let engine = FakeEngine(id: "cloud", script: [.final("synthetic")], location: .cloud)
        var events: [SttEvent] = []
        for await event in EngineRouter().transcribe(source: ScriptedCaptureSource([]), engines: [engine],
            conditions: .init(online: true, cloudConsent: true), vocabulary: .init(userID: "test", terms: [])) { events.append(event) }
        XCTAssertEqual(events.first, .selected(engine.descriptor))
        XCTAssertTrue(engine.descriptor.isCloud)
    }

}
