import SwiftUI
import AppModel

struct ApprovalView: View {
    let model: VoiceAppModel
    @State private var approving = false
    @ScaledMetric(relativeTo: .title2) private var headingSize = 26
    private var indigo: Color { Color(uiColor: .systemIndigo) }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let card = model.approval {
                        VStack(alignment: .leading, spacing: 14) {
                            Image(systemName: "sparkles").font(.title2).foregroundStyle(indigo).frame(width: 52, height: 52)
                                .background(indigo.opacity(0.14), in: .rect(cornerRadius: 16)).accessibilityHidden(true)
                            Text(AppPresentation.actionTitle(card.preview.tool)).font(.system(size: headingSize, weight: .bold))
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).accessibilityIdentifier("approval-exact-action")
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
                        Spacer(minLength: 24)
                        if let message = model.message { Text(message).fixedSize(horizontal: false, vertical: true) }
                        VStack(spacing: 10) {
                            Button {
                                approving = true
                                Task { await model.approve(); approving = false }
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
                    }
                }.padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 24)
                    .frame(minHeight: geometry.size.height, alignment: .topLeading)
            }.background(Color(uiColor: .systemGroupedBackground))
        }.presentationDetents([.fraction(0.9), .large]).presentationDragIndicator(.visible).interactiveDismissDisabled(approving)
    }
    private func detail(_ title: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) { Text(title).foregroundStyle(.secondary); Spacer(minLength: 12); Text(value).fontWeight(.semibold) }
            VStack(alignment: .leading, spacing: 6) { Text(title).foregroundStyle(.secondary); Text(value).fontWeight(.semibold) }
        }.font(.body).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 16).padding(.vertical, 16)
    }
}
