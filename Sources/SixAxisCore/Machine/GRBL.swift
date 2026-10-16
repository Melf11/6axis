import Foundation
import simd

/// GRBL 1.1 protocol: messages from the controller, real-time commands and texts (also grblHAL/FluidNC).
/// Reference: github.com/gnea/grbl/wiki/Grbl-v1.1-Interface
public enum GRBL {
    /// Size of GRBL's serial receive buffer; the streamer never has more unacknowledged bytes in flight.
    public static let rxBuffer = 127

    public enum RealTime: UInt8, Sendable {
        case status = 0x3F          // ?
        case feedHold = 0x21        // !
        case cycleStart = 0x7E      // ~
        case softReset = 0x18       // ctrl-x
        case jogCancel = 0x85
        case feed100 = 0x90, feedPlus10 = 0x91, feedMinus10 = 0x92
        case spindle100 = 0x99, spindlePlus10 = 0x9A, spindleMinus10 = 0x9B
    }

    public enum State: String, Sendable {
        case idle = "Idle", run = "Run", hold = "Hold", jog = "Jog", alarm = "Alarm", door = "Door", check = "Check", home = "Home", sleep = "Sleep"
        case unknown

        public var displayName: String {
            switch self {
            case .idle: return String(localized: "Bereit")
            case .run: return String(localized: "Läuft")
            case .hold: return String(localized: "Angehalten")
            case .jog: return String(localized: "Verfährt")
            case .alarm: return String(localized: "Alarm")
            case .door: return String(localized: "Tür offen")
            case .check: return String(localized: "Prüfmodus")
            case .home: return String(localized: "Referenzfahrt")
            case .sleep: return String(localized: "Ruhezustand")
            case .unknown: return String(localized: "Unbekannt")
            }
        }
    }

    public struct Status: Sendable, Equatable {
        public var state: State = .unknown
        public var machine: Vec3 = .zero
        public var workOffset: Vec3 = .zero
        public var feed: Double = 0
        public var spindle: Double = 0
        public var overrides = SIMD3<Int>(100, 100, 100)   // feed, rapid, spindle
        public var probeTriggered = false
        public var work: Vec3 { machine - workOffset }
        public init() {}
    }

    public enum Message: Sendable, Equatable {
        case ok
        case error(Int)
        case alarm(Int)
        case status(Status)
        case welcome(String)
        case setting(Int, String)
        case probe(Vec3, Bool)
        case feedback(String)
        case other(String)
    }

    /// Parses one line from the controller. `previous` supplies the work offset, which GRBL reports only now and then.
    public static func parse(_ raw: String, previous: Status = Status()) -> Message {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line == "ok" { return .ok }
        if line.hasPrefix("error:") { return .error(Int(line.dropFirst(6)) ?? -1) }
        if line.hasPrefix("ALARM:") { return .alarm(Int(line.dropFirst(6)) ?? -1) }
        if line.hasPrefix("Grbl ") || line.hasPrefix("GrblHAL ") || line.hasPrefix("FluidNC") { return .welcome(line) }
        if line.hasPrefix("<") && line.hasSuffix(">") {
            var s = previous
            s.probeTriggered = false
            let fields = line.dropFirst().dropLast().split(separator: "|").map(String.init)
            if let first = fields.first { s.state = State(rawValue: String(first.split(separator: ":").first ?? "")) ?? .unknown }
            var wpos: Vec3?
            for f in fields.dropFirst() {
                let parts = f.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let nums = parts[1].split(separator: ",").compactMap { Double($0) }
                switch parts[0] {
                case "MPos" where nums.count >= 3: s.machine = Vec3(nums[0], nums[1], nums[2])
                case "WPos" where nums.count >= 3: wpos = Vec3(nums[0], nums[1], nums[2])
                case "WCO" where nums.count >= 3: s.workOffset = Vec3(nums[0], nums[1], nums[2])
                case "FS" where nums.count >= 2: s.feed = nums[0]; s.spindle = nums[1]
                case "F" where nums.count >= 1: s.feed = nums[0]
                case "Ov" where nums.count >= 3: s.overrides = SIMD3(Int(nums[0]), Int(nums[1]), Int(nums[2]))
                case "Pn": s.probeTriggered = parts[1].contains("P")
                default: break
                }
            }
            // Controllers set to report work positions: derive the machine position from the known offset.
            if let w = wpos { s.machine = w + s.workOffset }
            return .status(s)
        }
        if line.hasPrefix("[PRB:") {
            let body = line.dropFirst(5).dropLast()
            let parts = body.split(separator: ":")
            let nums = (parts.first ?? "").split(separator: ",").compactMap { Double($0) }
            if nums.count >= 3 { return .probe(Vec3(nums[0], nums[1], nums[2]), parts.last == "1") }
        }
        if line.hasPrefix("$"), let eq = line.firstIndex(of: "="), let n = Int(line[line.index(after: line.startIndex)..<eq]) {
            return .setting(n, String(line[line.index(after: eq)...]))
        }
        if line.hasPrefix("[") { return .feedback(line) }
        return .other(line)
    }

