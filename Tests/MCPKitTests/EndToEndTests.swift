import Foundation
import Testing

@testable import MCPKit

/// The built example server as a separate process, spoken to over its stdin and stdout
/// the way Claude Code and Codex do.
@Suite("End to end", .serialized)
struct EndToEndTests {
    /// `swift build` puts the example next to the test bundle.
    private static var example: URL? {
        let products = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent()
        let url = products.appendingPathComponent("mcpkit-example")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    @Test("a session: initialize, list, call, image, cancel, close", .enabled(if: example != nil))
    func session() async throws {
        let process = Process()
        process.executableURL = try #require(Self.example)
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let lines = Lines(stdout.fileHandleForReading)

        func send(_ line: String) throws {
            try stdin.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
        }

        try send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        #expect(try await lines.next()["result"]?["serverInfo"]?["name"] == "mcpkit-example")
        try send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)

        try send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        #expect(try await lines.next()["result"]?["tools"]?.arrayValue?.map { $0["name"] } == ["echo", "wait", "pixel"])

        // A slow call, then a fast one: the fast answer arrives first.
        try send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"wait","arguments":{"ms":400}}}"#)
        try send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{"text":"línea con \"comillas\"\ny salto"}}}"#)
        let fast = try await lines.next()
        #expect(fast["id"] == 4)
        #expect(fast["result"]?["content"]?.arrayValue?.first?["text"] == "línea con \"comillas\"\ny salto")
        #expect(try await lines.next()["id"] == 3)

        try send(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"pixel"}}"#)
        let image = try await lines.next()["result"]?["content"]?.arrayValue?.first
        #expect(image?["type"] == "image")
        #expect(image?["mimeType"] == "image/png")

        // Cancelled: no answer for 6; the next request still works.
        try send(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"wait","arguments":{"ms":30000}}}"#)
        try send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":6}}"#)
        try send(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#)
        #expect(try await lines.next()["id"] == 7)

        try stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!process.isRunning, "the server exits when stdin closes")
        if process.isRunning { process.terminate() }
    }
}

private final class Marker {}

/// Lines from the server's stdout, decoded, with a timeout so a hang fails the test
/// instead of stalling the run.
private actor Lines {
    private var buffer: [String] = []

    init(_ handle: FileHandle) {
        let stream = AsyncStream<String> { continuation in
            Task {
                do {
                    for try await line in handle.bytes.lines { continuation.yield(line) }
                } catch {}
                continuation.finish()
            }
        }
        Task { await self.consume(stream) }
    }

    private func consume(_ stream: AsyncStream<String>) async {
        for await line in stream { buffer.append(line) }
    }

    func next() async throws -> JSONValue {
        let deadline = ContinuousClock.now + .seconds(5)
        while buffer.isEmpty {
            guard ContinuousClock.now < deadline else { throw TimedOut() }
            try await Task.sleep(for: .milliseconds(10))
        }
        let line = buffer.removeFirst()
        return try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    }

    struct TimedOut: Error {}
}
