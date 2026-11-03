import Foundation

/// Bounded JSON reader rejecting duplicate keys, including equivalent escaped keys.
indirect enum ReviewJSON: Sendable {
    case null, bool(Bool), number(Double), string(String), array([ReviewJSON]), object([String: ReviewJSON])
    var object: [String: ReviewJSON]? { if case .object(let value) = self { value } else { nil } }
    var array: [ReviewJSON]? { if case .array(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var number: Double? { if case .number(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var isNull: Bool { if case .null = self { true } else { false } }

    static func parse(_ data: Data, maximumBytes: Int) throws -> Self {
        guard data.count <= maximumBytes else { throw VisualFaceAssessmentFailure.resourceLimit }
        var parser = Parser(bytes: Array(data))
        let result = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.position == parser.bytes.count else { throw VisualFaceAssessmentFailure.invalidOutput }
        return result
    }
    func encoded() throws -> Data {
        try JSONSerialization.data(withJSONObject: foundationValue, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }
    private var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.foundationValue)
        case .object(let values): values.mapValues(\.foundationValue)
        }
    }
    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func isIdentifier(_ value: String) -> Bool {
        value.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\\z", options: .regularExpression) != nil
    }
    func requiringKeys(_ keys: Set<String>) throws -> [String: ReviewJSON] {
        guard let value = object, Set(value.keys) == keys else { throw VisualFaceAssessmentFailure.invalidOutput }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var position = 0
        var nodes = 0
        mutating func whitespace() {
            while position < bytes.count, [9, 10, 13, 32].contains(bytes[position]) { position += 1 }
        }
        mutating func value(depth: Int) throws -> ReviewJSON {
            whitespace(); nodes += 1
            guard depth <= 32, nodes <= 20_000, position < bytes.count else {
                throw VisualFaceAssessmentFailure.invalidOutput
            }
            switch bytes[position] {
            case 123:
                position += 1; whitespace(); var values: [String: ReviewJSON] = [:]
                if consume(125) { return .object(values) }
                repeat {
                    whitespace(); let key = try readString()
                    guard values[key] == nil else { throw VisualFaceAssessmentFailure.invalidOutput }
                    whitespace(); guard consume(58) else { throw VisualFaceAssessmentFailure.invalidOutput }
                    values[key] = try value(depth: depth + 1); whitespace()
                    if consume(125) { return .object(values) }
                    guard consume(44) else { throw VisualFaceAssessmentFailure.invalidOutput }
                } while true
            case 91:
                position += 1; whitespace(); var values: [ReviewJSON] = []
                if consume(93) { return .array(values) }
                repeat {
                    values.append(try value(depth: depth + 1)); whitespace()
                    if consume(93) { return .array(values) }
                    guard consume(44) else { throw VisualFaceAssessmentFailure.invalidOutput }
                } while true
            case 34: return .string(try readString())
            case 110: try literal(Array("null".utf8)); return .null
            case 116: try literal(Array("true".utf8)); return .bool(true)
            case 102: try literal(Array("false".utf8)); return .bool(false)
            default: return try readNumber()
            }
        }
        mutating func consume(_ byte: UInt8) -> Bool {
            guard position < bytes.count, bytes[position] == byte else { return false }
            position += 1; return true
        }
        mutating func literal(_ literal: [UInt8]) throws {
            guard position + literal.count <= bytes.count,
                  Array(bytes[position..<(position + literal.count)]) == literal else {
                throw VisualFaceAssessmentFailure.invalidOutput
            }
            position += literal.count
        }
        mutating func readString() throws -> String {
            let start = position
            guard consume(34) else { throw VisualFaceAssessmentFailure.invalidOutput }
            while position < bytes.count {
                let byte = bytes[position]; position += 1
                if byte == 34 {
                    guard let value = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<position])) else {
                        throw VisualFaceAssessmentFailure.invalidOutput
                    }
                    return value
                }
                guard byte >= 32 else { throw VisualFaceAssessmentFailure.invalidOutput }
                if byte == 92 {
                    guard position < bytes.count else { throw VisualFaceAssessmentFailure.invalidOutput }
                    position += 1
                }
            }
            throw VisualFaceAssessmentFailure.invalidOutput
        }
        mutating func readNumber() throws -> ReviewJSON {
            let start = position
            while position < bytes.count, [45,43,46,69,101].contains(bytes[position]) || (48...57).contains(bytes[position]) {
                position += 1
            }
            let token = String(decoding: bytes[start..<position], as: UTF8.self)
            guard token.range(of: "\\A-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\\z",
                              options: .regularExpression) != nil,
                  let value = Double(token), value.isFinite else { throw VisualFaceAssessmentFailure.invalidOutput }
            return .number(value)
        }
    }
}
