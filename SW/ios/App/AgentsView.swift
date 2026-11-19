import SwiftUI
import AppModel
import VoiceRemoteProtocol

struct AgentsView: View {
    let model: VoiceAppModel
    @State private var showingPermissions = false
    private var indigo: Color { Color(uiColor: .systemIndigo) }
    var body: some View {
        List {
            if model.tasks.isEmpty && model.agentControl?.destinations.isEmpty != false {
                ContentUnavailableView("No agents connected", systemImage: "sparkles", description: Text("Add an agent computer in Devices to see its sessions here."))
            }
            ForEach(model.tasks, id: \.command.command_id) { task in
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(AppPresentation.taskState(task)).font(.subheadline.weight(.semibold)).foregroundStyle(indigo)
                                .accessibilityIdentifier("task-status")
                            Spacer(minLength: 0)
                            if let session = task.route?.destination.session { Text(session.providerSessionID).font(.subheadline).foregroundStyle(.secondary) }
                        }.fixedSize(horizontal: false, vertical: true)
                        Text(AppPresentation.taskTitle(task)).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        if let reply = task.appReply { Text(reply).font(.subheadline).fixedSize(horizontal: false, vertical: true) }
                        if task.state == .running { ProgressView().tint(indigo).accessibilityLabel("Task running") }
                        if model.agentControl?.completionEpoch(for: task) != nil {
                            Button("Confirm observed completion…") { model.reviewTaskCompletion(task) }.frame(minHeight: 44)
                        }
                        if task.hold == .reapprovalRequired, task.state == .queued {
                            Button("Review restored task") { model.reviewRestoredTask(task) }.frame(minHeight: 44)
                        }
                        if task.state == .queued || task.state == .dispatched || task.state == .running {
                            Button(task.cancellationRequested ? "Retry cancellation" : "Cancel task", role: .destructive) {
                                Task { await model.cancelTask(task) }
                            }.frame(minHeight: 44).buttonStyle(.bordered).buttonBorderShape(.capsule).accessibilityIdentifier("cancel-task")
                        }
                    }.padding(.vertical, 4)
                }
            }
            if let agents = model.agentControl {
                Section {
                    ForEach(Array(agents.destinations.enumerated()), id: \.offset) { _, destination in
                        Button {
                            try? agents.choose(destination.session); model.settingsChanged()
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(destination.session.providerSessionID).font(.body.weight(.semibold))
                                    Text(sessionDetail(destination.session.provider, project: destination.session.workspace, host: destination.session.host, available: destination.available))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }.fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                if agents.routing.defaultSession == destination.session {
                                    Text("Default").font(.subheadline.weight(.semibold)).foregroundStyle(indigo)
                                } else if agents.selected == destination.session {
                                    Image(systemName: "checkmark").foregroundStyle(indigo).accessibilityLabel("Selected")
                                } else { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true) }
                            }.foregroundStyle(.primary).frame(minHeight: 52)
                        }.buttonStyle(.plain)
                            .contextMenu {
                                Button("Make default") { try? agents.makeDefault(destination.session) }
                                Button("Choose sessions automatically") { agents.clearSelection(); model.settingsChanged() }
                            }
                    }
                } header: { Text("Sessions you can ask").textCase(nil) } footer: {
                    Text("Agents only act after you approve. Sensitive actions always ask for Face ID.")
                        .font(.footnote).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.listStyle(.insetGrouped).navigationTitle("Agents")
            .toolbar { Button("Permissions", systemImage: "checkmark.shield") { showingPermissions = true }.labelStyle(.titleAndIcon).accessibilityIdentifier("agent-permissions") }
            .sheet(isPresented: $showingPermissions) {
                AgentPermissionsView(model: model)
                    #if DEBUG
                    .modifier(UIDemoPresentation())
                    #endif
            }
    }
    private func sessionDetail(_ provider: String, project: String, host: String, available: Bool) -> String {
        let hostName = model.devices.first(where: { $0.device_id == host })?.display_name ?? host
        return available ? AppPresentation.provider(provider) + " · " + project + " · " + hostName : hostName + " · offline, tasks wait"
    }
}

private struct AgentPermissionsView: View {
    let model: VoiceAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingInfo = false
    var body: some View {
        NavigationStack {
            List {
                Section("Sessions") {
                    Button("Choose sessions automatically") { model.agentControl?.clearSelection(); model.settingsChanged() }.frame(minHeight: 44)
                }
                Section("Cloud fallback") {
                    Toggle("Task doesn’t need this computer or its files", isOn: Binding(
                        get: { model.settings.routing.independentCloudTasks }, set: { model.settings.routing.independentCloudTasks = $0 }))
                        .accessibilityIdentifier("independent-task")
                    Toggle("Allow cloud fallback", isOn: Binding(
                        get: { model.settings.routing.allowCloudFallback }, set: { model.settings.routing.allowCloudFallback = $0 }))
                        .accessibilityIdentifier("cloud-fallback")
                }
                Section("Permissions") {
                    if let device = model.destination, device.capabilities.contains(.receive_text) {
                        Button("Allow target selection on \(device.display_name) for 15 minutes") {
                            model.grantTargetSelection(device: device, project: model.agentControl?.selected?.workspace ?? "default")
                        }.frame(minHeight: 44)
                    }
                    ForEach(model.grants, id: \.id) { grant in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(grant.capability.displayLabel).font(.headline)
                            Text(grant.session.device + " · " + grant.session.project).font(.subheadline)
                            Text(grant.risk.displayLabel).font(.subheadline)
                            Text("Expires \(Date(timeIntervalSince1970: Double(grant.expiresAt) / 1000), style: .relative)").font(.subheadline)
                            Button("Revoke permission", role: .destructive) { model.revokeGrant(grant) }.frame(minHeight: 44)
                        }.fixedSize(horizontal: false, vertical: true).buttonStyle(.borderless)
                    }
                    Toggle("Enable voice wake for this permission", isOn: Binding(get: { model.wakeArmed }, set: { model.wakeArmed = $0 }))
                        .accessibilityIdentifier("wake-permission")
                }
            }.navigationTitle("Permissions").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("About agents", systemImage: "info.circle") { showingInfo = true } }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("permissions-done") }
                }
                .sheet(isPresented: $showingInfo) {
                    InfoSheet(title: "Agents and permissions", paragraphs: [
                        "Choosing a session changes where future tasks go. Every agent task still requires review and fresh Face ID or your iPhone passcode.",
                        "An offline computer keeps its tasks held. A cloud fallback starts independent work; it does not continue a local session. Confirm that each task is independent before approving it.",
                        "Permissions only allow deliberate Hold commands to choose the exact device and project. They expire and are not restored after restart. Voice alone never proves identity."
                    ])
                }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
    }
}
