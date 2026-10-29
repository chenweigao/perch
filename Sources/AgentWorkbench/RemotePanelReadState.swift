import Foundation
import Observation
import WorkbenchCore

/// One read channel for file and Git navigation. Replacing a read invalidates
/// its publication; user-started Git writes never enter this channel.
@MainActor @Observable
final class RemotePanelReadState {
    var loading = false
    var error: String?
    var fileRequest: FileReadRequest?
    @ObservationIgnored var generation = 0
    @ObservationIgnored private var reader: RemoteReader?
    @ObservationIgnored private var task: Task<Void, Never>?

    func run(_ command: String, destination: String, local: Bool, token: Int,
             apply: @escaping (Data) throws -> Void, failed: @escaping () -> Void) {
        let session = RemoteReader(local: local)
        reader = session
        task = Task { [weak self] in
            let result = await session.run(command: command, destination: destination)
            guard let self, token == self.generation else { return }
            self.loading = false
            self.reader = nil
            switch result {
            case .success(let data):
                do { try apply(data) } catch { failed(); self.error = error.localizedDescription }
            case .failure(let failure):
                failed()
                self.error = failure.localizedDescription
            }
        }
    }

    func cancel() {
        fileRequest = nil
        generation += 1
        task?.cancel()
        task = nil
        reader?.terminate()
        reader = nil
        loading = false
    }
}
