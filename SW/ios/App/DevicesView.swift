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
        List {
            Section {
                if host.model.devices.isEmpty {
                    ContentUnavailableView("Add your computer", systemImage: "desktopcomputer", description: Text("Pair to type text or review agent tasks on your computer."))
                }
                if let notice = host.link.notice { Text(notice) }
                ForEach(host.model.devices, id: \.device_id) { device in
                    NavigationLink {
                        List {
                            LabeledContent("Use", value: device.role.displayLabel)
                            Text(connectionStatus(device.device_id))
                            ForEach(device.capabilities, id: \.self) { Text($0.displayLabel) }
                            if host.link.suspendedIDs.contains(device.device_id) {
                                Button("Retry connection") { host.link.retrySuspended(device.device_id) }.frame(minHeight: 44)
                            }
                            Button("Revoke computer", role: .destructive) { Task { await host.model.revoke(device.device_id) } }.frame(minHeight: 44)
                        }.navigationTitle(device.display_name)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "desktopcomputer").font(.title3).foregroundStyle(.blue).frame(width: 40, height: 40)
                                .background(Color.blue.opacity(0.1), in: .rect(cornerRadius: 12)).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.display_name).font(.body.weight(.semibold)).accessibilityIdentifier("device-" + device.device_id)
                                Text(connectionStatus(device.device_id)).font(.subheadline).foregroundStyle(isConnected(device.device_id) ? Color.green : .secondary)
                            }.fixedSize(horizontal: false, vertical: true)
                        }.frame(minHeight: 56)
                    }.accessibilityIdentifier("device-row-" + device.device_id)
                    .swipeActions { Button("Revoke", role: .destructive) { Task { await host.model.revoke(device.device_id) } } }
                }
            } header: { Text("Computers").textCase(nil) }
            Section {
                NavigationLink {
                    remoteDetails
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "mic").font(.title3).foregroundStyle(.blue).frame(width: 40, height: 40)
                            .background(Color.blue.opacity(0.1), in: .rect(cornerRadius: 12)).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.remote.isEnrolled ? host.remote.sourceName : "Voice remote").font(.body.weight(.semibold))
                            Text(host.remote.status).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("remote-status")
                        }.fixedSize(horizontal: false, vertical: true)
                    }.frame(minHeight: 56)
                }.accessibilityIdentifier("remote-details")
                Picker("Use for talking", selection: $host.captureChoice) {
                    Text("Phone or headset").tag(CaptureChoice.phone)
                    Text("Remote").tag(CaptureChoice.remote)
                    Text("Best mic, automatically").tag(CaptureChoice.automatic)
                }
            } header: { Text("Voice remote").textCase(nil) } footer: {
                Text("Recordings made while the remote was out of range appear in History as text.")
                    .font(.footnote).fixedSize(horizontal: false, vertical: true)
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
        }.listStyle(.insetGrouped).navigationTitle("Devices").task { await host.model.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Add computer", systemImage: "plus") { pairingSheet = true }.accessibilityIdentifier("pair-computer") }
        }
        .sheet(isPresented: $pairingSheet, onDismiss: { Task { await host.pairing.cancel() } }) { PairComputerView(host: host) }
        .sheet(isPresented: $showingInfo) { InfoSheet(title: "Devices and microphones", paragraphs: ["Put your remote in pairing mode, then choose Find remote. Compare the six-digit number on your iPhone with the number on the remote. Continue only when both numbers match. If either screen shows no number, cancel and try again.", "Choose Phone or headset to use your iPhone microphone or connected headset. Choose Remote to use the paired remote. Best mic, automatically chooses an available microphone before you start. It keeps that microphone for the whole phrase.", "If the remote disconnects, unfinished words are discarded. Recordings made out of range appear in History after the remote reconnects. Forget remote removes this app’s connection; also forget it in iPhone Bluetooth Settings and reset its pairing on the remote."]) }
        .confirmationDialog("Discard this recording without transcription?", isPresented: Binding(get: { discardID != nil }, set: { if !$0 { discardID = nil } })) {
            Button("Discard recording", role: .destructive) {
                if let id = discardID { Task { await host.remote.discardOfflineRecording(id) } }; discardID = nil
            }
            Button("Cancel", role: .cancel) { discardID = nil }
        }
    }
    private var remoteDetails: some View {
        List {
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

            Button("About devices", systemImage: "info.circle") { showingInfo = true }
        }.navigationTitle("Voice remote")
    }
    private func isConnected(_ id: String) -> Bool {
        #if DEBUG
        if host.demo != nil { return id == UIDemo.computer.device_id }
        #endif
        return host.link.connectedIDs.contains(id)
    }
    private func connectionStatus(_ id: String) -> String {
        if isConnected(id) {
            let device = host.model.devices.first { $0.device_id == id }
            return "Connected · " + (device?.role == .both ? "types text, runs agents" : (device?.role == .agent ? "runs agents" : "types text"))
        }
        if host.link.suspendedIDs.contains(id) { return "Connection paused · pairing retained" }
        let waiting = host.model.history.filter { $0.targetID == id && host.model.deliveryStates[$0.segmentID] == .held }.count
        return waiting > 0 ? "Offline · \(waiting) message\(waiting == 1 ? "" : "s") waiting" : "Offline · words wait until it’s back"
    }
}

