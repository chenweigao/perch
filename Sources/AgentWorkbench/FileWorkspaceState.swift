import Foundation
import Observation
import WorkbenchCore

@MainActor @Observable
final class FileWorkspaceState {
    private(set) var tabs: [FileReadingTab] = []
    private(set) var selected: String?
    private(set) var history: [FileReadingTab] = []
    private(set) var historyIndex = -1
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex + 1 < history.count }
    func historyEntry(_ delta: Int) -> FileReadingTab? {
        let index = historyIndex + delta
        guard history.indices.contains(index) else { return nil }
        historyIndex = index; return history[index]
    }
    @ObservationIgnored private var key = ""
    @ObservationIgnored private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var current: FileReadingTab? { tabs.first { $0.path == selected } }
    func activate(host: UUID?, cwd: String) {
        history = []; historyIndex = -1
        key = "files.tabs.\(host?.uuidString ?? "none"):\(cwd)"
        tabs = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([FileReadingTab].self, from: $0) } ?? []
        selected = defaults.string(forKey: key + ".selected").flatMap { path in tabs.contains { $0.path == path } ? path : nil } ?? tabs.last?.path
    }
    func select(_ path: String, source: SessionReference? = nil) {
        if !tabs.contains(where: { $0.path == path }) {
            tabs.append(FileReadingTab(path: path, source: source))
            if tabs.count > 12 { tabs.removeFirst() }
        }
        if let source, let index = tabs.firstIndex(where: { $0.path == path }) { tabs[index].source = source }
        recordVisit(path, source: source)
        selected = path; save()
    }
    func recordVisit(_ path: String, source: SessionReference?) {
        if history.indices.contains(historyIndex), history[historyIndex].path == path {
            if let source { history[historyIndex].source = source }
            return
        }
        history = Array(history.prefix(historyIndex + 1))
        var visit = tabs.first { $0.path == path } ?? FileReadingTab(path: path)
        visit.source = source
        history.append(visit)
        if history.count > 40 { history.removeFirst() }
        historyIndex = history.count - 1
    }
    func resolveVisit(_ path: String, to actual: String) {
        if history.indices.contains(historyIndex), history[historyIndex].path == path { history[historyIndex].path = actual }
    }
    func restoreVisit(_ visit: FileReadingTab) {
        if let index = tabs.firstIndex(where: { $0.path == visit.path }) { tabs[index] = visit }
        else {
            tabs.append(visit)
            if tabs.count > 12 { tabs.removeFirst() }
        }
    }
    func resolve(_ requested: String, to actual: String) {
        guard requested != actual else { return }
        tabs.removeAll { $0.path == requested }; select(actual)
    }
    func close(_ path: String) -> String? {
        let index = tabs.firstIndex { $0.path == path } ?? 0
        tabs.removeAll { $0.path == path }
        if selected == path { selected = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].path }
        save(); return selected
    }
    func setReading(_ reading: Bool) {
        guard let index = tabs.firstIndex(where: { $0.path == selected }) else { return }
        tabs[index].reading = reading
        for index in history.indices where history[index].path == selected { history[index].reading = reading }
        save()
    }
    func offsetRecorder() -> (Double) -> Void {
        let capturedKey = key, capturedPath = selected
        return { [weak self] offset in
            guard let self, self.key == capturedKey else { return }
            if let index = self.tabs.firstIndex(where: { $0.path == capturedPath }) { self.tabs[index].offset = offset }
            for index in self.history.indices where self.history[index].path == capturedPath { self.history[index].offset = offset }
            self.save()
        }
    }
    private func save() {
        defaults.set(try? JSONEncoder().encode(tabs), forKey: key)
        defaults.set(selected, forKey: key + ".selected")
    }
}
