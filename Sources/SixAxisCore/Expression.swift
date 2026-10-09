import Foundation

/// The kind of value an expression is expected to produce. Bare numbers take the default unit.
public enum ValueKind: Sendable {
    case length   // mm
    case angle    // degrees
    case scalar
}

public struct ExpressionError: Error, LocalizedError, Sendable {
    public let message: String
    public init(message: LocalizedStringResource) { self.message = String(localized: message) }
    public var errorDescription: String? { message }
}

/// A user parameter ("Benutzerparameter"), e.g. `wand = 2 mm`.
public struct UserParameter: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var expression: String
    public var comment: String

    public init(id: UUID = UUID(), name: String, expression: String, comment: String = "") {
        self.id = id
        self.name = name
        self.expression = expression
        self.comment = comment
    }
}

/// Evaluates arithmetic expressions with units and named parameters.
///
/// Grammar: `+ - * / ^`, parentheses, functions (sin, cos, tan, sqrt, abs, min, max, round, floor, ceil),
/// constants (pi), units (mm, cm, m, in, ft, deg, rad), and parameter names. Comma or dot as decimal separator
/// is accepted when unambiguous ("2,5" → 2.5).
public struct Evaluator: Sendable {
    public var parameters: [String: String]
    private var cache: [String: Double] = [:]

    public init(parameters: [UserParameter] = []) {
        self.parameters = Dictionary(parameters.map { ($0.name, $0.expression) }, uniquingKeysWith: { a, _ in a })
    }

    public mutating func evaluate(_ text: String, kind: ValueKind = .length) throws -> Double {
        var visiting = Set<String>()
        return try evaluate(text, kind: kind, visiting: &visiting)
    }

    /// Non-mutating convenience; does not cache parameter values.
    public func value(_ text: String, kind: ValueKind = .length) throws -> Double {
        var copy = self
        return try copy.evaluate(text, kind: kind)
    }

    private mutating func evaluate(_ text: String, kind: ValueKind, visiting: inout Set<String>) throws -> Double {
        var parser = Parser(tokens: try tokenize(text), kind: kind)
        let v = try parser.parseExpression { name in
            try self.lookup(name, kind: kind, visiting: &visiting)
        }
        guard parser.atEnd else { throw ExpressionError(message: "Unerwartetes Zeichen in „\(text)“") }
        guard v.isFinite else { throw ExpressionError(message: "Ergebnis ist keine gültige Zahl") }
        return v
    }

    private mutating func lookup(_ name: String, kind: ValueKind, visiting: inout Set<String>) throws -> Double {
        if let v = cache[name] { return v }
        guard let expr = parameters[name] else { throw ExpressionError(message: "Unbekannter Parameter „\(name)“") }
        guard !visiting.contains(name) else { throw ExpressionError(message: "Zirkulärer Bezug bei „\(name)“") }
        visiting.insert(name)
        let v = try evaluate(expr, kind: kind, visiting: &visiting)
        visiting.remove(name)
        cache[name] = v
        return v
    }

    // MARK: Lexer

    enum Token: Equatable {
        case number(Double)
        case ident(String)
        case op(Character)
    }

