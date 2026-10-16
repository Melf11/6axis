import XCTest
import simd
@testable import SixAxisCore

/// 1.2 "Modellieren": construction geometry, holes, threads, patterns, moving and combining bodies.
final class ModellingTests: XCTestCase {
    /// Rectangle sketch on `plane` (corner at the origin), extruded by `height`.
    func box(_ doc: inout CADDocument, w: Double = 100, d: Double = 60, height: Double = 20, plane: PlaneRef = .xy,
             at origin: Vec2 = .zero) -> UUID {
        var sk = Sketch(plane: plane)
        let p = [sk.addPoint(origin), sk.addPoint(origin + Vec2(w, 0)), sk.addPoint(origin + Vec2(w, d)), sk.addPoint(origin + Vec2(0, d))]
        for i in 0..<4 { sk.addLine(p[i], p[(i + 1) % 4]) }
        let s = Feature(name: "S", kind: .sketch(sk))
        doc.features.append(s)
        var ex = ExtrudeFeature()
        ex.profiles = [ProfileRef(sketch: s.id, sample: origin + Vec2(w / 2, d / 2))]
        ex.distance = "\(height) mm"
        let e = Feature(name: "E", kind: .extrude(ex))
        doc.features.append(e)
        return e.id
    }

    func build(_ doc: CADDocument, file: StaticString = #filePath, line: UInt = #line) -> ModelState {
        let state = ModelBuilder().build(doc)
        XCTAssertTrue(state.errors.isEmpty, "\(state.errors.values)", file: file, line: line)
        return state
    }

    /// Top face (z = height) of a body as a reference.
    func topFace(_ state: ModelState, _ body: UUID) -> BodyFaceRef {
        let b = state.bodies[body]!
        let i = b.faceInfos.compactMap { $0 }.max { $0.centroid.z < $1.centroid.z }!.index
        return BodyFaceRef(body: body, face: b.faceRef(i)!)
    }

    // MARK: Construction geometry

    func testOffsetPlaneCarriesASketch() {
        var doc = CADDocument()
        var cp = ConstructionPlaneFeature()
        cp.plane = .xy
        cp.distance = "35 mm"
        let plane = Feature(name: "Ebene", kind: .plane(cp))
        doc.features.append(plane)
        _ = box(&doc, height: 10, plane: .construction(plane.id))
        let state = build(doc)
        let bb = state.orderedBodies[0].shape.boundingBox!
        XCTAssertEqual(bb.min.z, 35, accuracy: 1e-6)
        XCTAssertEqual(bb.max.z, 45, accuracy: 1e-6)
    }

    func testAngleAndMidplaneAndAxis() throws {
        var doc = CADDocument()
        let body = box(&doc, height: 40)
        var state = build(doc)
        // Midplane between bottom and top face.
        var mid = ConstructionPlaneFeature()
        mid.mode = .midplane
        mid.plane = .xy
        mid.plane2 = .face(topFace(state, body))
        let m = Feature(name: "Mitte", kind: .plane(mid))
        // 90° about the X axis turns XY into a plane with normal ±Y.
        var ang = ConstructionPlaneFeature()
        ang.mode = .angle
        ang.plane = .xy
        ang.axis = .x
        ang.angle = "90"
        let a = Feature(name: "Winkel", kind: .plane(ang))
        var ax = ConstructionAxisFeature()
        ax.mode = .twoPlanes
        ax.plane = .construction(m.id)
        ax.plane2 = .yz
        let axis = Feature(name: "Achse", kind: .axis(ax))
        doc.features += [m, a, axis]
        state = build(doc)
        XCTAssertEqual(state.planes[m.id]!.origin.z, 20, accuracy: 1e-6)
        XCTAssertEqual(abs(state.planes[a.id]!.normal.y), 1, accuracy: 1e-9)
        let line = state.axes[axis.id]!
        XCTAssertEqual(abs(line.direction.y), 1, accuracy: 1e-9)
        XCTAssertEqual(line.origin.z, 20, accuracy: 1e-6)
        XCTAssertEqual(line.origin.x, 0, accuracy: 1e-6)
    }

