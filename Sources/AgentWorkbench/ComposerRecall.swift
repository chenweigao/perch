import Foundation

/// Up-arrow recall of sent prompts, one per composer. Recall starts only from an
/// empty draft, owns Up/Down/Escape while active, and ends on any edit that did
/// not come from recall itself. Return keeps its send meaning.
struct ComposerRecall: Equatable {
    /// The draft recall most recently applied; a different incoming edit ends recall.
    private(set) var applied: String?
    private var index = 0

    var isActive: Bool { applied != nil }

    /// Returns the draft to display when this key belongs to recall, nil when the
    /// key falls through to normal editing.
    mutating func handle(_ key: ComposerKey, draft: String, entries: [String]) -> String? {
        guard !entries.isEmpty else { applied = nil; return nil }
        switch key {
        case .up:
            if let applied, let current = entries.firstIndex(of: applied), current > 0 {
                index = current - 1
            } else if applied != nil {
                return draft // Already at the oldest entry; the key stays consumed.
            } else {
                guard draft.isEmpty else { return nil }
                index = entries.count - 1
            }
            applied = entries[index]
            return applied
        case .down:
            guard let applied, let current = entries.firstIndex(of: applied) else { return nil }
            if current + 1 < entries.count {
                index = current + 1
                self.applied = entries[index]
                return self.applied
            }
            self.applied = nil
            return "" // Past the newest entry: back to the empty draft recall started from.
        case .escape:
            guard applied != nil else { return nil }
            applied = nil
            return ""
        case .enter, .tab:
            return nil
        }
    }

    /// Any edit that differs from the applied recall is the user typing again.
    mutating func draftChanged(_ draft: String) {
        if applied != nil && applied != draft { applied = nil }
    }
}
