import SwiftUI
import AppModel
import VoiceRemoteProtocol

struct DevicesView: View {
    @Bindable var host: AppRuntime
    @State private var pairingSheet = false
    @State private var showingInfo = false
    @State private var systemPairingCode = ""
    @State private var remotePairingCode = ""
    @State private var discardID: String?
    var body: some View {
        @Bindable var remote = host.remote
        List {
            Section("Computers") {
                if host.model.devices.isEmpty {
                    ContentUnavailableView("Add your computer", systemImage: "desktopcomputer", description: Text("Pair to type text or review agent tasks on your computer."))
                }
                if let notice = host.link.notice { Text(notice) }
                ForEach(host.model.devices, id: \.device_id) { device in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(device.display_name).font(.headline).accessibilityIdentifier("device-" + device.device_id)
                        Text(device.role.displayLabel).font(.subheadline)
                        Text(connectionStatus(device.device_id)).font(.subheadline)
                        if host.link.suspendedIDs.contains(device.device_id) {
                            Button("Retry connection") { host.link.retrySuspended(device.device_id) }.frame(minHeight: 44)
                        }
                    }.fixedSize(horizontal: false, vertical: true)
                    .swipeActions { Button("Revoke", role: .destructive) { Task { await host.model.revoke(device.device_id) } } }
                }
            }
            Section("Voice remote") {
                Text(host.remote.status).accessibilityIdentifier("remote-status")
                if !host.remote.offlineStatus.isEmpty { Text(host.remote.offlineStatus) }
                if host.remote.enrollmentReady {
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
                Picker("Microphone source", selection: $host.captureChoice) {
                    Text("Phone or headset").tag(CaptureChoice.phone)
                    Text("Remote").tag(CaptureChoice.remote)
                    Text("Automatic").tag(CaptureChoice.automatic)
                }
                Text(host.remote.sourceName)
                if !host.sourceMetricsText.isEmpty { Text(host.sourceMetricsText).font(.caption) }
                Button("Find remote") { host.remote.scan() }
                ForEach(host.remote.discovered, id: \.identifier) { peripheral in
                    Button(peripheral.name ?? "Voice remote") { host.remote.connect(peripheral) }
                }
                Button("Disconnect remote") { host.remote.disconnect() }
                Button("Forget enrolled remote", role: .destructive) { Task { await host.remote.forgetEnrollment() } }
            }

            Section {
                NavigationLink("Phone details") {
                    List {
                        LabeledContent("Account", value: host.model.accountID).textSelection(.enabled)
                        LabeledContent("Phone", value: host.model.phoneID).textSelection(.enabled)
                        Text("Use these details when enrolling agent access on your computer.")
                    }.navigationTitle("Phone details")
                }.accessibilityIdentifier("phone-details")
            }
        }.navigationTitle("Devices").task { await host.model.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("About devices", systemImage: "info.circle") { showingInfo = true } }
            ToolbarItem(placement: .topBarTrailing) { Button("Add computer", systemImage: "plus") { pairingSheet = true }.accessibilityIdentifier("pair-computer") }
        }
        .sheet(isPresented: $pairingSheet, onDismiss: { Task { await host.pairing.cancel() } }) { PairComputerView(host: host) }
        .sheet(isPresented: $showingInfo) { InfoSheet(title: "Devices and microphones", paragraphs: ["Enter local pairing mode on the remote. Compare the fresh six-digit number in the iPhone system pairing prompt with the remote and approve on both. Reject mismatch, no-number, Legacy or Just Works pairing.", "Automatic compares recent captured PCM envelope estimates, clipping and interruptions. Proximity is unknown. Scores and thresholds are unverified; a live utterance never switches sources.", "Enrollment pins this peripheral after system/remote confirmation. iOS does not expose pairing-method attestation; remote firmware must enforce authenticated encrypted bonding. Prototype OFF is a software stop only."]) }
        .confirmationDialog("Discard this recording without transcription?", isPresented: Binding(get: { discardID != nil }, set: { if !$0 { discardID = nil } })) {
            Button("Discard recording", role: .destructive) {
                if let id = discardID { Task { await host.remote.discardOfflineRecording(id) } }; discardID = nil
            }
            Button("Cancel", role: .cancel) { discardID = nil }
        }
    }
    private func connectionStatus(_ id: String) -> String {
        #if DEBUG
        if host.demo != nil { return id == UIDemo.offline.device_id ? "Offline — dictation held" : "Connected (synthetic)" }
        #endif
        return host.link.suspendedIDs.contains(id) ? "Connection paused — pairing retained" :
            (host.link.connectedIDs.contains(id) ? "Connected" : "Unreachable — dictation held")
    }
}

