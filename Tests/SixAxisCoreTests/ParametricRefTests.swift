import XCTest
@testable import SixAxisCore

/// References must survive parameter changes that move geometry (profiles, edges, faces).
final class ParametricRefTests: XCTestCase {
    /// Rectangle at the origin, width = parameter `breite`, height 50; extruded 20; vertical edges filleted R5.
    func makeDoc(width: String) -> (CADDocument, UUID) {
        var doc = CADDocument()
        doc.parameters = [UserParameter(name: "breite", expression: "300 mm")]
        var sk = Sketch(plane: .xy)
        let p = [sk.addPoint(Vec2(0, 0)), sk.addPoint(Vec2(300, 0)), sk.addPoint(Vec2(300, 50)), sk.addPoint(Vec2(0, 50))]
        sk.addConstraint(.coincident(Sketch.originId, p[0]))
        let l = (0..<4).map { sk.addLine(p[$0], p[($0 + 1) % 4]) }
        sk.addConstraint(.horizontal(line: l[0]))
        sk.addConstraint(.vertical(line: l[1]))
        sk.addConstraint(.horizontal(line: l[2]))
        sk.addConstraint(.vertical(line: l[3]))
        sk.addConstraint(.length(line: l[0], value: "breite"))
        sk.addConstraint(.length(line: l[1], value: "50 mm"))
        let sketch = Feature(name: "S", kind: .sketch(sk))
        doc.features = [sketch]
        let sb = ModelBuilder().build(doc).sketches[sketch.id]!
        var ex = ExtrudeFeature()
        ex.profiles = [sb.profileRef(sb.regions[0])]
        ex.distance = "20 mm"
        let e = Feature(name: "E", kind: .extrude(ex))
        doc.features.append(e)
        let body = ModelBuilder().build(doc).bodies[e.id]!
        var f = FilletFeature()
        f.radius = "5 mm"
        f.edges = body.edgeInfos.compactMap { $0 }.filter { $0.kind == .line && abs($0.end.z - $0.start.z) > 1 }
            .map { BodyEdgeRef(body: e.id, edge: body.edgeRef($0.index)!) }
        XCTAssertEqual(f.edges.count, 4)
        doc.features.append(Feature(name: "F", kind: .fillet(f)))
        doc.parameters[0].expression = width
        return (doc, e.id)
    }

    func volume(width: Double) -> Double { (width * 50 - (4 - .pi) * 25) * 20 }

    func testShrinkKeepsProfileAndFillets() {
        for w in [300.0, 100.0, 40.0, 900.0] {
            let (doc, id) = makeDoc(width: "\(w) mm")
            let state = ModelBuilder().build(doc)
            XCTAssertTrue(state.errors.isEmpty, "breite \(w): \(state.errors)")
            XCTAssertEqual(state.bodies[id]?.shape.volume ?? 0, volume(width: w), accuracy: 1, "breite \(w)")
        }
    }

    func testOldFilesWithoutAnchorStillWork() throws {
        var (doc, _) = makeDoc(width: "300 mm")
        if case var .extrude(e) = doc.features[1].kind {
            e.profiles[0].anchor = nil
            doc.features[1].kind = .extrude(e)
        }
        let json = try doc.encoded()
        let back = try CADDocument.decode(json)
        XCTAssertTrue(ModelBuilder().build(back).errors.isEmpty)
        // A 0.9 file has no anchor/count keys at all.
        let stripped = String(data: json, encoding: .utf8)!
            .replacingOccurrences(of: #","anchor":null"#, with: "")
        XCTAssertNoThrow(try CADDocument.decode(Data(stripped.utf8)))
    }

    /// Plate with a hole that stays centred: both the ring and the disc must follow `breite`.
    func testRingAndDiscFollowParameter() {
        var doc = CADDocument()
        doc.parameters = [UserParameter(name: "breite", expression: "200 mm")]
        var sk = Sketch(plane: .xy)
        let p = [sk.addPoint(Vec2(0, 0)), sk.addPoint(Vec2(200, 0)), sk.addPoint(Vec2(200, 60)), sk.addPoint(Vec2(0, 60))]
        let l = (0..<4).map { sk.addLine(p[$0], p[($0 + 1) % 4]) }
        sk.addConstraint(.coincident(Sketch.originId, p[0]))
        for (i, c) in l.enumerated() { sk.addConstraint(i % 2 == 0 ? .horizontal(line: c) : .vertical(line: c)) }
        sk.addConstraint(.length(line: l[0], value: "breite"))
        sk.addConstraint(.length(line: l[1], value: "60 mm"))
        let c = sk.addPoint(Vec2(100, 30))
        let circle = sk.addCircle(center: c, radius: 10)
        sk.addConstraint(.horizontalDistance(Sketch.originId, c, value: "breite / 2"))
        sk.addConstraint(.verticalDistance(Sketch.originId, c, value: "30 mm"))
        sk.addConstraint(.radius(curve: circle, value: "10 mm"))
        let sketch = Feature(name: "S", kind: .sketch(sk))
        doc.features = [sketch]
        let sb = ModelBuilder().build(doc).sketches[sketch.id]!
        XCTAssertEqual(sb.regions.count, 2)
        let ring = sb.regions.max { $0.area < $1.area }!, disc = sb.regions.min { $0.area < $1.area }!
        var e1 = ExtrudeFeature(); e1.profiles = [sb.profileRef(ring)]; e1.distance = "10 mm"
        var e2 = ExtrudeFeature(); e2.profiles = [sb.profileRef(disc)]; e2.distance = "30 mm"
        let f1 = Feature(name: "Platte", kind: .extrude(e1)), f2 = Feature(name: "Zapfen", kind: .extrude(e2))
        doc.features += [f1, f2]
        for w in [200.0, 60.0, 500.0] {
            doc.parameters[0].expression = "\(w) mm"
            let state = ModelBuilder().build(doc)
            XCTAssertTrue(state.errors.isEmpty, "breite \(w): \(state.errors)")
            XCTAssertEqual(state.bodies[f1.id]?.shape.volume ?? 0, (w * 60 - .pi * 100) * 10, accuracy: 1, "Platte \(w)")
            XCTAssertEqual(state.bodies[f2.id]?.shape.volume ?? 0, .pi * 100 * 30, accuracy: 1, "Zapfen \(w)")
        }
    }
}
