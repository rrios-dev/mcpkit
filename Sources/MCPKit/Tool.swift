import Foundation

/// A tool the server offers: what the client lists, and the code that runs it.
public struct Tool: Sendable {
    public var name: String
    public var title: String?
    public var description: String
    /// A JSON Schema object describing the arguments (see `Schema`).
    public var inputSchema: JSONValue
    public var annotations: Annotations
    public var run: @Sendable (Arguments) async throws -> ToolResult

    public init(
        name: String,
        title: String? = nil,
        description: String,
        inputSchema: JSONValue = Schema.object(),
        annotations: Annotations = .readOnly,
        run: @escaping @Sendable (Arguments) async throws -> ToolResult
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.run = run
    }

    /// Hints the client uses to decide whether to ask the user before a call. They are
    /// hints, not guarantees: a client may ignore them, so a tool still checks its own
    /// preconditions.
    public struct Annotations: Sendable, Equatable {
        public var readOnly: Bool
        public var destructive: Bool
        public var idempotent: Bool
        /// The tool reaches beyond the local machine (a model provider, the web).
        public var openWorld: Bool

        public init(readOnly: Bool, destructive: Bool = false, idempotent: Bool = false, openWorld: Bool = false) {
            self.readOnly = readOnly
            self.destructive = destructive
            self.idempotent = idempotent
            self.openWorld = openWorld
        }

        /// Reads local data and changes nothing.
        public static let readOnly = Annotations(readOnly: true, idempotent: true)
        /// Changes something, nothing is lost.
        public static let action = Annotations(readOnly: false)

        var json: JSONValue {
            [
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
                "idempotentHint": .bool(idempotent),
                "openWorldHint": .bool(openWorld),
            ]
        }
    }

    var listing: JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": annotations.json,
        ]
        if let title { object["title"] = .string(title) }
        return .object(object)
    }
}

/// The arguments of one call, with typed reads that fail with a message the model can
/// act on ("`limit` must be an integer") instead of a protocol error.
public struct Arguments: Sendable {
    public let values: [String: JSONValue]

    public init(_ values: [String: JSONValue] = [:]) {
        self.values = values
    }

    /// The value, with an explicit JSON `null` read as absent. (Spelled out: a bare `nil`
    /// here would become `JSONValue.null`, which is `ExpressibleByNilLiteral`.)
    public subscript(key: String) -> JSONValue? {
        guard let value = values[key], value != JSONValue.null else { return Optional<JSONValue>.none }
        return value
    }

    public func string(_ key: String) throws -> String {
        guard let value = self[key] else { throw ToolError.missing(key) }
        guard let string = value.stringValue else { throw ToolError.invalid(key, "must be a string") }
        return string
    }

    public func optionalString(_ key: String) throws -> String? {
        guard self[key] != nil else { return nil }
        return try string(key)
    }

    public func optionalInt(_ key: String, in range: ClosedRange<Int>? = nil) throws -> Int? {
        guard let value = self[key] else { return nil }
        guard let int = value.intValue else { throw ToolError.invalid(key, "must be an integer") }
        if let range, !range.contains(int) {
            throw ToolError.invalid(key, "must be between \(range.lowerBound) and \(range.upperBound)")
        }
        return int
    }

    public func optionalBool(_ key: String) throws -> Bool? {
        guard let value = self[key] else { return nil }
        guard let bool = value.boolValue else { throw ToolError.invalid(key, "must be true or false") }
        return bool
    }

    public func optionalStrings(_ key: String) throws -> [String]? {
        guard let value = self[key] else { return nil }
        guard let array = value.arrayValue else { throw ToolError.invalid(key, "must be an array of strings") }
        return try array.map { element in
            guard let string = element.stringValue else { throw ToolError.invalid(key, "must be an array of strings") }
            return string
        }
    }

    /// An ISO 8601 date (`2026-10-14` or `2026-10-14T09:30:00Z`).
    public func optionalDate(_ key: String) throws -> Date? {
        guard let text = try optionalString(key) else { return nil }
        let full = ISO8601DateFormatter()
        if let date = full.date(from: text) { return date }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        if let date = day.date(from: text) { return date }
        throw ToolError.invalid(key, "must be an ISO 8601 date such as 2026-10-14")
    }
}

/// A failure the model should see and can correct: it becomes a result with
/// `isError: true`, not a JSON-RPC error.
public struct ToolError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }

    public static func missing(_ key: String) -> ToolError { ToolError("`\(key)` is required") }
    public static func invalid(_ key: String, _ problem: String) -> ToolError { ToolError("`\(key)` \(problem)") }
}

/// What a call returns.
public struct ToolResult: Sendable, Equatable {
    public var content: [Content]
    public var isError: Bool
    /// The same data as JSON, for clients that read it programmatically.
    public var structured: JSONValue?

    public init(content: [Content], isError: Bool = false, structured: JSONValue? = nil) {
        self.content = content
        self.isError = isError
        self.structured = structured
    }

    public static func text(_ text: String, structured: JSONValue? = nil) -> ToolResult {
        ToolResult(content: [.text(text)], structured: structured)
    }

    public static func error(_ message: String) -> ToolResult {
        ToolResult(content: [.text(message)], isError: true)
    }

    public enum Content: Sendable, Equatable {
        case text(String)
        case image(Data, mimeType: String)

        var json: JSONValue {
            switch self {
            case .text(let text):
                ["type": "text", "text": .string(text)]
            case .image(let data, let mimeType):
                ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(mimeType)]
            }
        }
    }

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "content": .array(content.map(\.json)),
            "isError": .bool(isError),
        ]
        if let structured { object["structuredContent"] = structured }
        return .object(object)
    }
}

/// JSON Schema for tool arguments, the subset tools need.
public enum Schema {
    public static func object(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        var object: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { object["required"] = .array(required.map(JSONValue.string)) }
        return .object(object)
    }

    public static func string(_ description: String, enum values: [String]? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let values { object["enum"] = .array(values.map(JSONValue.string)) }
        return .object(object)
    }

    public static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["type": "integer", "description": .string(description)]
        if let minimum { object["minimum"] = .int(minimum) }
        if let maximum { object["maximum"] = .int(maximum) }
        return .object(object)
    }

    public static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }

    public static func strings(_ description: String) -> JSONValue {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }
}