private struct PairComputerView: View {
    @Bindable var host: AppRuntime
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var codeFocused: Bool
    @State private var scan = false
    var body: some View {
        @Bindable var pairing = host.pairing
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let phrase = pairing.phrase {
                            Text("Compare both screens").font(.title2.bold()).id("phrase")
                            Text(phrase.replacingOccurrences(of: " ", with: "\n"))
                                .font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel(phrase).accessibilityIdentifier("pairing-phrase")
                            Text("Only continue if all four words match on your computer.")
                            Button("The words match on both screens") {
                                Task { if await pairing.confirm() != nil { await host.model.refresh(); dismiss() } }
                            }.buttonStyle(.glassProminent).controlSize(.large).disabled(pairing.busy)
                        } else {
                            Text("Connect your computer").font(.largeTitle.bold())
                            Text("Paste the invitation from your computer, or scan its QR code.")
                            Picker("Use this computer for", selection: $pairing.role) {
                                Text("Text receiver").tag(DeviceInfoRole.text_receiver)
                                Text("Agent").tag(DeviceInfoRole.agent)
                                Text("Text and agent").tag(DeviceInfoRole.both)
                            }
                            Toggle("Allow agent tasks from this phone", isOn: $pairing.allowAgentCommands)
                                .disabled(pairing.role == .text_receiver).accessibilityIdentifier("pairing-agent-access")
                            if pairing.role == .text_receiver { Text("Choose an agent role to enable tasks.").font(.subheadline) }
                            TextField("Pairing invitation", text: $pairing.code, axis: .vertical)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                                .focused($codeFocused).textFieldStyle(.roundedBorder).accessibilityIdentifier("pairing-invitation")
                            Button("Connect") {
                                codeFocused = false
                                Task { await pairing.begin() }
                            }.buttonStyle(.glassProminent).controlSize(.large).disabled(pairing.busy)
                            Button("Scan QR code", systemImage: "qrcode.viewfinder") { codeFocused = false; scan = true }
                                .buttonStyle(.glass).controlSize(.large)
                        }
                        if pairing.busy { ProgressView("Waiting for computer…") }
                        if let error = pairing.error { Label(error, systemImage: "exclamationmark.triangle").fixedSize(horizontal: false, vertical: true) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }.scrollDismissesKeyboard(.interactively)
                .onChange(of: pairing.phrase) { _, phrase in
                    if phrase != nil { codeFocused = false; withAnimation(reduceMotion ? nil : .smooth) { proxy.scrollTo("phrase", anchor: .top) } }
                }
            }.navigationTitle("Pair computer").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { Task { await pairing.cancel(); dismiss() } }.accessibilityIdentifier("pairing-cancel") } }
        }.presentationDetents([.large]).presentationDragIndicator(.visible).interactiveDismissDisabled(pairing.busy)
        .sheet(isPresented: $scan) { scanner }
    }
    private var scanner: some View {
        var scanner = QRScanner { result in scan = false; if let result { Task { await host.pairing.begin(result) } } }
        #if DEBUG
        scanner.demoDenied = host.demo != nil
        #endif
        return scanner.ignoresSafeArea()
    }
}