    // MARK: Holes

    func holeDoc(_ configure: (inout HoleFeature) -> Void) -> (CADDocument, UUID, ModelState) {
        var doc = CADDocument()
        let body = box(&doc)
        let state = build(doc)
        var h = HoleFeature()
        h.points = [.face(topFace(state, body), position: Vec3(50, 30, 20))]
        configure(&h)
        doc.features.append(Feature(name: "B", kind: .hole(h)))
        return (doc, body, build(doc))
    }

    func testThroughHoleRemovesCylinder() {
        let (_, body, state) = holeDoc { h in
            h.extent = .through
            h.diameter = "10 mm"
        }
        XCTAssertEqual(state.bodies[body]!.shape.volume, 100 * 60 * 20 - .pi * 25 * 20, accuracy: 0.5)
    }

    func testBlindCounterboreAndCountersink() {
        let (_, body, cb) = holeDoc { h in
            h.type = .counterbore
            h.diameter = "6 mm"
            h.depth = "15 mm"
            h.headDiameter = "11 mm"
            h.headDepth = "6 mm"
        }
        let expected = 100 * 60 * 20 - .pi * (5.5 * 5.5 * 6 + 3 * 3 * 9)
        XCTAssertEqual(cb.bodies[body]!.shape.volume, expected, accuracy: 0.5)

        let (_, body2, cs) = holeDoc { h in
            h.type = .countersink
            h.extent = .through
            h.diameter = "5 mm"
            h.headDiameter = "10 mm"
            h.countersinkAngle = "90"
        }
        // 90° cone from Ø10 to Ø5 is 2.5 mm deep: frustum + rest of the Ø5 bore.
        let cone = Double.pi * 2.5 / 3 * (25 + 6.25 + 12.5)
        XCTAssertEqual(cs.bodies[body2]!.shape.volume, 100 * 60 * 20 - cone - .pi * 6.25 * 17.5, accuracy: 0.5)
    }

    func testHoleAtExactOffsetsFollowsThePart() {
        var doc = CADDocument()
        doc.parameters = [UserParameter(name: "breite", expression: "100 mm")]
        var sk = Sketch(plane: .xy)
        let c = [sk.addPoint(Vec2(0, 0)), sk.addPoint(Vec2(100, 0)), sk.addPoint(Vec2(100, 60)), sk.addPoint(Vec2(0, 60))]
        sk.points[sk.pointIndex(c[0])!].fixed = true
        let l = (0..<4).map { sk.addLine(c[$0], c[($0 + 1) % 4]) }
        sk.addConstraint(.horizontal(line: l[0])); sk.addConstraint(.vertical(line: l[1]))
        sk.addConstraint(.horizontal(line: l[2])); sk.addConstraint(.vertical(line: l[3]))
        sk.addConstraint(.length(line: l[0], value: "breite"))
        sk.addConstraint(.length(line: l[1], value: "60 mm"))
        let s = Feature(name: "S", kind: .sketch(sk))
        var ex = ExtrudeFeature()
        ex.profiles = [ProfileRef(sketch: s.id, sample: Vec2(5, 5))]
        ex.distance = "20 mm"
        let e = Feature(name: "E", kind: .extrude(ex))
        doc.features = [s, e]
        let top = topFace(build(doc), e.id)
        var h = HoleFeature()
        // 37 mm from the left edge (System 32 front distance), 20 mm from the right edge via the parameter.
        h.points = [.faceOffset(top, x: "37", y: "30"), .faceOffset(top, x: "breite - 20", y: "30")]
        h.extent = .through
        h.diameter = "5 mm"
        doc.features.append(Feature(name: "B", kind: .hole(h)))
        for w in [100.0, 160.0] {
            doc.parameters[0].expression = "\(w) mm"
            let state = build(doc)
            let holes = state.bodies[e.id]!.faceInfos.compactMap { $0 }.filter { $0.surface == .cylinder }.map(\.axisOrigin.x).sorted()
            XCTAssertEqual(holes.count, 2)
            XCTAssertEqual(holes[0], 37, accuracy: 1e-6)
            XCTAssertEqual(holes[1], w - 20, accuracy: 1e-6, "follows the width")
        }
    }

