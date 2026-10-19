import XCTest
import simd
@testable import SixAxisCore

final class CAMTests: XCTestCase {
    /// Plate 100 × 60 × 19 at the origin, optional pocket 40 × 30 × 5 and four Ø5 × 10 holes.
    func plate(pocket: Bool = false, holes: Bool = false) -> (CADDocument, UUID, ModelState) {
        var doc = CADDocument()
        var sk = Sketch(plane: .xy)
        let c = [sk.addPoint(Vec2(0, 0)), sk.addPoint(Vec2(100, 0)), sk.addPoint(Vec2(100, 60)), sk.addPoint(Vec2(0, 60))]
        for i in 0..<4 { sk.addLine(c[i], c[(i + 1) % 4]) }
        let s = Feature(name: "S", kind: .sketch(sk))
        var ex = ExtrudeFeature()
        ex.profiles = [ProfileRef(sketch: s.id, sample: Vec2(50, 30))]
        ex.distance = "19 mm"
        let e = Feature(name: "Platte", kind: .extrude(ex))
        doc.features = [s, e]
        var state = ModelBuilder().build(doc)
        let top = state.bodies[e.id]!.faceInfos.compactMap { $0 }.max { $0.centroid.z < $1.centroid.z }!.index
        let topRef = BodyFaceRef(body: e.id, face: state.bodies[e.id]!.faceRef(top)!)
        if pocket {
            var p = Sketch(plane: .face(topRef))
            let q = [p.addPoint(Vec2(10, 10)), p.addPoint(Vec2(50, 10)), p.addPoint(Vec2(50, 40)), p.addPoint(Vec2(10, 40))]
            for i in 0..<4 { p.addLine(q[i], q[(i + 1) % 4]) }
            let ps = Feature(name: "P", kind: .sketch(p))
            var cut = ExtrudeFeature()
            cut.profiles = [ProfileRef(sketch: ps.id, sample: Vec2(30, 25))]
            cut.distance = "-5 mm"
            cut.operation = .cut
            doc.features += [ps, Feature(name: "Tasche", kind: .extrude(cut))]
        }
        if holes {
            var h = HoleFeature()
            h.points = [Vec3(70, 15, 19), Vec3(90, 15, 19), Vec3(70, 45, 19), Vec3(90, 45, 19)].map { .face(topRef, position: $0) }
            h.diameter = "5 mm"
            h.depth = "10 mm"
            doc.features.append(Feature(name: "B", kind: .hole(h)))
        }
        state = ModelBuilder().build(doc)
        XCTAssertTrue(state.errors.isEmpty, "\(state.errors)")
        return (doc, e.id, state)
    }

    func face(_ state: ModelState, _ body: UUID, z: Double) -> BodyFaceRef {
        let b = state.bodies[body]!
        let i = b.faceInfos.compactMap { $0 }.first { $0.isPlanar && $0.normal.z > 0.999 && abs($0.origin.z - z) < 1e-6 }!.index
        return BodyFaceRef(body: body, face: b.faceRef(i)!)
    }

    func setup(_ op: CAMOperation, toolNumber: Int) -> CAMSetup {
        var s = CAMSetup()
        var o = op
        o.tool = s.tools.first { $0.number == toolNumber }!.id
        s.operations = [o]
        return s
    }

    /// Distance of a point from the rectangle 0…100 × 0…60 (outside), in XY.
    func outsideDistance(_ p: Vec3) -> Double {
        let dx = max(0 - p.x, 0, p.x - 100), dy = max(0 - p.y, 0, p.y - 60)
        return simd_length(Vec2(dx, dy))
    }

