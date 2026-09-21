import Darwin
import Foundation

/// Newline-delimited JSON over Herdr's forwarded Unix socket. Blocking I/O
/// runs off the main thread; the timeout also bounds a silent broken tunnel.
public enum JSONSocket {
    public static func request(path: String, method: String, params: [String: Any] = [:]) throws -> Data {
        let fd = try connect(path: path)
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 8, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var packet = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "method": method, "params": params])
        packet.append(10)
        try packet.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard n > 0 else { throw failure("发送请求") }
                offset += n
            }
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { throw failure("读取 Herdr 响应") }
            if let newline = buffer[..<count].firstIndex(of: 10) {
                result.append(contentsOf: buffer[..<newline])
                return result
            }
            result.append(contentsOf: buffer[..<count])
            guard result.count < 16 * 1024 * 1024 else { throw WorkbenchError("Herdr 响应超过 16 MB") }
        }
    }

    private static func connect(path: String) throws -> Int32 {
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw WorkbenchError("本地 socket 路径过长")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            _ = path.withCString { strlcpy(target.baseAddress!.assumingMemoryBound(to: CChar.self), $0, target.count) }
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure("创建 socket") }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let code = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard code == 0 else {
            let error = failure("连接 Herdr")
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    private static func failure(_ action: String) -> WorkbenchError {
        WorkbenchError("\(action)：\(String(cString: strerror(errno)))")
    }
}
