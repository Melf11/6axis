import Foundation
import simd

/// A GRBL 1.1 controller in software: planner buffer, motion over time, homing, probing, feed hold,
/// soft reset and alarms. Lets the machine panel and the tests run without a router.
public final class GRBLSimulator: MachineTransport, @unchecked Sendable {
    public var onLine: (@Sendable (String) -> Void)?
    public let name = String(localized: "Simulator")
    /// Seconds of simulated motion per real second (tests run fast).
    public var timeScale: Double
    /// Machine Z where the probe plate's surface is.
    public var probeSurface: Double = -40

    private let queue = DispatchQueue(label: "app.6axis.grblsim")
    private var timer: DispatchSourceTimer?
    private var rx = [UInt8]()
    private var planner: [(target: Vec3, feed: Double, kind: Kind)] = []
    private enum Kind: Equatable { case motion, dwell(Double), pause, probe }
    private var state: GRBL.State = .idle
    private var machine = Vec3.zero
    private var wco = Vec3.zero
    private var absolute = true
    private var feed = 0.0
    private var spindle = 0.0
    private var hold = false
    private var overrides = SIMD3<Int>(100, 100, 100)
    private var pendingAcks = 0
    private var reportWCO = true
    private var dwellLeft = 0.0
    public private(set) var executed: [String] = []

