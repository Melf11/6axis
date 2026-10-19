import XCTest
import simd
@testable import SixAxisCore

final class MeasureTests: XCTestCase {
    func body(_ s: Shape) -> BuiltBody { BuiltBody(id: UUID(), shape: s, sourceFeature: UUID()) }

    func face(_ b: BuiltBody, normal: Vec3) -> Int {
        b.faceInfos.compactMap { $0 }.first { $0.isPlanar && simd_dot($0.normal, normal) > 0.999 }!.index
    }

    func testFacesEdgesDistanceAngle() throws {
        let b = body(try Shape.box(min: .zero, max: Vec3(100, 60, 20)))
        let top = face(b, normal: Vec3(0, 0, 1)), bottom = face(b, normal: Vec3(0, 0, -1)), side = face(b, normal: Vec3(1, 0, 0))
        let one = Measure.measure([.face(b, top)])
        XCTAssertEqual(one.rows.first?.value ?? 0, 6000, accuracy: 1e-6)
        let two = Measure.measure([.face(b, top), .face(b, bottom)])
        XCTAssertEqual(two.rows.first { $0.label == "Abstand" }?.value ?? 0, 20, accuracy: 1e-6)
        XCTAssertEqual(two.rows.first { $0.label == "Winkel" }?.value ?? -1, 0, accuracy: 1e-6)
        let angle = Measure.measure([.face(b, top), .face(b, side)])
        XCTAssertEqual(angle.rows.first { $0.label == "Winkel" }?.value ?? 0, 90, accuracy: 1e-6)
        let edge = b.edgeInfos.compactMap { $0 }.first { abs($0.length - 100) < 1e-6 }!.index
        XCTAssertEqual(Measure.measure([.edge(b, edge)]).rows.first?.value ?? 0, 100, accuracy: 1e-6)
    }

    func testHoleSpacing() throws {
        var doc = CADDocument()
        var sk = Sketch(plane: .xy)
        let c = [sk.addPoint(Vec2(0, 0)), sk.addPoint(Vec2(100, 0)), sk.addPoint(Vec2(100, 60)), sk.addPoint(Vec2(0, 60))]
        for i in 0..<4 { sk.addLine(c[i], c[(i + 1) % 4]) }
        sk.addCircle(center: sk.addPoint(Vec2(20, 30)), radius: 4)
        sk.addCircle(center: sk.addPoint(Vec2(52, 30)), radius: 4)
        let s = Feature(name: "S", kind: .sketch(sk))
        var ex = ExtrudeFeature()
        ex.profiles = [ProfileRef(sketch: s.id, sample: Vec2(80, 50))]
        ex.distance = "20 mm"
        let e = Feature(name: "E", kind: .extrude(ex))
        doc.features = [s, e]
        let b = ModelBuilder().build(doc).bodies[e.id]!
        let holes = b.faceInfos.compactMap { $0 }.filter { $0.surface == .cylinder }
        XCTAssertEqual(holes.count, 2)
        let r = Measure.measure([.face(b, holes[0].index), .face(b, holes[1].index)])
        XCTAssertEqual(r.rows.first { $0.label == "Achsabstand" }?.value ?? 0, 32, accuracy: 1e-6)
        XCTAssertEqual(r.rows.first { $0.label == "Abstand" }?.value ?? 0, 24, accuracy: 1e-6)
        XCTAssertEqual(Measure.measure([.face(b, holes[0].index)]).rows.first { $0.label == "Durchmesser" }?.value ?? 0, 8, accuracy: 1e-9)
    }

    /// Outward normals of the faces at an edge: the fillet/chamfer arrow points along their bisector.
    func testEdgeFaceNormals() throws {
        let box = body(try Shape.box(min: .zero, max: Vec3(100, 60, 20)))
        let edge = box.edgeInfos.compactMap { $0 }.first { simd_distance($0.midpoint, Vec3(50, 0, 20)) < 1e-6 }!.index
        let n = box.edgeFaceNormals(edge)
        XCTAssertEqual(n.count, 2)
        XCTAssertEqual(simd_length(n.reduce(.zero, +) - Vec3(0, -1, 1)), 0, accuracy: 1e-9)

        // Rim of a hole: the wall's outward normal points into the hole, towards the axis.
        var doc = CADDocument()
        var sk = Sketch(plane: .xy)
        let c = [sk.addPoint(Vec2(0, 0)), sk.addPoint(Vec2(100, 0)), sk.addPoint(Vec2(100, 60)), sk.addPoint(Vec2(0, 60))]
        for i in 0..<4 { sk.addLine(c[i], c[(i + 1) % 4]) }
        sk.addCircle(center: sk.addPoint(Vec2(20, 30)), radius: 4)
        let s = Feature(name: "S", kind: .sketch(sk))
        var ex = ExtrudeFeature()
        ex.profiles = [ProfileRef(sketch: s.id, sample: Vec2(80, 50))]
        ex.distance = "20 mm"
        let e = Feature(name: "E", kind: .extrude(ex))
        doc.features = [s, e]
        let b = ModelBuilder().build(doc).bodies[e.id]!
        let rim = b.edgeInfos.compactMap { $0 }.first { $0.kind == .circle && abs($0.center.z - 20) < 1e-6 }!
        let rn = b.edgeFaceNormals(rim.index)
        XCTAssertEqual(rn.count, 2, "\(rn)")
        let radial = simd_normalize(Vec3(rim.midpoint.x - 20, rim.midpoint.y - 30, 0))
        XCTAssertTrue(rn.contains { simd_dot($0, Vec3(0, 0, 1)) > 0.999 }, "\(rn)")
        XCTAssertTrue(rn.contains { simd_dot($0, -radial) > 0.999 }, "\(rn)")
    }
}
