import XCTest
import simd
@testable import SixAxisCore

final class ExpressionTests: XCTestCase {
    func testArithmeticAndUnits() throws {
        let ev = Evaluator()
        XCTAssertEqual(try ev.value("10"), 10)
        XCTAssertEqual(try ev.value("2,5 cm"), 25, accuracy: 1e-12)
        XCTAssertEqual(try ev.value("1 in + 0.6 mm"), 26, accuracy: 1e-12)
        XCTAssertEqual(try ev.value("(2 + 3) * 4 ^ 2"), 80)
        XCTAssertEqual(try ev.value("-3 + max(1; 5)"), 2)
        XCTAssertEqual(try ev.value("90°", kind: .angle), 90)
        XCTAssertEqual(try ev.value("pi rad", kind: .angle), 180, accuracy: 1e-12)
        XCTAssertThrowsError(try ev.value("2 +"))
        XCTAssertThrowsError(try ev.value("1/0"))
    }

    func testParameters() throws {
        let ev = Evaluator(parameters: [
            UserParameter(name: "breite", expression: "40 mm"),
            UserParameter(name: "wand", expression: "breite / 20"),
            UserParameter(name: "a", expression: "b"),
            UserParameter(name: "b", expression: "a"),
        ])
        XCTAssertEqual(try ev.value("breite - 2 * wand"), 36)
        XCTAssertThrowsError(try ev.value("a"))
        XCTAssertThrowsError(try ev.value("unbekannt"))
    }
}

final class SolverTests: XCTestCase {
    func rectangle() -> (Sketch, [Int], [Int]) {
        var s = Sketch(plane: .xy)
        let p = [s.addPoint(Vec2(1, 1)), s.addPoint(Vec2(31, 2)), s.addPoint(Vec2(29, 18)), s.addPoint(Vec2(2, 21))]
        let l = (0..<4).map { s.addLine(p[$0], p[($0 + 1) % 4]) }
        s.addConstraint(.horizontal(line: l[0]))
        s.addConstraint(.horizontal(line: l[2]))
        s.addConstraint(.vertical(line: l[1]))
        s.addConstraint(.vertical(line: l[3]))
        return (s, p, l)
    }

    func testRectangleFullyConstrained() {
        var (s, p, l) = rectangle()
        s.addConstraint(.coincident(p[0], Sketch.originId))
        s.addConstraint(.length(line: l[0], value: "40"))
        s.addConstraint(.length(line: l[1], value: "breite / 2"))
        let solver = SketchSolver(evaluator: Evaluator(parameters: [UserParameter(name: "breite", expression: "50")]))
        let r = solver.solve(&s)
        XCTAssertTrue(r.converged)
        XCTAssertEqual(r.degreesOfFreedom, 0)
        XCTAssertTrue(r.isFullyConstrained)
        XCTAssertEqual(s.point(p[2])!.x, 40, accuracy: 1e-6)
        XCTAssertEqual(s.point(p[2])!.y, 25, accuracy: 1e-6)
    }

    func testUnderconstrainedDof() {
        var (s, _, _) = rectangle()
        let r = SketchSolver().solve(&s)
        XCTAssertTrue(r.converged)
        XCTAssertEqual(r.degreesOfFreedom, 4)
    }

    func testConflictDetected() {
        var (s, _, l) = rectangle()
        s.addConstraint(.perpendicular(l[0], l[2]))
        let r = SketchSolver().solve(&s)
        XCTAssertFalse(r.converged)
    }

    func testDragKeepsConstraints() {
        var (s, p, _) = rectangle()
        SketchSolver().solve(&s)
        SketchSolver().drag(&s, points: [p[2]: Vec2(50, 40)])
        XCTAssertEqual(s.point(p[2])!.x, 50, accuracy: 1e-6)
        XCTAssertEqual(s.point(p[1])!.x, 50, accuracy: 1e-6)
        XCTAssertEqual(s.point(p[3])!.y, 40, accuracy: 1e-6)
    }

    func testTangentCircle() {
        var s = Sketch(plane: .xy)
        let a = s.addPoint(Vec2(0, 0)), b = s.addPoint(Vec2(50, 0))
        let line = s.addLine(a, b)
        let c = s.addPoint(Vec2(20, 12))
        let circle = s.addCircle(center: c, radius: 5)
        s.addConstraint(.tangent(line, circle))
        s.addConstraint(.radius(curve: circle, value: "8"))
        let r = SketchSolver().solve(&s)
        XCTAssertTrue(r.converged)
        let pa = s.point(a)!, d = simd_normalize(s.point(b)! - pa), v = s.point(c)! - pa
        XCTAssertEqual(abs(d.x * v.y - d.y * v.x), 8, accuracy: 1e-5)
    }
}

