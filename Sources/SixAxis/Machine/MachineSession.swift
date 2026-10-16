import AppKit
import Foundation
import GameController
import simd
import SixAxisCore

/// App-side state of the machine connection (main thread), fed by the controller's snapshots.
@MainActor @Observable
final class MachineSession {
    static let shared = MachineSession()

    private(set) var snapshot = MachineController.Snapshot()
    var ports: [String] = []
    /// "" = simulator.
    var selectedPort = ""
    var jogStep: Double = 1
    var jogFeed: Double = 2000
    var plateThickness: Double = 12
    /// Target for "Anfahren" (work coordinates, as typed; empty = keep axis).
    var gotoX = ""
    var gotoY = ""
    var gotoZ = ""

    func goTo() {
        func v(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }
        guard connected, !running else { return }
        controller.moveTo(x: v(gotoX), y: v(gotoY), z: v(gotoZ), currentZ: snapshot.status.work.z)
    }
    /// Loaded program (from the milling workspace or a file) and its name.
    private(set) var program: String?
    private(set) var programName = ""
    private(set) var programSeconds: Double = 0
    var confirmStart = false
    var showSafetyNotice = false

    @ObservationIgnored let controller = MachineController()
    @ObservationIgnored private var gamepadTimer: Timer?

    private init() {
        controller.onChange = { [weak self] s in
            DispatchQueue.main.async { self?.snapshot = s }
        }
        refreshPorts()
        observeGamepads()
    }

    var connected: Bool { snapshot.connected }
    var running: Bool { snapshot.jobRunning }
    var state: GRBL.State { snapshot.status.state }

    func refreshPorts() { ports = SerialPort.available() }

    func connect() {
        do {
            if selectedPort.isEmpty {
                controller.connect(GRBLSimulator(timeScale: Editor.isAutomatedRun ? 20 : 1))
            } else {
                controller.connect(try SerialPort(path: selectedPort))
                if !UserDefaults.standard.bool(forKey: "machine.safetyNoticeShown") { showSafetyNotice = true }
            }
        } catch {
            snapshot.message = error.localizedDescription
        }
    }

    func disconnect() { controller.disconnect() }

    func jog(_ dx: Double, _ dy: Double, _ dz: Double) {
        guard connected, !running else { return }
        controller.jog(Vec3(dx, dy, dz) * jogStep, feed: jogFeed)
    }

    // MARK: Programs

    func load(_ text: String, name: String, seconds: Double) {
        program = text
        programName = name
        programSeconds = seconds
        snapshot.jobFinished = false
    }

    func loadFromMilling(_ editor: Editor) {
        guard let setup = editor.doc.cam else { return }
        let r = CAMPlanner.plan(setup, state: editor.state, evaluator: editor.evaluator,
                                bodies: editor.state.bodyOrder.filter { editor.doc.isBodyVisible($0) })
        guard !r.paths.isEmpty else {
            snapshot.message = String(localized: "Keine Fräsbahnen – erst im Arbeitsbereich „Fräsen“ Bearbeitungen anlegen")
            return
        }
        let title = editor.fileURL?.deletingPathExtension().lastPathComponent ?? String(localized: "Unbenannt")
        load(GCodeWriter.write(r, setup: setup, title: title), name: title, seconds: r.time())
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["nc", "gcode", "ngc", "tap", "txt"].compactMap { .init(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        load(text, name: url.lastPathComponent, seconds: 0)
    }

    func start() {
        guard let program, connected else { return }
        controller.run(program: program)
    }

    /// Remaining time from the progress (when the program's run time is known).
    var remaining: Double? {
        guard programSeconds > 0, snapshot.jobLines > 0 else { return nil }
        return programSeconds * (1 - Double(snapshot.jobDone) / Double(snapshot.jobLines))
    }

    // MARK: Gamepad (GameController.framework): left stick X/Y, right stick or shoulders Z

    private func observeGamepads() {
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startGamepadTimer() }
        }
        if !GCController.controllers().isEmpty { startGamepadTimer() }
    }

    private func startGamepadTimer() {
        guard gamepadTimer == nil else { return }
        gamepadTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollGamepad() }
        }
    }

    private var stickActive = false

    private func pollGamepad() {
        guard connected, !running, let pad = GCController.controllers().first?.extendedGamepad else { return }
        let x = Double(pad.leftThumbstick.xAxis.value), y = Double(pad.leftThumbstick.yAxis.value)
        var z = Double(pad.rightThumbstick.yAxis.value)
        if pad.rightShoulder.isPressed { z = 1 }
        if pad.leftShoulder.isPressed { z = -1 }
        let v = Vec3(abs(x) > 0.15 ? x : 0, abs(y) > 0.15 ? y : 0, abs(z) > 0.15 ? z : 0)
        if simd_length(v) > 0 {
            // Short continuous jogs: distance for 0.1 s at the deflection's share of the jog speed.
            let feed = jogFeed * max(abs(v.x), abs(v.y), abs(v.z))
            controller.jog(simd_normalize(v) * feed / 60 * 0.12, feed: max(feed, 50))
            stickActive = true
        } else if stickActive {
            controller.stopJog()
            stickActive = false
        }
    }
}
