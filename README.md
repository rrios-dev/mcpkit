# MCPKit

A small [Model Context Protocol](https://modelcontextprotocol.io) server for Swift
apps, over stdio, on Foundation alone. It is what lets Quill, Ámbar and Tessera be
used from Claude Code, Codex or any other MCP client.

It covers what a local app needs and no more: the lifecycle (`initialize`, `ping`),
tools (`tools/list`, `tools/call`) with annotations, text and image results,
cancellation, and requests served concurrently so a slow tool does not block the rest.

```swift
import MCPKit

let server = Server(
    info: Server.Info(name: "notes", version: "1.0"),
    tools: [
        Tool(name: "search_notes", description: "Finds notes containing the words.",
             inputSchema: Schema.object(["query": Schema.string("Words to find.")], required: ["query"])) { arguments in
            .text(try search(arguments.string("query")))
        },
    ],
    gate: { accessEnabled ? nil : "Turn on agent access in Notes › Settings." },
    onCall: { call in log("\(call.client ?? "?") used \(call.tool)") }
)
await server.run()
```

Register the built executable with a client:

```bash
claude mcp add --scope user notes -- /Applications/Notes.app/Contents/MacOS/notes-mcp
```

```bash
codex mcp add notes -- /Applications/Notes.app/Contents/MacOS/notes-mcp
```

- **Errors the model can fix** (a missing argument, a tool that fails) come back as
  results with `isError: true`; only protocol mistakes are JSON-RPC errors.
- **`gate`** refuses every call with a message while the app's agent access is off.
- **`onCall`** reports which client ran which tool, never the arguments or results, for
  an access log the user can see.
- stdout carries only protocol; log to stderr.
- **`LocalChannel`** lets the MCP executable ask the running app for what only the app
  can do (it holds the credentials or the windows): one JSON line each way over a 0600
  Unix socket, accepted only from the same user and, for a signed app, only from code
  signed by the same team.

## For apps

Beyond the protocol, what every Mac app that agents can use needs:

- **`AgentAccess`** — the user's consent, off by default, in `agent-access.json` (0600), and the
  message a server answers with while it is off.
- **`AccessLog`** — which agent used which tool and when, never the arguments, in
  `agent-access.log` (0600, trimmed); `recorder()` plugs into `Server(onCall:)`.
- **`ExecutableIdentity`** — whether the app was updated since this server started. macOS then
  stops vouching for the old process and the app's signature check refuses it; telling that
  apart lets the agent be told to reconnect.
- **`AgentClient`** — registering the server with Claude Code or Codex through their own
  command-line tools, in a login shell so the user's PATH applies.

`swift test` runs the protocol tests and an end-to-end session against the bundled
`mcpkit-example` server. MIT licence.
