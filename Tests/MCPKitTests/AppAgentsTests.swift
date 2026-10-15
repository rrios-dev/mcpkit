import Foundation
import Testing

@testable import MCPKit

/// The pieces every app shares: consent, the access log, the stale-server check, registration.
@Suite("App agents", .serialized)
struct AppAgentsTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mcpkit-agents-\(UUID().uuidString)")
    }

    @Test("access is off until saved on, and the file is owner-only")
    func access() throws {
        let directory = directory()
        #expect(AgentAccess.load(from: directory).enabled == false)
        try AgentAccess(enabled: true).save(to: directory)
        #expect(AgentAccess.load(from: directory).enabled)
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(AgentAccess.fileName).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(AgentAccess.refusal(app: "Quill", nothingShared: "Until then nothing is shared.")
            == "Quill's agent access is off. The user can turn it on in Quill › Settings › Agents. Until then nothing is shared.")
    }

    @Test("the log keeps clients and tools, newest first, trimmed, owner-only; foreign lines are skipped")
    func log() throws {
        let log = AccessLog(directory: directory())
        try FileManager.default.createDirectory(at: log.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.url.path, contents: Data("{\"tool\":\"old\",\"ok\":\"true\"}\n".utf8),
                                       attributes: [.posixPermissions: 0o600])
        for index in 0..<(AccessLog.keep * 2 + 5) {
            log.append(AccessLog.Entry(date: Date(timeIntervalSince1970: Double(index)), client: "codex", tool: "t\(index)", succeeded: index % 2 == 0))
        }
        #expect(log.recent(2).map(\.tool) == ["t404", "t403"])
        #expect(try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n").count <= AccessLog.keep * 2)
        let mode = try FileManager.default.attributesOfItem(atPath: log.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        log.recorder()(Server.Call(client: "claude-code", tool: "list", succeeded: false))
        #expect(log.recent(1).first.map { [$0.client, $0.tool] } == ["claude-code", "list"])
        log.clear()
        #expect(log.recent().isEmpty)
    }

    @Test("a replaced executable is told apart from an untouched one")
    func replaced() throws {
        let file = directory().appendingPathExtension("bin")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: file)
        let replaced = ExecutableIdentity.replacedSinceLaunch(path: file.path)
        #expect(!replaced())
        // An install writes a new file in its place (a new inode), as the apps' installers do.
        try FileManager.default.removeItem(at: file)
        try Data("two".utf8).write(to: file)
        #expect(replaced())
        #expect(ExecutableIdentity.reconnectMessage(app: "Ámbar", server: "ambar", refused: "will not take changes from it")
            .hasPrefix("Ámbar was updated after this agent connected"))
    }

    @Test("registration commands quote the path and pass the arguments")
    func commands() {
        let path = "/Applications/My App.app/Contents/MacOS/it's-mcp"
        #expect(AgentClient.claudeCode.addCommand(server: "quill", path: path)
            == "claude mcp add --scope user quill -- '/Applications/My App.app/Contents/MacOS/it'\\''s-mcp'")
        #expect(AgentClient.codex.addCommand(server: "tessera", path: "/usr/local/bin/tessera", arguments: ["mcp"])
            == "codex mcp add tessera -- '/usr/local/bin/tessera' 'mcp'")
        #expect(AgentClient.claudeCode.removeCommand(server: "ambar") == "claude mcp remove --scope user ambar")
    }

    @Test("running a command reports done, a missing tool, or the failure")
    func run() async {
        #expect(await AgentClient.claudeCode.run("true") == .done)
        let missing = await AgentClient.claudeCode.run("claude-tool-that-does-not-exist-xyz")
        #expect(missing == .notInstalled)
        #expect(await AgentClient.codex.run("echo first; echo boom; exit 3") == .failed("boom"))
    }
}