final class KernelTests: XCTestCase {
    func boxDocument(height: String = "10 mm") -> (CADDocument, UUID) {
        var doc = CADDocument()
        var sk = Sketch(plane: .xy)
        let p = [sk.addPoint(Vec2(0, 0)), sk.addPoint(Vec2(40, 0)), sk.addPoint(Vec2(40, 20)), sk.addPoint(Vec2(0, 20))]
        for i in 0..<4 { sk.addLine(p[i], p[(i + 1) % 4]) }
        let c = sk.addPoint(Vec2(20, 10))
        sk.addCircle(center: c, radius: 5)
        let sketch = Feature(name: "Skizze1", kind: .sketch(sk))
        var ex = ExtrudeFeature()
        ex.profiles = [ProfileRef(sketch: sketch.id, sample: Vec2(5, 5))]
        ex.distance = height
        let extrude = Feature(name: "Extrusion1", kind: .extrude(ex))
        doc.features = [sketch, extrude]
        return (doc, extrude.id)
    }

    func testRegionsAndExtrude() throws {
        let (doc, ex) = boxDocument()
        let state = ModelBuilder().build(doc)
        XCTAssertTrue(state.errors.isEmpty, "\(state.errors)")
        let sb = try XCTUnwrap(state.sketches[doc.features[0].id])
        XCTAssertEqual(sb.regions.count, 2, "rectangle with hole + disc")
        let body = try XCTUnwrap(state.bodies[ex])
        XCTAssertEqual(body.shape.volume, (800 - .pi * 25) * 10, accuracy: 0.01)
        let mesh = try XCTUnwrap(body.mesh)
        XCTAssertGreaterThan(mesh.indices.count, 0)
        XCTAssertGreaterThan(mesh.edgeSegments.count, 0)
    }

    func testParametricRebuildAndFillet() throws {
        var (doc, ex) = boxDocument(height: "h")
        doc.parameters = [UserParameter(name: "h", expression: "5")]
        let builder = ModelBuilder()
        var state = builder.build(doc)
        XCTAssertEqual(state.bodies[ex]!.shape.volume, (800 - .pi * 25) * 5, accuracy: 0.01)

        // Fillet a vertical outer edge.
        let body = state.bodies[ex]!
        let idx = try XCTUnwrap(body.edgeInfos.firstIndex { e in
            guard let e else { return false }
            return e.kind == .line && abs(e.midpoint.x - 40) < 1e-6 && abs(e.midpoint.y - 20) < 1e-6
        })
        var fillet = FilletFeature()
        fillet.edges = [BodyEdgeRef(body: ex, edge: body.edgeRef(idx)!)]
        fillet.radius = "2"
        doc.features.append(Feature(name: "Abrundung1", kind: .fillet(fillet)))
        state = builder.build(doc)
        XCTAssertNil(state.errors.values.first)
        XCTAssertLessThan(state.bodies[ex]!.shape.volume, (800 - .pi * 25) * 5)

        // Changing the parameter re-resolves the edge reference by geometry.
        doc.parameters[0].expression = "12"
        state = builder.build(doc)
        XCTAssertTrue(state.errors.isEmpty, "\(state.errors)")
        XCTAssertGreaterThan(state.bodies[ex]!.shape.volume, 8000)
    }

    func testCutAndExport() throws {
        var (doc, ex) = boxDocument()
        var sk = Sketch(plane: .face(BodyFaceRef(body: ex, face: FaceRef(index: 0, centroid: Vec3(20, 10, 10), normal: Vec3(0, 0, 1)))))
        let c = sk.addPoint(Vec2(5, 5))
        sk.addCircle(center: c, radius: 2)
        let sketch = Feature(name: "Skizze2", kind: .sketch(sk))
        var cut = ExtrudeFeature()
        cut.profiles = [ProfileRef(sketch: sketch.id, sample: Vec2(5, 5))]
        cut.distance = "-4"
        cut.operation = .cut
        doc.features += [sketch, Feature(name: "Extrusion2", kind: .extrude(cut))]
        let state = ModelBuilder().build(doc)
        XCTAssertTrue(state.errors.isEmpty, "\(state.errors)")
        let v = state.bodies[ex]!.shape.volume
        XCTAssertEqual(v, (800 - .pi * 25) * 10 - .pi * 4 * 4, accuracy: 0.05)

        let dir = FileManager.default.temporaryDirectory
        try state.bodies[ex]!.shape.writeSTL(to: dir.appendingPathComponent("6axis-test.stl"))
        try state.bodies[ex]!.shape.writeSTEP(to: dir.appendingPathComponent("6axis-test.step"))
        let re = try Shape.readSTEP(from: dir.appendingPathComponent("6axis-test.step"))
        XCTAssertEqual(re.volume, v, accuracy: 0.05)
    }

    func testDocumentRoundTrip() throws {
        let (doc, _) = boxDocument()
        let data = try doc.encoded()
        XCTAssertEqual(try CADDocument.decode(data), doc)
    }
}
