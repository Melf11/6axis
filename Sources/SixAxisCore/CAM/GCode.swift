import Foundation
import simd

/// G-code output for the supported controllers (small templates, one per dialect).
public enum GCodeWriter {
    public static func write(_ r: CAMResult, setup: CAMSetup, title: String, date: Date = Date()) -> String {
        var out: [String] = []
        func n(_ v: Double) -> String {
            var s = String(format: "%.3f", v)
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s == "-0" ? "0" : s
        }
        func c(_ text: String) -> String {
            // Parentheses end a comment; controllers and senders expect plain ASCII.
            var t = text.replacingOccurrences(of: "(", with: "[").replacingOccurrences(of: ")", with: "]")
            for (a, b) in [("Ø", "D"), ("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("Ä", "Ae"), ("Ö", "Oe"), ("Ü", "Ue"), ("ß", "ss"),
                           ("–", "-"), ("—", "-"), ("°", " Grad"), ("×", "x"), ("„", "\""), ("“", "\"")] {
                t = t.replacingOccurrences(of: a, with: b)
            }
            return "(" + String(t.unicodeScalars.filter(\.isASCII).map(Character.init)) + ")"
        }
        let stock = r.stockMax - r.stockMin
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        out.append(c("6axis – \(title) – \(df.string(from: date))"))
        out.append(c("Steuerung: \(setup.post.displayName)"))
        out.append(c("Nullpunkt: \(setup.origin.displayName)"))
        out.append(c("Rohteil: \(n(stock.x)) x \(n(stock.y)) x \(n(stock.z)) mm"))
        out.append(c("Sicherheitshoehe: Z\(n(r.safeZ - r.origin.z))"))
        var seen = Set<UUID>()
        for p in r.paths where seen.insert(p.tool.id).inserted {
            out.append(c("T\(p.tool.number): \(p.tool.name), \(Int(p.tool.rpm)) U/min"))
        }
        out.append(c("Laufzeit ca. \(Int((r.time() / 60).rounded(.up))) min"))
        out.append("G21 G90 G17 G94")
        let safe = r.safeZ - r.origin.z
        out.append("G0 Z\(n(safe))")
        var currentTool: UUID?
        var lastFeed = -1.0
        for p in r.paths {
            out.append(c(p.name))
            if p.tool.id != currentTool {
                if currentTool != nil { out.append("M5") }
                switch setup.post {
                case .grbl:
                    // GRBL has no tool changer: pause for a manual change (only when the tool really changes).
                    if currentTool != nil {
                        out.append(c("Werkzeugwechsel: T\(p.tool.number) \(p.tool.name) einsetzen, Z neu nullen, dann fortsetzen"))
                        out.append("M0")
                    }
                case .linuxcnc, .mach3:
                    out.append("T\(p.tool.number) M6")
                    if setup.post == .linuxcnc { out.append("G43 H\(p.tool.number)") }
                }
                out.append("M3 S\(Int(p.tool.rpm))")
                out.append("G4 P\(setup.post == .mach3 ? "2000" : "2")")
                currentTool = p.tool.id
                lastFeed = -1
            }
            for m in p.moves {
                let q = m.to - r.origin
                switch m.kind {
                case .rapid:
                    out.append("G0 X\(n(q.x)) Y\(n(q.y)) Z\(n(q.z))")
                case .feed, .plunge:
                    let f = m.kind == .feed ? p.tool.feed : p.tool.plunge
                    if f != lastFeed {
                        out.append("G1 X\(n(q.x)) Y\(n(q.y)) Z\(n(q.z)) F\(Int(f))")
                        lastFeed = f
                    } else {
                        out.append("G1 X\(n(q.x)) Y\(n(q.y)) Z\(n(q.z))")
                    }
                }
            }
        }
        out.append("G0 Z\(n(safe))")
        out.append("M5")
        out.append("M30")
        return out.joined(separator: "\n") + "\n"
    }
}