private struct PairComputerView: View {
    @Bindable var host: AppRuntime
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title2) private var wordSize = 26
    @FocusState private var codeFocused: Bool
    @State private var scan = false
    var body: some View {
        @Bindable var pairing = host.pairing
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let phrase = pairing.phrase {
                            Text("Check the words match").font(.title.bold())
                            Text("Your computer shows four words too. If they're the same, this phone is talking to your computer and no one else.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
                                ForEach(Array(phrase.split(separator: " ").enumerated()), id: \.offset) { _, word in
                                    Text(String(word)).font(.system(size: wordSize, weight: .bold)).frame(maxWidth: .infinity, minHeight: 76)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
                                }
                            }.accessibilityElement(children: .ignore).accessibilityLabel(phrase).accessibilityIdentifier("pairing-phrase")
                            Toggle(isOn: Binding(get: { pairing.allowAgentCommands }, set: { _ in })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Let this phone run agents here").fontWeight(.semibold)
                                    Text(pairing.allowAgentCommands ? "On: agent tasks still need your approval" : "Off: the computer only types your words")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }.fixedSize(horizontal: false, vertical: true)
                            }.disabled(true).padding(16)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
                                .accessibilityHint("Agent access is chosen before connecting. Cancel and start again to change it.")
                            Spacer(minLength: 24)
                            Button {
                                Task { if await pairing.confirm() != nil { await host.model.refresh(); dismiss() } }
                            } label: { Text("The words match").font(.headline).frame(maxWidth: .infinity, minHeight: 40).fixedSize(horizontal: false, vertical: true) }
                                .buttonStyle(.glassProminent).disabled(pairing.busy).accessibilityIdentifier("pairing-confirm")
                            Button(role: .destructive) { Task { await pairing.cancel(); dismiss() } } label: {
                                Text("They don't match").font(.headline).frame(maxWidth: .infinity, minHeight: 36).fixedSize(horizontal: false, vertical: true)
                            }.buttonStyle(.glass).foregroundStyle(.red).tint(.red).accessibilityIdentifier("pairing-mismatch")
                        } else {
                            Text("Connect your computer").font(.largeTitle.bold())
                            Text("Paste the invitation from your computer, or scan its QR code.").fixedSize(horizontal: false, vertical: true)
                            Picker("This computer will", selection: $pairing.role) {
                                Text("Type my words").tag(DeviceInfoRole.text_receiver)
                                Text("Run agents").tag(DeviceInfoRole.agent)
                                Text("Type my words and run agents").tag(DeviceInfoRole.both)
                            }
                            Toggle("Let this phone run agents here", isOn: $pairing.allowAgentCommands)
                                .disabled(pairing.role == .text_receiver).accessibilityIdentifier("pairing-agent-access")
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Pairing invitation").font(.subheadline.weight(.semibold))
                                TextField("Pairing invitation", text: $pairing.code, prompt: Text("Paste the invitation from your computer").foregroundStyle(.secondary), axis: .vertical)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                                    .focused($codeFocused).textFieldStyle(.plain).foregroundStyle(.primary)
                                    .frame(minHeight: 44).accessibilityIdentifier("pairing-invitation")
                            }.padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
                        }
                        if pairing.busy { ProgressView("Waiting for computer…") }
                        if let message = pairing.error { Label(message, systemImage: "exclamationmark.triangle").fixedSize(horizontal: false, vertical: true) }
                    }.padding(24).frame(minHeight: geometry.size.height, alignment: .topLeading)
                }.scrollDismissesKeyboard(.interactively)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        // Pinned so the keyboard never hides Connect.
                        if pairing.phrase == nil {
                            HStack(spacing: 10) {
                                Button("Scan QR code", systemImage: "qrcode.viewfinder") { codeFocused = false; scan = true }
                                    .buttonStyle(.glass).controlSize(.large)
                                Button { codeFocused = false; Task { await pairing.begin() } } label: {
                                    Text("Connect").frame(maxWidth: .infinity)
                                }.buttonStyle(.glassProminent).controlSize(.large).disabled(pairing.busy)
                            }.dynamicTypeSize(...DynamicTypeSize.xxxLarge).padding(.horizontal, 24).padding(.vertical, 12)
                                .background(Color(uiColor: .systemGroupedBackground))
                        }
                    }
                    .id(pairing.phrase == nil ? "invitation" : "confirmation")
            }.background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { Task { await pairing.cancel(); dismiss() } }.accessibilityIdentifier("pairing-cancel") }
                    ToolbarItem(placement: .topBarTrailing) { Text(pairing.phrase == nil ? "Step 1 of 2" : "Step 2 of 2").font(.subheadline).foregroundStyle(.secondary) }
                }
        }
        #if DEBUG
        .modifier(UIDemoPresentation())
        #endif
        .presentationDetents([.large]).presentationDragIndicator(.visible).interactiveDismissDisabled(pairing.busy)
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
