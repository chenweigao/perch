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
    func makeNSView(context: Context) -> WorkbenchTaskLifetimeView {
        let view = WorkbenchTaskLifetimeView()
        view.onDetach = { [weak coordinator = context.coordinator] in coordinator?.cancel() }
        return view
    }
    func updateNSView(_ view: WorkbenchTaskLifetimeView, context: Context) {
        context.coordinator.update(id: id, action: action)
    }
    static func dismantleNSView(_ view: WorkbenchTaskLifetimeView, coordinator: Coordinator) {
        coordinator.cancel()
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

        func cancel() {
            task?.cancel()
            task = nil
            id = nil
        }

        deinit { task?.cancel() }
    }
}

private final class WorkbenchTaskLifetimeView: NSView {
    var onDetach: (() -> Void)?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { onDetach?() }
        super.viewWillMove(toWindow: newWindow)
    }
}
