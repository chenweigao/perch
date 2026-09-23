import SwiftUI
import WorkbenchCore

struct ConversationFindBar: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var kimi: KimiConnection
    @ObservedObject var native: NativeAgentConnection
    @State private var query = ""
    @State private var index = 0
    @State private var hits: [ConversationSearchHit] = []
    @State private var search = ConversationSearch()
    @FocusState private var focused: Bool
    private var messages: [KimiMessage] { model.showKimi ? kimi.conversation?.displayMessages ?? [] : native.snapshot?.messages ?? [] }
    private var hasOlder: Bool { model.showKimi ? kimi.conversation?.hasOlder == true : native.snapshot?.hasOlder == true }
    private var loadingOlder: Bool { model.showKimi ? kimi.loadingOlder : native.loadingOlder }
    private var canLoadHistory: Bool { model.showKimi ? kimi.online && kimi.snapshotReady : native.online }
    private var running: Bool { model.showKimi ? kimi.conversation?.snapshot.session.busy == true : native.snapshot?.busy == true }
    private var readingKey: String {
        model.showKimi ? "\(kimi.host.id):kimi:\(kimi.selectedId ?? "")" : "\(native.host.id):native:\(native.selectedID ?? "")"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                TextField("Find in conversation", text: $query).textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { move(1) }.onChange(of: query) { _, _ in index = 0; updateSearch(preservingSelection: false); reveal() }
                Text(hits.isEmpty ? "0 matches" : "\(min(index + 1, hits.count))/\(hits.count)").monospacedDigit()
                Button { move(-1) } label: { Image(systemName: "chevron.up") }.help("Previous match · ⇧⌘G").accessibilityLabel("Previous match").disabled(hits.isEmpty)
                Button { move(1) } label: { Image(systemName: "chevron.down") }.help("Next match · ⌘G").accessibilityLabel("Next match").disabled(hits.isEmpty)
                if hasOlder {
                    Button(loadingOlder ? "Loading…" : "Search full history") {
                        if model.showKimi { kimi.loadAllHistoryForSearch() } else { native.loadAllHistoryForSearch() }
                    }.disabled(loadingOlder || !canLoadHistory)
                }
                Button(action: close) { Image(systemName: "xmark") }.help("Close find").accessibilityLabel("Close find")
            }
            if hits.indices.contains(index) { Text(hits[index].excerpt).lineLimit(2).textSelection(.enabled).foregroundStyle(.secondary) }
            if hasOlder { Text("Matches cover loaded messages. Load full history to search older replies.").foregroundStyle(.secondary) }
        }.font(.system(size: 12)).padding(10).background(.regularMaterial)
            .onAppear { focused = true; updateSearch() }
            .onChange(of: model.selectedReference) { _, _ in index = 0; updateSearch(preservingSelection: false) }
            .onChange(of: messages) { _, _ in updateSearch() }
            .onChange(of: running) { _, _ in updateSearch() }
            .onChange(of: hits.count) { _, count in index = min(index, max(0, count - 1)) }
            .onReceive(NotificationCenter.default.publisher(for: .init("PerchFindNext"))) { notice in move(notice.object as? Int ?? 1) }
            .onReceive(NotificationCenter.default.publisher(for: .init("PerchFocusFind"))) { _ in focused = true }
            .onExitCommand(perform: close)
    }
    private func updateSearch(preservingSelection: Bool = true) {
        let current = preservingSelection && hits.indices.contains(index) ? hits[index].id : nil
        hits = search.hits(in: messages, query: query, running: running)
        // Loading older messages inserts matches before the current one.
        // Keep the user's match selected instead of changing it by array index.
        index = current.flatMap { id in hits.firstIndex { $0.id == id } } ?? min(index, max(0, hits.count - 1))
    }
    private func close() {
        model.showConversationFind = false
        NotificationCenter.default.post(name: .init("PerchFocusComposer"), object: nil)
    }
    private func move(_ delta: Int) { updateSearch(); guard !hits.isEmpty else { return }; index = (index + delta + hits.count) % hits.count; reveal() }
    private func reveal() {
        guard hits.indices.contains(index) else { return }
        ConversationReadingMemory.shared.following[readingKey] = false
        NotificationCenter.default.post(name: .init("PerchRevealConversationHit"), object: ConversationFindTarget(session: readingKey, hit: hits[index], query: query))
    }
}
