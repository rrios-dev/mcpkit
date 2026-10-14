import Foundation

/// An MCP server over stdio: one JSON-RPC message per line on stdin, one per line on
/// stdout. stderr is free for logs; stdout carries nothing but protocol.
///
/// Requests run concurrently, so a slow tool does not hold up `ping` or a cancellation.
public final class Server: Sendable {
    public struct Info: Sendable {
        public var name: String
        public var title: String?
        public var version: String
        /// Read by the client and usually shown to the model: how to use these tools.
        public var instructions: String?

        public init(name: String, title: String? = nil, version: String, instructions: String? = nil) {
            self.name = name
            self.title = title
            self.version = version
            self.instructions = instructions
        }
    }

    /// A call that ran, for the app's access log: which client, which tool, whether it
    /// worked. Never the arguments or the result — those are the user's data.
    public struct Call: Sendable, Equatable {
        public var client: String?
        public var tool: String
        public var succeeded: Bool
    }

    /// Protocol revisions this server speaks, newest first. A client asking for one of
    /// them gets it back; any other request gets the newest, and the client decides.
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public let info: Info
    private let tools: [String: Tool]
    private let order: [String]
    private let gate: @Sendable () -> String?
    private let onCall: @Sendable (Call) -> Void
    private let state = State()

    /// - Parameters:
    ///   - gate: checked before every tool call; a non-nil message refuses the call
    ///     with it (an app whose agent access is switched off says how to turn it on).
    ///   - onCall: told about every call that ran (see `Call`).
    public init(
        info: Info,
        tools: [Tool],
        gate: @escaping @Sendable () -> String? = { nil },
        onCall: @escaping @Sendable (Call) -> Void = { _ in }
    ) {
        self.info = info
        self.tools = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.order = tools.map(\.name)
        self.gate = gate
        self.onCall = onCall
    }

    // MARK: Running

    /// Serves until stdin closes.
    public func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) async {
        let writer = Writer(output)
        await withTaskGroup(of: Void.self) { group in
            do {
                for try await line in input.bytes.lines {
                    let line = line.trimmingCharacters(in: .whitespaces)
                    guard !line.isEmpty else { continue }
                    group.addTask {
                        if let reply = await self.handle(line) {
                            await writer.write(reply)
                        }
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("mcp: stdin failed: \(error)\n".utf8))
            }
            await state.cancelAll()
            group.cancelAll()
        }
    }

    // MARK: Messages

    /// One incoming line, one reply line (nil for notifications and cancelled requests).
    public func handle(_ line: String) async -> String? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return encode(.failure(id: .null, code: -32700, message: "Parse error"))
        }
        guard case .object(let object) = message, object["jsonrpc"] == "2.0",
              let method = object["method"]?.stringValue else {
            // A response from the client (we send no requests) or something malformed.
            if case .object(let object) = message, object["method"] == nil, object["id"] != nil { return nil }
            return encode(.failure(id: message["id"] ?? .null, code: -32600, message: "Invalid request"))
        }
        let params = object["params"]?.objectValue ?? [:]
        guard let id = object["id"], id != .null else {
            await notification(method, params)
            return nil
        }
        let reply = await request(id: id, method: method, params: params)
        if await state.finish(id) { return nil }
        return encode(reply)
    }

    private func notification(_ method: String, _ params: [String: JSONValue]) async {
        if method == "notifications/cancelled", let id = params["requestId"] {
            await state.cancel(id)
        }
    }

    private func request(id: JSONValue, method: String, params: [String: JSONValue]) async -> Reply {
        switch method {
        case "initialize":
            return .success(id: id, result: await initialize(params))
        case "ping":
            return .success(id: id, result: [:])
        case "tools/list":
            return .success(id: id, result: ["tools": .array(order.compactMap { tools[$0]?.listing })])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return .failure(id: id, code: -32602, message: "tools/call needs a tool name")
            }
            guard let tool = tools[name] else {
                return .failure(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            let arguments = Arguments(params["arguments"]?.objectValue ?? [:])
            return .success(id: id, result: await call(tool, arguments, id: id).json)
        default:
            return .failure(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func initialize(_ params: [String: JSONValue]) async -> JSONValue {
        let asked = params["protocolVersion"]?.stringValue
        let version = asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
        let client = params["clientInfo"]?["name"]?.stringValue
        await state.setClient(client)
        var serverInfo: [String: JSONValue] = ["name": .string(info.name), "version": .string(info.version)]
        if let title = info.title { serverInfo["title"] = .string(title) }
        var result: [String: JSONValue] = [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": .object(serverInfo),
        ]
        if let instructions = info.instructions { result["instructions"] = .string(instructions) }
        return .object(result)
    }

    private func call(_ tool: Tool, _ arguments: Arguments, id: JSONValue) async -> ToolResult {
        let client = await state.client
        if let refusal = gate() {
            onCall(Call(client: client, tool: tool.name, succeeded: false))
            return .error(refusal)
        }
        let task = Task { () -> ToolResult in
            do {
                return try await tool.run(arguments)
            } catch let error as ToolError {
                return .error(error.message)
            } catch is CancellationError {
                return .error("Cancelled")
            } catch {
                return .error("\(tool.name) failed: \(error.localizedDescription)")
            }
        }
        await state.start(id, task)
        let result = await task.value
        onCall(Call(client: client, tool: tool.name, succeeded: !result.isError))
        return result
    }

    // MARK: Encoding

    enum Reply {
        case success(id: JSONValue, result: JSONValue)
        case failure(id: JSONValue, code: Int, message: String)
    }

    private func encode(_ reply: Reply) -> String {
        let message: JSONValue = switch reply {
        case .success(let id, let result):
            ["jsonrpc": "2.0", "id": id, "result": result]
        case .failure(let id, let code, let message):
            ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        // Not pretty-printed: a message must fit on one line.
        let data = (try? encoder.encode(message)) ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// The calls in flight and the client's name, behind an actor.
private actor State {
    private(set) var client: String?
    private var running: [JSONValue: Task<ToolResult, Never>] = [:]
    private var cancelled: Set<JSONValue> = []

    func setClient(_ name: String?) { client = name }

    func start(_ id: JSONValue, _ task: Task<ToolResult, Never>) {
        if cancelled.contains(id) { task.cancel() }
        running[id] = task
    }

    func cancel(_ id: JSONValue) {
        cancelled.insert(id)
        running[id]?.cancel()
    }

    /// Forgets the request; true when it was cancelled, so no reply is sent.
    func finish(_ id: JSONValue) -> Bool {
        running[id] = nil
        return cancelled.remove(id) != nil
    }

    func cancelAll() {
        running.values.forEach { $0.cancel() }
    }
}

/// Writes whole lines to stdout, one at a time.
private actor Writer {
    private let handle: FileHandle
    private var broken = false

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func write(_ line: String) {
        guard !broken else { return }
        do {
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            broken = true
        }
    }
}
