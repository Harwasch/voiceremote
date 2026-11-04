import SwiftUI
import AppModel
import VoiceRemoteProtocol

struct AgentsView: View {
    let model: VoiceAppModel
    @State private var showingInfo = false
    var body: some View {
        List {
            if model.tasks.isEmpty && model.agentControl?.destinations.isEmpty != false {
                ContentUnavailableView("No agents connected", systemImage: "person.2", description: Text("Add an agent computer in Devices to see its sessions here."))
            }
            if !model.tasks.isEmpty {
                Section("Tasks") {
                    ForEach(model.tasks, id: \.command.command_id) { task in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(AppPresentation.taskStatus(task)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("task-status")
                            if model.agentControl?.completionEpoch(for: task) != nil {
                                Button("Confirm observed completion…") { model.reviewTaskCompletion(task) }.frame(minHeight: 44)
                            }
                            if task.hold == .reapprovalRequired, task.state == .queued {
                                Button("Review restored task") { model.reviewRestoredTask(task) }.frame(minHeight: 44)
                            }
                            if task.state == .queued || task.state == .dispatched || task.state == .running {
                                Button(task.cancellationRequested ? "Retry cancellation" : "Cancel task", role: .destructive) {
                                    Task { await model.cancelTask(task) }
                                }.frame(minHeight: 44).accessibilityIdentifier("cancel-task")
                            }
                        }.buttonStyle(.borderless)
                    }
                }
            }
            if let agents = model.agentControl {
                Section("Sessions") {
                    Button("Choose sessions automatically") { agents.clearSelection(); model.settingsChanged() }.frame(minHeight: 44)
                    ForEach(Array(agents.destinations.enumerated()), id: \.offset) { _, destination in
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                try? agents.choose(destination.session); model.settingsChanged()
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(destination.session.providerSessionID).font(.headline)
                                    Text(AppPresentation.provider(destination.session.provider) + " · " + destination.session.host + " · " + destination.session.workspace).font(.subheadline)
                                    Text(destination.available ? "Connected" : "Offline — commands held").font(.subheadline)
                                    if agents.selected == destination.session { Label("Selected", systemImage: "checkmark") }
                                    if agents.routing.defaultSession == destination.session { Text("Default session") }
                                }.fixedSize(horizontal: false, vertical: true).foregroundStyle(.primary).frame(minHeight: 44)
                            }.buttonStyle(.plain)
                            Menu("Session options", systemImage: "ellipsis") {
                                Button("Make default") { try? agents.makeDefault(destination.session) }
                            }.frame(minHeight: 44)
                        }
                    }
                }
                Section("Cloud fallback") {
                    Toggle("Task doesn’t need this computer or its files", isOn: Binding(
                        get: { model.settings.routing.independentCloudTasks }, set: { model.settings.routing.independentCloudTasks = $0 }))
                        .accessibilityIdentifier("independent-task")
                    Toggle("Allow cloud fallback", isOn: Binding(
                        get: { model.settings.routing.allowCloudFallback }, set: { model.settings.routing.allowCloudFallback = $0 }))
                        .accessibilityIdentifier("cloud-fallback")
                }
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
        }.navigationTitle("Agents")
        .toolbar { Button("About agents", systemImage: "info.circle") { showingInfo = true } }
        .sheet(isPresented: $showingInfo) {
            InfoSheet(title: "Agents and permissions", paragraphs: [
                "Choosing a session changes where future tasks go. Every agent task still requires review and fresh Face ID or your iPhone passcode.",
                "An offline computer keeps its tasks held. A cloud fallback starts independent work; it does not continue a local session. Confirm that each task is independent before approving it.",
                "Permissions only allow deliberate Hold commands to choose the exact device and project. They expire and are not restored after restart. Voice alone never proves identity."
            ])
        }
    }
}
