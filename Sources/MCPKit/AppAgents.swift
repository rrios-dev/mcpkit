import Foundation

// What every Mac app that agents can use needs besides the protocol: the user's consent, a
// record of what agents did, telling a stale server from a refused one, and registering the
// server with the agents. Extracted from Quill, Ámbar and Tessera, which had each grown its
// own copy.

/// Whether agents may use the app. Off by default: the user turns it on.
///
/// It is consent and clarity, not a security boundary — any process of the same user can read
/// the app's files anyway — and an app's docs should say so.
public struct AgentAccess: Codable, Equatable, Sendable {
    public var enabled = false

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }

    /// The file inside the app's data directory.
    public static let fileName = "agent-access.json"

    public static func load(from directory: URL) -> AgentAccess {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
              let access = try? JSONDecoder().decode(AgentAccess.self, from: data) else { return AgentAccess() }
        return access
    }

    /// Written owner-only (0600).
    public func save(to directory: URL) throws {
        let url = directory.appendingPathComponent(Self.fileName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// What a server answers while access is off: how to turn it on, and that nothing is shared.
    public static func refusal(app: String, nothingShared: String) -> String {
        "\(app)'s agent access is off. The user can turn it on in \(app) › Settings › Agents. \(nothingShared)"
    }
}

/// Which agent used which tool, and when — never the arguments or the result, which are the
/// user's data. One JSON object per line, owner-only, trimmed to the last `keep` lines.
public struct AccessLog: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var date: Date
        public var client: String?
        public var tool: String
        public var succeeded: Bool

        public init(date: Date, client: String?, tool: String, succeeded: Bool) {
            self.date = date
            self.client = client
            self.tool = tool
            self.succeeded = succeeded
        }
    }

    /// The file inside the app's data directory.
    public static let fileName = "agent-access.log"
    /// Lines kept; the file is trimmed back to this when it grows past twice as many.
    public static let keep = 200

    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName)
    }

    public func append(_ entry: Entry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let line = try? encoder.encode(entry) else { return }
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line + Data([0x0A]))
        trimIfNeeded()
    }

    /// The log for a server: what `Server(onCall:)` takes.
    public func recorder() -> @Sendable (Server.Call) -> Void {
        { call in append(Entry(date: Date(), client: call.client, tool: call.tool, succeeded: call.succeeded)) }
    }

    /// Newest first. Lines in another format are skipped.
    public func recent(_ limit: Int = 20) -> [Entry] {
        Array(entries().reversed().prefix(limit))
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    private func entries() -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
    }

    private func trimIfNeeded() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n")
        guard lines.count > Self.keep * 2 else { return }
        let kept = lines.suffix(Self.keep).joined(separator: "\n") + "\n"
        try? Data(kept.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// The file a process was started from. Updating an app replaces it, and from then on macOS no
/// longer vouches for a server still running the old code: the app's signature check refuses
/// it ("the code on disk does not match what is running"). Comparing tells that case apart from
/// any other refusal, so the agent can be told to reconnect.
public enum ExecutableIdentity {
    /// The executable's inode and modification date; empty if it cannot be read.
    public static func current(path: String? = Bundle.main.executablePath) -> String {
        guard let path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: (path as NSString).resolvingSymlinksInPath) else { return "" }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? ""
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(inode)-\(modified)"
    }

    /// A check taken now that says, later, whether the executable was replaced since.
    public static func replacedSinceLaunch(path: String? = Bundle.main.executablePath) -> @Sendable () -> Bool {
        let launched = current(path: path)
        return { current(path: path) != launched }
    }

    /// What to tell the agent when that happened.
    public static func reconnectMessage(app: String, server: String, refused: String) -> String {
        """
        \(app) was updated after this agent connected, so macOS no longer vouches for this \
        connection and \(app) \(refused) (reading still works). Reconnect the \(server) MCP server — \
        in Claude Code, /mcp and reconnect, or start a new session — and try again.
        """
    }
}

/// The agents an app can register its server with, through their own command-line tools.
public enum AgentClient: String, CaseIterable, Identifiable, Hashable, Sendable {
    case claudeCode, codex

    public var id: Self { self }

    public var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// The client's command-line tool.
    public var executable: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        }
    }

    /// The command that registers `server` (the name the agent sees) at `path`, for the user's
    /// whole account. `arguments` follow the path (Tessera's `mcp`).
    public func addCommand(server: String, path: String, arguments: [String] = []) -> String {
        let tail = ([Self.quoted(path)] + arguments.map(Self.quoted)).joined(separator: " ")
        return switch self {
        case .claudeCode: "claude mcp add --scope user \(server) -- \(tail)"
        case .codex: "codex mcp add \(server) -- \(tail)"
        }
    }

    public func removeCommand(server: String) -> String {
        switch self {
        case .claudeCode: "claude mcp remove --scope user \(server)"
        case .codex: "codex mcp remove \(server)"
        }
    }

    /// Single-quoted for zsh, so a path with spaces or quotes stays one argument.
    public static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What running a client's command came to.
    public enum Outcome: Equatable, Sendable {
        case done
        /// The client's tool is not installed, or not on the user's PATH.
        case notInstalled
        /// It ran and failed: its last line of output.
        case failed(String)
    }

    /// Runs `command` in a login shell, so the user's PATH applies (an app started from the
    /// Finder does not inherit it).
    public func run(_ command: String) async -> Outcome {
        let executable = executable
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return .failed("\(error)")
            }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            if process.terminationStatus == 0 { return .done }
            if output.contains("command not found") || output.contains("not found: \(executable)") { return .notInstalled }
            return .failed(output.split(separator: "\n").last.map(String.init) ?? "")
        }.value
    }

    /// Registers the server, replacing a previous registration (connecting again after the app
    /// moved fixes the path).
    public func connect(server: String, path: String, arguments: [String] = []) async -> Outcome {
        _ = await run(removeCommand(server: server))
        return await run(addCommand(server: server, path: path, arguments: arguments))
    }

    public func disconnect(server: String) async -> Outcome {
        await run(removeCommand(server: server))
    }
}
