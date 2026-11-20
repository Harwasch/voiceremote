import SwiftUI
import AppModel

struct ApprovalView: View {
    let model: VoiceAppModel
    @State private var approving = false
    @State private var refusalMessage: String?
    private var indigo: Color { Color(uiColor: .systemIndigo) }
    var body: some View {
        ScrollView {
            if let card = model.approval {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "sparkles").font(.title2).foregroundStyle(indigo).frame(width: 52, height: 52)
                            .background(indigo.opacity(0.14), in: .rect(cornerRadius: 16)).accessibilityHidden(true)
                        ApprovalHeading(text: AppPresentation.actionTitle(card.preview.tool))
                            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                            .textSelection(.enabled).accessibilityIdentifier("approval-exact-action")
                        Text(card.consequences).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(spacing: 0) {
                        detail("Runs on", value: card.destination.display_name + (card.route.map { " · " + AppPresentation.provider($0.session.provider) } ?? ""))
                        if let route = card.route { Divider().padding(.horizontal, 16); detail("Project", value: route.session.workspace) }
                        Divider().padding(.horizontal, 16)
                        detail("Approval lasts", value: "This task only")
                    }.background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
                    DisclosureGroup("Show the exact instruction") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(card.exactAction).textSelection(.enabled)
                            Text("Device: " + card.destination.device_id).textSelection(.enabled)
                            if let route = card.routeDescription { Text(route).textSelection(.enabled) }
                        }.font(.subheadline).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                    }.frame(minHeight: 44).tint(indigo).accessibilityIdentifier("approval-details")
                    if refusalMessage == nil, let message = model.message { Text(message).fixedSize(horizontal: false, vertical: true) }
                }.padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 24)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                if let refusalMessage {
                    Text(refusalMessage).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("approval-refused")
                    Button { model.dismissApproval() } label: {
                        Text("Close").font(.headline).frame(maxWidth: .infinity, minHeight: 40)
                    }.buttonStyle(.glassProminent).tint(indigo).accessibilityIdentifier("approval-deny")
                } else if let card = model.approval {
                    Button {
                        approving = true
                        Task {
                            await model.approve()
                            if model.message == "Approval denied or expired. Nothing was started." { refusalMessage = model.message }
                            approving = false
                        }
                    } label: {
                        Label(model.canRetryQueue ? "Retry queue" : (card.preview.risk == .sensitive ? "Approve with Face ID" : "Approve this action"),
                            systemImage: card.preview.risk == .sensitive ? "faceid" : "checkmark")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 40).fixedSize(horizontal: false, vertical: true)
                    }.buttonStyle(.glassProminent).tint(indigo).disabled(approving).accessibilityIdentifier("approve-action")
                        .accessibilityHint(card.preview.risk == .sensitive ? "Requires Face ID or your iPhone passcode. Approves only the exact action shown." : "Approves only the exact action shown.")
                    Button(role: .cancel) { model.dismissApproval() } label: {
                        Text("Don't allow").font(.headline).frame(maxWidth: .infinity, minHeight: 36).fixedSize(horizontal: false, vertical: true)
                    }.buttonStyle(.glass).accessibilityIdentifier("approval-deny")
                }
            }.dynamicTypeSize(...DynamicTypeSize.xxxLarge).padding(.horizontal, 24).padding(.vertical, 16)
                .frame(maxWidth: .infinity).background(Color(uiColor: .systemGroupedBackground))
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .presentationDetents([.fraction(0.9), .large]).presentationDragIndicator(.visible).interactiveDismissDisabled(approving)
        .onChange(of: model.approval?.id) { _, _ in refusalMessage = nil }
    }
    private func detail(_ title: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) { Text(title).foregroundStyle(.secondary); Spacer(minLength: 12); Text(value).fontWeight(.semibold) }
            VStack(alignment: .leading, spacing: 6) { Text(title).foregroundStyle(.secondary); Text(value).fontWeight(.semibold) }
        }.font(.body).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 16).padding(.vertical, 16)
    }
}
private struct ApprovalHeading: View {
    let text: String
    @ScaledMetric(relativeTo: .title2) private var size = 26
    var body: some View { Text(text).font(.system(size: size, weight: .bold)).fixedSize(horizontal: false, vertical: true) }
}