    /// Plain-language texts for GRBL error codes (the common ones).
    public static func errorText(_ code: Int) -> String {
        switch code {
        case 1: return String(localized: "Befehl nicht verstanden (Buchstabe fehlt)")
        case 2: return String(localized: "Zahlenwert fehlt oder ist ungültig")
        case 3: return String(localized: "Einstellungsbefehl nicht unterstützt")
        case 9: return String(localized: "G-Code gesperrt – erst Alarm aufheben oder Referenzfahrt")
        case 15: return String(localized: "Verfahrweg über die Software-Endlage hinaus")
        case 20: return String(localized: "Nicht unterstützter G-Code-Befehl")
        case 22: return String(localized: "Vorschub fehlt")
        case 24, 25, 26: return String(localized: "Fehlerhafter G-Code (Achsen/Wörter)")
        case 33: return String(localized: "Kreisbogen ungültig")
        default: return String(localized: "Steuerungsfehler \(code)")
        }
    }

    public static func alarmText(_ code: Int) -> String {
        switch code {
        case 1: return String(localized: "Endschalter ausgelöst – Position unsicher, Referenzfahrt nötig")
        case 2: return String(localized: "Ziel liegt außerhalb des Arbeitsraums (Software-Endlage)")
        case 3: return String(localized: "Zurückgesetzt während der Fahrt – Position unsicher")
        case 4: return String(localized: "Tastplatte war schon vor dem Antasten berührt")
        case 5: return String(localized: "Tastplatte nicht erreicht (Antastweg zu kurz?)")
        case 6, 7, 8, 9: return String(localized: "Referenzfahrt fehlgeschlagen (Endschalter nicht gefunden)")
        default: return String(localized: "Alarm \(code)")
        }
    }
}

/// Sends a program line by line, keeping at most `GRBL.rxBuffer` unacknowledged bytes in the controller
/// (character-counting protocol: smooth motion without waiting for each "ok").
public struct GCodeStreamer: Sendable {
    public private(set) var lines: [String]
    public private(set) var next = 0
    public private(set) var acknowledged = 0
    private var inFlight: [Int] = []   // byte counts of sent, unacknowledged lines
    public private(set) var errors: [(line: Int, code: Int)] = []

    public init(program: String) {
        // Strip comments and blank lines; GRBL wants plain, upper-case blocks.
        lines = program.split(whereSeparator: \.isNewline).compactMap { raw -> String? in
            var s = String(raw)
            while let open = s.firstIndex(of: "("), let close = s[open...].firstIndex(of: ")") { s.removeSubrange(open...close) }
            if let semi = s.firstIndex(of: ";") { s = String(s[..<semi]) }
            s = s.trimmingCharacters(in: .whitespaces).uppercased()
            return s.isEmpty ? nil : s
        }
    }

    public var isFinished: Bool { acknowledged >= lines.count }
    public var progress: Double { lines.isEmpty ? 1 : Double(acknowledged) / Double(lines.count) }
    private var bytesInFlight: Int { inFlight.reduce(0, +) }

    /// Lines that fit into the controller's buffer now.
    public mutating func linesToSend() -> [String] {
        var out: [String] = []
        while next < lines.count {
            let size = lines[next].utf8.count + 1
            guard bytesInFlight + size <= GRBL.rxBuffer else { break }
            inFlight.append(size)
            out.append(lines[next])
            next += 1
        }
        return out
    }

    /// The controller answered "ok" or "error:n" for the oldest line in flight.
    public mutating func acknowledge(error code: Int? = nil) {
        guard !inFlight.isEmpty else { return }
        inFlight.removeFirst()
        if let code { errors.append((acknowledged, code)) }
        acknowledged += 1
    }

    /// Start (again) at a line, e.g. after a stop.
    public mutating func restart(at line: Int) {
        next = max(0, min(lines.count, line))
        acknowledged = next
        inFlight = []
        errors = []
    }
}
