import Observation
import SwiftUI

/// Lightweight reading choices survive inspector remounts, without retaining
/// file contents or requests. The controller owns one instance per full session.
@MainActor @Observable
final class TaskContextReadingState {
    @ObservationIgnored var overviewOffset: CGFloat = 0
    var allFiles = false
    var completedTasks = false
    let files = FileWorkspaceState(defaults: nil)
}

struct TaskContextScrollView<Content: View>: View {
    let reading: TaskContextReadingState
    let onScrolled: (Bool) -> Void
    let content: Content
    private let initialOffset: CGFloat
    @State private var position: ScrollPosition

    init(reading: TaskContextReadingState, onScrolled: @escaping (Bool) -> Void,
         @ViewBuilder content: () -> Content) {
        self.reading = reading
        self.onScrolled = onScrolled
        self.content = content()
        initialOffset = reading.overviewOffset
        _position = State(initialValue: ScrollPosition(y: reading.overviewOffset))
    }

    var body: some View {
        ScrollView { content }
            .scrollPosition($position)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentOffset.y) } action: { previous, offset in
                reading.overviewOffset = offset
                if (previous > 1) != (offset > 1) { onScrolled(offset > 1) }
            }
            // This view is mounted only once the session's content is ready.
            // Capture the saved offset before initial layout can report zero.
            .onAppear {
                onScrolled(initialOffset > 1)
                position.scrollTo(y: initialOffset)
            }
    }
}
