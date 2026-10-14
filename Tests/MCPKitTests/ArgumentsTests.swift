import Foundation
import Testing

@testable import MCPKit

/// Typed reads of a call's arguments, and JSON values.
@Suite("Arguments")
struct ArgumentsTests {
    @Test("integers accept whole doubles and check their range")
    func integers() throws {
        let arguments = Arguments(["a": 3, "b": 4.0, "c": 4.5, "d": 99, "e": nil])
        #expect(try arguments.optionalInt("a") == 3)
        #expect(try arguments.optionalInt("b") == 4)
        #expect(throws: ToolError.invalid("c", "must be an integer")) { try arguments.optionalInt("c") }
        #expect(throws: ToolError.invalid("d", "must be between 1 and 50")) { try arguments.optionalInt("d", in: 1...50) }
        #expect(try arguments.optionalInt("e") == nil)
        #expect(try arguments.optionalInt("missing") == nil)
    }

    @Test("dates take a day or a full timestamp")
    func dates() throws {
        let arguments = Arguments(["day": "2026-10-14", "full": "2026-10-14T09:30:00Z", "bad": "yesterday"])
        #expect(try arguments.optionalDate("day") != nil)
        #expect(try arguments.optionalDate("full") == Date(timeIntervalSince1970: 1_791_970_200))
        #expect(throws: ToolError.self) { try arguments.optionalDate("bad") }
    }

    @Test("string arrays")
    func strings() throws {
        let arguments = Arguments(["ok": ["a", "b"], "mixed": ["a", 1]])
        #expect(try arguments.optionalStrings("ok") == ["a", "b"])
        #expect(throws: ToolError.self) { try arguments.optionalStrings("mixed") }
    }

    @Test("JSON round-trips")
    func roundTrip() throws {
        let value: JSONValue = ["a": [1, 2.5, "x", true, nil], "b": ["c": "d"]]
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }
}
