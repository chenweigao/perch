import Foundation
import Observation
import WorkbenchCore

@MainActor @Observable
final class FileWorkspaceState {
    private(set) var tabs: [FileReadingTab] = []
    private(set) var selected: String?
    @ObservationIgnored private var key = ""
    @ObservationIgnored private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var current: FileReadingTab? { tabs.first { $0.path == selected } }
    func activate(host: UUID?, cwd: String) {
        key = "files.tabs.\(host?.uuidString ?? "none"):\(cwd)"
        tabs = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([FileReadingTab].self, from: $0) } ?? []
        selected = defaults.string(forKey: key + ".selected").flatMap { path in tabs.contains { $0.path == path } ? path : nil } ?? tabs.last?.path
    }
    func select(_ path: String) {
        if !tabs.contains(where: { $0.path == path }) {
            tabs.append(FileReadingTab(path: path))
            if tabs.count > 12 { tabs.removeFirst() }
        }
        selected = path; save()
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
        tabs[index].reading = reading; save()
    }
    func offsetRecorder() -> (Double) -> Void {
        let capturedKey = key, capturedPath = selected
        return { [weak self] offset in
            guard let self, self.key == capturedKey,
                  let index = self.tabs.firstIndex(where: { $0.path == capturedPath }) else { return }
            self.tabs[index].offset = offset; self.save()
        }
    }
    private func save() {
        defaults.set(try? JSONEncoder().encode(tabs), forKey: key)
        defaults.set(selected, forKey: key + ".selected")
    }
}
