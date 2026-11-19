import SwiftUI
import AppModel
import Brain

struct SuggestionCardView: View {
    let model: VoiceAppModel
    let card: SuggestionCard
    private var indigo: Color { Color(uiColor: .systemIndigo) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles").foregroundStyle(indigo).frame(width: 36, height: 36)
                    .background(indigo.opacity(0.14), in: .circle).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppPresentation.actionTitle(card.proposal.tool)).font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("suggestion-summary")
                    Text("Suggested from what you said · expires in \(card.expiresAt, style: .relative)")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { review; dismiss }
                VStack(spacing: 10) { review; dismiss }
            }
        }.padding(18).background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
            .contextMenu {
                Menu("Edit target") {
                    ForEach(model.devices, id: \.device_id) { device in
                        Button(device.display_name) { Task { await model.editTarget(card, device: device) } }
                    }
                }
            }
    }
    private var review: some View {
        Button { Task { await model.review(card) } } label: { Text("Review").frame(maxWidth: .infinity, minHeight: 28) }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(indigo).frame(minHeight: 44).contentShape(Capsule()).accessibilityIdentifier("review-suggestion")
    }
    private var dismiss: some View {
        Button { Task { await model.dismiss(card) } } label: { Text("Dismiss").frame(maxWidth: .infinity, minHeight: 28) }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.primary).frame(minHeight: 44).contentShape(Capsule()).accessibilityIdentifier("dismiss-suggestion")
    }
}
