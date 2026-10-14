import Darwin
import Foundation
import Security

/// One request, one reply, over a Unix domain socket: how an app's MCP executable asks
/// the running app to do what only the app can (it holds the credentials, the windows,
/// the state). Newline-delimited JSON, mode 0600.
///
/// Who may connect: processes of the same user, and — when the app is signed by a
/// team — only code signed by that same team, checked on the peer's audit token (a pid
/// can be reused; an audit token cannot). An ad hoc development build trusts every
/// process of its user, as it has no team to compare with.
public enum LocalChannel {
    /// Longest request or reply accepted.
    public static let maxLine = 4 * 1024 * 1024

    /// A socket path for `name` inside `directory`, or a short one in the user's
    /// temporary directory when that would not fit in `sun_path` (104 bytes).
    public static func path(named name: String, in directory: URL) -> String {
        let inside = directory.appendingPathComponent(name + ".sock").path
        if inside.utf8.count < 100 { return inside }
        let temporary = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp/"
        return (temporary.hasSuffix("/") ? temporary : temporary + "/") + "\(name)-\(getuid()).sock"
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// Nothing listens: the app is not running.
        case notRunning
        case tooLong
        case noReply
        case io(Int32)

        public var description: String {
            switch self {
            case .notRunning: "the app is not running"
            case .tooLong: "the message is too long"
            case .noReply: "the app did not answer"
            case .io(let code): "socket error \(code)"
            }
        }
    }

    // MARK: Client

    /// Sends `request` and waits up to `timeout` for the reply.
    public static func send(_ request: Data, to path: String, timeout: Duration = .seconds(300)) async throws -> Data {
        try await Task.detached {
            let descriptor = try connect(path)
            defer { close(descriptor) }
            let seconds = Int(timeout.components.seconds)
            var tv = timeval(tv_sec: max(1, seconds), tv_usec: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            guard request.count < maxLine else { throw Failure.tooLong }
            guard writeAll(descriptor, request + Data([0x0A])) else { throw Failure.io(errno) }
            guard let reply = readLine(descriptor) else { throw Failure.noReply }
            return reply
        }.value
    }

    // MARK: Server

    /// A listening socket. Each connection carries one request; `handle` answers it.
    public final class Listener: @unchecked Sendable {
        public let path: String
        private let descriptor: Int32
        private let handle: @Sendable (Data) async -> Data
        private let team: String?
        private let lock = NSLock()
        private var stopped = false

        /// Binds `path` (replacing a stale socket left by a crash) and starts serving.
        public init(path: String, handle: @escaping @Sendable (Data) async -> Data) throws {
            self.path = path
            self.handle = handle
            self.team = LocalChannel.ownTeam
            unlink(path)
            descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw Failure.io(errno) }
            var address = try makeAddress(path)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else {
                let code = errno
                close(descriptor)
                throw Failure.io(code)
            }
            chmod(path, 0o600)
            guard listen(descriptor, 8) == 0 else {
                let code = errno
                close(descriptor)
                throw Failure.io(code)
            }
            let thread = Thread { [weak self] in self?.acceptLoop() }
            thread.name = "LocalChannel"
            thread.start()
        }

        deinit { stop() }

        public func stop() {
            let wasStopped = lock.withLock {
                defer { stopped = true }
                return stopped
            }
            guard !wasStopped else { return }
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
            unlink(path)
        }

        private var isStopped: Bool { lock.withLock { stopped } }

        private func acceptLoop() {
            while !isStopped {
                let client = accept(descriptor, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                noSignalOnBrokenPipe(client)
                guard LocalChannel.isTrusted(client, team: team) else {
                    close(client)
                    continue
                }
                var tv = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                let handle = self.handle
                Task.detached {
                    defer { close(client) }
                    guard let request = readLine(client) else { return }
                    let reply = await handle(request)
                    _ = writeAll(client, reply + Data([0x0A]))
                }
            }
        }
    }

    // MARK: Trust

    /// The team that signed this process; nil for an ad hoc build.
    public static let ownTeam: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    static func isTrusted(_ descriptor: Int32, team: String?) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0, uid == getuid() else { return false }
        guard let team else { return true }
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let auditToken = withUnsafeBytes(of: &token) { Data($0) }
        var guest: SecCode?
        let attributes = [kSecGuestAttributeAudit: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }

    // MARK: Plumbing

    static func connect(_ path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.io(errno) }
        noSignalOnBrokenPipe(descriptor)
        var address = try makeAddress(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            throw Failure.notRunning
        }
        return descriptor
    }

    static func readLine(_ descriptor: Int32) -> Data? {
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            if let newline = received.firstIndex(of: 0x0A) { return received[..<newline] }
            guard received.count < maxLine else { return nil }
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return received.isEmpty ? nil : received }
            received.append(contentsOf: buffer[0..<count])
        }
    }

    static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    static func noSignalOnBrokenPipe(_ descriptor: Int32) {
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func makeAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.tooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
        return address
    }
}
