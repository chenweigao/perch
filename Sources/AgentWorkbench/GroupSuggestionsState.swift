import Foundation
import Observation
import WorkbenchCore

/// The sheet owns this state; SwiftUI owns the task that calls `load`.
@MainActor @Observable
final class GroupSuggestionsState {
    struct Request: Identifiable {
        let id = UUID()
        let input: GroupingInput
        let configuration: ActivitySummaryConfiguration
        let revision: Int
        let language: String
    }

    private(set) var request: Request?
    private(set) var suggestions: [GroupSuggestion] = []
    var selected = Set<String>()
    private(set) var loading = false
    private(set) var generated = false
    var error: String?
    var applied = false

    func begin(input: GroupingInput, configuration: ActivitySummaryConfiguration, revision: Int, language: String) {
        reset()
        request = Request(input: input, configuration: configuration, revision: revision, language: language)
        loading = true
    }

    func reset() {
        request = nil
        suggestions = []; selected = []; loading = false; generated = false; error = nil; applied = false
    }

    func load(_ request: Request, operation: (Request) async throws -> [GroupSuggestion]) async {
        guard loading, self.request?.id == request.id else { return }
        defer {
            // An old request must not clear the spinner of its replacement.
            if self.request?.id == request.id { loading = false }
        }
        do {
            try Task.checkCancellation()
            let result = try await operation(request)
            try Task.checkCancellation()
            guard self.request?.id == request.id else { return }
            suggestions = result; selected = Set(result.map(\.id)); generated = true
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), self.request?.id == request.id else { return }
            self.error = error.localizedDescription
        }
    }
}
