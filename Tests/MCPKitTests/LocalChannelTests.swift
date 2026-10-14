import Foundation
import Testing

@testable import MCPKit

/// The app's side channel: one request, one reply, same user only.
@Suite("Local channel", .serialized)
struct LocalChannelTests {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lc-\(UInt32.random(in: 0...UInt32.max))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a request gets the handler's reply, and the socket is private")
    func roundTrip() async throws {
        let path = LocalChannel.path(named: "test", in: try directory())
        let listener = try LocalChannel.Listener(path: path) { request in
            Data("got: ".utf8) + request
        }
        defer { listener.stop() }
        let reply = try await LocalChannel.send(Data(#"{"say":"hola"}"#.utf8), to: path, timeout: .seconds(5))
        #expect(String(decoding: reply, as: UTF8.self) == #"got: {"say":"hola"}"#)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test("several requests at once are all answered")
    func concurrent() async throws {
        let path = LocalChannel.path(named: "test", in: try directory())
        let listener = try LocalChannel.Listener(path: path) { request in
            try? await Task.sleep(for: .milliseconds(100))
            return request
        }
        defer { listener.stop() }
        let replies = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<6 {
                group.addTask {
                    String(decoding: try await LocalChannel.send(Data("\(index)".utf8), to: path, timeout: .seconds(5)), as: UTF8.self)
                }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(replies == Set((0..<6).map(String.init)))
    }

    @Test("nothing listening reads as the app not running; a stale socket is replaced")
    func notRunning() async throws {
        let path = LocalChannel.path(named: "test", in: try directory())
        await #expect(throws: LocalChannel.Failure.notRunning) {
            try await LocalChannel.send(Data("x".utf8), to: path, timeout: .seconds(1))
        }
        let first = try LocalChannel.Listener(path: path) { _ in Data("first".utf8) }
        first.stop()
        FileManager.default.createFile(atPath: path, contents: Data())
        let second = try LocalChannel.Listener(path: path) { _ in Data("second".utf8) }
        defer { second.stop() }
        #expect(try await LocalChannel.send(Data("x".utf8), to: path, timeout: .seconds(5)) == Data("second".utf8))
    }

    @Test("a long directory falls back to a short path")
    func shortPath() {
        let long = URL(fileURLWithPath: "/" + String(repeating: "d", count: 120))
        #expect(LocalChannel.path(named: "quill", in: long).hasSuffix("quill-\(getuid()).sock"))
    }
}
