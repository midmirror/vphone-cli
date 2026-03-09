import Foundation

/// Local Unix domain socket server that bridges external tools to a running VM.
///
/// Listens at `{vmDir}/.vphone.sock` using the same length-prefixed JSON
/// framing as the vsock protocol (`[uint32 big-endian length][UTF-8 JSON]`).
///
/// Supported commands:
/// ```json
/// {"t": "ipa_install", "path": "/abs/path/to/app.ipa"}
/// ```
///
/// Responses:
/// ```json
/// {"ok": true,  "msg":   "..."}
/// {"ok": false, "error": "..."}
/// ```
@MainActor
class VPhoneLocalControlServer {
    let socketPath: String
    private weak var control: VPhoneControl?
    private var serverFD: Int32 = -1

    init(vmDir: String, control: VPhoneControl) {
        let dir = vmDir.isEmpty ? "." : vmDir
        socketPath = URL(fileURLWithPath: dir)
            .appendingPathComponent(".vphone.sock").path
        self.control = control
    }

    // MARK: - Lifecycle

    func start() {
        // Remove stale socket left by a previous (possibly crashed) run.
        try? FileManager.default.removeItem(atPath: socketPath)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("[local-ctrl] socket() failed: errno \(errno)")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cStr in
                _ = strncpy(
                    UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                    cStr,
                    sunPathSize - 1
                )
            }
        }

        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sPtr in
                Darwin.bind(fd, sPtr, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bindOK else {
            print("[local-ctrl] bind() failed: errno \(errno) path=\(socketPath)")
            Darwin.close(fd)
            return
        }

        guard Darwin.listen(fd, 5) == 0 else {
            print("[local-ctrl] listen() failed: errno \(errno)")
            Darwin.close(fd)
            return
        }

        serverFD = fd
        print("[local-ctrl] listening at \(socketPath)")
        startAcceptLoop(serverFD: fd)
    }

    func stop() {
        if serverFD >= 0 {
            Darwin.close(serverFD)
            serverFD = -1
        }
        try? FileManager.default.removeItem(atPath: socketPath)
        print("[local-ctrl] stopped")
    }

    // MARK: - Accept Loop

    private func startAcceptLoop(serverFD: Int32) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                let clientFD = Darwin.accept(serverFD, nil, nil)
                guard clientFD >= 0 else { break }
                // Dispatch each client to its own background slot.
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    Self.serveClient(fd: clientFD, server: self)
                }
            }
        }
    }

    // MARK: - Client Handler

    private nonisolated static func serveClient(fd: Int32, server: VPhoneLocalControlServer?) {
        guard let msg = readMessage(fd: fd),
              let type = msg["t"] as? String
        else {
            Darwin.close(fd)
            return
        }

        switch type {
        case "ipa_install":
            guard let path = msg["path"] as? String, !path.isEmpty else {
                writeResponse(fd: fd, ok: false, message: "missing or empty 'path'")
                Darwin.close(fd)
                return
            }
            // Hand off to main actor which owns VPhoneControl. The Task closes fd when done.
            Task { @MainActor [server] in
                defer { Darwin.close(fd) }
                guard let control = server?.control else {
                    Self.writeResponse(fd: fd, ok: false, message: "server unavailable")
                    return
                }
                guard control.isConnected else {
                    Self.writeResponse(fd: fd, ok: false, message: "guest not connected")
                    return
                }
                do {
                    let result = try await control.installIPA(localURL: URL(fileURLWithPath: path))
                    Self.writeResponse(fd: fd, ok: true, message: result)
                } catch {
                    Self.writeResponse(fd: fd, ok: false, message: "\(error)")
                }
            }

        default:
            writeResponse(fd: fd, ok: false, message: "unknown command: \(type)")
            Darwin.close(fd)
        }
    }

    // MARK: - Framing (mirrors VPhoneControl framing helpers)

    private nonisolated static func readMessage(fd: Int32) -> [String: Any]? {
        var header: UInt32 = 0
        guard withUnsafeMutableBytes(of: &header, {
            readFully(fd: fd, buf: $0.baseAddress!, count: 4)
        }) else { return nil }

        let length = Int(UInt32(bigEndian: header))
        guard length > 0, length < 4 * 1024 * 1024 else { return nil }

        let payload = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        defer { payload.deallocate() }
        guard readFully(fd: fd, buf: payload, count: length) else { return nil }

        return try? JSONSerialization.jsonObject(with: Data(bytes: payload, count: length))
            as? [String: Any]
    }

    private nonisolated static func writeResponse(fd: Int32, ok: Bool, message: String) {
        let dict: [String: Any] = ok
            ? ["ok": true, "msg": message]
            : ["ok": false, "error": message]
        guard let json = try? JSONSerialization.data(withJSONObject: dict) else { return }
        var header = UInt32(json.count).bigEndian
        withUnsafeBytes(of: &header) { _ = writeFully(fd: fd, buf: $0.baseAddress!, count: 4) }
        json.withUnsafeBytes { _ = writeFully(fd: fd, buf: $0.baseAddress!, count: json.count) }
    }

    private nonisolated static func readFully(fd: Int32, buf: UnsafeMutableRawPointer, count: Int)
        -> Bool
    {
        var offset = 0
        while offset < count {
            let n = Darwin.read(fd, buf + offset, count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    private nonisolated static func writeFully(fd: Int32, buf: UnsafeRawPointer, count: Int)
        -> Bool
    {
        var offset = 0
        while offset < count {
            let n = Darwin.write(fd, buf + offset, count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}
