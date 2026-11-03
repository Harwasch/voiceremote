import SwiftUI
import AppModel
import VoiceRemoteProtocol

struct DevicesView: View {
    @Bindable var host: AppRuntime
    @State private var scan = false
    @State private var systemPairingCode = ""
    @State private var remotePairingCode = ""
    @State private var discardID: String?
    var body: some View {
        @Bindable var pairing = host.pairing
        @Bindable var remote = host.remote
        List {
            Section("This phone") {
                Text("Account: " + host.model.accountID).font(.caption).textSelection(.enabled)
                Text("Phone: " + host.model.phoneID).font(.caption).textSelection(.enabled)
                Text("Use this account and phone identity when enrolling agent access on your computer.").font(.footnote)
            }
            Section("Computers") {
                if let notice = host.link.notice { Text(notice).foregroundStyle(.secondary) }
                ForEach(host.model.devices, id: \.device_id) { device in
                    VStack(alignment: .leading) {
                        Text(device.display_name); Text(device.role.rawValue).font(.caption)
                        Text(host.link.suspendedIDs.contains(device.device_id) ? "Relay suspended — credentials retained" :
                            (host.link.connectedIDs.contains(device.device_id) ? "Connected" : "Unreachable — dictation held")).font(.caption)
                        if host.link.suspendedIDs.contains(device.device_id) {
                            Button("Retry connection") { host.link.retrySuspended(device.device_id) }
                        }
                    }
                        .swipeActions { Button("Revoke", role: .destructive) { Task { await host.model.revoke(device.device_id) } } }
                }
            }
            Section("Add computer") {
                Picker("Role", selection: $pairing.role) {
                    Text("Text receiver").tag(DeviceInfoRole.text_receiver)
                    Text("Agent executor").tag(DeviceInfoRole.agent)
                    Text("Both").tag(DeviceInfoRole.both)
                }
                Toggle("Allow this phone to dispatch agent commands", isOn: $pairing.allowAgentCommands)
                    .disabled(pairing.role == .text_receiver)
                Text("Agent access is separate from the role label. Only explicitly enabled capabilities confirmed by this computer are enrolled.").font(.footnote)
                Button("Scan QR code", systemImage: "qrcode.viewfinder") { scan = true }
                TextField("Pairing code or QR payload", text: $pairing.code, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                Text("Paste the complete code printed by the computer or scan its QR. Configure the relay in Settings for pairing across networks.").font(.footnote)
                Button("Connect") { Task { await host.pairing.begin() } }.disabled(host.pairing.busy)
                if host.pairing.busy { ProgressView("Waiting for computer…") }
                if let phrase = host.pairing.phrase {
                    Text("Compare these four words on both screens").font(.headline)
                    Text(phrase).font(.title2).textSelection(.enabled)
                    Button("The words match on both screens") {
                        Task { _ = await host.pairing.confirm(); await host.model.refresh() }
                    }.disabled(host.pairing.busy)
                }
                if host.pairing.phrase != nil || host.pairing.busy {
                    Button("Cancel pairing", role: .cancel) { Task { await host.pairing.cancel() } }
                }
                if let error = host.pairing.error { Text(error).foregroundStyle(.red) }
            }
            Section("Voice remote") {
                Text(host.remote.status)
                if !host.remote.offlineStatus.isEmpty { Text(host.remote.offlineStatus) }
                if host.remote.enrollmentReady {
                    Text("Enter local pairing mode on the remote. Compare the fresh six-digit number in the iPhone system pairing prompt with the remote and approve on both. Reject mismatch, no-number, Legacy or Just Works pairing.").font(.footnote)
                    SecureField("Six digits shown by iPhone", text: $systemPairingCode).keyboardType(.numberPad)
                    SecureField("Six digits shown by remote", text: $remotePairingCode).keyboardType(.numberPad)
                    Button("I compared and confirmed both screens") {
                        let system = systemPairingCode, remote = remotePairingCode
                        systemPairingCode = ""; remotePairingCode = ""
                        Task { await host.remote.confirmEnrollment(systemCode: system, remoteCode: remote) }
                    }.disabled(host.remote.enrollmentBusy)
                }
                Button("Retry sync") { host.remote.retryOfflineSync() }.disabled(!host.remote.isEnrolled)
                ForEach(host.remote.offlineIssues) { issue in
                    VStack(alignment: .leading) {
                        Text("Recording \(issue.recordingID)").font(.headline)
                        Text(issue.reason).font(.caption)
                        Button("Discard recording", role: .destructive) { discardID = issue.id }
                    }
                }
                Toggle("Use remote microphone", isOn: $remote.useRemote)
                Button("Find remote") { host.remote.scan() }
                ForEach(host.remote.discovered, id: \.identifier) { peripheral in
                    Button(peripheral.name ?? "Voice remote") { host.remote.connect(peripheral) }
                }
                Button("Disconnect remote") { host.remote.disconnect() }
                Button("Forget enrolled remote", role: .destructive) { Task { await host.remote.forgetEnrollment() } }
                Text("Enrollment pins this peripheral after system/remote confirmation. iOS does not expose pairing-method attestation; remote firmware must enforce authenticated encrypted bonding. Prototype OFF is a software stop only.").font(.footnote)
            }
        }.navigationTitle("Devices").task { await host.model.refresh() }
        .confirmationDialog("Discard this recording without transcription?", isPresented: Binding(get: { discardID != nil }, set: { if !$0 { discardID = nil } })) {
            Button("Discard recording", role: .destructive) {
                if let id = discardID { Task { await host.remote.discardOfflineRecording(id) } }
                discardID = nil
            }
            Button("Cancel", role: .cancel) { discardID = nil }
        }
        .sheet(isPresented: $scan) {
            QRScanner { result in
                scan = false
                if let result { Task { await host.pairing.begin(result) } }
            }.ignoresSafeArea()
        }
    }
}
