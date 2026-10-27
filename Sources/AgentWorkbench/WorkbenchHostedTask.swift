import SwiftUI

extension View {
    /// Floating AppKit hosts do not reliably receive SwiftUI appearance effects
    /// inside a WindowGroup. Tie page work to the native host's mounted lifetime.
    func workbenchHostedTask<Key: Equatable>(id: Key, action: @escaping @MainActor () async -> Void) -> some View {
        background(WorkbenchHostedTask(id: id, action: action).frame(width: 0, height: 0))
    }
}

private struct WorkbenchHostedTask<Key: Equatable>: NSViewRepresentable {
    let id: Key
    let action: @MainActor () async -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(id: id, action: action)
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.task?.cancel()
    }

    @MainActor final class Coordinator {
        private var id: Key?
        var task: Task<Void, Never>?

        func update(id: Key, action: @escaping @MainActor () async -> Void) {
            guard self.id != id else { return }
            self.id = id
            task?.cancel()
            task = Task {
                guard !Task.isCancelled else { return }
                await action()
            }
        }

        deinit { task?.cancel() }
    }
}
