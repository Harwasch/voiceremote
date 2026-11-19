// Purpose: exercise the exact demo adapters with real portable models and Policy.
// Inputs: UIDemo.swift and built AppModel dependency objects. Linux-only executable.
// Verification: local synthetic probe; Apple SDK/UI acceptance remains unverified.
#if os(Linux)
import Foundation
import AppModel
import Core
import Stt
import Brain
import Policy
import Router

@main struct Probe {
    @MainActor static func main() async throws {
        let demo = UIDemo()
        let registry = DeviceRegistry(accountID: UIDemo.account, revocation: demo.target)
        let history = try AppHistoryStore(now: Int64(Date().timeIntervalSince1970 * 1000), accountID: UIDemo.account)
        let policy = try PolicyGate(audit: AuditLog(journal: DemoJournal(), checkpoints: DemoCheckpoint(), retention: AuditRetention(), accountID: UIDemo.account), biometric: demo.biometric)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let router = try TaskRouter(store: RetainedTaskStore(url: root.appendingPathComponent("tasks"), accountID: UIDemo.account), policy: policy)
        let agents = AgentControl(router: router, policy: policy, account: UIDemo.account, actor: UIDemo.phone)
        let model = VoiceAppModel(accountID: UIDemo.account, phoneID: UIDemo.phone, actorID: UIDemo.phone,
            registry: registry, history: history, target: demo.target, policy: policy,
            makeCapture: { try await demo.makeCapture() }, engines: { demo.engines }, brain: { _ in DemoBrain() },
            agentControl: agents, deliver: { _ in throw RouterError.invalidAuthorization })
        agents.onChange = { Task { await model.refreshTasks() } }
        try await demo.seed(model, history: history, registry: registry, agents: agents)
        print("seed: devices=\(model.devices.count), history=\(model.history.count), suggestions=\(model.suggestions.count), grants=\(model.grants.count), sessions=\(agents.destinations.count)")
        precondition(model.suggestions.count == 1 && model.grants.count == 1 && model.tasks.isEmpty)
        if demo.arguments.contains("--ui-stop-probe") {
            model.setCapture(.continuous)
            let expected: ListeningState = demo.arguments.contains("--ui-slow-prepare") ? .preparing :
                demo.arguments.contains("--ui-capture-failure") ? .failed :
                demo.arguments.contains("--ui-interrupt") ? .interrupted : .listening
            for _ in 0..<500 where model.listening != expected { try await Task.sleep(for: .milliseconds(10)) }
            precondition(model.listening == expected)
            for _ in 0..<500 where !demo.destinationBeforeCapture { try await Task.sleep(for: .milliseconds(10)) }
            precondition(demo.destinationBeforeCapture)
            if demo.arguments.contains("--ui-slow-finish") {
                model.finishUtterance()
                precondition(model.listening == .finishing)
            }
            model.stop()
            precondition(model.controls.capture == .off && model.listening == .idle && model.partial.isEmpty)
            try await Task.sleep(for: .milliseconds(100))
            await model.refresh()
            precondition(model.history.count == 4 && model.partial.isEmpty && model.listening == .idle)
            precondition(demo.destinationBeforeCapture)
            print("synthetic stop probe: state reached, destination precedes capture, Stop cancels without unfinished history")
            return
        }
        await model.review(model.suggestions[0]); precondition(model.approval?.preview.risk == .sensitive)
        await model.approve()
        if demo.biometric.refuse {
            precondition(model.tasks.isEmpty); print("real Policy biometric refusal: zero tasks"); return
        }
        for _ in 0..<100 { await Task.yield() }
        await model.refreshTasks()
        precondition(model.tasks.count == 1)
        let task = model.tasks[0]
        print("approved task: \(task.visibleStatus)")
        precondition(agents.completionEpoch(for: task) != nil)
        await model.cancelTask(task)
        precondition(model.tasks[0].cancellationRequested)
        await model.sendHeld("synthetic-held")
        precondition(model.deliveryStates["synthetic-held"] == .unconfirmed)
        let pairing = PairingFlow(backend: DemoPairing(registry: registry))
        pairing.code = "voiceremote://synthetic-invitation"
        await pairing.begin()
        precondition(pairing.phrase == "maple river copper orbit")
        let beforeConfirm = await registry.all(); precondition(beforeConfirm.count == 2)
        let confirmed = await pairing.confirm(); precondition(confirmed != nil)
        await model.refresh(); precondition(model.devices.count == 3)
        await model.revoke("synthetic-new"); precondition(model.devices.count == 2)
        let recorder = try BenchmarkRecorder(prompts: [.init(id: "synthetic-1", category: "normal", expectedText: "Synthetic prompt.")], directory: root.appendingPathComponent("recorder"))
        recorder.start(source: DemoCapture(), first: demo.engines[0], second: demo.engines[1], vocabulary: .init(userID: UIDemo.account, terms: []), device: "synthetic", captureKind: .synthetic, cloudConsent: false, synthetic: true)
        for _ in 0..<10 { await Task.yield() }
        precondition(recorder.recording)
        recorder.finish()
        for _ in 0..<500 where recorder.busy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(recorder.completed == 1)
        print("real Policy approval, cancellation, held send, pairing/revoke, synthetic recorder: passed")
    }
}

#endif