    public init(timeScale: Double = 1) {
        self.timeScale = timeScale
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10))
        t.setEventHandler { [weak self] in self?.tick(0.01) }
        t.resume()
        timer = t
    }

    deinit { timer?.cancel() }

    public func close() {
        timer?.cancel()
        timer = nil
    }

    /// Replies keep their order (like bytes on a serial line).
    private let out = DispatchQueue(label: "app.6axis.grblsim.out")

    private func reply(_ s: String) {
        let cb = onLine
        out.async { cb?(s) }
    }

    // MARK: Input

    public func send(_ bytes: [UInt8]) {
        queue.async { [self] in
            for b in bytes {
                if let rt = GRBL.RealTime(rawValue: b), b != 0x0A {
                    realTime(rt)
                    continue
                }
                if b == 0x0A {
                    let line = String(decoding: rx, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    rx.removeAll()
                    handle(line)
                } else if b != 0x0D {
                    rx.append(b)
                }
            }
        }
    }

    private func realTime(_ c: GRBL.RealTime) {
        switch c {
        case .status: reply(statusLine())
        case .feedHold:
            if state == .run || state == .jog { hold = true; state = .hold }
        case .cycleStart:
            if hold || state == .hold { hold = false; state = planner.isEmpty ? .idle : .run }
        case .softReset:
            let moving = state == .run || state == .hold
            planner.removeAll()
            hold = false
            pendingAcks = 0
            state = moving ? .alarm : .idle
            reply("Grbl 1.1h ['$' for help]")
            if moving { reply("ALARM:3") }
        case .jogCancel:
            if state == .jog { planner.removeAll(); state = .idle }
        case .feed100: overrides.x = 100
        case .feedPlus10: overrides.x = min(200, overrides.x + 10)
        case .feedMinus10: overrides.x = max(10, overrides.x - 10)
        case .spindle100: overrides.z = 100
        case .spindlePlus10: overrides.z = min(200, overrides.z + 10)
        case .spindleMinus10: overrides.z = max(10, overrides.z - 10)
        }
    }

    private func statusLine() -> String {
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        var s = "<\(state == .hold ? "Hold:0" : state.rawValue)|MPos:\(f(machine.x)),\(f(machine.y)),\(f(machine.z))|FS:\(Int(feed)),\(Int(spindle))"
        if reportWCO { s += "|WCO:\(f(wco.x)),\(f(wco.y)),\(f(wco.z))"; reportWCO = false } else { reportWCO = true }
        s += "|Ov:\(overrides.x),\(overrides.y),\(overrides.z)>"
        return s
    }

    // MARK: Commands

    private func handle(_ line: String) {
        guard !line.isEmpty else { return }
        executed.append(line)
        if state == .alarm && line != "$X" && line != "$H" && !line.hasPrefix("$$") {
            reply("error:9")
            return
        }
        switch line {
        case "$X": state = .idle; reply("[MSG:Caution: Unlocked]"); reply("ok"); return
        case "$H":
            state = .home
            planner.append((Vec3(machine.x, machine.y, 0), 2000, .motion))
            planner.append((Vec3(0, 0, 0), 3000, .motion))
            queueAck()
            return
        case "$$":
            for (k, v) in [(22, "1"), (110, "3000"), (111, "3000"), (112, "1000"), (130, "800"), (131, "600"), (132, "120")] { reply("$\(k)=\(v)") }
            reply("ok")
            return
        default: break
        }
        if line.hasPrefix("$J=") {
            parseMotion(String(line.dropFirst(3)), jog: true)
            return
        }
        parseMotion(line, jog: false)
    }

    private func words(_ s: String) -> [(Character, Double)] {
        var out: [(Character, Double)] = []
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            guard c.isLetter else { i = s.index(after: i); continue }
            var j = s.index(after: i)
            while j < s.endIndex, s[j].isNumber || s[j] == "." || s[j] == "-" { j = s.index(after: j) }
            if let v = Double(s[s.index(after: i)..<j]) { out.append((c, v)) }
            i = j
        }
        return out
    }

    /// Where the machine will be once the planned blocks are done (new blocks start from there).
    private var planned: Vec3 { planner.last { $0.kind == .motion || $0.kind == .probe }?.target ?? machine }

    private func parseMotion(_ line: String, jog: Bool) {
        let w = words(line)
        let machine = planned
        var target = absolute ? machine - wco : Vec3.zero
        var hasAxis = false, rapid = false, machineCoords = false, probe = false, setOffset = false
        var relative = !absolute
        for (c, v) in w {
            switch c {
            case "G":
                switch v {
                case 0: rapid = true
                case 1, 2, 3: rapid = false
                case 90: relative = false; if !jog { absolute = true }
                case 91: relative = true; if !jog { absolute = false }
                case 53: machineCoords = true
                case 38.2: probe = true
                case 10: setOffset = true
                case 4:
                    if let p = w.first(where: { $0.0 == "P" })?.1 { planner.append((machine, 0, .dwell(p))); queueAck(); return }
                case 17, 20, 21, 94, 43, 54: break
                default: reply("error:20"); return
                }
            case "M":
                switch v {
                case 3, 4: spindle = w.first { $0.0 == "S" }?.1 ?? spindle
                case 5: spindle = 0
                case 0, 1: planner.append((machine, 0, .pause))
                case 2, 30: break
                case 6: reply("error:20"); return
                default: break
                }
            case "F": feed = v
            default: break
            }
        }
        if relative && !machineCoords { target = .zero }
        for (c, v) in w {
            switch c {
            case "X": target.x = v; hasAxis = true
            case "Y": target.y = v; hasAxis = true
            case "Z": target.z = v; hasAxis = true
            default: break
            }
        }
        if setOffset {
            // G10 L20 P1: the current position gets the given work coordinates.
            let machine = self.machine
            let current = machine - wco
            var desired = current
            for (c, v) in w where "XYZ".contains(c) {
                if c == "X" { desired.x = v }
                if c == "Y" { desired.y = v }
                if c == "Z" { desired.z = v }
            }
            wco = machine - desired
            reportWCO = true
            reply("ok")
            return
        }
        guard hasAxis else { reply("ok"); return }
        var dest: Vec3
        if machineCoords { dest = machine; for (c, v) in w { if c == "X" { dest.x = v }; if c == "Y" { dest.y = v }; if c == "Z" { dest.z = v } } }
        else if relative { dest = machine + target }
        else { dest = target + wco; for c in "XYZ" where !w.contains(where: { $0.0 == c }) { if c == "X" { dest.x = machine.x }; if c == "Y" { dest.y = machine.y }; if c == "Z" { dest.z = machine.z } } }
        if jog { state = .jog }
        planner.append((dest, rapid ? 3000 : max(feed, 1), probe ? .probe : .motion))
        queueAck()
    }

    /// GRBL answers "ok" once a block is in the planner (15 blocks deep).
    private func queueAck() {
        if planner.count <= 15 { reply("ok") } else { pendingAcks += 1 }
    }

    // MARK: Motion

    private func tick(_ dt: Double) {
        guard !hold, let block = planner.first else {
            if planner.isEmpty, state == .run || state == .jog || state == .home { state = .idle; feed = 0 }
            return
        }
        if state == .idle { state = .run }
        switch block.kind {
        case .pause:
            planner.removeFirst()
            hold = true
            state = .hold
        case let .dwell(seconds):
            dwellLeft += dt * timeScale
            if dwellLeft >= seconds { dwellLeft = 0; finishBlock() }
        case .motion, .probe:
            let speed = block.feed * Double(overrides.x) / 100 / 60 * timeScale   // mm per second
            let d = block.target - machine
            let step = speed * dt
            if block.kind == .probe, machine.z - step <= probeSurface, block.target.z <= probeSurface {
                machine.z = probeSurface
                planner.removeAll()
                pendingAcks = 0
                reply(String(format: "[PRB:%.3f,%.3f,%.3f:1]", machine.x, machine.y, machine.z))
                state = .idle
                return
            }
            if simd_length(d) <= step {
                machine = block.target
                if block.kind == .probe {
                    reply("ALARM:5")
                    state = .alarm
                    planner.removeAll()
                    return
                }
                finishBlock()
            } else {
                machine += simd_normalize(d) * step
            }
        }
    }

    private func finishBlock() {
        planner.removeFirst()
        if pendingAcks > 0 { pendingAcks -= 1; reply("ok") }
    }
}