    func testOutsideContourWithTabs() {
        let (doc, body, state) = plate()
        var op = CAMOperation(name: "Kontur", kind: .contour)
        op.faces = [face(state, body, z: 19)]
        let s = setup(op, toolNumber: 2)   // Ø6, stepdown 3
        let r = CAMPlanner.plan(s, state: state, evaluator: Evaluator(parameters: doc.parameters), bodies: [body])
        XCTAssertEqual(r.paths.count, 1)
        let moves = r.paths[0].moves
        let bottom = moves.map(\.to.z).min()!
        XCTAssertEqual(bottom, -0.3, accuracy: 1e-6, "through the part plus overcut")
        // Every cutting point lies on the offset path: 3 mm outside the plate.
        for m in moves where m.kind != .rapid && m.to.z < 18.99 {
            XCTAssertEqual(outsideDistance(m.to), 3, accuracy: 0.02, "\(m.to)")
        }
        // Seven passes for 19.3 mm at 3 mm stepdown.
        let depths = Set(moves.filter { $0.kind == .feed }.map { ($0.to.z * 1000).rounded() / 1000 })
        XCTAssertTrue(depths.contains(-0.3))
        // Four tabs: on the last pass some points stay at the tab top (bottom of part + 3 mm).
        let tabTop = 3.0
        XCTAssertTrue(moves.contains { $0.kind == .feed && abs($0.to.z - tabTop) < 1e-6 }, "tabs lift the cutter")
        XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)")
        // Climb milling outside = clockwise from above.
        let last = moves.filter { $0.kind == .feed && abs($0.to.z + 0.3) < 1e-6 }.map(\.to)
        XCTAssertLessThan(CAMPlanner.signedArea(last + [last[0]]), 0)
    }

    func testPocketStaysInside() {
        let (doc, body, state) = plate(pocket: true)
        var op = CAMOperation(name: "Tasche", kind: .pocket)
        op.faces = [face(state, body, z: 14)]
        let r = CAMPlanner.plan(setup(op, toolNumber: 2), state: state, evaluator: Evaluator(parameters: doc.parameters), bodies: [body])
        let cuts = r.paths[0].moves.filter { $0.kind != .rapid && $0.to.z < 19 }
        XCTAssertFalse(cuts.isEmpty)
        for m in cuts {
            XCTAssertGreaterThanOrEqual(m.to.x, 10 + 3 - 0.02)
            XCTAssertLessThanOrEqual(m.to.x, 50 - 3 + 0.02)
            XCTAssertGreaterThanOrEqual(m.to.y, 10 + 3 - 0.02)
            XCTAssertLessThanOrEqual(m.to.y, 40 - 3 + 0.02)
        }
        XCTAssertEqual(cuts.map(\.to.z).min()!, 14, accuracy: 1e-6)
        // The tool reaches into the corner region of the pocket (finishing ring at offset 3).
        XCTAssertTrue(cuts.contains { abs($0.to.x - 13) < 0.05 && abs($0.to.y - 20) < 10 })
    }

    func testDrillingAndGCode() {
        let (doc, body, state) = plate(holes: true)
        var op = CAMOperation(name: "Bohren", kind: .drill)
        op.faces = [face(state, body, z: 19)]
        var s = setup(op, toolNumber: 4)   // drill Ø5
        let r = CAMPlanner.plan(s, state: state, evaluator: Evaluator(parameters: doc.parameters), bodies: [body])
        XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)")
        let bottoms = r.paths[0].moves.filter { abs($0.to.z - 9) < 1e-6 }
        XCTAssertEqual(Set(bottoms.map { "\(Int($0.to.x)),\(Int($0.to.y))" }).count, 4, "all four holes to 10 mm depth")
        let g = GCodeWriter.write(r, setup: s, title: "Platte")
        XCTAssertTrue(g.contains("G21 G90 G17 G94"))
        XCTAssertTrue(g.contains("M3 S6000"))
        XCTAssertFalse(g.contains("M6"), "GRBL has no tool changer")
        XCTAssertTrue(g.hasSuffix("M30\n"))
        XCTAssertTrue(g.unicodeScalars.allSatisfy(\.isASCII), "plain ASCII for every controller")
        // Origin front left top of the stock (margin 10): hole at x = 70 → X80, depth Z-10.
        XCTAssertTrue(g.contains("X80 Y25 Z-10"), g)
        s.post = .linuxcnc
        XCTAssertTrue(GCodeWriter.write(r, setup: s, title: "Platte").contains("T4 M6"))
    }

    func testWarnsWhenCutIsDeeperThanTheFlutes() {
        let (doc, body, state) = plate()
        var op = CAMOperation(name: "Kontur", kind: .contour)
        op.faces = [face(state, body, z: 19)]
        let r = CAMPlanner.plan(setup(op, toolNumber: 1), state: state, evaluator: Evaluator(parameters: doc.parameters), bodies: [body])
        XCTAssertTrue(r.warnings.contains { $0.contains("Schneidenlänge") }, "\(r.warnings)")
        XCTAssertGreaterThan(r.time(), 0)
    }
}

final class CAMFormatTests: XCTestCase {
    func testSetupRoundTripAndOlderFiles() throws {
        var doc = CADDocument()
        var s = CAMSetup()
        var op = CAMOperation(name: "Kontur1", kind: .contour)
        op.tool = s.tools[1].id
        s.operations = [op]
        doc.cam = s
        let back = try CADDocument.decode(try doc.encoded())
        XCTAssertEqual(back.cam, s)
        XCTAssertGreaterThanOrEqual(CADDocument.currentFormatVersion, 7)
        XCTAssertNil(try CADDocument.decode(try CADDocument().encoded()).cam, "no setup until the user starts milling")
    }
}
