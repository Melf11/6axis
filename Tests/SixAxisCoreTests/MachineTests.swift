import XCTest
import simd
@testable import SixAxisCore

final class MachineTests: XCTestCase {
    func testParsesControllerMessages() {
        XCTAssertEqual(GRBL.parse("ok"), .ok)
        XCTAssertEqual(GRBL.parse("error:22"), .error(22))
        XCTAssertEqual(GRBL.parse("ALARM:1"), .alarm(1))
        guard case let .status(s) = GRBL.parse("<Run|MPos:10.000,-5.500,-2.000|FS:1500,18000|WCO:5.000,0.000,-10.000|Ov:110,100,90>") else {
            return XCTFail("status")
        }
        XCTAssertEqual(s.state, .run)
        XCTAssertEqual(s.work, Vec3(5, -5.5, 8))
        XCTAssertEqual(s.feed, 1500)
        XCTAssertEqual(s.overrides, SIMD3(110, 100, 90))
        // Without WCO the previous offset stays.
        guard case let .status(t) = GRBL.parse("<Hold:0|MPos:0.000,0.000,0.000|FS:0,0>", previous: s) else { return XCTFail("status") }
        XCTAssertEqual(t.state, .hold)
        XCTAssertEqual(t.workOffset, Vec3(5, 0, -10))
        XCTAssertEqual(GRBL.parse("[PRB:1.000,2.000,-40.000:1]"), .probe(Vec3(1, 2, -40), true))
    }

    func testStreamerNeverOverfillsTheBuffer() {
        let program = (0..<200).map { "G1 X\($0).123 Y\($0 * 2).456 Z-1.000 F1500 (cut)" }.joined(separator: "\n")
        var st = GCodeStreamer(program: program)
        XCTAssertEqual(st.lines.count, 200)
        XCTAssertFalse(st.lines[0].contains("("), "comments stripped")
        var sent = st.linesToSend()
        XCTAssertLessThanOrEqual(sent.reduce(0) { $0 + $1.utf8.count + 1 }, GRBL.rxBuffer)
        XCTAssertGreaterThan(sent.count, 1)
        while !st.isFinished {
            st.acknowledge()
            sent = st.linesToSend()
        }
        XCTAssertEqual(st.progress, 1)
    }

    // MARK: Controller against the simulator

    func wait(_ m: MachineController, _ what: String, timeout: Double = 10, _ cond: (MachineController.Snapshot) -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond(m.snapshot) && Date() < end { usleep(10_000) }
        XCTAssertTrue(cond(m.snapshot), "\(what): \(m.snapshot.status) \(m.snapshot.message ?? "") \(m.snapshot.log.suffix(5))")
    }

    func connected(timeScale: Double = 60) -> (MachineController, GRBLSimulator) {
        let m = MachineController(), sim = GRBLSimulator(timeScale: timeScale)
        m.connect(sim)
        wait(m, "banner") { $0.firmware.hasPrefix("Grbl") && $0.status.state == .idle }
        return (m, sim)
    }

    func testHomeJogZeroProbePark() {
        let (m, sim) = connected()
        m.home()
        wait(m, "homed") { $0.status.state == .idle && simd_length($0.status.machine) < 1e-6 && $0.homed }
        m.jog(Vec3(-100, -50, -10), feed: 3000)
        wait(m, "jogged") { $0.status.state == .idle && abs($0.status.machine.x + 100) < 1e-6 }
        m.zero(x: true, y: true, z: false)
        wait(m, "zeroed XY") { abs($0.status.work.x) < 1e-6 && abs($0.status.work.y) < 1e-6 && abs($0.status.work.z + 10) < 1e-6 }
        sim.probeSurface = -40
        m.probeZ(thickness: 12)
        // Contact at machine Z -40: work Z there = 12 (plate), then 5 mm up.
        wait(m, "probed") { $0.status.state == .idle && abs($0.status.work.z - 17) < 1e-3 && abs($0.status.machine.z + 35) < 1e-3 }
        // Move to a work position: up first, then over.
        m.moveTo(x: 20, y: 5, z: 25, currentZ: m.snapshot.status.work.z)
        wait(m, "moved to") { $0.status.state == .idle && abs($0.status.work.x - 20) < 1e-6 && abs($0.status.work.z - 25) < 1e-6 }
        XCTAssertTrue(sim.executed.suffix(2).first?.contains("Z") == true, "Z first when going up")
        m.park(x: -10, y: -10)
        wait(m, "parked") { $0.status.state == .idle && abs($0.status.machine.x + 10) < 1e-6 && abs($0.status.machine.z + 2) < 1e-6 }
        m.disconnect()
    }

    func testRunsAJobWithPauseAndStop() {
        let (m, sim) = connected(timeScale: 30)
        let program = "G21 G90\nM3 S10000\n" + (0..<60).map { "G1 X\($0 % 2 == 0 ? 50 : 0) Y\($0) F3000" }.joined(separator: "\n") + "\nM5\nM30"
        m.run(program: program)
        wait(m, "running") { $0.jobRunning && $0.status.state == .run }
        m.pause()
        wait(m, "held") { $0.status.state == .hold }
        let done = m.snapshot.jobDone
        usleep(300_000)
        XCTAssertLessThanOrEqual(abs(m.snapshot.jobDone - done), 15, "only the planner fills while holding")
        m.resume()
        wait(m, "finished", timeout: 30) { $0.jobFinished && !$0.jobRunning }
        XCTAssertEqual(m.snapshot.jobDone, m.snapshot.jobLines)
        XCTAssertEqual(sim.executed.filter { $0.hasPrefix("G1") }.count, 60, "every line reached the controller once")

        // Stop during a job: buffers cleared, alarm until unlocked.
        m.run(program: program)
        wait(m, "running again") { $0.status.state == .run }
        m.stop()
        wait(m, "stopped") { !$0.jobRunning && $0.alarm == 3 }
        m.unlock()
        wait(m, "unlocked") { $0.status.state == .idle && $0.alarm == nil }
        m.disconnect()
    }

    func testCAMProgramRunsOnTheSimulator() {
        let t = CAMTests()
        let (doc, body, state) = t.plate(holes: true)
        var op = CAMOperation(name: "Bohren", kind: .drill)
        op.faces = [t.face(state, body, z: 19)]
        let setup = t.setup(op, toolNumber: 4)
        let r = CAMPlanner.plan(setup, state: state, evaluator: Evaluator(parameters: doc.parameters), bodies: [body])
        let g = GCodeWriter.write(r, setup: setup, title: "Test")
        let (m, sim) = connected(timeScale: 200)
        m.run(program: g)
        wait(m, "6axis program finished", timeout: 30) { $0.jobFinished }
        XCTAssertNil(m.snapshot.message.flatMap { $0.contains("Fehler") ? $0 : nil }, "no controller errors")
        XCTAssertTrue(sim.executed.contains("M30"))
        m.disconnect()
    }
}