    func testHoleFollowsSketchPoint() {
        var doc = CADDocument()
        doc.parameters = [UserParameter(name: "x", expression: "20 mm")]
        let body = box(&doc)
        var sk = Sketch(plane: .xy)
        let p = sk.addPoint(Vec2(20, 30))
        sk.addConstraint(.horizontalDistance(Sketch.originId, p, value: "x"))
        sk.addConstraint(.verticalDistance(Sketch.originId, p, value: "30 mm"))
        let s = Feature(name: "Punkte", kind: .sketch(sk))
        var h = HoleFeature()
        h.points = [.sketchPoint(sketch: s.id, point: p)]
        h.flip = true      // sketch on the bottom: drill upwards into the part
        h.extent = .through
        h.diameter = "8 mm"
        doc.features += [s, Feature(name: "B", kind: .hole(h))]
        for x in [20.0, 70.0] {
            doc.parameters[0].expression = "\(x) mm"
            let state = build(doc)
            let shape = state.bodies[body]!.shape
            XCTAssertEqual(shape.volume, 100 * 60 * 20 - .pi * 16 * 20, accuracy: 0.5)
            let hole = state.bodies[body]!.faceInfos.compactMap { $0 }.first { $0.surface == .cylinder }!
            XCTAssertEqual(hole.axisOrigin.x, x, accuracy: 1e-6, "hole follows the dimension")
            XCTAssertEqual(hole.radius, 4, accuracy: 1e-9)
        }
    }

    // MARK: Threads

