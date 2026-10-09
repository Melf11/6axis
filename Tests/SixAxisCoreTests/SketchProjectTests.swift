import simd
import XCTest
@testable import SixAxisCore

final class SketchProjectTests: XCTestCase {
    func regionAreas(_ sk: Sketch) -> [Double] {
        var doc = CADDocument()
        let f = Feature(name: "S", kind: .sketch(sk))
        doc.features = [f]
        return ModelBuilder().build(doc).sketches[f.id]!.regions.map(\.area).sorted()
    }

    func testProjectTopFaceOfBoxIsAProfile() throws {
        let box = try Shape.box(min: Vec3(10, 20, 0), max: Vec3(70, 60, 19))
        let body = BuiltBody(id: UUID(), shape: box, sourceFeature: UUID())
        let top = try XCTUnwrap(body.faceInfos.compactMap { $0 }.first { $0.normal.z > 0.99 })
        var sk = Sketch(plane: .xy)
        let curves = SketchEdit.projectFace(&sk, body: body, face: top.index, plane: .xy)
        XCTAssertEqual(curves.count, 4)
        XCTAssertTrue(sk.curves.allSatisfy(\.isLine))
        let areas = regionAreas(sk)
        XCTAssertEqual(areas.count, 1)
        XCTAssertEqual(areas[0], 60 * 40, accuracy: 1e-6)
        XCTAssertTrue(sk.points.allSatisfy(\.fixed), "projected geometry is fixed reference")
        XCTAssertEqual(sk.points.count, 1 + 4, "corners shared between the four edges")
    }

    func testProjectCylinderEdgeIsCircle() throws {
        var sk = Sketch(plane: .xy)
        sk.addCircle(center: sk.addPoint(Vec2(5, 5)), radius: 12)
        var doc = CADDocument()
        let s = Feature(name: "S", kind: .sketch(sk))
        doc.features = [s]
        let sb = ModelBuilder().build(doc).sketches[s.id]!
        var ex = ExtrudeFeature()
        ex.profiles = [sb.profileRef(sb.regions[0])]
        ex.distance = "20"
        let e = Feature(name: "E", kind: .extrude(ex))
        doc.features.append(e)
        let body = try XCTUnwrap(ModelBuilder().build(doc).bodies[e.id])
        let rim = try XCTUnwrap(body.edgeInfos.compactMap { $0 }.first { $0.kind == .circle && $0.midpoint.z > 19 })
        var target = Sketch(plane: .xy)
        let made = SketchEdit.projectEdge(&target, body: body, edge: rim.index, plane: .xy)
        XCTAssertEqual(made.count, 1)
        guard case let .circle(c, r) = target.curve(made[0])!.geometry else { return XCTFail("not a circle") }
        XCTAssertEqual(r, 12, accuracy: 0.05)
        XCTAssertEqual(simd_distance(target.point(c)!, Vec2(5, 5)), 0, accuracy: 0.05)
    }

    func testJoinUnorderedSegments() {
        let segs = [(Vec2(1, 0), Vec2(2, 0)), (Vec2(0, 0), Vec2(1, 0)), (Vec2(2, 0), Vec2(2, 1))]
        let polys = SketchEdit.polylines(from: segs)
        XCTAssertEqual(polys.count, 1)
        XCTAssertEqual(polys[0].count, 4)
    }
}
