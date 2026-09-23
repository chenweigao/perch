import Foundation
import Darwin

public final class KimiAPI: @unchecked Sendable {
    public let baseURL: URL
    private let token: String
    private let session: URLSession
    private let lifecycleLock = NSLock()
    private var closed = false
    private var activeRequests = 0
    public init(baseURL: URL, token: String, configuration: URLSessionConfiguration = .ephemeral) {
        self.baseURL = baseURL; self.token = token
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }
    public func request(_ path: String, method: String = "GET", body: JSONValue? = nil) async throws -> Data {
        var request = authorizedRequest(path)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        try beginRequest()
        defer { endRequest() }
        let (data, response) = try await session.data(for: request)
        if let response = response as? HTTPURLResponse, response.statusCode == 401 { throw WorkbenchError("Kimi 访问凭证失效，请重新连接。") }
        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            let envelope = try? JSONDecoder().decode(JSONValue.self, from: data)
            throw WorkbenchError(envelope?["error"].string ?? envelope?["msg"].string ?? "HTTP \(response.statusCode)")
        }
        return data
    }
    public func get<T: Decodable>(_ type: T.Type, _ path: String) async throws -> T {
        try KimiWire.decode(type, from: await request(path))
    }
    public func post<T: Decodable>(_ type: T.Type, _ path: String, body: JSONValue = .object([:])) async throws -> T {
        try KimiWire.decode(type, from: await request(path, method: "POST", body: body))
    }
    public func upload(_ url: URL, mediaType: String) async throws -> JSONValue {
        let boundary = "awb-" + UUID().uuidString
        var request = authorizedRequest("/api/v1/files")
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let filename = url.lastPathComponent.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mediaType)\r\n\r\n".utf8)
        body.append(try Data(contentsOf: url)); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        try beginRequest()
        defer { endRequest() }
        let (data, _) = try await session.upload(for: request, from: body)
        return try KimiWire.decode(JSONValue.self, from: data)
    }
    public func webSocket() throws -> URLSessionWebSocketTask {
        var request = authorizedRequest("/api/v1/ws")
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.scheme = "ws"; request.url = components.url
        try beginRequest()
        defer { endRequest() }
        let socket = session.webSocketTask(with: request); socket.maximumMessageSize = 16 * 1024 * 1024
        return socket
    }
    public func invalidate() {
        // data(for:) may create its task after suspension; keep the session valid
        // until every caller that started before closure has returned.
        lifecycleLock.lock()
        guard !closed else { lifecycleLock.unlock(); return }
        closed = true
        let hasActiveRequests = activeRequests > 0
        lifecycleLock.unlock()
        if hasActiveRequests {
            session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        } else {
            session.invalidateAndCancel()
        }
    }
    private func beginRequest() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !closed else { throw CancellationError() }
        activeRequests += 1
    }
    private func endRequest() {
        lifecycleLock.lock()
        activeRequests -= 1
        let shouldInvalidate = closed && activeRequests == 0
        lifecycleLock.unlock()
        if shouldInvalidate { session.invalidateAndCancel() }
    }
    private func authorizedRequest(_ path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("AgentWorkbench/0.1", forHTTPHeaderField: "User-Agent")
        return request
    }
    public static func availableLoopbackPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WorkbenchError("无法创建本地连接") }
        defer { close(fd) }
        var addr = sockaddr_in(); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { throw WorkbenchError("无法分配本地端口") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard status == 0 else { throw WorkbenchError("无法读取本地端口") }
        return UInt16(bigEndian: addr.sin_port)
    }
}
