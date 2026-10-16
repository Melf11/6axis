import Foundation
import simd

/// Drives a GRBL-compatible router: connection, status polling, jogging, homing, zeroing, probing, parking
/// and running jobs with pause/stop/overrides. All protocol work happens on its own queue; `onChange`
/// delivers snapshots (call sites hop to the main thread).
public final class MachineController: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var connected = false
        public var portName = ""
        public var firmware = ""
        public var status = GRBL.Status()
        /// Job: line counts, running, paused by the user or by M0 (tool change).
        public var jobLines = 0
        public var jobDone = 0
        public var jobRunning = false
        public var jobFinished = false
        public var message: String?
        public var alarm: Int?
        public var homed = false
        public var log: [String] = []
        public init() {}
    }

    public var onChange: (@Sendable (Snapshot) -> Void)?
    public private(set) var snapshot = Snapshot()
    private let queue = DispatchQueue(label: "app.6axis.machine")
    private var transport: MachineTransport?
    private var poll: DispatchSourceTimer?
    private var streamer: GCodeStreamer?
    /// Commands sent outside a job, waiting for their "ok".
    private var commandAcks = 0
    private var afterProbe: [String] = []
    /// Z (work) of the probe plate's top surface during probing.
    private var plateThickness = 0.0

    public init() {}

    private func changed() {
        let s = snapshot
        onChange?(s)
    }

    private func log(_ line: String) {
        snapshot.log.append(line)
        if snapshot.log.count > 300 { snapshot.log.removeFirst(snapshot.log.count - 300) }
    }

    // MARK: Connection

    public func connect(_ t: MachineTransport) {
        queue.async { [self] in
            disconnectNow()
            transport = t
            t.onLine = { [weak self] line in self?.queue.async { self?.received(line) } }
            snapshot = Snapshot()
            snapshot.connected = true
            snapshot.portName = t.name
            // Wake the controller and ask for its banner.
            t.send([0x0A, 0x0A])
            t.send([GRBL.RealTime.softReset.rawValue])
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(150))
            timer.setEventHandler { [weak self] in self?.transport?.send([GRBL.RealTime.status.rawValue]) }
            timer.resume()
            poll = timer
            changed()
        }
    }

    public func disconnect() { queue.async { [self] in disconnectNow(); changed() } }

    private func disconnectNow() {
        poll?.cancel()
        poll = nil
        transport?.close()
        transport = nil
        streamer = nil
        commandAcks = 0
        snapshot.connected = false
        snapshot.jobRunning = false
    }

    // MARK: Incoming

    private func received(_ line: String) {
        let msg = GRBL.parse(line, previous: snapshot.status)
        if case .status = msg {} else { log(line) }
        switch msg {
        case let .status(s):
            snapshot.status = s
            if let st = streamer, st.isFinished, s.state == .idle, snapshot.jobRunning {
                snapshot.jobRunning = false
                snapshot.jobFinished = true
                snapshot.message = String(localized: "Programm fertig")
                streamer = nil
            }
        case .ok:
            if var st = streamer, !st.isFinished, commandAcks == 0 {
                st.acknowledge()
                snapshot.jobDone = st.acknowledged
                streamer = st
                pump()
            } else if commandAcks > 0 {
                commandAcks -= 1
            }
        case let .error(code):
            if var st = streamer, commandAcks == 0 {
                st.acknowledge(error: code)
                streamer = st
                // Stop at the first error: holding is safer than continuing with a skipped block.
                transport?.send([GRBL.RealTime.feedHold.rawValue])
                snapshot.message = String(localized: "Fehler in Zeile \(st.acknowledged): \(GRBL.errorText(code)) – Programm angehalten")
            } else {
                if commandAcks > 0 { commandAcks -= 1 }
                snapshot.message = GRBL.errorText(code)
            }
        case let .alarm(code):
            snapshot.alarm = code
            snapshot.message = GRBL.alarmText(code)
            snapshot.jobRunning = false
            streamer = nil
            afterProbe = []
        case let .welcome(text):
            snapshot.firmware = text
            snapshot.alarm = nil
            commandAcks = 0
        case let .probe(_, success):
            if success {
                for l in afterProbe { sendCommand(l) }
                snapshot.message = String(localized: "Z angetastet – Nullpunkt auf Plattenstärke \(formatValue(plateThickness)) gesetzt")
            }
            afterProbe = []
        case .feedback, .setting, .other:
            break
        }
        changed()
    }

    private func pump() {
        guard var st = streamer, let t = transport else { return }
        for l in st.linesToSend() { t.send(line: l) }
        streamer = st
    }

    // MARK: Commands (outside a job)

    private func sendCommand(_ line: String) {
        guard let t = transport else { return }
        commandAcks += 1
        log("> " + line)
        t.send(line: line)
    }

    private func command(_ lines: [String]) {
        queue.async { [self] in
            guard !snapshot.jobRunning else { return }
            for l in lines { sendCommand(l) }
            changed()
        }
    }

    /// Jog relative to the current position (mm).
    public func jog(_ delta: Vec3, feed: Double) {
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        var axes = ""
        if delta.x != 0 { axes += " X\(f(delta.x))" }
        if delta.y != 0 { axes += " Y\(f(delta.y))" }
        if delta.z != 0 { axes += " Z\(f(delta.z))" }
        guard !axes.isEmpty else { return }
        command(["$J=G91 G21\(axes) F\(Int(feed))"])
    }

    public func stopJog() { queue.async { [self] in transport?.send([GRBL.RealTime.jogCancel.rawValue]) } }
    public func home() { command(["$H"]); queue.async { [self] in snapshot.homed = true } }
    /// Clears an alarm; absolute mode again in case a probing move was interrupted.
    public func unlock() { command(["$X", "G90"]); queue.async { [self] in snapshot.alarm = nil; snapshot.message = nil; changed() } }

    /// Sets the work zero of the given axes at the current position.
    public func zero(x: Bool, y: Bool, z: Bool) {
        var axes = ""
        if x { axes += " X0" }
        if y { axes += " Y0" }
        if z { axes += " Z0" }
        guard !axes.isEmpty else { return }
        command(["G10 L20 P1\(axes)"])
    }

    /// Probes Z down onto a touch plate of `thickness`; on contact Z is zeroed on the workpiece and the tool lifts.
    public func probeZ(thickness: Double, travel: Double = 40, feed: Double = 100) {
        queue.async { [self] in
            guard !snapshot.jobRunning else { return }
            plateThickness = thickness
            // Relative probing move (G91 in the same block); absolute mode again afterwards.
            afterProbe = ["G10 L20 P1 Z\(String(format: "%.3f", thickness))", "G0 Z5", "G90"]
            sendCommand("G38.2 G91 Z-\(String(format: "%.1f", travel)) F\(Int(feed))")
            changed()
        }
    }

    /// Moves to a work position (nil = keep that axis). Down: X/Y first, then Z; up: Z first – never
    /// diagonally into the workpiece.
    public func moveTo(x: Double?, y: Double?, z: Double?, currentZ: Double) {
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        var xy = ""
        if let x { xy += " X\(f(x))" }
        if let y { xy += " Y\(f(y))" }
        var lines: [String] = []
        if let z, z >= currentZ { lines.append("G90 G0 Z\(f(z))") }
        if !xy.isEmpty { lines.append("G90 G0" + xy) }
        if let z, z < currentZ { lines.append("G90 G0 Z\(f(z))") }
        command(lines)
    }

    /// Up first (machine coordinates), then over the park position.
    public func park(x: Double, y: Double, safeZ: Double = -2) {
        command(["G53 G0 Z\(safeZ)", "G53 G0 X\(x) Y\(y)"])
    }

    public func spindle(on: Bool, rpm: Double) { command([on ? "M3 S\(Int(rpm))" : "M5"]) }

    // MARK: Jobs

    public func run(program: String, fromLine: Int = 0) {
        queue.async { [self] in
            guard transport != nil, !snapshot.jobRunning else { return }
            var st = GCodeStreamer(program: program)
            st.restart(at: fromLine)
            streamer = st
            snapshot.jobLines = st.lines.count
            snapshot.jobDone = fromLine
            snapshot.jobRunning = true
            snapshot.jobFinished = false
            snapshot.message = nil
            commandAcks = 0
            pump()
            changed()
        }
    }

    public func pause() { queue.async { [self] in transport?.send([GRBL.RealTime.feedHold.rawValue]) } }

    public func resume() {
        queue.async { [self] in
            transport?.send([GRBL.RealTime.cycleStart.rawValue])
            if snapshot.message?.hasPrefix(String(localized: "Fehler in Zeile")) == true { snapshot.message = nil }
            changed()
        }
    }

    /// Immediate stop: feed hold, then soft reset (clears the controller's buffers).
    public func stop() {
        queue.async { [self] in
            guard let t = transport else { return }
            t.send([GRBL.RealTime.feedHold.rawValue])
            t.send([GRBL.RealTime.softReset.rawValue])
            streamer = nil
            commandAcks = 0
            afterProbe = []
            snapshot.jobRunning = false
            snapshot.message = String(localized: "Gestoppt")
            changed()
        }
    }

    public func override(feed: GRBL.RealTime) { queue.async { [self] in transport?.send([feed.rawValue]) } }
}
