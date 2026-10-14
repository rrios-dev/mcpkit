import Foundation
import Testing

@testable import MCPKit

/// The protocol, one message at a time (`Server.handle`).
@Suite("Server")
struct ServerTests {
    private func server(
        gate: @escaping @Sendable () -> String? = { nil },
        onCall: @escaping @Sendable (Server.Call) -> Void = { _ in }
    ) -> Server {
        Server(
            info: Server.Info(name: "test", title: "Test", version: "1.0", instructions: "Use them well."),
            tools: [
                Tool(name: "echo", description: "Echo.", inputSchema: Schema.object(["text": Schema.string("Text.")], required: ["text"])) {
                    .text(try $0.string("text"))
                },
                Tool(name: "boom", description: "Fails.", annotations: .action) { _ in
                    struct Boom: LocalizedError { var errorDescription: String? { "the disk is on fire" } }
                    throw Boom()
                },
                Tool(name: "slow", description: "Slow.") { _ in
                    try await Task.sleep(for: .seconds(10))
                    return .text("done")
                },
            ],
            gate: gate,
            onCall: onCall
        )
    }

    private func reply(_ server: Server, _ line: String) async throws -> JSONValue {
        let text = try #require(await server.handle(line))
        #expect(!text.contains("\n"), "a message must be one line")
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test("initialize echoes a known protocol version and describes the server")
    func initialize() async throws {
        let answer = try await reply(server(), #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2"}}}"#)
        #expect(answer["id"] == 1)
        #expect(answer["result"]?["protocolVersion"] == "2025-06-18")
        #expect(answer["result"]?["serverInfo"]?["name"] == "test")
        #expect(answer["result"]?["capabilities"]?["tools"] != nil)
        #expect(answer["result"]?["instructions"] == "Use them well.")
    }

    @Test("an unknown protocol version gets the newest one")
    func unknownVersion() async throws {
        let answer = try await reply(server(), #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        #expect(answer["id"] == "a")
        #expect(answer["result"]?["protocolVersion"] == .string(Server.protocolVersions[0]))
    }

    @Test("tools are listed in order, with schema and annotations")
    func list() async throws {
        let answer = try await reply(server(), #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try #require(answer["result"]?["tools"]?.arrayValue)
        #expect(tools.map { $0["name"] } == ["echo", "boom", "slow"])
        #expect(tools[0]["inputSchema"]?["required"] == ["text"])
        #expect(tools[0]["annotations"]?["readOnlyHint"] == true)
        #expect(tools[1]["annotations"]?["readOnlyHint"] == false)
    }

    @Test("a call returns its content")
    func call() async throws {
        let answer = try await reply(server(), #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hola"}}}"#)
        #expect(answer["result"]?["isError"] == false)
        #expect(answer["result"]?["content"]?.arrayValue?.first?["text"] == "hola")
    }

    @Test("bad arguments and failing tools are results the model can read, not protocol errors")
    func toolErrors() async throws {
        let missing = try await reply(server(), #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#)
        #expect(missing["result"]?["isError"] == true)
        #expect(missing["result"]?["content"]?.arrayValue?.first?["text"] == "`text` is required")
        let wrongType = try await reply(server(), #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"echo","arguments":{"text":3}}}"#)
        #expect(wrongType["result"]?["content"]?.arrayValue?.first?["text"] == "`text` must be a string")
        let thrown = try await reply(server(), #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"boom"}}"#)
        #expect(thrown["result"]?["isError"] == true)
        #expect(thrown["result"]?["content"]?.arrayValue?.first?["text"] == "boom failed: the disk is on fire")
    }

    @Test("protocol mistakes get JSON-RPC errors")
    func protocolErrors() async throws {
        let server = server()
        #expect(try await reply(server, "{not json")["error"]?["code"] == -32700)
        #expect(try await reply(server, #"{"id":1,"method":"ping"}"#)["error"]?["code"] == -32600)
        #expect(try await reply(server, #"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#)["error"]?["code"] == -32601)
        #expect(try await reply(server, #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"nope"}}"#)["error"]?["code"] == -32602)
    }

    @Test("ping answers, notifications and client responses get no reply")
    func quiet() async throws {
        let server = server()
        #expect(try await reply(server, #"{"jsonrpc":"2.0","id":9,"method":"ping"}"#)["result"] == [:])
        #expect(await server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(await server.handle(#"{"jsonrpc":"2.0","id":10,"result":{}}"#) == nil)
    }

    @Test("a cancelled call stops and sends nothing")
    func cancel() async throws {
        let server = server()
        async let answer = server.handle(#"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"slow"}}"#)
        try await Task.sleep(for: .milliseconds(100))
        let clock = ContinuousClock.now
        #expect(await server.handle(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":11}}"#) == nil)
        #expect(await answer == nil)
        #expect(ContinuousClock.now - clock < .seconds(2))
    }

    @Test("a closed gate refuses every call with its message")
    func gate() async throws {
        let answer = try await reply(server(gate: { "Turn on agent access in Settings." }), #"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"echo","arguments":{"text":"x"}}}"#)
        #expect(answer["result"]?["isError"] == true)
        #expect(answer["result"]?["content"]?.arrayValue?.first?["text"] == "Turn on agent access in Settings.")
    }

    @Test("every call is reported with the client's name, never its content")
    func accessLog() async throws {
        let calls = Calls()
        let server = server(onCall: { calls.append($0) })
        _ = await server.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"codex"}}}"#)
        _ = await server.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"secret"}}}"#)
        _ = await server.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"boom"}}"#)
        #expect(calls.all == [
            Server.Call(client: "codex", tool: "echo", succeeded: true),
            Server.Call(client: "codex", tool: "boom", succeeded: false),
        ])
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Server.Call] = []
    func append(_ call: Server.Call) { lock.withLock { calls.append(call) } }
    var all: [Server.Call] { lock.withLock { calls } }
}