    private func tokenize(_ s: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || ((c == "." || c == ",") && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i
                var text = ""
                while j < chars.count, chars[j].isNumber || chars[j] == "." || chars[j] == "," {
                    text.append(chars[j] == "," ? "." : chars[j])
                    j += 1
                }
                if j < chars.count, chars[j] == "e" || chars[j] == "E",
                   j + 1 < chars.count, chars[j + 1].isNumber || ((chars[j + 1] == "-" || chars[j + 1] == "+") && j + 2 < chars.count && chars[j + 2].isNumber) {
                    text.append("e"); j += 1
                    if chars[j] == "-" || chars[j] == "+" { text.append(chars[j]); j += 1 }
                    while j < chars.count, chars[j].isNumber { text.append(chars[j]); j += 1 }
                }
                guard let v = Double(text) else { throw ExpressionError(message: "Ungültige Zahl „\(text)“") }
                tokens.append(.number(v))
                i = j
            } else if c.isLetter || c == "_" {
                var j = i
                var text = ""
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" {
                    text.append(chars[j]); j += 1
                }
                tokens.append(.ident(text))
                i = j
            } else if "+-*/^()".contains(c) || c == "°" || c == ";" {
                tokens.append(.op(c == ";" ? "," : c))
                i += 1
            } else {
                throw ExpressionError(message: "Unerwartetes Zeichen „\(c)“")
            }
        }
        return tokens
    }

    // MARK: Parser

    struct Parser {
        let tokens: [Token]
        let kind: ValueKind
        var pos = 0

        init(tokens: [Token], kind: ValueKind) {
            self.tokens = tokens
            self.kind = kind
        }

        var atEnd: Bool { pos >= tokens.count }
        func peek() -> Token? { pos < tokens.count ? tokens[pos] : nil }

        mutating func parseExpression(_ lookup: (String) throws -> Double) throws -> Double {
            var v = try parseTerm(lookup)
            while let t = peek(), t == .op("+") || t == .op("-") {
                pos += 1
                let r = try parseTerm(lookup)
                v = t == .op("+") ? v + r : v - r
            }
            return v
        }

        mutating func parseTerm(_ lookup: (String) throws -> Double) throws -> Double {
            var v = try parseUnary(lookup)
            while let t = peek(), t == .op("*") || t == .op("/") {
                pos += 1
                let r = try parseUnary(lookup)
                if t == .op("/") {
                    guard r != 0 else { throw ExpressionError(message: "Division durch null") }
                    v /= r
                } else {
                    v *= r
                }
            }
            return v
        }

        mutating func parseUnary(_ lookup: (String) throws -> Double) throws -> Double {
            if peek() == .op("-") { pos += 1; return -(try parseUnary(lookup)) }
            if peek() == .op("+") { pos += 1; return try parseUnary(lookup) }
            return try parsePower(lookup)
        }

        mutating func parsePower(_ lookup: (String) throws -> Double) throws -> Double {
            let base = try parsePostfixUnit(lookup)
            if peek() == .op("^") {
                pos += 1
                let e = try parseUnary(lookup)
                return pow(base, e)
            }
            return base
        }

        mutating func parsePostfixUnit(_ lookup: (String) throws -> Double) throws -> Double {
            var v = try parsePrimary(lookup)
            // A unit directly following a value scales it: "10 mm", "2.5in", "45 deg", "30°".
            while let t = peek() {
                if t == .op("°") { pos += 1; v *= unitFactor("deg")!; continue }
                if case let .ident(name) = t, let f = unitFactor(name) { pos += 1; v *= f; continue }
                break
            }
            return v
        }

        func unitFactor(_ name: String) -> Double? {
            switch name {
            case "mm": return 1
            case "cm": return 10
            case "m": return 1000
            case "in", "inch", "zoll": return 25.4
            case "ft": return 304.8
            case "deg", "grad": return kind == .angle ? 1 : .pi / 180
            case "rad": return kind == .angle ? 180 / .pi : 1
            default: return nil
            }
        }

        mutating func parsePrimary(_ lookup: (String) throws -> Double) throws -> Double {
            guard let t = peek() else { throw ExpressionError(message: "Ausdruck unvollständig") }
            pos += 1
            switch t {
            case let .number(v):
                return v
            case .op("("):
                let v = try parseExpression(lookup)
                guard peek() == .op(")") else { throw ExpressionError(message: "„)“ fehlt") }
                pos += 1
                return v
            case let .ident(name):
                if peek() == .op("(") {
                    pos += 1
                    var args = [try parseExpression(lookup)]
                    while peek() == .op(",") { pos += 1; args.append(try parseExpression(lookup)) }
                    guard peek() == .op(")") else { throw ExpressionError(message: "„)“ fehlt") }
                    pos += 1
                    return try call(name, args)
                }
                if name == "pi" || name == "PI" { return .pi }
                return try lookup(name)
            default:
                throw ExpressionError(message: "Unerwartetes Zeichen")
            }
        }

        func call(_ name: String, _ a: [Double]) throws -> Double {
            // Trig functions take degrees when evaluating angles or plain numbers, as users type them.
            let toRad = Double.pi / 180
            func one() throws -> Double {
                guard a.count == 1 else { throw ExpressionError(message: "\(name) erwartet ein Argument") }
                return a[0]
            }
            switch name {
            case "sin": return sin(try one() * toRad)
            case "cos": return cos(try one() * toRad)
            case "tan": return tan(try one() * toRad)
            case "asin": return asin(try one()) / toRad
            case "acos": return acos(try one()) / toRad
            case "atan": return atan(try one()) / toRad
            case "sqrt": return sqrt(try one())
            case "abs": return abs(try one())
            case "round": return (try one()).rounded()
            case "floor": return floor(try one())
            case "ceil": return ceil(try one())
            case "min": guard !a.isEmpty else { break }; return a.min()!
            case "max": guard !a.isEmpty else { break }; return a.max()!
            default: break
            }
            throw ExpressionError(message: "Unbekannte Funktion „\(name)“")
        }
    }
}

/// Formats a value for display in a field, e.g. 12.5 → "12.5 mm".
public func formatValue(_ v: Double, kind: ValueKind = .length) -> String {
    let rounded = (v * 1000).rounded() / 1000
    var s = String(format: "%.3f", rounded)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    if s == "-0" { s = "0" }
    switch kind {
    case .length: return s + " mm"
    case .angle: return s + "°"
    case .scalar: return s
    }
}
