import SwiftUI

/// Explanatory detail stays off the main task surface. Native bars/sheets supply materials.
struct InfoSheet: View {
    let title: String
    let paragraphs: [String]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.presentationDragIndicator(.visible)
        #if DEBUG
        .modifier(UIDemoPresentation())
        #endif
    }
}
