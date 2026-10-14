import Foundation
import MCPKit

// The smallest working server, and the one the end-to-end tests drive:
//   claude mcp add example -- "$(swift build --show-bin-path)/mcpkit-example"

let server = Server(
    info: Server.Info(name: "mcpkit-example", version: "0.1.0", instructions: "Example tools for testing MCPKit."),
    tools: [
        Tool(
            name: "echo",
            description: "Returns the text it is given.",
            inputSchema: Schema.object(["text": Schema.string("What to echo.")], required: ["text"])
        ) { arguments in
            .text(try arguments.string("text"))
        },
        Tool(
            name: "wait",
            description: "Waits the given milliseconds, then answers. For cancellation tests.",
            inputSchema: Schema.object(["ms": Schema.integer("How long to wait.", minimum: 0, maximum: 60_000)], required: ["ms"])
        ) { arguments in
            let ms = try arguments.optionalInt("ms", in: 0...60_000) ?? 0
            try await Task.sleep(for: .milliseconds(ms))
            return .text("waited \(ms) ms")
        },
        Tool(
            name: "pixel",
            description: "Returns a one-pixel PNG.",
            annotations: .readOnly
        ) { _ in
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
            return ToolResult(content: [.image(png, mimeType: "image/png")])
        },
    ]
)
await server.run()
