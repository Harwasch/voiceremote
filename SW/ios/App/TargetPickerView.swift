import SwiftUI
import AppModel
import Core
import VoiceRemoteProtocol

struct TargetPickerView: View {
    let model: VoiceAppModel
    var connectedIDs: Set<String> = []
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if model.controls.mode == .ai_control, let agents = model.agentControl {
                    Section("Sessions you can ask") {
                        ForEach(Array(agents.destinations.enumerated()), id: \.offset) { _, destination in
                            Button { try? agents.choose(destination.session); model.settingsChanged() } label: {
                                selectionRow(destination.session.providerSessionID,
                                    detail: AppPresentation.provider(destination.session.provider) + (destination.available ? " · Connected" : " · Offline, tasks wait"),
                                    symbol: "sparkles", selected: agents.selected == destination.session)
                            }.foregroundStyle(.primary)
                        }
                    }
                }
                Section {
                    Button { model.setTarget(.auto) } label: {
                        selectionRow("Auto", detail: "Follows the last text field you used. Now: " + (model.destination?.display_name ?? "This iPhone"), symbol: "arrow.triangle.branch", selected: model.controls.target == .auto)
                    }.accessibilityIdentifier("target-auto")
                }
                Section {
                    ForEach(model.devices.filter { $0.capabilities.contains(.receive_text) }, id: \.device_id) { device in
                        Button { model.setTarget(.device(device.device_id)) } label: {
                            selectionRow(device.display_name, detail: connectedIDs.contains(device.device_id) ? "Ready for your words" : "Offline · words wait until it's back", symbol: "desktopcomputer", selected: model.controls.target == .device(device.device_id))
                        }.accessibilityIdentifier("target-" + device.device_id)
                    }
                    Button { model.setTarget(.device(model.phoneID)) } label: {
                        selectionRow("This iPhone", detail: "Types with the Voice Remote keyboard", symbol: "iphone", selected: model.controls.target == .device(model.phoneID))
                    }.accessibilityIdentifier("target-phone")
                } header: {
                    Text("Or always send to")
                } footer: {
                    Text("Switching stops what you're saying now. Dictation never presses Send.")
                        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
            }.listStyle(.insetGrouped).foregroundStyle(.primary)
                .navigationTitle("Where your words go").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("destination-done") } }
        }.presentationDetents([.fraction(0.82), .large]).presentationDragIndicator(.visible)
    }
    private func selectionRow(_ name: String, detail: String, symbol: String, selected: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: .circle).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if selected { Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Selected") }
        }.frame(minHeight: 56).contentShape(Rectangle())
    }
}
