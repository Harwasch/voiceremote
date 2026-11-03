import SwiftUI
import AppModel
import VoiceRemoteProtocol

struct DevicesView: View {
    @Bindable var host: AppRuntime
    @State private var scan = false
    var body: some View {
        @Bindable var pairing = host.pairing
        @Bindable var remote = host.remote
        List {
            Section("Computers") {
                if let notice = host.link.notice { Text(notice).foregroundStyle(.secondary) }
                ForEach(host.model.devices, id: \.device_id) { device in
                    VStack(alignment: .leading) { Text(device.display_name); Text(device.role.rawValue).font(.caption) }
                        .swipeActions { Button("Revoke", role: .destructive) { Task { await host.model.revoke(device.device_id) } } }
                }
            }
            Section("Add computer") {
                Picker("Role", selection: $pairing.role) {
                    Text("Text receiver").tag(DeviceInfoRole.text_receiver)
                    Text("Agent executor").tag(DeviceInfoRole.agent)
                    Text("Both").tag(DeviceInfoRole.both)
                }
                Button("Scan QR code", systemImage: "qrcode.viewfinder") { scan = true }
                TextField("Pairing code or QR payload", text: $pairing.code, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                Text("Offline fallback: paste the complete QR payload. Short code and external-network lookup await the Pairing transport update.").font(.footnote)
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
                Toggle("Use remote microphone", isOn: $remote.useRemote)
                Button("Find remote") { host.remote.scan() }
                ForEach(host.remote.discovered, id: \.identifier) { peripheral in
                    Button(peripheral.name ?? "Voice remote") { host.remote.connect(peripheral) }
                }
                Button("Disconnect remote", role: .destructive) { host.remote.disconnect() }
                Text("Draft BLE contract. Audio remains disabled until authenticated bond enrollment can be verified. Prototype OFF is a software stop; hardware microphone cutoff is unverified.").font(.footnote)
            }
        }.navigationTitle("Devices").task { await host.model.refresh() }
        .sheet(isPresented: $scan) {
            QRScanner { result in
                scan = false
                if let result { Task { await host.pairing.begin(result) } }
            }.ignoresSafeArea()
        }
    }
}