    func testModeledExternalThread() throws {
        var doc = CADDocument()
        var sk = Sketch(plane: .xy)
        sk.addCircle(center: sk.addPoint(.zero), radius: 4)
        let s = Feature(name: "S", kind: .sketch(sk))
        var ex = ExtrudeFeature()
        ex.profiles = [ProfileRef(sketch: s.id, sample: .zero)]
        ex.distance = "12 mm"
        let e = Feature(name: "Bolzen", kind: .extrude(ex))
        doc.features = [s, e]
        var state = build(doc)
        let b = state.bodies[e.id]!
        let cyl = b.faceInfos.compactMap { $0 }.first { $0.surface == .cylinder }!
        XCTAssertEqual(cyl.radius, 4, accuracy: 1e-9)
        XCTAssertEqual(cyl.axisRange.upperBound - cyl.axisRange.lowerBound, 12, accuracy: 1e-6)
        var t = ThreadFeature()
        t.faces = [BodyFaceRef(body: e.id, face: b.faceRef(cyl.index)!)]
        doc.features.append(Feature(name: "G", kind: .thread(t)))
        let start = Date()
        state = build(doc)
        let threaded = state.bodies[e.id]!.shape
        XCTAssertEqual(threaded.solidCount, 1)
        // Groove inside the material: V-section 0.339 mm² at mean radius 3.744 mm per turn (Pappus), ≈ 8.4 turns.
        let turns = (12 - 0.957 - 2 * 0.15 * 1.25) / 1.25
        XCTAssertEqual(Double.pi * 16 * 12 - threaded.volume, 0.339 * 2 * .pi * 3.744 * turns, accuracy: 4)
        // M8: the groove removes material between Ø8 and the minor diameter (≈ Ø6.47), roughly half of it.
        let full = Double.pi * 16 * 12
        let core = Double.pi * pow(4 - 0.6134 * 1.25, 2) * 12
        XCTAssertLessThan(threaded.volume, full - 0.3 * (full - core))
        XCTAssertGreaterThan(threaded.volume, core)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "thread must build in reasonable time")
    }

    func testTappedHoleAndCosmeticThread() {
        let (_, body, state) = holeDoc { h in
            h.thread = "M6"
            h.depth = "12 mm"
        }
        let v = state.bodies[body]!.shape.volume
        let drilled = 100 * 60 * 20 - .pi * 2.5 * 2.5 * 12
        XCTAssertLessThan(v, drilled - 5, "groove cut beyond the tap drill")
        XCTAssertGreaterThan(v, 100 * 60 * 20 - .pi * 3.1 * 3.1 * 12)

        let (_, body2, marked) = holeDoc { h in
            h.thread = "M6"
            h.threadModeled = false
        }
        XCTAssertEqual(marked.bodies[body2]!.shape.volume, 100 * 60 * 20 - .pi * 2.5 * 2.5 * 10, accuracy: 0.5)
        XCTAssertEqual(marked.threadMarks.first?.name, "M6")
    }

    func testInternalThreadInExistingHoleDetectsSize() {
        var (doc, body, state) = holeDoc { h in
            h.extent = .through
            h.diameter = "6.8 mm"
        }
        let b = state.bodies[body]!
        let hole = b.faceInfos.compactMap { $0 }.first { $0.surface == .cylinder }!
        var t = ThreadFeature()
        t.faces = [BodyFaceRef(body: body, face: b.faceRef(hole.index)!)]
        doc.features.append(Feature(name: "G", kind: .thread(t)))
        state = build(doc)
        let drilled = 100 * 60 * 20 - Double.pi * 3.4 * 3.4 * 20
        let v = state.bodies[body]!.shape.volume
        // M8 internal: material removed out to about Ø8, roughly half of the ring between Ø6.8 and Ø8.
        let ring = Double.pi * (16 - 3.4 * 3.4) * 20
        XCTAssertLessThan(v, drilled - 0.3 * ring)
        XCTAssertGreaterThan(v, drilled - 0.8 * ring)
        XCTAssertEqual(state.bodies[body]!.shape.solidCount, 1)
    }

    func testThreadTable() {
        XCTAssertEqual(MetricThread.matching(diameter: 8, isInternal: false)?.name, "M8")
        XCTAssertEqual(MetricThread.matching(diameter: 6.8, isInternal: true)?.name, "M8")
        XCTAssertEqual(MetricThread.named("M10")?.pitch, 1.5)
    }

    // MARK: Patterns

    func testRectangularPatternOfHoles() {
        var (doc, body, _) = holeDoc { h in
            h.extent = .through
            h.diameter = "4 mm"
        }
        doc.features[2].kind = {
            guard case var .hole(h) = doc.features[2].kind else { fatalError() }
            h.points = [.face(topFace(build(Array(doc.features.prefix(2))), body), position: Vec3(10, 10, 20))]
            return .hole(h)
        }()
        var p = PatternFeature()
        p.features = [doc.features[2].id]
        p.direction = .x
        p.count = "4"
        p.spacing = "25 mm"
        p.direction2 = .y
        p.count2 = "2"
        p.spacing2 = "32 mm"
        doc.features.append(Feature(name: "M", kind: .pattern(p)))
        let state = build(doc)
        XCTAssertEqual(state.bodies[body]!.shape.volume, 100 * 60 * 20 - 8 * .pi * 4 * 20, accuracy: 1)
        XCTAssertEqual(state.bodyOrder.count, 1)
    }

    func build(_ features: [Feature]) -> ModelState {
        var d = CADDocument()
        d.features = features
        return ModelBuilder().build(d)
    }

    func testCircularPatternAndMirrorOfBodies() {
        var doc = CADDocument()
        let body = box(&doc, w: 10, d: 10, height: 5, at: Vec2(40, -5))
        var c = PatternFeature()
        c.kind = .circular
        c.bodies = [body]
        c.axis = .z
        c.circularCount = "6"
        let pat = Feature(name: "Kreis", kind: .pattern(c))
        doc.features.append(pat)
        var state = build(doc)
        XCTAssertEqual(state.bodyOrder.count, 6)
        // The copy at 180° sits on the negative X side.
        let xs = state.orderedBodies.map { ($0.shape.boundingBox!.min.x + $0.shape.boundingBox!.max.x) / 2 }
        XCTAssertEqual(xs.min()!, -45, accuracy: 1e-6)

        var m = PatternFeature()
        m.kind = .mirror
        m.bodies = [body]
        m.plane = .xz
        doc.features[doc.features.count - 1] = Feature(id: pat.id, name: "Spiegel", kind: .pattern(m))
        state = build(doc)
        XCTAssertEqual(state.bodyOrder.count, 2)
        let mirrored = state.orderedBodies[1].shape
        XCTAssertEqual(mirrored.volume, 500, accuracy: 1e-6, "mirror keeps a valid, positive solid")
        XCTAssertEqual(mirrored.boundingBox!.min.y, -5, accuracy: 1e-6)
        // Ids of copies stay stable across rebuilds.
        XCTAssertEqual(build(doc).bodyOrder, state.bodyOrder)
    }

    // MARK: Move and combine

    func testMoveRotateCopy() {
        var doc = CADDocument()
        let body = box(&doc, w: 20, d: 10, height: 10)
        var m = MoveFeature()
        m.bodies = [body]
        m.axis = .z
        m.angle = "90"
        m.dx = "100 mm"
        m.copy = true
        doc.features.append(Feature(name: "V", kind: .move(m)))
        let state = build(doc)
        XCTAssertEqual(state.bodyOrder.count, 2)
        let bb = state.orderedBodies[1].shape.boundingBox!
        // 20 × 10 turned by 90° about Z lies in x ∈ [-10, 0], y ∈ [0, 20]; then shifted by 100 in X.
        XCTAssertEqual(bb.min.x, 90, accuracy: 1e-6)
        XCTAssertEqual(bb.max.y, 20, accuracy: 1e-6)
        XCTAssertEqual(state.orderedBodies[0].shape.boundingBox!.min.x, 0, accuracy: 1e-6, "original stays")
    }

    func testCombineCutKeepsOrRemovesTool() {
        var doc = CADDocument()
        let a = box(&doc, w: 50, d: 50, height: 20)
        let b = box(&doc, w: 10, d: 10, height: 40, at: Vec2(20, 20))
        // The second extrusion would join; make it a separate body.
        if case var .extrude(e) = doc.features[3].kind { e.operation = .newBody; doc.features[3].kind = .extrude(e) }
        var c = CombineFeature()
        c.target = a
        c.tools = [b]
        c.operation = .cut
        doc.features.append(Feature(name: "K", kind: .combine(c)))
        var state = build(doc)
        XCTAssertEqual(state.bodyOrder, [a])
        XCTAssertEqual(state.bodies[a]!.shape.volume, 50 * 50 * 20 - 100 * 20, accuracy: 1e-6)
        c.keepTools = true
        doc.features[4].kind = .combine(c)
        state = build(doc)
        XCTAssertEqual(state.bodyOrder.count, 2)
    }

    func testFormatVersion5RoundTrip() throws {
        var (doc, _, _) = holeDoc { $0.thread = "M5" }
        var p = PatternFeature()
        p.kind = .mirror
        p.plane = .construction(UUID())
        doc.features.append(Feature(name: "P", kind: .pattern(p)))
        let back = try CADDocument.decode(try doc.encoded())
        XCTAssertEqual(back, doc)
        XCTAssertGreaterThanOrEqual(CADDocument.currentFormatVersion, 5)
    }
}
