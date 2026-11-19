import SwiftUI
import UIKit
import AppModel
import Core
import KeyboardBridge

struct HistoryView: View {
    let model: VoiceAppModel
    @State private var search = ""
    @State private var showingSearch = false
    private var entries: [HistoryEntry] {
        model.history.reversed().filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }
    }
    private var days: [Date] {
        Set(entries.filter { !waiting($0) }.map { Calendar.current.startOfDay(for: Date(timeIntervalSince1970: Double($0.createdAt) / 1000)) }).sorted(by: >)
    }
    private func waiting(_ entry: HistoryEntry) -> Bool {
        model.deliveryStates[entry.segmentID] == .held || model.deliveryStates[entry.segmentID] == .failed
    }
    var body: some View {
        List {
            if showingSearch {
                TextField("Search history", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("history-search")
            }
            if entries.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No text yet" : "No matching text", systemImage: "text.bubble", description: Text("Your finished phrases appear here."))
            }
            ForEach(entries.filter(waiting), id: \.segmentID) { entry in
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Waiting for " + target(entry)).fontWeight(.semibold)
                            Spacer(minLength: 8); timestamp(entry)
                        }.font(.subheadline).foregroundStyle(Color(uiColor: .systemBrown))
                        text(entry)
                        if model.deliveryStates[entry.segmentID] == .failed { Text("Insertion failed · your words are saved").font(.subheadline).foregroundStyle(.secondary) }
                        HStack(spacing: 10) {
                            Button("Send now") { Task { await model.sendHeld(entry.segmentID) } }
                                .frame(minHeight: 44).buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                                .accessibilityIdentifier("send-" + entry.segmentID)
                            actions(entry)
                        }
                    }.padding(.vertical, 4)
                }.listRowBackground(Color(uiColor: .tertiarySystemGroupedBackground).overlay(Color.orange.opacity(0.12)))
            }
            ForEach(days, id: \.self) { day in
                Section {
                    ForEach(entries.filter { !waiting($0) && Calendar.current.isDate(Date(timeIntervalSince1970: Double($0.createdAt) / 1000), inSameDayAs: day) }, id: \.segmentID) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(target(entry) + (model.deliveryStates[entry.segmentID] == .unconfirmed ? " · not confirmed" : ""))
                                Spacer(minLength: 8); timestamp(entry)
                            }.font(.subheadline).foregroundStyle(.secondary)
                            text(entry)
                            if let state = model.deliveryStates[entry.segmentID], state == .retentionReview || state == .offline {
                                Text(state.label).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            if let origin = model.offlineOrigins[entry.segmentID] { Text(origin.label).font(.subheadline).foregroundStyle(.secondary) }
                            if model.deliveryStates[entry.segmentID] == .unconfirmed {
                                Text("Check the computer before sending again").font(.subheadline).foregroundStyle(Color(uiColor: .systemBrown))
                            }
                        }.padding(.vertical, 2)
                            .contextMenu { menuItems(entry) }
                            .accessibilityHint("Touch and hold for text actions.")
                            .swipeActions { Button("Delete", role: .destructive) { Task { await model.deleteHistory(entry.segmentID) } } }
                    }
                } header: { Text(Calendar.current.isDateInToday(day) ? "Today" : day.formatted(date: .abbreviated, time: .omitted)).textCase(nil) } footer: {
                    Text("Text only. Recent text is kept 7 days; waiting and unconfirmed text stays until you delete it.")
                        .font(.footnote).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.listStyle(.insetGrouped).navigationTitle("History").task { await model.refresh() }
            .toolbar { Button("Search history", systemImage: "magnifyingglass") { showingSearch.toggle() } }
    }
    private func target(_ entry: HistoryEntry) -> String {
        model.devices.first(where: { $0.device_id == entry.targetID })?.display_name ?? (entry.targetID == model.phoneID ? "This iPhone" : "Unavailable computer")
    }
    private func timestamp(_ entry: HistoryEntry) -> some View {
        Text(Date(timeIntervalSince1970: Double(entry.createdAt) / 1000), style: .time)
    }
    private func text(_ entry: HistoryEntry) -> some View {
        Text(entry.text).font(.body).fixedSize(horizontal: false, vertical: true).accessibilityValue(model.deliveryStates[entry.segmentID]?.label ?? "Saved text")
            .accessibilityIdentifier("history-" + entry.segmentID)
    }
    private func actions(_ entry: HistoryEntry) -> some View {
        Menu { menuItems(entry) } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44).background(.quaternary, in: .circle)
        }.accessibilityLabel("More actions").accessibilityIdentifier("history-more-" + entry.segmentID)
    }
    @ViewBuilder private func menuItems(_ entry: HistoryEntry) -> some View {
        if model.deliveryStates[entry.segmentID] == .unconfirmed {
            Button("Send again after checking computer") { Task { await model.sendHeld(entry.segmentID) } }
        }
        Button("Copy", systemImage: "doc.on.doc") {
            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: entry.text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(BridgePolicy.retention)])
        }
        ShareLink(item: entry.text) { Label("Share", systemImage: "square.and.arrow.up") }
        Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.deleteHistory(entry.segmentID) } }
    }
}
