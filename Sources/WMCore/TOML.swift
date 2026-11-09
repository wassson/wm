import Foundation

/// A parsed TOML value. Supports the subset of TOML a config file needs:
/// tables, dotted keys, basic/literal strings, integers, floats, booleans,
/// arrays and inline tables. (No dates, multi-line strings or arrays of tables.)
public indirect enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case float(Double)
    case boolean(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var int: Int? { if case .integer(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .boolean(let v) = self { return v }; return nil }
    public var array: [TOMLValue]? { if case .array(let v) = self { return v }; return nil }
    public var table: [String: TOMLValue]? { if case .table(let v) = self { return v }; return nil }
    public var double: Double? {
        switch self {
        case .integer(let v): return Double(v)
        case .float(let v): return v
        default: return nil
        }
    }
}

public struct TOMLError: Error, CustomStringConvertible, Equatable {
    public let line: Int
    public let message: String
    public var description: String { "line \(line): \(message)" }
}

public enum TOML {
    public static func parse(_ text: String) throws -> [String: TOMLValue] {
        var parser = TOMLParser(text)
        return try parser.parseDocument()
    }
}

struct TOMLParser {
    private let chars: [Character]
    private var i = 0
    private var line = 1

    init(_ text: String) {
        // "\r\n" is a single Character in Swift; normalise so newline checks are simple.
        chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
    }

    // MARK: - Scanning

    private var atEnd: Bool { i >= chars.count }
    private var peek: Character? { atEnd ? nil : chars[i] }

    private mutating func advance() {
        if chars[i] == "\n" { line += 1 }
        i += 1
    }

    private func error(_ message: String) -> TOMLError { TOMLError(line: line, message: message) }

    private mutating func skipSpaces() {
        while let c = peek, c == " " || c == "\t" { advance() }
    }

    private mutating func skipComment() {
        guard peek == "#" else { return }
        while let c = peek, c != "\n" { advance() }
    }

    /// Skips whitespace, newlines and comments.
    private mutating func skipBlank() {
        while let c = peek {
            if c == " " || c == "\t" || c == "\n" || c == "\r" {
                advance()
            } else if c == "#" {
                skipComment()
            } else {
                break
            }
        }
    }

    private mutating func expectLineEnd() throws {
        skipSpaces()
        skipComment()
        guard let c = peek else { return }
        guard c == "\n" else { throw error("expected end of line, found '\(c)'") }
    }

    private mutating func expect(_ expected: Character) throws {
        guard let c = peek else { throw error("expected '\(expected)' but reached end of file") }
        guard c == expected else { throw error("expected '\(expected)', found '\(c)'") }
        advance()
    }

    private func matches(_ word: String) -> Bool {
        let w = Array(word)
        guard i + w.count <= chars.count else { return false }
        return Array(chars[i..<(i + w.count)]) == w
    }

    // MARK: - Document

    mutating func parseDocument() throws -> [String: TOMLValue] {
        var root: [String: TOMLValue] = [:]
        var currentTable: [String] = []

        while true {
            skipBlank()
            guard let c = peek else { break }

            if c == "[" {
                advance()
                if peek == "[" { throw error("arrays of tables ([[...]]) are not supported") }
                skipSpaces()
                currentTable = try parseKeyPath()
                skipSpaces()
                try expect("]")
                try ensureTable(&root, currentTable[...])
            } else {
                let key = try parseKeyPath()
                skipSpaces()
                try expect("=")
                skipSpaces()
                let value = try parseValue()
                try insert(&root, (currentTable + key)[...], value)
            }
            try expectLineEnd()
        }
        return root
    }

    // MARK: - Keys

    private mutating func parseKeyPath() throws -> [String] {
        var parts = [try parseKey()]
        while true {
            skipSpaces()
            guard peek == "." else { break }
            advance()
            skipSpaces()
            parts.append(try parseKey())
        }
        return parts
    }

    private mutating func parseKey() throws -> String {
        switch peek {
        case "\"": return try parseBasicString()
        case "'": return try parseLiteralString()
        default:
            var key = ""
            while let c = peek, c.isASCII, c.isLetter || c.isNumber || c == "_" || c == "-" {
                key.append(c)
                advance()
            }
            guard !key.isEmpty else {
                throw error(peek.map { "expected a key, found '\($0)'" } ?? "expected a key")
            }
            return key
        }
    }

    // MARK: - Values

    private mutating func parseValue() throws -> TOMLValue {
        guard let c = peek else { throw error("expected a value") }
        switch c {
        case "\"": return .string(try parseBasicString())
        case "'": return .string(try parseLiteralString())
        case "[": return try parseArray()
        case "{": return try parseInlineTable()
        default:
            if matches("true") { i += 4; return .boolean(true) }
            if matches("false") { i += 5; return .boolean(false) }
            return try parseNumber()
        }
    }

    private mutating func parseBasicString() throws -> String {
        advance()  // opening quote
        if peek == "\"" {
            // Either an empty string ("") or the start of a multi-line string (""").
            if matches("\"\"") { throw error("multi-line strings are not supported") }
            advance()
            return ""
        }
        var s = ""
        while true {
            guard let c = peek else { throw error("unterminated string") }
            if c == "\n" { throw error("unterminated string (newline before closing quote)") }
            advance()
            if c == "\"" { return s }
            if c != "\\" { s.append(c); continue }

            guard let e = peek else { throw error("unterminated escape sequence") }
            advance()
            switch e {
            case "n": s.append("\n")
            case "t": s.append("\t")
            case "r": s.append("\r")
            case "\\": s.append("\\")
            case "\"": s.append("\"")
            case "u", "U":
                let len = e == "u" ? 4 : 8
                var hex = ""
                for _ in 0..<len {
                    guard let h = peek, h.isHexDigit else { throw error("invalid unicode escape") }
                    hex.append(h)
                    advance()
                }
                guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
                    throw error("invalid unicode escape \\\(e)\(hex)")
                }
                s.unicodeScalars.append(scalar)
            default:
                throw error("invalid escape sequence \\\(e)")
            }
        }
    }

    private mutating func parseLiteralString() throws -> String {
        advance()  // opening quote
        var s = ""
        while true {
            guard let c = peek, c != "\n" else { throw error("unterminated string") }
            advance()
            if c == "'" { return s }
            s.append(c)
        }
    }

    private mutating func parseNumber() throws -> TOMLValue {
        var raw = ""
        while let c = peek, c.isASCII, c.isNumber || "+-._eE".contains(c) {
            raw.append(c)
            advance()
        }
        guard !raw.isEmpty else {
            throw error(peek.map { "unexpected character '\($0)'" } ?? "expected a value")
        }
        let clean = raw.replacingOccurrences(of: "_", with: "")
        if let v = Int(clean) { return .integer(v) }
        if clean.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }), let v = Double(clean) {
            return .float(v)
        }
        throw error("invalid value '\(raw)' (strings must be quoted)")
    }

    private mutating func parseArray() throws -> TOMLValue {
        advance()  // [
        var items: [TOMLValue] = []
        while true {
            skipBlank()
            if peek == "]" { advance(); return .array(items) }
            items.append(try parseValue())
            skipBlank()
            if peek == "," { advance(); continue }
            if peek == "]" { advance(); return .array(items) }
            throw error("expected ',' or ']' in array")
        }
    }

    private mutating func parseInlineTable() throws -> TOMLValue {
        advance()  // {
        var table: [String: TOMLValue] = [:]
        skipSpaces()
        if peek == "}" { advance(); return .table(table) }
        while true {
            skipSpaces()
            let key = try parseKeyPath()
            skipSpaces()
            try expect("=")
            skipSpaces()
            let value = try parseValue()
            try insert(&table, key[...], value)
            skipSpaces()
            if peek == "," { advance(); continue }
            try expect("}")
            return .table(table)
        }
    }

    // MARK: - Building the tree

    private func insert(_ dict: inout [String: TOMLValue], _ path: ArraySlice<String>, _ value: TOMLValue) throws {
        guard let key = path.first else { return }
        let rest = path.dropFirst()
        if rest.isEmpty {
            guard dict[key] == nil else { throw error("duplicate key '\(key)'") }
            dict[key] = value
            return
        }
        var sub: [String: TOMLValue]
        switch dict[key] {
        case nil: sub = [:]
        case .table(let t)?: sub = t
        default: throw error("'\(key)' is already defined and is not a table")
        }
        try insert(&sub, rest, value)
        dict[key] = .table(sub)
    }

    private func ensureTable(_ dict: inout [String: TOMLValue], _ path: ArraySlice<String>) throws {
        guard let key = path.first else { return }
        var sub: [String: TOMLValue]
        switch dict[key] {
        case nil: sub = [:]
        case .table(let t)?: sub = t
        default: throw error("'\(key)' is already defined and is not a table")
        }
        try ensureTable(&sub, path.dropFirst())
        dict[key] = .table(sub)
    }
}
