import SwiftUI
import WorkbenchCore

struct ConversationFindBar: View {
    @Bindable var model: WorkbenchModel
    let kimi: KimiConnection
    let native: NativeAgentConnection
    @State private var query = ""
    @State private var options = ConversationFindOptions()
    @State private var index = 0
    @State private var result = ConversationFindResult.empty
    @State private var search = ConversationSearch()
    @FocusState private var focused: Bool
    private var hits: [ConversationSearchHit] { result.hits }
    private var messages: [KimiMessage] { model.showKimi ? kimi.conversation?.displayMessages ?? [] : native.snapshot?.messages ?? [] }
    private var hasOlder: Bool { model.showKimi ? kimi.conversation?.hasOlder == true : native.snapshot?.hasOlder == true }
    private var loadingOlder: Bool { model.showKimi ? kimi.loadingOlder : native.loadingOlder }
    private var canLoadHistory: Bool { model.showKimi ? kimi.online && kimi.snapshotReady : native.online }
    private var running: Bool { model.showKimi ? kimi.conversation?.snapshot.session.isTurnRunning == true : native.snapshot?.busy == true }
    private var readingKey: String {
        model.showKimi ? "\(kimi.host.id):kimi:\(kimi.selectedId ?? "")" : "\(native.host.id):native:\(native.selectedID ?? "")"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controls
            if let error = result.queryError { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            if hits.indices.contains(index) { Text(hits[index].excerpt).lineLimit(2).textSelection(.enabled).foregroundStyle(.secondary) }
            if hasOlder { Text("Matches cover loaded messages. Load full history to search older replies.").foregroundStyle(.secondary) }
        }.font(.system(size: 12)).padding(10).background(.regularMaterial)
            .onAppear { focused = true; updateSearch() }
            .onChange(of: model.selectedReference) { old, _ in if let old { sessionChanged(from: old) } }
            .onChange(of: messages) { _, _ in updateSearch() }
            .onChange(of: running) { _, _ in updateSearch() }
            .onChange(of: hits.count) { _, count in index = min(index, max(0, count - 1)) }
            .onReceive(NotificationCenter.default.publisher(for: .init("PerchFindNext"))) { notice in move(notice.object as? Int ?? 1) }
            .onReceive(NotificationCenter.default.publisher(for: .init("PerchFocusFind"))) { _ in focused = true }
            .onExitCommand(perform: close)
    }
    private var controls: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
            TextField("Find in conversation", text: $query).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { move(1) }.onChange(of: query) { _, _ in index = 0; updateSearch(preservingSelection: false); reveal(); publishHighlight() }
            optionToggles
            roleMenu
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
    }
    private var optionToggles: some View {
        HStack(spacing: 2) {
            FindOptionToggle(label: "Aa", help: "Case sensitive", on: $options.caseSensitive) { refreshOptions() }
            FindOptionToggle(label: ".*", help: "Regular expression", on: $options.regex) { refreshOptions() }
        }
    }
    private var roleMenu: some View {
        Menu {
            ForEach(ConversationFindOptions.Role.allCases, id: \.self) { role in
                Button(roleTitle(role)) { options.role = role; refreshOptions() }
            }
        } label: {
            HStack(spacing: 3) {
                Text(roleTitle(options.role))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
            }
        }.menuStyle(.borderlessButton).fixedSize().help("Search only user prompts, replies, or tool content")
    }
    private func roleTitle(_ role: ConversationFindOptions.Role) -> String {
        switch role {
        case .all: return "All"
        case .user: return "User"
        case .assistant: return "Replies"
        case .tool: return "Tools"
        }
    }
    private func refreshOptions() {
        index = 0
        updateSearch(preservingSelection: false)
        reveal()
        publishHighlight()
    }
    /// Switching sessions resets the bar and clears highlights left behind in
    /// the outgoing session's transcript.
    private func sessionChanged(from old: SessionReference) {
        let kind = old.kind == .kimi ? "kimi" : "native"
        let oldKey = "\(old.hostID.uuidString):\(kind):\(old.terminalID)"
        let clear = ConversationHighlightUpdate(session: oldKey, query: "", options: ConversationFindOptions())
        NotificationCenter.default.post(name: .init("PerchConversationHighlight"), object: clear)
        index = 0; options = ConversationFindOptions(); updateSearch(preservingSelection: false)
    }
    private func updateSearch(preservingSelection: Bool = true) {
        let current = preservingSelection && hits.indices.contains(index) ? hits[index].id : nil
        result = search.hits(in: messages, query: query, running: running, options: options)
        // Loading older messages inserts matches before the current one.
        // Keep the user's match selected instead of changing it by array index.
        index = current.flatMap { id in hits.firstIndex { $0.id == id } } ?? min(index, max(0, hits.count - 1))
    }
    private func close() {
        model.showConversationFind = false
        publishHighlight(clear: true)
        NotificationCenter.default.post(name: .init("PerchFocusComposer"), object: nil)
    }
    private func move(_ delta: Int) { updateSearch(); guard !hits.isEmpty else { return }; index = (index + delta + hits.count) % hits.count; reveal() }
    private func reveal() {
        guard hits.indices.contains(index) else { return }
        ConversationReadingMemory.shared.following[readingKey] = false
        NotificationCenter.default.post(name: .init("PerchRevealConversationHit"),
                                        object: ConversationFindTarget(session: readingKey, hit: hits[index], query: query, options: options))
    }
    private func publishHighlight(clear: Bool = false) {
        NotificationCenter.default.post(name: .init("PerchConversationHighlight"),
                                        object: ConversationHighlightUpdate(session: readingKey, query: clear ? "" : query, options: options))
    }
}

private struct FindOptionToggle: View {
    let label: String
    let help: String
    @Binding var on: Bool
    let onChange: () -> Void
    var body: some View {
        Button { on.toggle(); onChange() } label: {
            Text(label).font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 22, height: 20)
                .background(on ? Color.primary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(on ? .primary : .secondary).help(help)
    }
}
